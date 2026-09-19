-- Regression coverage for the repository-integrity findings from the
-- adversarial Git-safety audit. Each block below independently verifies,
-- through real Git repositories, that the corresponding bug class stays
-- fixed: it is not enough for CurrantGit to believe it behaved correctly,
-- Git's own on-disk state must confirm it.
local currantgit = require("currantgit")
local original_cwd = vim.fn.getcwd()

local function assert_contains(lines, needle)
  for _, line in ipairs(lines) do
    if line:find(needle, 1, true) then
      return
    end
  end
  error("expected buffer to contain: " .. needle)
end

local function git(args, cwd)
  local result = vim.system(vim.list_extend({ "git" }, args), { cwd = cwd, text = true }):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout or "")
end

local function read_file(path)
  local file = assert(io.open(path, "r"))
  local content = file:read("*a")
  file:close()
  return content
end

local function write_file(path, content)
  local file = assert(io.open(path, "w"))
  file:write(content)
  file:close()
end

local function make_repo()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  git({ "init", "-q" }, dir)
  git({ "config", "user.name", "CurrantGit Safety" }, dir)
  git({ "config", "user.email", "safety@currantgit.invalid" }, dir)
  return dir
end

local function goto_item(path)
  for line, item in pairs(vim.b.currantgit_line_items or {}) do
    if type(item) == "table" and item.path == path then
      vim.api.nvim_win_set_cursor(0, { line, 0 })
      return
    end
  end
  error("could not find status item: " .. path)
end

local function open_status_and_wait()
  local before_buffer = vim.api.nvim_get_current_buf()
  local before_tick = vim.api.nvim_buf_get_changedtick(before_buffer)
  currantgit.git({})
  assert(vim.wait(5000, function()
    return vim.bo.filetype == "currantgit" and vim.b.currantgit_title == "status"
      and (vim.api.nvim_get_current_buf() ~= before_buffer
        or vim.api.nvim_buf_get_changedtick(before_buffer) > before_tick)
  end, 10), "status surface did not render")
end

-- 1. Cross-repository cwd-race (CRITICAL): a discard/stage/unstage action
-- must mutate the repository the buffer was opened against, never whatever
-- repository the editor's cwd happens to point at once the async git
-- process or confirmation prompt resolves.
local function test_cwd_race()
  local repo_a = make_repo()
  local repo_b = make_repo()

  write_file(repo_a .. "/shared.txt", "one\ntwo\n")
  git({ "add", "shared.txt" }, repo_a)
  git({ "commit", "-q", "-m", "base" }, repo_a)
  write_file(repo_a .. "/shared.txt", "one\ntwo\nTHREE\n")

  write_file(repo_b .. "/shared.txt", "hello\n")
  git({ "add", "shared.txt" }, repo_b)
  git({ "commit", "-q", "-m", "base" }, repo_b)
  write_file(repo_b .. "/shared.txt", "hello\nmodified-in-B\n")

  vim.cmd("cd " .. vim.fn.fnameescape(repo_a))
  open_status_and_wait()
  goto_item("shared.txt")

  local discard_mapping = vim.fn.maparg("X", "n", false, true)
  assert(discard_mapping.callback, "discard mapping was not registered")

  local original_select = vim.ui.select
  vim.ui.select = function(_, _, callback)
    -- Simulate the real async confirmation gap: the user is asked to
    -- confirm, and the editor's cwd changes before they answer.
    vim.defer_fn(function() callback("Discard", 1) end, 50)
  end

  discard_mapping.callback()
  vim.cmd("cd " .. vim.fn.fnameescape(repo_b))

  -- Wait for the discard's own status refresh to fully settle (not merely
  -- for the worktree file to change) before touching either repository
  -- again: the refresh itself issues another `git status` against the
  -- captured root, and tearing down the fixture too early would just
  -- trade one race for another.
  assert(vim.wait(3000, function()
    for _, item in ipairs(vim.b.currantgit_items or {}) do
      if item.path == "shared.txt" then return false end
    end
    return true
  end, 10), "post-discard status refresh did not settle")
  vim.ui.select = original_select

  assert(read_file(repo_a .. "/shared.txt") == "one\ntwo\n",
    "discard did not revert the intended repository")
  assert(read_file(repo_b .. "/shared.txt") == "hello\nmodified-in-B\n",
    "cwd changed mid-action and corrupted an unrelated repository")

  vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
  vim.fn.delete(repo_a, "rf")
  vim.fn.delete(repo_b, "rf")
