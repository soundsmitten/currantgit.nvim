-- User journeys driven through real keystrokes. Each scenario runs in its
-- own fixture and child Neovim (see harness.lua). Assertions about Git state
-- read the fixture with the driver's own `git`, never the plugin's model.

local h = require("e2e.harness")
local expect, equal = h.expect, h.equal

-- The working-tree fixture most status journeys share: one staged add, two
-- unstaged modifications, one untracked file.
local function worktree_fixture(s)
  s:write("tracked.txt", "one\ntwo\n")
  s:write("discard.txt", "keep\n")
  s:git({ "add", "." })
  s:git({ "commit", "-q", "-m", "fixture base" })
  s:write("tracked.txt", "one\nchanged\n")
  s:write("discard.txt", "throw this away\n")
  s:write("untracked.txt", "untracked\n")
  s:write("staged.txt", "staged\n")
  s:git({ "add", "staged.txt" })
end

local function staged_paths(s)
  return vim.split(s:git({ "diff", "--cached", "--name-only" }), "\n", { trimempty = true })
end

local function contains(list, value)
  return vim.tbl_contains(list, value)
end

local function has_line(s, needle)
  for _, line in ipairs(s:lines()) do
    if line:find(needle, 1, true) then return true end
  end
  return false
end

return {
  {
    name = "status: s stages and u unstages the file under the cursor",
    fixture = worktree_fixture,
    run = function(s)
      s:open_status()
      s:search("M tracked.txt")
      s:press("s", "status after stage")
      s:wait("tracked.txt in the index", function() return contains(staged_paths(s), "tracked.txt") end)
      s:settle()
      -- The re-render moved the row into the staged section.
      local lines = s:lines()
      local staged_heading = vim.fn.index(lines, "Staged changes (2)")
      expect(staged_heading >= 0, "staged section should count two files:\n%s", table.concat(lines, "\n"))

      s:search("M tracked.txt")
      s:press("u", "status after unstage")
      s:wait("tracked.txt out of the index", function() return not contains(staged_paths(s), "tracked.txt") end)
      equal(s:read("tracked.txt"), "one\nchanged\n", "unstage must not touch the worktree")
    end,
  },
  {
    name = "status: visual selection stages several files at once",
    fixture = worktree_fixture,
    run = function(s)
      s:open_status()
      s:search("M discard.txt")
      s:keys("Vj")
      s:wait("two-line visual selection", function()
        return s:mode().mode == "V" and s:eval("math.abs(vim.fn.line('v') - vim.fn.line('.'))") == 1
      end)
      s:press("s", "status after visual stage")
      s:wait("both files staged", function()
        local staged = staged_paths(s)
        return contains(staged, "discard.txt") and contains(staged, "tracked.txt")
      end)
      s:settle()
      equal(s:mode().mode, "n", "staging should leave visual mode")
    end,
  },
  {
    name = "status: X asks first; Cancel keeps the file, Discard restores it",
    fixture = worktree_fixture,
    run = function(s)
      s:open_status()
      s:search("M discard.txt")
      s:keys("X")
      s:wait("discard prompt", function() return s:mode().mode == "c" end)
      s:keys("2<CR>")
      s:settle()
      equal(s:read("discard.txt"), "throw this away\n", "Cancel must leave the worktree file alone")

      s:search("M discard.txt")
      s:keys("X")
      s:wait("discard prompt", function() return s:mode().mode == "c" end)
      s:keys("1<CR>")
      s:wait("discard.txt restored", function() return s:read("discard.txt") == "keep\n" end)
      s:settle()
      expect(not has_line(s, "discard.txt"), "discarded file should leave the status list")
      equal(s:read("tracked.txt"), "one\nchanged\n", "discard must only touch the selected file")
    end,
  },
  {
    name = "status: native folds and = inline diff work with real keys",
    fixture = worktree_fixture,
    run = function(s)
      s:open_status()
      s:search("Unstaged changes")
      local heading = s:eval("vim.fn.line('.')")
      s:keys("zc")
      s:wait("section folded", function() return s:eval("vim.fn.foldclosed(" .. heading .. ")") == heading end)
      s:keys("zo")
      s:wait("section open", function() return s:eval("vim.fn.foldclosed(" .. heading .. ")") == -1 end)

      s:search("M tracked.txt")
      s:press("=", "inline diff open")
      s:wait("inline hunk shown", function() return has_line(s, "+changed") end)
      equal(s:surface(), "status", "= should expand in place, not open another surface")
      s:search("M tracked.txt")
      s:press("=", "inline diff closed")
      s:wait("inline hunk hidden", function() return not has_line(s, "+changed") end)
    end,
  },
  {
    name = "diff: d opens the diff, s stages the hunk, u unstages it",
    fixture = worktree_fixture,
    run = function(s)
      s:open_status()
      s:search("M tracked.txt")
      s:press("d", "diff surface")
      s:wait("diff surface", function() return s:eval("vim.bo.filetype") == "diff" and has_line(s, "+changed") end)
      s:settle()
      s:search("@@")
      s:press("s", "diff after hunk stage")
      s:wait("hunk in the index", function()
        return s:git({ "diff", "--cached", "--", "tracked.txt" }):find("+changed", 1, true) ~= nil
      end)
      equal(s:git({ "diff", "--", "tracked.txt" }), "", "the only hunk should be fully staged")
      s:settle()

      s:keys(":Git diff --cached<CR>")
      s:wait("cached diff", function() return s:eval("vim.bo.filetype") == "diff" and has_line(s, "+changed") end)
      s:settle()
      s:search("@@ -1,2 +1,2 @@")
      s:press("u", "diff after hunk unstage")
      s:wait("hunk out of the index", function()
        return s:git({ "diff", "--cached", "--", "tracked.txt" }) == ""
      end)
      equal(s:read("tracked.txt"), "one\nchanged\n", "hunk unstage must not touch the worktree")
    end,
  },
  {
    name = ":Git stays an unrestricted escape hatch (quoted commit message)",
    fixture = worktree_fixture,
    run = function(s)
      s:open_status()
      s:keys(':Git commit -m "two words"<CR>')
      s:wait("commit created", function()
        return s:git({ "log", "-1", "--format=%s" }) == "two words"
      end)
      equal(s:git({ "show", "--name-only", "--format=", "HEAD" }), "staged.txt", "only the staged file is committed")
    end,
  },
  {
    name = "blame: b opens a blame column beside the file, gq closes it",
    fixture = worktree_fixture,
    run = function(s)
      s:open_status()
      s:search("M tracked.txt")
      s:press("b", "blame")
      s:wait("blame surface", function() return s:eval("vim.b.currantgit_title") == "blame" end)
      s:settle()
      equal(s:eval("#vim.api.nvim_tabpage_list_wins(0)"), 2, "blame sits beside the source file")
      s:keys("gq")
      s:wait("blame closed, cursor on the source", function()
        return s:eval("#vim.api.nvim_tabpage_list_wins(0)") == 1
          and s:eval("vim.api.nvim_buf_get_name(0)"):sub(-#"/tracked.txt") == "/tracked.txt"
      end)
    end,
  },
  {
    name = "log: :Git log lists commits and <CR> opens one",
    fixture = function(s)
      worktree_fixture(s)
      s:git({ "commit", "-q", "-m", "second commit" })
    end,
    run = function(s)
      s:keys(":Git log<CR>")
      s:wait("log surface", function() return s:eval("vim.b.currantgit_title") == "log" and has_line(s, "second commit") end)
      s:settle()
      s:search("fixture base")
      local sha = s:git({ "rev-parse", "--short", "HEAD~1" })
      s:press("<CR>", "commit view")
      s:wait("commit view for HEAD~1", function() return has_line(s, sha) and s:eval("vim.b.currantgit_title") ~= "log" end)
    end,
  },
  {
    name = "help: g? opens :help on the status section, from a bare checkout",
    fixture = worktree_fixture,
    run = function(s)
      s:open_status()
      expect(has_line(s, "Available actions"), "status should always show the action list")
      local status_window = s:eval("vim.api.nvim_get_current_win()")
      s:keys("g?")
      s:wait("help window", function() return s:eval("vim.bo.buftype") == "help" end)
      expect(s:line():find("*currantgit-status*", 1, true), "g? should land on the currantgit-status tag, got %q", s:line())
      s:keys(":helpclose<CR>")
      s:wait("back on status", function()
        return s:eval("vim.api.nvim_get_current_win()") == status_window and s:surface() == "status"
      end)
    end,
  },
  {
    name = "conflict: <CR> opens the resolver read-only; ]x jumps; index untouched",
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
    end,
    run = function(s)
      local stages = s:git({ "ls-files", "-u" })
      local conflicted = s:read("f.txt")
      expect(#vim.split(stages, "\n") == 3, "fixture should leave three index stages, got:\n%s", stages)

      s:open_status()
      s:search("f.txt")
      s:keys("<CR>")
      s:wait("resolver tab", function()
        return s:eval("vim.t.currantgit_conflict ~= nil") and s:eval("vim.b.currantgit_conflict_pane") == "result"
      end)
      s:settle()
      equal(s:eval("#vim.api.nvim_tabpage_list_wins(0)"), 3, "resolver shows ours | result | theirs")
      equal(s:eval("vim.wo.diff"), true, "result pane uses native diff mode")

      s:keys("gg]x")
      s:wait("cursor on the conflict", function() return s:line():find("^<<<<<<<") ~= nil end)

      equal(s:git({ "ls-files", "-u" }), stages, "opening the resolver must not touch the index")
      equal(s:read("f.txt"), conflicted, "opening the resolver must not write the file")
    end,
  },
  {
    name = "conflict: co takes ours, u undoes it, :w saves; the index stays unmerged",
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
    end,
    run = function(s)
      local stages = s:git({ "ls-files", "-u" })
      s:open_status()
      s:search("f.txt")
      s:keys("<CR>")
      s:wait("resolver result pane", function() return s:eval("vim.b.currantgit_conflict_pane") == "result" end)
      s:settle()
      s:keys("gg]x")
      s:wait("cursor in the region", function() return s:line():find("^<<<<<<<") ~= nil end)

      local function buffer_text() return table.concat(s:lines(), "\n") end
      local conflicted = buffer_text()
      s:keys("co")
      s:wait("region replaced by ours", function() return buffer_text() == "a\nOURS\nc" end)
      s:keys("u")
      s:wait("markers back after undo", function() return buffer_text() == conflicted end)
      s:keys("co")
      s:wait("region replaced by ours again", function() return buffer_text() == "a\nOURS\nc" end)
      expect(s:eval("vim.wo.winbar"):find("1 of 1 resolved", 1, true), "winbar should count the region, got %q", s:eval("vim.wo.winbar"))

      expect(s:read("f.txt"):find("<<<<<<<", 1, true), "a region choice must not save the file by itself")
      s:keys(":w<CR>")
      s:wait("file saved", function() return s:read("f.txt") == "a\nOURS\nc\n" end)
      equal(s:git({ "ls-files", "-u" }), stages, "resolving in the buffer must not touch the index")
    end,
  },
  {
    name = "conflict: co outside a region is Vim's own change-word-back",
    fixture = function(s)
      s:write("f.txt", "a\nb\nc\n")
      s:git({ "add", "." })
      s:git({ "commit", "-q", "-m", "base" })
      s:git({ "checkout", "-q", "-b", "side" })
      s:write("f.txt", "keep this line\nb\nTHEIRS\n")
      s:git({ "commit", "-q", "-am", "theirs" })
      s:git({ "checkout", "-q", "main" })
      s:write("f.txt", "keep this line\nb\nOURS\n")
      s:git({ "commit", "-q", "-am", "ours" })
      s:git({ "merge", "-q", "side" }, { allow_failure = true })
    end,
    run = function(s)
      s:open_status()
      s:search("f.txt")
      s:keys("<CR>")
      s:wait("resolver result pane", function() return s:eval("vim.b.currantgit_conflict_pane") == "result" end)
      s:settle()
      -- Line 1 is outside the conflict: `cb` must change back a word. `cb`
      -- is exclusive, so the cursor's own "e" survives; "keep this Xe" is
      -- what `nvim --clean` produces for the same keys.
      s:keys("gg$cbX<Esc>")
      s:wait("native cb applied", function() return s:lines()[1] == "keep this Xe" end)
      equal(s:mode().mode, "n", "back in normal mode after the native change")
    end,
  },
}
