-- Conflict resolution's Git side (docs/issues/0010, slice 3): the in-progress
-- operation header, rr/rs/ra, marking a file resolved, and R to restore a
-- conflict. Every verdict reads real Git and the filesystem.

local h = require("e2e.harness")
local expect, equal = h.expect, h.equal

local CONFLICTED = "a\n<<<<<<< HEAD\nOURS\n=======\nTHEIRS\n>>>>>>> side\nc\n"

-- main and side both change line 2 of f.txt and g.txt; side adds a commit
-- touching only h.txt so a rebase has two steps.
local function branches(s)
  s:write("f.txt", "a\nb\nc\n")
  s:write("g.txt", "a\nb\nc\n")
  s:git({ "add", "." })
  s:git({ "commit", "-q", "-m", "base" })
  s:git({ "checkout", "-q", "-b", "side" })
  s:write("f.txt", "a\nTHEIRS\nc\n")
  s:write("g.txt", "a\nTHEIRS\nc\n")
  s:git({ "commit", "-q", "-am", "theirs" })
  s:write("h.txt", "h\n")
  s:git({ "add", "h.txt" })
  s:git({ "commit", "-q", "-m", "side extra" })
  s:git({ "checkout", "-q", "main" })
  s:write("f.txt", "a\nOURS\nc\n")
  s:write("g.txt", "a\nOURS\nc\n")
  s:git({ "commit", "-q", "-am", "ours" })
end

local function merging(s)
  branches(s)
  s:git({ "merge", "-q", "side" }, { allow_failure = true })
end

local function rebasing(s)
  branches(s)
  s:git({ "checkout", "-q", "side" })
  s:git({ "rebase", "-q", "main" }, { allow_failure = true })
end

local function short(s, rev) return s:git({ "rev-parse", "--short=7", rev }) end
local function head(s) return s:git({ "rev-parse", "HEAD" }) end
local function unmerged(s) return s:git({ "ls-files", "-u" }) end
local function messages(s) return s:eval("vim.api.nvim_exec2('messages', { output = true }).output") end
local function has_line(s, text) return vim.tbl_contains(s:lines(), text) end
local function mapped(s, lhs) return s:eval("vim.fn.maparg(...)", lhs, "n") ~= "" end

local function answer(s, choice)
  s:wait("confirmation prompt", function() return s:mode().mode == "c" end)
  s:keys(choice .. "<CR>")
end

local function editor(s, name)
  s:wait(name, function()
    return s:eval("vim.fn.expand('%:t')") == name and s:mode().mode == "n"
  end)
end

