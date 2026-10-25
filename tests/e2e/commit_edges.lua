-- Commit edge cases from the adversarial pass on the Git editor bridge
-- (docs/decisions/0015): odd paths, linked worktrees, unborn branches, hooks,
-- refusals and Neovim quitting mid-edit. Verdicts come from real Git and the
-- filesystem, never from CurrantGit.
local h = require("e2e.harness")
local expect, equal = h.expect, h.equal

local function base(s)
  s:write("a.txt", "a\n")
  s:write("b.txt", "b\n")
  s:git({ "add", "." })
  s:git({ "commit", "-q", "-m", "base" })
  s:write("a.txt", "a\nstaged\n")
  s:git({ "add", "a.txt" })
  s:write("b.txt", "b\nunstaged\n")
end
local function head(s) return s:git({ "rev-parse", "-q", "--verify", "HEAD" }, { allow_failure = true }) end
local function editor(s, name)
  local ok, err = pcall(s.wait, s, name, function() return s:eval("vim.fn.expand('%:t')") == name and s:mode().mode == "n" end)
  if not ok then
    local state = pcall(function()
      print("    [diag] mode=" .. vim.inspect(s:mode()) .. " cur=" .. s:eval("vim.fn.expand('%:p')"))
      print("    [diag] wins=" .. vim.inspect(s:eval([[vim.tbl_map(function(w) return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)), ":t") end, vim.api.nvim_tabpage_list_wins(0))]])))
      print("    [diag] msgs=" .. s:eval("vim.api.nvim_exec2('messages', { output = true }).output"):gsub("\n", " | "))
    end)
    error(err, 0)
  end
end
local function msgs(s) return s:eval("vim.api.nvim_exec2('messages', { output = true }).output") end
local function clear_err(s) s:keys(':let v:errmsg = ""<CR>') end
local function retarget(dirname)
  return function(fixture)
    return function(s)
      local dir = s.dir .. "/" .. dirname
      vim.fn.mkdir(dir, "p")
      s.dir = dir
      s:git({ "init", "-q", "-b", "main" })
      fixture(s)
    end
  end
end