end

-- 2. Pathspec glob magic (CRITICAL): stage/unstage/discard/diff pathspecs
-- built from a literal filename must not be reinterpreted as fnmatch
-- wildcards by Git (gitglossary(7), PATHSPECS) and collaterally mutate an
-- unrelated file that happens to match the pattern.
local function test_glob_pathspec()
  local repo = make_repo()
  write_file(repo .. "/afile.txt", "a\n")
  write_file(repo .. "/a*file.txt", "b\n")
  git({ "add", "." }, repo)
  git({ "commit", "-q", "-m", "base" }, repo)
  write_file(repo .. "/afile.txt", "a-changed\n")
  write_file(repo .. "/a*file.txt", "b-changed\n")

  vim.cmd("cd " .. vim.fn.fnameescape(repo))
  open_status_and_wait()
  goto_item("a*file.txt")

  local function item_status(path)
    for _, item in ipairs(vim.b.currantgit_items or {}) do
      if item.path == path then return item.status end
    end
    return nil
  end

  -- Each step below waits for the surface's own post-action refresh to
  -- settle (proving CurrantGit's status projection agrees with reality),
  -- then independently re-derives ground truth straight from Git and the
  -- filesystem, per the audit doctrine that the implementation is not its
  -- own oracle.
  local stage_mapping = vim.fn.maparg("s", "n", false, true)
  assert(stage_mapping.callback, "stage mapping was not registered")
  stage_mapping.callback()
  assert(vim.wait(3000, function()
    local status = item_status("a*file.txt")
    return status ~= nil and status:sub(1, 1) ~= " "
  end, 10), "stage refresh did not settle")
  assert(git({ "diff", "--name-only" }, repo) == "afile.txt",
    "staging 'a*file.txt' must leave only the unrelated 'afile.txt' unstaged-modified")
  assert(git({ "diff", "--cached", "--name-only" }, repo) == "a*file.txt",
    "staging 'a*file.txt' should stage exactly that file")
  assert(read_file(repo .. "/afile.txt") == "a-changed\n",
    "staging 'a*file.txt' must not touch the unrelated 'afile.txt'")

  goto_item("a*file.txt")
  local unstage_mapping = vim.fn.maparg("u", "n", false, true)
  assert(unstage_mapping.callback, "unstage mapping was not registered")
  unstage_mapping.callback()
  assert(vim.wait(3000, function()
    local status = item_status("a*file.txt")
    return status ~= nil and status:sub(1, 1) == " "
  end, 10), "unstage refresh did not settle")
  assert(git({ "diff", "--cached", "--name-only" }, repo) == "",
    "unstaging a glob-named file left the index in an unexpected state")
  assert(read_file(repo .. "/afile.txt") == "a-changed\n",
    "unstaging 'a*file.txt' must not touch the unrelated 'afile.txt'")

  goto_item("a*file.txt")
  local discard_mapping = vim.fn.maparg("X", "n", false, true)
  assert(discard_mapping.callback, "discard mapping was not registered")
  local original_select = vim.ui.select
  vim.ui.select = function(_, _, callback) callback("Discard", 1) end
  discard_mapping.callback()
  assert(vim.wait(3000, function()
    return item_status("a*file.txt") == nil
  end, 10), "discard refresh did not settle")
  vim.ui.select = original_select
  assert(read_file(repo .. "/a*file.txt") == "b\n",
    "discarding the glob-named file did not revert it")
  assert(read_file(repo .. "/afile.txt") == "a-changed\n",
    "discarding 'a*file.txt' must not revert the unrelated 'afile.txt'")

  vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
  vim.fn.delete(repo, "rf")
end

-- 3. Blame line-dropping (HIGH): `git blame --line-porcelain` only emits the
-- same-commit run's line-count field on the first line of that run; every
-- line thereafter must still be parsed.
local function test_blame_multiline()
  local blame = require("currantgit.blame")
  local repo = make_repo()
  write_file(repo .. "/f.txt", "one\ntwo\nthree\nfour\nfive\n")
  git({ "add", "f.txt" }, repo)
  git({ "commit", "-q", "-m", "single commit, five lines" }, repo)

  local result = vim.system({ "git", "blame", "--line-porcelain", "--", "f.txt" }, {
    cwd = repo,
    text = true,
  }):wait()
  assert(result.code == 0, result.stderr)

  local rows = blame.parse(result.stdout)
  assert(#rows == 5, "expected all five same-commit lines to survive parsing, got " .. #rows)
  local expected = { "one", "two", "three", "four", "five" }
  for index, row in ipairs(rows) do
    assert(row.line == index, "row " .. index .. " has the wrong line number: " .. tostring(row.line))
    assert(row.text == expected[index], "row " .. index .. " has the wrong text: " .. tostring(row.text))
  end

  vim.fn.delete(repo, "rf")
end

-- 4. diff.parse crash on a trailing non-hunk file (HIGH): a multi-file diff
-- whose LAST file has no `@@` hunk (binary, pure mode change, 100%-similar
-- rename, etc.) while an earlier file did have one must not crash the
-- parser.
local function test_diff_trailing_binary()
  local diff = require("currantgit.diff")
  local repo = make_repo()
  write_file(repo .. "/a_text.txt", "line1\nline2\n")
  write_file(repo .. "/z_bin.dat", "\0binary\0one\0")
  git({ "add", "." }, repo)
  git({ "commit", "-q", "-m", "base" }, repo)
  write_file(repo .. "/a_text.txt", "line1\nCHANGED\n")
  write_file(repo .. "/z_bin.dat", "\0binary\0two\0")

  local result = vim.system({ "git", "diff", "--", "a_text.txt", "z_bin.dat" }, {
    cwd = repo,
    text = true,
  }):wait()
  assert(result.code == 0, result.stderr)
  assert(result.stdout:find("Binary files", 1, true), "fixture diff should contain a binary-file entry")

  local ok, lines, fold_levels, line_items, hunks = pcall(diff.parse, result.stdout, { mode = "working" })
  assert(ok, "diff.parse crashed on a trailing non-hunk file: " .. tostring(lines))
  assert(#hunks == 1, "expected exactly one hunk from a_text.txt")
  assert(hunks[1].path == "a_text.txt")
  assert(hunks[1].end_line and hunks[1].end_line > hunks[1].start_line,
    "hunk end_line was not finalized")
  assert(fold_levels and line_items, "diff.parse should still return fold levels and line items")

  vim.fn.delete(repo, "rf")
end

-- 5. Status parsing of renames and non-conflict D/A/U status codes (MEDIUM):
-- the human `--short` format renders a staged rename as one string,
-- `"old.txt -> new.txt"`, which a naive parser mistakes for a literal path.
-- Separately, a loose `[DAU][DAU]` conflict-code guess misclassifies real,
-- non-conflict codes such as `AD` (staged add, then worktree delete) as
-- merge conflicts.
local function test_status_rename_and_status_codes()
  local repo = make_repo()
  write_file(repo .. "/old.txt", "line1\nline2\nline3\n")
  git({ "add", "old.txt" }, repo)
  git({ "commit", "-q", "-m", "base" }, repo)
  git({ "mv", "old.txt", "new.txt" }, repo)
  write_file(repo .. "/new.txt", "line1\nline2\nline3\nline4\n")
  write_file(repo .. "/added.txt", "staged then removed\n")
  git({ "add", "added.txt" }, repo)
  os.remove(repo .. "/added.txt")

  vim.cmd("cd " .. vim.fn.fnameescape(repo))
  open_status_and_wait()

  local function find(path)
    for _, item in ipairs(vim.b.currantgit_items or {}) do
      if item.path == path then return item end
    end
  end

  local renamed = find("new.txt")
  assert(renamed, "renamed item should be addressable by its new path")
  assert(renamed.old_path == "old.txt",
    "renamed item should expose the origin path separately from the new path")
  assert(renamed.change_kind == "renamed")

  local staged_then_removed = find("added.txt")
  assert(staged_then_removed, "AD item should still be discoverable")
  assert(staged_then_removed.change_kind ~= "conflict",
    "'AD' (staged add, worktree delete) is not a merge conflict")
  for _, section in ipairs(vim.b.currantgit_sections or {}) do
    assert(section.section_kind ~= "conflicts",
      "a clean-of-conflicts repository must not render a conflicts section")
  end

  -- The renamed item's actions must target the real, current file. Wait for
  -- a genuine buffer switch/changedtick increase, not just `filetype`,
  -- which a reused buffer could already satisfy (see docs/gotchas.md).
  goto_item("new.txt")
  local before_buffer = vim.api.nvim_get_current_buf()
  local before_tick = vim.api.nvim_buf_get_changedtick(before_buffer)
  local diff_mapping = vim.fn.maparg("d", "n", false, true)
  assert(diff_mapping.callback, "diff mapping was not registered")
  diff_mapping.callback()
  assert(vim.wait(3000, function()
    return vim.bo.filetype == "diff"
      and (vim.api.nvim_get_current_buf() ~= before_buffer
        or vim.api.nvim_buf_get_changedtick(before_buffer) > before_tick)
  end, 10), "diff on a renamed item did not open")
  assert_contains(vim.api.nvim_buf_get_lines(0, 0, -1, false), "+line4")

  vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
  vim.fn.delete(repo, "rf")
end

-- 6. Diff mode-trust (CRITICAL): staging a hunk applies its patch to the
-- live index via `git apply --cached`. That must only ever be offered for
-- a diff that actually represents the live index (`git diff` or
-- `git diff --cached`), never for an arbitrary historical comparison whose
-- "old" side may coincidentally match the current index and silently
-- create a phantom staged change.
local function test_diff_mode_trust()
  local repo = make_repo()
  write_file(repo .. "/file.txt", "a\n")
  git({ "add", "file.txt" }, repo)
  git({ "commit", "-q", "-m", "c1: a" }, repo)
  write_file(repo .. "/file.txt", "b\n")
  git({ "add", "file.txt" }, repo)
  git({ "commit", "-q", "-m", "c2: b" }, repo)
  write_file(repo .. "/file.txt", "a\n")
  git({ "add", "file.txt" }, repo)
  git({ "commit", "-q", "-m", "c3: back to a" }, repo)
  local c1 = git({ "rev-parse", "HEAD~2" }, repo)
  local c2 = git({ "rev-parse", "HEAD~1" }, repo)

  vim.cmd("cd " .. vim.fn.fnameescape(repo))
  -- A reused "diff" buffer can already satisfy `filetype == "diff"` from a
  -- previous test's render before this async diff finishes loading (the
  -- exact class of race documented in docs/gotchas.md). Wait for a genuine
  -- buffer switch or changedtick increase instead.
  local before_buffer = vim.api.nvim_get_current_buf()
  local before_tick = vim.api.nvim_buf_get_changedtick(before_buffer)
  currantgit.git({ "diff", c1, c2 })
  assert(vim.wait(3000, function()
    return vim.bo.filetype == "diff"
      and (vim.api.nvim_get_current_buf() ~= before_buffer
        or vim.api.nvim_buf_get_changedtick(before_buffer) > before_tick)
  end, 10), "historical diff did not open")

  local hunk_item
  for _, item in pairs(vim.b.currantgit_line_items or {}) do
    if type(item) == "table" and item.kind == "hunk" then hunk_item = item end
  end
  assert(hunk_item, "expected a hunk in the historical diff")
  assert(hunk_item.mode ~= "working" and hunk_item.mode ~= "staged",
    "a two-revision historical diff must not claim to be the live index: got mode="
      .. tostring(hunk_item.mode))

  local available = require("currantgit.actions").available(hunk_item, { buffer = 0 })
  for _, action in ipairs(available) do
    assert(action.id ~= "hunk.stage" and action.id ~= "hunk.unstage",
      "a historical diff must not offer to mutate the index via " .. action.id)
  end

  vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
  vim.fn.delete(repo, "rf")
end

test_cwd_race()
test_glob_pathspec()
test_blame_multiline()
test_diff_trailing_binary()
test_status_rename_and_status_codes()
test_diff_mode_trust()
assert(#currantgit.errors() == 0, table.concat(currantgit.errors(), "\n"))
print("CurrantGit safety: ok")