return {
  {
    name = "operation: status names a merge, rebase, cherry-pick and revert in progress",
    fixture = merging,
    run = function(s)
      s:open_status()
      s:wait("merge header", function() return has_line(s, "Merging " .. short(s, "MERGE_HEAD")) end)
      s:git({ "merge", "--abort" })
      s:git({ "checkout", "-q", "side" })
      s:git({ "rebase", "-q", "main" }, { allow_failure = true })
      s:keys("r")
      s:wait("rebase header", function()
        return has_line(s, ("Rebasing side onto %s (1/2)"):format(short(s, "main")))
      end)
      s:git({ "rebase", "--abort" })
      s:git({ "checkout", "-q", "main" })
      s:git({ "cherry-pick", "side~1" }, { allow_failure = true })
      s:keys("r")
      s:wait("cherry-pick header", function() return has_line(s, "Cherry-picking " .. short(s, "side~1")) end)
      s:git({ "cherry-pick", "--abort" })
      s:write("f.txt", "a\nOURS2\nc\n")
      s:git({ "commit", "-q", "-am", "ours2" })
      s:git({ "revert", "--no-edit", "HEAD~1" }, { allow_failure = true })
      s:keys("r")
      s:wait("revert header", function() return has_line(s, "Reverting " .. short(s, "HEAD~1")) end)
      s:git({ "revert", "--abort" })
      s:keys("r")
      s:wait("no header once clean", function()
        for _, line in ipairs(s:lines()) do
          if line:match("^Merging ") or line:match("^Rebasing ") or line:match("^Cherry%-picking ")
            or line:match("^Reverting ") then return false end
        end
        return true
      end)
    end,
  },
  {
    name = "operation: - on a conflict row never drops the conflict stages",
    fixture = merging,
    run = function(s)
      local stages = unmerged(s)
      s:open_status()
      s:search("f.txt")
      s:keys("-")
      s:wait("refusal", function() return messages(s):find("conflict markers", 1, true) ~= nil end)
      s:settle()
      equal(unmerged(s), stages, "all three stages still in the index")
      equal(s:read("f.txt"), CONFLICTED, "worktree untouched")
    end,
  },
  {
    name = "operation: s refuses a file that still has conflict markers",
    fixture = merging,
    run = function(s)
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
    name = "operation: s refuses while the file has unsaved edits in a buffer",
    fixture = merging,
    run = function(s)
      local stages = unmerged(s)
      s:write("f.txt", "a\nOURS\nc\n")
      s:keys(":edit f.txt<CR>")
      s:wait("file open", function() return s:eval("vim.fn.expand('%:t')") == "f.txt" end)
      s:keys("Gounsaved<Esc>")
      s:wait("modified", function() return s:eval("vim.bo.modified") end)
      s:open_status()
      s:search("f.txt")
      s:keys("s")
      s:wait("refusal", function() return messages(s):find("unsaved", 1, true) ~= nil end)
      s:settle()
      equal(unmerged(s), stages, "nothing staged")
      s:keys(":bufdo set nomodified<CR>")
    end,
  },
  {
    name = "operation: s marks a resolved file resolved; - does too",
    fixture = merging,
    run = function(s)
      s:write("f.txt", "a\nOURS\nc\n")
      s:write("g.txt", "a\nTHEIRS\nc\n")
      s:open_status()
      s:search("f.txt")
      s:press("s", "status after s")
      s:wait("f.txt resolved in the index", function() return not unmerged(s):find("f.txt", 1, true) end)
      s:settle()
      s:search("g.txt")
      s:press("-", "status after -")
      s:wait("g.txt resolved in the index", function() return unmerged(s) == "" end)
      equal(s:git({ "show", ":0:f.txt" }), "a\nOURS\nc", "f.txt staged as written")
      equal(s:git({ "show", ":0:g.txt" }), "a\nTHEIRS\nc", "g.txt staged as written")
    end,
  },
  {
    name = "operation: visual s stages the resolved conflict and names the one with markers",
    fixture = merging,
    run = function(s)
      s:write("f.txt", "a\nOURS\nc\n")
      s:open_status()
      s:search("f.txt")
      s:keys("Vj")
      s:wait("two rows selected", function() return s:mode().mode == "V" end)
      s:keys("s")
      s:wait("f.txt resolved in the index", function() return not unmerged(s):find("f.txt", 1, true) end)
      s:wait("g.txt named as skipped", function() return messages(s):find("g.txt", 1, true) ~= nil end)
      s:settle()
      expect(unmerged(s):find("g.txt", 1, true), "g.txt still unmerged")
    end,
  },
  {
    name = "operation: rr continues a merge through Git's message editor",
    fixture = merging,
    run = function(s)
      local ours, theirs = head(s), s:git({ "rev-parse", "side" })
      s:write("f.txt", "a\nOURS\nc\n")
      s:write("g.txt", "a\nOURS\nc\n")
      s:git({ "add", "f.txt", "g.txt" })
      s:open_status()
      s:keys("rr")
      editor(s, "COMMIT_EDITMSG")
      equal(s:lines()[1], "Merge branch 'side'", "Git's merge message")
      s:keys(":wq<CR>")
      s:wait("merge committed", function() return head(s) ~= ours end)
      equal(s:git({ "log", "-1", "--format=%P" }), ours .. " " .. theirs, "two parents")
      s:wait("header gone", function() return not has_line(s, "Merging " .. theirs:sub(1, 7)) and s:surface() == "status" end)
    end,
  },
  {
    name = "operation: rr with unmerged files shows Git's refusal and changes nothing",
    fixture = merging,
    run = function(s)
      local before, stages = head(s), unmerged(s)
      s:open_status()
      s:keys("rr")
      s:wait("Git's refusal", function() return messages(s):find("unmerged", 1, true) ~= nil end)
      s:keys(':let v:errmsg = ""<CR>')
      s:settle()
      equal(head(s), before, "no commit")
      equal(unmerged(s), stages, "index unchanged")
    end,
  },
  {
    name = "operation: rr continues a rebase, rs skips, and r stays instant without one",
    fixture = rebasing,
    run = function(s)
      s:open_status()
      expect(mapped(s, "rr") and mapped(s, "rs") and mapped(s, "ra"), "rr/rs/ra mapped during a rebase")
      s:write("f.txt", "a\nREBASED\nc\n")
      s:write("g.txt", "a\nREBASED\nc\n")
      s:git({ "add", "f.txt", "g.txt" })
      s:keys("rr")
      editor(s, "COMMIT_EDITMSG")
      s:keys(":wq<CR>")
      s:wait("rebase finished", function()
        return s:git({ "log", "--format=%s" }) == "side extra\ntheirs\nours\nbase"
      end)
      equal(s:git({ "branch", "--show-current" }), "side", "back on side")
      s:wait("keys unmapped after the rebase", function()
        return s:surface() == "status" and not mapped(s, "rr") and not mapped(s, "rs") and not mapped(s, "ra")
      end)
    end,
  },
  {
    name = "operation: rs skips the stopped rebase commit",
    fixture = rebasing,
    run = function(s)
      s:open_status()
      s:keys("rs")
      s:wait("rebase finished", function() return s:git({ "log", "--format=%s" }) == "side extra\nours\nbase" end)
      equal(s:git({ "branch", "--show-current" }), "side", "back on side")
    end,
  },
  {
    name = "operation: rs is not offered for a merge, which has no --skip",
    fixture = merging,
    run = function(s)
      s:open_status()
      expect(mapped(s, "rr") and mapped(s, "ra"), "rr/ra mapped during a merge")
      expect(not mapped(s, "rs"), "no rs for a merge")
    end,
  },
  {
    name = "operation: ra asks first; Cancel keeps the merge, confirming aborts it",
    fixture = merging,
    run = function(s)
      local ours = head(s)
      s:write("f.txt", "a\nOURS\nc\n")
      s:open_status()
      s:keys("ra")
      answer(s, "2")
      s:settle()
      expect(s:git({ "rev-parse", "-q", "--verify", "MERGE_HEAD" }, { allow_failure = true }) ~= "", "still merging")
      equal(s:read("f.txt"), "a\nOURS\nc\n", "Cancel keeps the work")
      s:keys("ra")
      answer(s, "1")
      s:wait("merge aborted", function()
        return s:git({ "rev-parse", "-q", "--verify", "MERGE_HEAD" }, { allow_failure = true }) == ""
      end)
      equal(head(s), ours, "HEAD unchanged")
      equal(s:git({ "status", "--porcelain" }), "", "worktree and index clean")
    end,
  },
  {
    name = "operation: ra aborts a rebase back to the original branch",
    fixture = rebasing,
    run = function(s)
      local side = s:git({ "rev-parse", "side" })
      s:open_status()
      s:keys("ra")
      answer(s, "1")
      s:wait("rebase aborted", function() return s:git({ "branch", "--show-current" }) == "side" end)
      equal(head(s), side, "side where it was")
    end,
  },
  {
    name = "operation: rr continues a cherry-pick",
    fixture = function(s)
      branches(s)
      s:git({ "cherry-pick", "side~1" }, { allow_failure = true })
      s:write("f.txt", "a\nPICKED\nc\n")
      s:write("g.txt", "a\nPICKED\nc\n")
      s:git({ "add", "f.txt", "g.txt" })
    end,
    run = function(s)
      local before = head(s)
      s:open_status()
      -- Unlike rebase and merge, `cherry-pick --continue` commits with the
      -- picked commit's message and opens no editor (git 2.50.1).
      s:keys("rr")
      s:wait("picked", function() return head(s) ~= before end)
      equal(s:git({ "log", "-1", "--format=%s" }), "theirs", "the picked commit's message")
    end,
  },
  {
    name = "operation: R restores a half-resolved file's conflict after confirming",
    fixture = merging,
    run = function(s)
      local stages = unmerged(s)
      s:write("f.txt", "a\nhalf done\nc\n")
      s:open_status()
      s:search("f.txt")
      s:keys("R")
      answer(s, "2")
      s:settle()
      equal(s:read("f.txt"), "a\nhalf done\nc\n", "Cancel keeps the edit")
      s:search("f.txt")
      s:keys("R")
      answer(s, "1")
      s:wait("markers back", function() return (s:read("f.txt") or ""):find("<<<<<<<", 1, true) ~= nil end)
      equal(unmerged(s), stages, "stages intact")
      equal(s:read("g.txt"), CONFLICTED:gsub("f%.txt", "g.txt"), "other conflicted file untouched")
    end,
  },
}