local scenarios = {
  {
    name = "commit edge: repo path with spaces, quote, unicode and a leading dash",
    fixture = retarget("-my repo 'é' x")(base),
    run = function(s)
      local old = head(s)
      s:open_status(); s:keys("cc"); editor(s, "COMMIT_EDITMSG")
      s:keys("ggiOdd path<Esc>:wq<CR>")
      s:wait("commit", function() return head(s) ~= old end)
      equal(s:git({ "log", "-1", "--format=%s" }), "Odd path", "subject")
    end,
  },
  {
    name = "commit edge: linked worktree: Git's files live outside the work tree",
    fixture = function(s)
      base(s)
      s:git({ "commit", "-q", "-m", "staged on main" })
      local wt = s.dir .. "-wt"
      s:git({ "worktree", "add", "-q", "-b", "feature", wt })
      s.dir = wt
      s:write("a.txt", "in worktree\n")
      s:git({ "add", "a.txt" })
    end,
    run = function(s)
      local old = head(s)
      local main_head = s:git({ "rev-parse", "main" })
      s:open_status(); s:keys("cc"); editor(s, "COMMIT_EDITMSG")
      expect(s:eval("vim.api.nvim_buf_get_name(0)"):find("/worktrees/", 1, true), "message file is in the main repo's worktrees dir")
      s:keys("ggiFrom worktree<Esc>:wq<CR>")
      s:wait("commit", function() return head(s) ~= old end)
      equal(s:git({ "rev-parse", "--abbrev-ref", "HEAD" }), "feature", "committed on the worktree branch")
      equal(s:git({ "rev-parse", "main" }), main_head, "main untouched")
    end,
  },
  {
    name = "commit edge: unborn branch: ca is refused by Git, cc makes the root commit",
    fixture = function(s) s:write("a.txt", "a\n"); s:git({ "add", "a.txt" }) end,
    run = function(s)
      s:open_status()
      local index = s:git({ "diff", "--cached", "--stat" })
      s:keys("ca")
      s:wait("Git's refusal", function() return msgs(s):find("nothing to amend", 1, true) ~= nil end)
      clear_err(s)
      equal(head(s), "", "still no commits")
      equal(s:git({ "diff", "--cached", "--stat" }), index, "index unchanged")
      equal(s:eval("vim.bo.filetype"), "currantgit", "no editor opened")
      s:keys("cc"); editor(s, "COMMIT_EDITMSG")
      s:keys("ggiRoot<Esc>:wq<CR>")
      s:wait("root commit", function() return head(s) ~= "" end)
      equal(s:git({ "rev-list", "--count", "HEAD" }), "1", "one commit")
    end,
  },
  {
    name = "commit edge: nothing staged: Git refuses before any editor opens",
    fixture = function(s) base(s); s:git({ "reset", "-q" }) end,
    run = function(s)
      local old = head(s)
      s:open_status()
      local wins = s:eval("#vim.api.nvim_list_wins()")
      s:keys("cc")
      s:wait("Git's refusal", function() return msgs(s):find("no changes added to commit", 1, true) ~= nil end)
      clear_err(s)
      equal(head(s), old, "no commit")
      equal(s:eval("#vim.api.nvim_list_wins()"), wins, "no split opened")
    end,
  },
  {
    name = "commit edge: pre-commit hook rejects: no editor, no commit, index intact",
    fixture = function(s)
      base(s)
      s:write(".git/hooks/pre-commit", "#!/bin/sh\necho 'hook says no' >&2\nexit 1\n")
      vim.uv.fs_chmod(s.dir .. "/.git/hooks/pre-commit", 493)
    end,
    run = function(s)
      local old, index = head(s), s:git({ "diff", "--cached" })
      s:open_status(); s:keys("cc")
      s:wait("hook error shown", function() return msgs(s):find("hook says no", 1, true) ~= nil end)
      clear_err(s)
      equal(head(s), old, "no commit")
      equal(s:git({ "diff", "--cached" }), index, "index unchanged")
      equal(s:eval("vim.fn.expand('%:t')") ~= "COMMIT_EDITMSG", true, "no editor")
    end,
  },
  {
    name = "commit edge: commit-msg hook rejects after editing: no commit, message kept by Git",
    fixture = function(s)
      base(s)
      s:write(".git/hooks/commit-msg", "#!/bin/sh\necho 'bad message' >&2\nexit 1\n")
      vim.uv.fs_chmod(s.dir .. "/.git/hooks/commit-msg", 493)
    end,
    run = function(s)
      local old = head(s)
      s:open_status(); s:keys("cc"); editor(s, "COMMIT_EDITMSG")
      s:keys("ggiRejected subject<Esc>:wq<CR>")
      s:wait("hook error shown", function() return msgs(s):find("bad message", 1, true) ~= nil end)
      clear_err(s)
      equal(head(s), old, "no commit")
      expect(s:read(".git/COMMIT_EDITMSG"):find("Rejected subject", 1, true), "Git leaves the message on disk")
    end,
  },
  {
    name = "commit edge: COMMIT_EDITMSG already open and modified elsewhere: refused, Git aborts",
    fixture = function(s) base(s); s:write(".git/COMMIT_EDITMSG", "old draft\n") end,
    run = function(s)
      local old = head(s)
      s:keys(":edit .git/COMMIT_EDITMSG<CR>"); s:wait("draft open", function() return s:eval("vim.fn.expand('%:t')") == "COMMIT_EDITMSG" end)
      s:keys("Gounsaved draft line<Esc>")
      s:wait("modified", function() return s:eval("vim.bo.modified") == true end)
      s:open_status(); s:keys("cc")
      s:wait("refusal", function() return msgs(s):find("has unsaved changes in another buffer", 1, true) ~= nil end)
      s:wait("Git gave up", function() return msgs(s):find("problem with the editor", 1, true) ~= nil end)
      clear_err(s)
      equal(head(s), old, "no commit")
      local draft = s:eval([[(function() for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_get_name(b):match("COMMIT_EDITMSG$") then return table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n") end end end)()]])
      expect(draft and draft:find("unsaved draft line", 1, true), "the user's unsaved draft is untouched")
      -- Leave cleanly: drop the draft so the harness does not see a modified buffer.
      s:keys(":bufdo set nomodified<CR>")
    end,
  },
  {
    name = "commit edge: two editors at once (commit + tag -a), finished in reverse order",
    fixture = base,
    run = function(s)
      local old = head(s)
      s:open_status(); s:keys("cc"); editor(s, "COMMIT_EDITMSG")
      s:keys(":Git tag -a v1<CR>")
      editor(s, "TAG_EDITMSG")
      s:keys("ggiTag note<Esc>:wq<CR>")
      s:wait("tag created", function() return s:git({ "tag", "-l" }) == "v1" end)
      local win = s:eval([[vim.fn.win_findbuf(vim.fn.bufnr("COMMIT_EDITMSG"))[1] or -1]])
      expect(win ~= -1, "the commit message is still open after the tag finished")
      s:keys(":call win_gotoid(" .. win .. ")<CR>")
      editor(s, "COMMIT_EDITMSG")
      s:keys("ggiAfter tag<Esc>:wq<CR>")
      s:wait("commit", function() return head(s) ~= old end)
      equal(s:git({ "rev-parse", "v1^{commit}" }), old, "tag points at the old HEAD")
      equal(s:git({ "tag", "-l", "--format=%(contents:subject)", "v1" }), "Tag note", "tag message")
    end,
  },
  {
    name = "commit edge: commit.template is honored; untouched template aborts",
    fixture = function(s)
      base(s)
      s:write(".git/tmpl", "Ticket: \n")
      s:git({ "config", "commit.template", ".git/tmpl" })
    end,
    run = function(s)
      local old = head(s)
      s:open_status(); s:keys("cc"); editor(s, "COMMIT_EDITMSG")
      equal(s:lines()[1], "Ticket: ", "template text first")
      s:keys(":wq<CR>")
      s:wait("abort", function() return msgs(s):find("did not edit the message", 1, true) ~= nil or msgs(s):find("empty commit message", 1, true) ~= nil end)
      clear_err(s)
      equal(head(s), old, "no commit from an untouched template")
    end,
  },
}

table.insert(scenarios, {
  name = "commit edge: Neovim quits mid-edit: Git aborts, no lock, no stray processes",
  fixture = base,
  run = function(s)
    local old = head(s)
    s:open_status(); s:keys("cc"); editor(s, "COMMIT_EDITMSG")
    s:keys("ggiNever committed<Esc>")
    local pid = vim.fn.jobpid(s.channel)
    s:stop()
    s.channel = nil
    local function shims() return vim.trim(vim.system({ "pgrep", "-f", "git_editor_shim.lua" }):wait().stdout or "") end
    local ok = vim.wait(5000, function()
      return shims() == "" and vim.uv.fs_stat(s.dir .. "/.git/index.lock") == nil
    end, 50)
    expect(ok, "shim gone and no index.lock (shims: %q)", shims())
    equal(head(s), old, "no commit")
    expect(vim.system({ "kill", "-0", tostring(pid) }):wait().code ~= 0, "child nvim exited")
    -- The harness expects a live child at the end; start a fresh one.
    s:start()
  end,
})

return scenarios
