-- Commit workflows: Git's own editor round-trips through the running Neovim.
-- Every assertion about the outcome reads the fixture with the driver's own
-- `git`; the child is only typed into and observed.

local h = require("e2e.harness")
local expect, equal = h.expect, h.equal

local function fixture(s)
  s:write("tracked.txt", "one\ntwo\n")
  s:write("keep.txt", "keep\n")
  s:git({ "add", "." })
  s:git({ "commit", "-q", "-m", "First commit" })
  s:write("tracked.txt", "one\nstaged\n")
  s:git({ "add", "tracked.txt" })
  s:write("keep.txt", "keep\nunstaged edit\n")
  s:write("untracked.txt", "untracked\n")
end

-- Everything a commit must leave alone, read straight from disk and Git.
local function snapshot(s)
  return {
    worktree_keep = s:read("keep.txt"),
    worktree_tracked = s:read("tracked.txt"),
    unstaged = s:git({ "diff" }),
    untracked = s:git({ "ls-files", "--others", "--exclude-standard" }),
  }
end

local function head(s) return s:git({ "rev-parse", "HEAD" }) end
local function subject(s, rev) return s:git({ "log", "-1", "--format=%s", rev or "HEAD" }) end

local function wait_for_editor(s, filetype, name)
  s:wait(name .. " buffer", function()
    return s:eval("vim.bo.filetype") == filetype
      and s:eval("vim.fn.expand('%:t')") == name
  end)
  s:wait("normal mode in the editor buffer", function() return s:mode().mode == "n" end)
end

local function message_lines(s)
  return s:git({ "log", "-1", "--format=%B" })
end

local function messages(s)
  return s:eval("vim.api.nvim_exec2('messages', { output = true }).output")
end

