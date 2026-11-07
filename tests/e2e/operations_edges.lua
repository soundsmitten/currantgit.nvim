-- Adversarial cases for slice 3 of docs/issues/0010: odd markers and paths,
-- worktrees, the --apply rebase backend, stale status, multi-commit picks.
-- Verdicts come from real Git and the filesystem only.

local h = require("e2e.harness")
local expect, equal = h.expect, h.equal

local function conflict_on(s, path, ours, theirs)
  s:write(path, "a\nb\nc\n")
  s:git({ "add", "--", path })
  s:git({ "commit", "-q", "-m", "base" })
  s:git({ "checkout", "-q", "-b", "side" })
  s:write(path, "a\n" .. theirs .. "\nc\n")
  s:git({ "commit", "-q", "-am", "theirs" })
  s:git({ "checkout", "-q", "main" })
  s:write(path, "a\n" .. ours .. "\nc\n")
  s:git({ "commit", "-q", "-am", "ours" })
end

local function unmerged(s) return s:git({ "ls-files", "-u" }) end
local function messages(s) return s:eval("vim.api.nvim_exec2('messages', { output = true }).output") end
local function has_line(s, text) return vim.tbl_contains(s:lines(), text) end
local function short(s, rev) return s:git({ "rev-parse", "--short=7", rev }) end
local function answer(s, choice)
  s:wait("confirmation prompt", function() return s:mode().mode == "c" end)
  s:keys(choice .. "<CR>")
end

return {
  {
    name = "operation edge: conflict-marker-size 9 still blocks s",
    fixture = function(s)
      s:write(".gitattributes", "*.txt conflict-marker-size=9\n")
      s:git({ "add", ".gitattributes" })
      conflict_on(s, "f.txt", "OURS", "THEIRS")
      s:git({ "merge", "-q", "side" }, { allow_failure = true })
    end,
    run = function(s)
      expect(s:read("f.txt"):find("<<<<<<<<< HEAD", 1, true), "Git wrote 9-character markers")
      local stages = unmerged(s)
      s:open_status()
      s:search("f.txt")
      s:keys("s")
      s:wait("refusal", function() return messages(s):find("conflict markers", 1, true) ~= nil end)
      s:settle()
      equal(unmerged(s), stages, "nothing staged")
    end,
  },
  {
    name = "operation edge: conflict-marker-size 5 (shorter than 7) still blocks s",
    fixture = function(s)
      s:write(".gitattributes", "*.txt conflict-marker-size=5\n")
      s:git({ "add", ".gitattributes" })
      conflict_on(s, "f.txt", "OURS", "THEIRS")
      s:git({ "merge", "-q", "side" }, { allow_failure = true })
    end,
    run = function(s)
      expect(s:read("f.txt"):find("<<<<< HEAD", 1, true), "Git wrote 5-character markers")
      local stages = unmerged(s)
      s:open_status()
      s:search("f.txt")
      s:keys("s")
      s:wait("refusal", function() return messages(s):find("conflict markers", 1, true) ~= nil end)
      s:settle()
      equal(unmerged(s), stages, "nothing staged")
    end,
  },
  {
    name = "operation edge: CRLF markers block s; a Markdown ======= heading does not",
    fixture = function(s)
      conflict_on(s, "f.txt", "OURS", "THEIRS")
      s:git({ "merge", "-q", "side" }, { allow_failure = true })
      s:write("f.txt", "a\r\n<<<<<<< HEAD\r\nOURS\r\n=======\r\nTHEIRS\r\n>>>>>>> side\r\nc\r\n")
    end,
    run = function(s)
      local stages = unmerged(s)
      s:open_status()
      s:search("f.txt")
      s:keys("s")
      s:wait("refusal", function() return messages(s):find("conflict markers", 1, true) ~= nil end)
      s:settle()
      equal(unmerged(s), stages, "CRLF markers still block")
      s:write("f.txt", "Title\n=======\nbody\n")
      s:search("f.txt")
      s:press("s", "status after s")
      s:wait("staged", function() return unmerged(s) == "" end)
    end,
  },
  {
    name = "operation edge: s and R on a path with spaces, unicode and a leading dash",
    fixture = function(s)
      conflict_on(s, "-weird name é.txt", "OURS", "THEIRS")
      s:git({ "merge", "-q", "side" }, { allow_failure = true })
    end,
    run = function(s)
      local path = "-weird name é.txt"
      local stages = unmerged(s)
      s:write(path, "a\npartial\nc\n")
      s:open_status()
      s:search(path)
      s:keys("R")
      answer(s, "1")
      s:wait("markers back", function() return (s:read(path) or ""):find("<<<<<<<", 1, true) ~= nil end)
      equal(unmerged(s), stages, "stages intact")
      s:write(path, "a\nRESOLVED\nc\n")
      s:settle()
      s:search(path)
      s:press("s", "status after s")
      s:wait("resolved", function() return unmerged(s) == "" end)
      equal(s:git({ "show", ":0:" .. path }), "a\nRESOLVED\nc", "staged as written")
    end,
  },
  {
    name = "operation edge: a merge in a linked worktree shows there, not in the main checkout",
    fixture = function(s)
      conflict_on(s, "f.txt", "OURS", "THEIRS")
      local wt = s.dir .. "-wt"
      s:git({ "worktree", "add", "-q", "-b", "wt", wt, "main" })
      vim.system({ "git", "-C", wt, "merge", "-q", "side" }, { env = { GIT_CONFIG_GLOBAL = "/dev/null" } }):wait()
      s.worktree = wt
    end,
    run = function(s)
      s:open_status()
      for _, line in ipairs(s:lines()) do
        expect(not line:match("^Merging "), "main checkout must not show the worktree's merge")
      end
      expect(s:eval("vim.fn.maparg('rr', 'n')") == "", "no rr in the main checkout")
      s:keys(":cd " .. vim.fn.fnameescape(s.worktree) .. "<CR>")
      s:open_status()
      s:wait("worktree header", function()
        return has_line(s, "Merging " .. short(s, "side"))
      end)
    end,
  },
  {
    name = "operation edge: the --apply rebase backend is recognized and continues",
    fixture = function(s)
      conflict_on(s, "f.txt", "OURS", "THEIRS")
      s:git({ "checkout", "-q", "side" })
      s:git({ "rebase", "-q", "--apply", "main" }, { allow_failure = true })
    end,
    run = function(s)
      expect(vim.uv.fs_stat(s.dir .. "/.git/rebase-apply") ~= nil, "Git used the apply backend")
      s:open_status()
      s:wait("rebase header", function()
        return has_line(s, ("Rebasing side onto %s (1/1)"):format(short(s, "main")))
      end)
      s:write("f.txt", "a\nAPPLIED\nc\n")
      s:git({ "add", "f.txt" })
      s:keys("rr")
      s:wait("rebase finished", function() return vim.uv.fs_stat(s.dir .. "/.git/rebase-apply") == nil end)
      equal(s:git({ "log", "--format=%s" }), "theirs\nours\nbase", "replayed on main")
    end,
  },
  {
    name = "operation edge: ra refuses when the operation changed behind status",
    fixture = function(s)
      conflict_on(s, "f.txt", "OURS", "THEIRS")
      s:git({ "merge", "-q", "side" }, { allow_failure = true })
    end,
    run = function(s)
      s:open_status()
      s:wait("merge header", function() return has_line(s, "Merging " .. short(s, "side")) end)
      -- Outside Neovim: abort the merge and start a rebase instead.
      s:git({ "merge", "--abort" })
      s:git({ "checkout", "-q", "side" })
      s:git({ "rebase", "-q", "main" }, { allow_failure = true })
      local side_before = s:git({ "rev-parse", "side" })
      s:keys("ra")
      s:wait("refusal", function() return messages(s):find("changed since status was drawn", 1, true) ~= nil end)
      s:settle()
      expect(vim.uv.fs_stat(s.dir .. "/.git/rebase-merge") ~= nil, "the rebase is still in progress")
      equal(s:git({ "rev-parse", "side" }), side_before, "nothing aborted")
    end,
  },
  {
    name = "operation edge: a multi-commit cherry-pick skips one and continues the rest",
    fixture = function(s)
      conflict_on(s, "f.txt", "OURS", "THEIRS")
      s:git({ "checkout", "-q", "side" })
      s:write("g.txt", "g\n")
      s:git({ "add", "g.txt" })
      s:git({ "commit", "-q", "-m", "side g" })
      s:git({ "checkout", "-q", "main" })
      s:git({ "cherry-pick", "side~1", "side" }, { allow_failure = true })
    end,
    run = function(s)
      s:open_status()
      s:wait("pick header", function() return has_line(s, "Cherry-picking " .. short(s, "side~1")) end)
      expect(s:eval("vim.fn.maparg('rs', 'n')") ~= "", "rs offered for cherry-pick")
      s:keys("rs")
      s:wait("sequence finished", function() return s:git({ "log", "--format=%s" }) == "side g\nours\nbase" end)
      equal(s:read("f.txt"), "a\nOURS\nc\n", "skipped pick left no trace")
    end,
  },
  {
    name = "operation edge: R is not offered on a delete/modify conflict",
    fixture = function(s)
      s:write("f.txt", "a\n")
      s:git({ "add", "." })
      s:git({ "commit", "-q", "-m", "base" })
      s:git({ "checkout", "-q", "-b", "side" })
      s:git({ "rm", "-q", "f.txt" })
      s:git({ "commit", "-q", "-m", "delete" })
      s:git({ "checkout", "-q", "main" })
      s:write("f.txt", "changed\n")
      s:git({ "commit", "-q", "-am", "modify" })
      s:git({ "merge", "-q", "side" }, { allow_failure = true })
    end,
    run = function(s)
      local stages, content = unmerged(s), s:read("f.txt")
      s:open_status()
      s:search("f.txt")
      s:keys("R")
      vim.wait(600)
      s:settle()
      expect(s:mode().mode == "n", "no prompt opened")
      equal(unmerged(s), stages, "stages intact")
      equal(s:read("f.txt"), content, "file intact")
      s:keys(':let v:errmsg = ""<CR>')
    end,
  },
  {
    name = "operation edge: ra on a merge keeps untracked files",
    fixture = function(s)
      conflict_on(s, "f.txt", "OURS", "THEIRS")
      s:git({ "merge", "-q", "side" }, { allow_failure = true })
      s:write("notes.txt", "my notes\n")
    end,
    run = function(s)
      s:open_status()
      s:keys("ra")
      answer(s, "1")
      s:wait("aborted", function()
        return s:git({ "rev-parse", "-q", "--verify", "MERGE_HEAD" }, { allow_failure = true }) == ""
      end)
      equal(s:read("notes.txt"), "my notes\n", "untracked file survives")
    end,
  },
}