return {
  {
    name = "commit: cc opens the message, :wq commits only what is staged",
    fixture = fixture,
    run = function(s)
      local before, parent = snapshot(s), head(s)
      s:open_status()
      s:keys("cc")
      wait_for_editor(s, "gitcommit", "COMMIT_EDITMSG")
      expect(table.concat(s:lines(), "\n"):find("# Please enter the commit message", 1, true),
        "the buffer should hold Git's own template")
      s:keys("ggiAdd staged line<Esc>:wq<CR>")
      s:wait("commit created", function() return head(s) ~= parent end)
      equal(subject(s), "Add staged line", "subject comes from the buffer")
      equal(s:git({ "rev-parse", "HEAD~1" }), parent, "a new commit on top of the old HEAD")
      equal(s:git({ "show", "--name-only", "--format=", "HEAD" }), "tracked.txt", "only the staged file")
      equal(message_lines(s), "Add staged line", "template comments are stripped")
      equal(snapshot(s), before, "worktree, unstaged and untracked state untouched")
      s:wait("status refreshed with nothing staged", function()
        return s:surface() == "status" and vim.fn.index(s:lines(), "Staged changes (1)") < 0
          and vim.tbl_contains(s:lines(), "Unstaged changes (1)")
      end)
    end,
  },
  {
    name = "commit: an untouched template aborts, like Git, and changes nothing",
    fixture = fixture,
    run = function(s)
      local before, parent = snapshot(s), head(s)
      local index = s:git({ "diff", "--cached" })
      s:open_status()
      s:keys("cc")
      wait_for_editor(s, "gitcommit", "COMMIT_EDITMSG")
      s:keys(":wq<CR>")
      s:wait("Git's abort message", function() return messages(s):find("empty commit message", 1, true) ~= nil end)
      -- Reported as an error, as fugitive does; this test expects it.
      s:keys(':let v:errmsg = ""<CR>')
      equal(head(s), parent, "no commit")
      equal(s:git({ "diff", "--cached" }), index, "index unchanged")
      equal(snapshot(s), before, "worktree unchanged")
    end,
  },
  {
    name = "commit: :q! after typing discards the message and commits nothing",
    fixture = fixture,
    run = function(s)
      local parent = head(s)
      s:open_status()
      s:keys("cc")
      wait_for_editor(s, "gitcommit", "COMMIT_EDITMSG")
      s:keys("ggiNever written<Esc>:q!<CR>")
      s:wait("Git's abort message", function() return messages(s):find("empty commit message", 1, true) ~= nil end)
      -- Reported as an error, as fugitive does; this test expects it.
      s:keys(':let v:errmsg = ""<CR>')
      equal(head(s), parent, "no commit")
    end,
  },
  {
    name = "commit: ca amends with the old message prefilled",
    fixture = fixture,
    run = function(s)
      local before, old = snapshot(s), head(s)
      local grandparent = s:git({ "rev-parse", "-q", "--verify", "HEAD~1" }, { allow_failure = true })
      s:open_status()
      s:keys("ca")
      wait_for_editor(s, "gitcommit", "COMMIT_EDITMSG")
      equal(s:lines()[1], "First commit", "amend starts from the current message")
      s:keys("ggccFirst commit, amended<Esc>:wq<CR>")
      s:wait("HEAD rewritten", function() return head(s) ~= old end)
      equal(subject(s), "First commit, amended", "new subject")
      equal(s:git({ "rev-list", "--count", "HEAD" }), "1", "amend replaces, it does not add")
      equal(s:git({ "rev-parse", "-q", "--verify", "HEAD~1" }, { allow_failure = true }), grandparent, "same parent (none)")
      equal(s:git({ "show", "HEAD:tracked.txt" }), "one\nstaged", "staged change folded in")
      equal(snapshot(s), before, "worktree untouched")
    end,
  },
  {
    name = "commit: ce amends without opening an editor",
    fixture = fixture,
    run = function(s)
      local old = head(s)
      s:open_status()
      s:keys("ce")
      s:wait("HEAD rewritten", function() return head(s) ~= old end)
      equal(subject(s), "First commit", "message kept")
      equal(s:git({ "show", "HEAD:tracked.txt" }), "one\nstaged", "staged change folded in")
      equal(s:eval("vim.bo.filetype"), "currantgit", "no editor buffer opened")
    end,
  },
  {
    name = "commit: cw rewords and leaves staged changes staged",
    fixture = fixture,
    run = function(s)
      local old = head(s)
      local staged = s:git({ "diff", "--cached" })
      s:open_status()
      s:keys("cw")
      wait_for_editor(s, "gitcommit", "COMMIT_EDITMSG")
      s:keys("ggccReworded<Esc>:wq<CR>")
      s:wait("HEAD rewritten", function() return head(s) ~= old end)
      equal(subject(s), "Reworded", "new subject")
      equal(s:git({ "show", "HEAD:tracked.txt" }), "one\ntwo", "staged change NOT folded in")
      equal(s:git({ "diff", "--cached" }), staged, "still staged")
    end,
  },
  {
    name = "commit: cvc shows the diff below the scissors and keeps it out of the message",
    fixture = fixture,
    run = function(s)
      local parent = head(s)
      s:open_status()
      s:keys("cvc")
      wait_for_editor(s, "gitcommit", "COMMIT_EDITMSG")
      local text = table.concat(s:lines(), "\n")
      expect(text:find(">8", 1, true) and text:find("+staged", 1, true), "verbose diff under the scissors line")
      s:keys("ggiVerbose commit<Esc>:wq<CR>")
      s:wait("commit created", function() return head(s) ~= parent end)
      equal(message_lines(s), "Verbose commit", "diff not in the message")
    end,
  },
  {
    name = "commit: :Git commit with no message uses the same editor",
    fixture = fixture,
    run = function(s)
      local parent = head(s)
      s:open_status()
      s:keys(":Git commit<CR>")
      wait_for_editor(s, "gitcommit", "COMMIT_EDITMSG")
      s:keys("ggiFrom the command<Esc>:wq<CR>")
      s:wait("commit created", function() return head(s) ~= parent end)
      equal(subject(s), "From the command", "subject comes from the buffer")
    end,
  },
  {
    name = "commit: a CurrantGit view opened from the message window leaves the edit running",
    fixture = fixture,
    run = function(s)
      local parent = head(s)
      s:open_status()
      s:keys("cc")
      wait_for_editor(s, "gitcommit", "COMMIT_EDITMSG")
      -- A second Git command that finishes while the message is still open,
      -- run from the message window. Its output must not replace (and so
      -- wipe) the message buffer: that would end the edit and abort.
      s:keys(":Git tag -a v1 -m tagged<CR>")
      s:wait("tag created", function() return s:git({ "tag", "-l" }) == "v1" end)
      s:keys(":Git log<CR>")
      s:wait("log open", function() return s:eval("vim.b.currantgit_title") == "log" end)
      equal(head(s), parent, "commit still waiting on its message")
      s:keys(":wincmd p<CR>")
      wait_for_editor(s, "gitcommit", "COMMIT_EDITMSG")
      s:keys("ggiStill here<Esc>:wq<CR>")
      s:wait("commit created", function() return head(s) ~= parent end)
      equal(subject(s), "Still here", "the original edit completed")
    end,
  },
  {
    name = "commit: a merge commit keeps Git's merge message and both parents",
    fixture = function(s)
      s:write("f.txt", "a\nb\nc\n")
      s:git({ "add", "." })
      s:git({ "commit", "-q", "-m", "base" })
      s:git({ "checkout", "-q", "-b", "side" })
      s:write("f.txt", "a\nTHEIRS\nc\n")
      s:git({ "commit", "-q", "-am", "theirs" })
      s:git({ "checkout", "-q", "main" })
      s:write("f.txt", "a\nOURS\nc\n")
      s:git({ "commit", "-q", "-am", "ours" })
      s:git({ "merge", "-q", "side" }, { allow_failure = true })
      s:write("f.txt", "a\nOURS\nc\n")
      s:git({ "add", "f.txt" })
    end,
    run = function(s)
      local ours, theirs = head(s), s:git({ "rev-parse", "side" })
      s:open_status()
      s:keys("cc")
      wait_for_editor(s, "gitcommit", "COMMIT_EDITMSG")
      equal(s:lines()[1], "Merge branch 'side'", "Git's prepared merge message")
      s:keys(":wq<CR>")
      s:wait("merge committed", function() return head(s) ~= ours end)
      equal(s:git({ "log", "-1", "--format=%P" }), ours .. " " .. theirs, "two parents")
      equal(s:git({ "rev-parse", "-q", "--verify", "MERGE_HEAD" }, { allow_failure = true }), "", "merge finished")
    end,
  },
  {
    name = "commit: :Git rebase -i edits the todo here, even with repo editors set",
    fixture = function(s)
      s:write("f.txt", "1\n")
      s:git({ "add", "." })
      s:git({ "commit", "-q", "-m", "one" })
      s:write("f.txt", "2\n")
      s:git({ "commit", "-q", "-am", "two" })
      s:write("g.txt", "3\n")
      s:git({ "add", "g.txt" })
      s:git({ "commit", "-q", "-m", "three" })
      -- Editors that would fail outright; CurrantGit's must take precedence.
      s:git({ "config", "core.editor", "false" })
      s:git({ "config", "sequence.editor", "false" })
    end,
    run = function(s)
      s:open_status()
      s:keys(":Git rebase -i HEAD~2<CR>")
      wait_for_editor(s, "gitrebase", "git-rebase-todo")
      -- Git 2.50 writes "pick <sha> # <subject>"; older Git omits the "#".
      equal(s:lines()[1]:match("^pick %x+ #? ?two$") ~= nil, true, "first todo line picks 'two', got " .. s:lines()[1])
      s:keys("ggcwdrop<Esc>:wq<CR>")
      s:wait("rebase finished", function()
        return s:git({ "log", "--format=%s" }) == "three\none"
      end)
      equal(s:read("f.txt"), "1\n", "dropping 'two' reverted its change")
      equal(s:read("g.txt"), "3\n", "'three' replayed")
    end,
  },
}
