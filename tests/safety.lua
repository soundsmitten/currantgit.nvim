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

-- `--name-only` without `-z` C-quotes/octal-escapes unusual paths (same
-- `core.quotePath` behavior as diff headers -- see diff.lua's
-- `unquote_diff_path`), so a plain string comparison against a raw unicode
-- filename would spuriously fail even when the correct file is staged.
-- `-z` gives raw, unquoted, NUL-terminated paths instead.
local function changed_paths(args, cwd)
  local result = vim.system(vim.list_extend({ "git" }, vim.list_extend(vim.deepcopy(args), { "-z" })), {
    cwd = cwd, text = true,
  }):wait()
  assert(result.code == 0, result.stderr)
  local paths = {}
  for _, entry in ipairs(vim.split(result.stdout or "", "\0", { plain = true })) do
    if entry ~= "" then paths[#paths + 1] = entry end
  end
  return paths
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

-- 7. `:Git` argument splitting (HIGH): `command.args` (Neovim's `<args>`,
-- confirmed via `:help nvim_create_user_command()` to be the raw,
-- unprocessed argument string -- NOT quote-aware `<q-args>`-then-split) must
-- be tokenized the way a user typing `:Git commit -m "two words"` expects: a
-- quoted multi-word argument survives as one argv element. Naive
-- whitespace-only splitting instead produces `{"commit", "-m", '"two',
-- 'words"'}`, which either fails outright or silently commits the wrong
-- message.
local function test_git_command_quoted_args()
  local repo = make_repo()
  write_file(repo .. "/f.txt", "one\n")
  git({ "add", "f.txt" }, repo)
  git({ "commit", "-q", "-m", "base" }, repo)
  write_file(repo .. "/f.txt", "one\ntwo\n")
  git({ "add", "f.txt" }, repo)

  vim.cmd("cd " .. vim.fn.fnameescape(repo))
  vim.cmd([[Git commit -m "two words"]])
  assert(vim.wait(3000, function()
    return git({ "log", "-1", "--format=%s" }, repo) == "two words"
  end, 10), "quoted multi-word :Git commit argument was not preserved as one argv element")
  assert(git({ "status", "--porcelain" }, repo) == "", "commit should have left the worktree clean")

  write_file(repo .. "/f.txt", "one\ntwo\nthree\n")
  git({ "add", "f.txt" }, repo)
  vim.cmd([[Git commit -m 'single-quoted words too']])
  assert(vim.wait(3000, function()
    return git({ "log", "-1", "--format=%s" }, repo) == "single-quoted words too"
  end, 10), "single-quoted multi-word :Git commit argument was not preserved as one argv element")

  write_file(repo .. "/f.txt", "one\ntwo\nthree\nfour\n")
  git({ "add", "f.txt" }, repo)
  vim.cmd([[Git commit -m "quote: \"nested\""]])
  assert(vim.wait(3000, function()
    return git({ "log", "-1", "--format=%s" }, repo) == 'quote: "nested"'
  end, 10), "escaped double-quote inside a quoted argument was not preserved")

  -- An unterminated quote is malformed input: refuse cleanly and touch
  -- nothing, rather than guessing where the argument was meant to end.
  -- Dispatched through real cmdline key input (`nvim_feedkeys`), not
  -- `vim.cmd()`/`nvim_exec2()` -- a synchronous `vim.notify(ERROR)` inside a
  -- user-command callback re-raises as a Vim error when invoked through
  -- `nvim_exec2`, which is an artifact of that entry point, not of how a
  -- real `:Git ...<CR>` keypress behaves.
  local before_status = git({ "status", "--porcelain" }, repo)
  vim.api.nvim_feedkeys(
    vim.api.nvim_replace_termcodes([[:Git commit -m "unterminated<CR>]], true, false, true),
    "x",
    false
  )
  vim.wait(200, function() return false end, 10)
  assert(git({ "status", "--porcelain" }, repo) == before_status,
    "an unterminated quote must not run any Git command or change repository state")

  vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
  vim.fn.delete(repo, "rf")
end

-- 8. Bare repository (audit continuation item 2): a bare repo has no
-- working tree, so `git rev-parse --show-toplevel` (which `repository_root`
-- relies on) fails with a clear, real Git error rather than returning a
-- path. Every top-level entry point must surface that failure as a boring
-- notification and never crash or render a misleading/empty surface.
local function test_bare_repository_refuses_cleanly()
  local dir = vim.fn.tempname()
  git({ "init", "-q", "--bare", dir })

  vim.cmd("cd " .. vim.fn.fnameescape(dir))
  local before_buffer = vim.api.nvim_get_current_buf()
  currantgit.git({})
  vim.wait(300, function() return false end, 10)
  -- `repository_root()` fails before `open_status` ever calls `set_buffer`
  -- (which always switches the current buffer), so the current buffer must
  -- be unchanged. Checking the *previously current* buffer's filetype would
  -- be wrong: it could already be a reused `currantgit://status` buffer left
  -- over from an earlier test in this same Neovim instance (see
  -- docs/gotchas.md on stale-render buffer reuse).
  assert(vim.api.nvim_get_current_buf() == before_buffer,
    "a bare repository has no working tree; :Git status must not render a status surface")

  currantgit.git({ "log" })
  vim.wait(300, function() return false end, 10)
  currantgit.git({ "diff" })
  vim.wait(300, function() return false end, 10)
  assert(#currantgit.errors() == 0,
    "bare-repository commands must fail as clean notifications, not crashes: "
      .. table.concat(currantgit.errors(), "\n"))

  vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
  vim.fn.delete(dir, "rf")
end

-- 9. Detached HEAD (audit continuation item 2): `## HEAD (no branch)` is a
-- real, valid `git status --porcelain=v1 -z --branch` header line, and every
-- ordinary action (status render, diff) must keep working normally against
-- a detached-HEAD checkout.
local function test_detached_head()
  local repo = make_repo()
  write_file(repo .. "/f.txt", "one\n")
  git({ "add", "f.txt" }, repo)
  git({ "commit", "-q", "-m", "c1" }, repo)
  write_file(repo .. "/f.txt", "one\ntwo\n")
  git({ "add", "f.txt" }, repo)
  git({ "commit", "-q", "-m", "c2" }, repo)
  git({ "checkout", "-q", "--detach", "HEAD~1" }, repo)
  write_file(repo .. "/f.txt", "one\ndetached-edit\n")

  vim.cmd("cd " .. vim.fn.fnameescape(repo))
  open_status_and_wait()
  assert_contains(vim.api.nvim_buf_get_lines(0, 0, -1, false), "HEAD (no branch)")
  goto_item("f.txt")

  local before_buffer = vim.api.nvim_get_current_buf()
  local before_tick = vim.api.nvim_buf_get_changedtick(before_buffer)
  local diff_mapping = vim.fn.maparg("d", "n", false, true)
  assert(diff_mapping.callback, "diff mapping was not registered")
  diff_mapping.callback()
  assert(vim.wait(3000, function()
    return vim.bo.filetype == "diff"
      and (vim.api.nvim_get_current_buf() ~= before_buffer
        or vim.api.nvim_buf_get_changedtick(before_buffer) > before_tick)
  end, 10), "diff did not open against a detached-HEAD checkout")
  assert_contains(vim.api.nvim_buf_get_lines(0, 0, -1, false), "+detached-edit")
  assert(#currantgit.errors() == 0, table.concat(currantgit.errors(), "\n"))

  vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
  vim.fn.delete(repo, "rf")
end

-- 10. Unborn branch / zero-commit repository (audit continuation item 2):
-- `## No commits yet on <branch>` is a real, valid status header, `git log`
-- and `git blame` both fail with a real, expected Git error (no HEAD to
-- resolve yet) rather than hanging or crashing, and `git diff` against an
-- empty index/worktree is simply empty.
local function test_unborn_branch()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  git({ "init", "-q", "-b", "main" }, dir)
  git({ "config", "user.name", "CurrantGit Safety" }, dir)
  git({ "config", "user.email", "safety@currantgit.invalid" }, dir)
  write_file(dir .. "/f.txt", "content\n")

  vim.cmd("cd " .. vim.fn.fnameescape(dir))
  open_status_and_wait()
  assert_contains(vim.api.nvim_buf_get_lines(0, 0, -1, false), "No commits yet on main")
  assert_contains(vim.api.nvim_buf_get_lines(0, 0, -1, false), "f.txt")

  currantgit.git({ "log" })
  vim.wait(300, function() return false end, 10)
  currantgit.git({ "diff" })
  vim.wait(300, function() return false end, 10)
  vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/f.txt"))
  currantgit.git({ "blame", "f.txt" })
  vim.wait(300, function() return false end, 10)
  assert(#currantgit.errors() == 0,
    "unborn-branch log/diff/blame must fail as clean notifications, not crashes: "
      .. table.concat(currantgit.errors(), "\n"))

  vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
  vim.fn.delete(dir, "rf")
end

local function open_diff_and_wait(args)
  local before_buffer = vim.api.nvim_get_current_buf()
  local before_tick = vim.api.nvim_buf_get_changedtick(before_buffer)
  currantgit.git(args)
  assert(vim.wait(3000, function()
    return vim.bo.filetype == "diff"
      and (vim.api.nvim_get_current_buf() ~= before_buffer
        or vim.api.nvim_buf_get_changedtick(before_buffer) > before_tick)
  end, 10), "diff did not open for " .. table.concat(args, " "))
end

-- Stages the hunk under the cursor and waits for BOTH the real Git state
-- (`git_predicate`, independently re-derived) and CurrantGit's own
-- post-stage refresh (`open_diff_args` re-running `git diff`) to actually
-- finish, not just the former. Waiting on real Git state alone is not
-- enough here: `stage_hunk`'s callback kicks off its own async `git diff`
-- refresh, and if a test moves on (and deletes its repo) before that
-- refresh's subprocess has actually spawned, it fails later with an ENOENT
-- against a directory that no longer exists -- corrupting an unrelated
-- later test. See docs/gotchas.md on waiting for genuine completion, not a
-- flag/state a stale render could already satisfy.
local function stage_current_hunk_and_wait(git_predicate)
  local before_buffer = vim.api.nvim_get_current_buf()
  local before_tick = vim.api.nvim_buf_get_changedtick(before_buffer)
  local stage_mapping = vim.fn.maparg("s", "n", false, true)
  assert(stage_mapping.callback, "stage-hunk mapping was not registered")
  stage_mapping.callback()
  assert(vim.wait(3000, function()
    return git_predicate()
      and vim.bo.filetype == "diff"
      and (vim.api.nvim_get_current_buf() ~= before_buffer
        or vim.api.nvim_buf_get_changedtick(before_buffer) > before_tick)
  end, 10), "hunk stage did not settle")
end

local function goto_hunk(index)
  index = index or 1
  local found = 0
  local lines = {}
  for line, item in pairs(vim.b.currantgit_line_items or {}) do
    if type(item) == "table" and item.kind == "hunk" then lines[#lines + 1] = line end
  end
  table.sort(lines)
  local line = lines[index]
  assert(line, "expected at least " .. index .. " hunk(s) in the diff")
  vim.api.nvim_win_set_cursor(0, { line, 0 })
end

-- 11. `git apply --cached` on a hunk touching a file with no trailing
-- newline (audit continuation item 3): Git represents this with a literal
-- `\ No newline at end of file` marker line in the diff. Staging must
-- reproduce the exact byte content, not silently gain or lose a trailing
-- newline.
local function test_hunk_stage_no_trailing_newline()
  local repo = make_repo()
  write_file(repo .. "/f.txt", "line1\nline2")
  git({ "add", "f.txt" }, repo)
  git({ "commit", "-q", "-m", "base" }, repo)
  write_file(repo .. "/f.txt", "line1\nline2-changed")

  vim.cmd("cd " .. vim.fn.fnameescape(repo))
  open_diff_and_wait({ "diff", "--", "f.txt" })
  goto_hunk(1)
  stage_current_hunk_and_wait(function()
    return git({ "diff", "--cached", "--name-only" }, repo) == "f.txt"
  end)

  local staged = git({ "cat-file", "blob", ":f.txt" }, repo)
  assert(staged == "line1\nline2-changed",
    "staged blob must byte-match the working tree content exactly, got: " .. vim.inspect(staged))
  assert(git({ "diff", "--name-only" }, repo) == "", "the file should now be fully staged")
  assert(#currantgit.errors() == 0, table.concat(currantgit.errors(), "\n"))

  vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
  vim.fn.delete(repo, "rf")
end

-- 12. Sequential multi-hunk staging (audit continuation item 3):
-- stage_hunk/unstage_hunk always re-run `git diff` after mutating the index
-- (see `open_diff_args` callback in `action_context`), so a second hunk's
-- patch is regenerated against the now-current index rather than reused
-- stale. Staging both hunks in a two-hunk file, one at a time, must fully
-- stage the file with nothing left unstaged.
local function test_hunk_stage_sequential_multi_hunk()
  local repo = make_repo()
  local lines = {}
  for line_number = 1, 20 do lines[line_number] = tostring(line_number) end
  write_file(repo .. "/f.txt", table.concat(lines, "\n") .. "\n")
  git({ "add", "f.txt" }, repo)
  git({ "commit", "-q", "-m", "base" }, repo)
  lines[2] = "TWO-changed"
  lines[18] = "EIGHTEEN-changed"
  write_file(repo .. "/f.txt", table.concat(lines, "\n") .. "\n")

  vim.cmd("cd " .. vim.fn.fnameescape(repo))
  open_diff_and_wait({ "diff", "--", "f.txt" })
  goto_hunk(1)
  -- `currantgit_line_items` maps every LINE inside a hunk's body to that
  -- same hunk object (see diff.lua), so counting entries there counts lines,
  -- not hunks. `currantgit_diff_hunks` is the actual per-hunk list.
  stage_current_hunk_and_wait(function()
    return #(vim.b.currantgit_diff_hunks or {}) == 1
  end)

  goto_hunk(1)
  stage_current_hunk_and_wait(function()
    return git({ "diff", "--name-only" }, repo) == ""
  end)

  assert(git({ "diff", "--cached", "--name-only" }, repo) == "f.txt", "both hunks should now be staged")
  local staged = git({ "cat-file", "blob", ":f.txt" }, repo)
  assert(staged:find("TWO%-changed") and staged:find("EIGHTEEN%-changed"),
    "both hunks' content must be present in the staged blob")
  assert(#currantgit.errors() == 0, table.concat(currantgit.errors(), "\n"))

  vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
  vim.fn.delete(repo, "rf")
end

-- 13. Failed hunk application is atomic (audit continuation item 3): if a
-- hunk's patch no longer applies (its context has already diverged from the
-- index), `git apply --cached` must fail the whole patch and leave the index
-- completely unchanged (`git help apply`: "For atomicity, git apply by
-- default fails the whole patch and does not touch the working tree when
-- some of the hunks do not apply") -- never a partial/corrupt index state,
-- and CurrantGit must surface it as a clean error, not silently do nothing
-- while claiming success.
local function test_hunk_stage_atomic_on_conflict()
  local repo = make_repo()
  write_file(repo .. "/f.txt", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n")
  git({ "add", "f.txt" }, repo)
  git({ "commit", "-q", "-m", "base" }, repo)
  write_file(repo .. "/f.txt", "1\n2\n3\n4\nFIVE-changed\n6\n7\n8\n9\n10\n")

  vim.cmd("cd " .. vim.fn.fnameescape(repo))
  open_diff_and_wait({ "diff", "--", "f.txt" })
  goto_hunk(1)
  local hunk_item = vim.b.currantgit_line_items[vim.api.nvim_win_get_cursor(0)[1]]
  assert(type(hunk_item) == "table" and hunk_item.kind == "hunk", "expected a hunk under the cursor")
  local stale_patch = hunk_item.patch

  -- Stage it for real once (this is the legitimate path), which makes the
  -- index already equal the patch's "new" side.
  stage_current_hunk_and_wait(function()
    return git({ "diff", "--cached", "--name-only" }, repo) == "f.txt"
      and git({ "diff", "--name-only" }, repo) == ""
  end)

  local index_before = git({ "cat-file", "blob", ":f.txt" }, repo)
  -- Re-applying the SAME (now stale) patch text directly against the
  -- current index must fail, and fail without mutating anything -- this
  -- reproduces the "diff buffer went stale, user still presses the stage
  -- key" race directly against real Git, independent of CurrantGit's own
  -- reporting of the outcome.
  local result = vim.system({ "git", "apply", "--cached", "--unidiff-zero" }, {
    cwd = repo,
    text = true,
    stdin = stale_patch,
  }):wait()
  assert(result.code ~= 0, "a stale hunk patch must not apply cleanly a second time")
  local index_after = git({ "cat-file", "blob", ":f.txt" }, repo)
  assert(index_before == index_after,
    "a failed git apply --cached must leave the index completely unchanged")

  vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
  vim.fn.delete(repo, "rf")
end

-- 14. A hunk's patch is pinned to the moment the diff was rendered, not to
-- the live worktree (audit continuation item 3, "stale hunk"): `git apply
-- --cached` only ever compares against the INDEX, never the worktree. If the
-- worktree changes again after a diff is opened but before the index has
-- been touched, staging the (now visually stale) hunk still succeeds --
-- because its "old" side still matches the untouched index -- and stages
-- exactly the patch that was visible when the diff was opened, not
-- whatever is in the worktree now. This is correct, expected `git apply
-- --cached` behavior (it is defined purely in terms of the index), not data
-- loss: the worktree's further edit is left completely untouched. Recorded
-- as a real, non-obvious behavior a user could be surprised by, not treated
-- as a bug to "fix" by inventing staleness detection Git itself has no
-- concept of.
local function test_hunk_stage_pinned_to_render_time_not_worktree()
  local repo = make_repo()
  write_file(repo .. "/f.txt", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n")
  git({ "add", "f.txt" }, repo)
  git({ "commit", "-q", "-m", "base" }, repo)
  write_file(repo .. "/f.txt", "1\n2\n3\n4\nFIVE-changed\n6\n7\n8\n9\n10\n")

  vim.cmd("cd " .. vim.fn.fnameescape(repo))
  open_diff_and_wait({ "diff", "--", "f.txt" })
  goto_hunk(1)

  -- The worktree changes again after the diff was rendered, before the
  -- index has been touched at all.
  write_file(repo .. "/f.txt", "1\n2\n3\n4\nFIVE-changed-EXTERNALLY\n6\n7\n8\n9\n10\n")

  stage_current_hunk_and_wait(function()
    return git({ "diff", "--cached", "--name-only" }, repo) == "f.txt"
  end)

  local staged = git({ "cat-file", "blob", ":f.txt" }, repo)
  assert(staged:find("FIVE%-changed\n") and not staged:find("EXTERNALLY"),
    "the staged content should be exactly what the diff showed, not the later worktree edit")
  assert(read_file(repo .. "/f.txt"):find("EXTERNALLY"),
    "the later worktree edit must survive untouched in the working tree")
  assert(#currantgit.errors() == 0, table.concat(currantgit.errors(), "\n"))

  vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
  vim.fn.delete(repo, "rf")
end

-- 15. Unusual-but-valid paths through the real UI (audit continuation item
-- 4, combined with item 5): a filename containing non-ASCII bytes makes Git
-- C-quote/octal-escape it in unified-diff headers (`core.quotePath`, always
-- on for such bytes) -- `diff --git "a/caf\303\251.txt" "b/caf\303\251.txt"`,
-- not `diff --git a/café.txt b/café.txt`. `diff.lua`'s
-- `+++ b/(.+)` header-path regex didn't match that quoted form, so it fell
-- through to `open_diff_args`'s naive fallback path -- which, reached via
-- the real `d` (diff) mapping, is the RAW constructed pathspec including
-- CurrantGit's own `:(literal)` prefix, not the real filename. `hunk.path`
-- ended up literally `":(literal)café.txt"`. Also exercises stage, unstage,
-- discard, open, and blame against unicode, embedded-space, and
-- leading-dash filenames end-to-end.
local function test_unusual_paths_end_to_end()
  local repo = make_repo()
  local paths = { "café.txt", "file with spaces.txt", "-dashfile.txt" }
  for _, path in ipairs(paths) do
    write_file(repo .. "/" .. path, "one\n")
  end
  git({ "add", "." }, repo)
  git({ "commit", "-q", "-m", "base" }, repo)
  for _, path in ipairs(paths) do
    write_file(repo .. "/" .. path, "one\ntwo\n")
  end

  vim.cmd("cd " .. vim.fn.fnameescape(repo))

  for _, path in ipairs(paths) do
    open_status_and_wait()
    goto_item(path)

    local before_buffer = vim.api.nvim_get_current_buf()
    local before_tick = vim.api.nvim_buf_get_changedtick(before_buffer)
    local diff_mapping = vim.fn.maparg("d", "n", false, true)
    diff_mapping.callback()
    assert(vim.wait(3000, function()
      return vim.bo.filetype == "diff"
        and (vim.api.nvim_get_current_buf() ~= before_buffer
          or vim.api.nvim_buf_get_changedtick(before_buffer) > before_tick)
    end, 10), "diff did not open for " .. path)
    assert_contains(vim.api.nvim_buf_get_lines(0, 0, -1, false), "+two")
    for _, item in pairs(vim.b.currantgit_line_items or {}) do
      if type(item) == "table" and item.kind == "hunk" then
        assert(item.path == path,
          "hunk.path for " .. path .. " must be the real filename, got: " .. vim.inspect(item.path))
      end
    end

    open_status_and_wait()
    goto_item(path)
    local stage_mapping = vim.fn.maparg("s", "n", false, true)
    stage_mapping.callback()
    assert(vim.wait(3000, function()
      local staged = changed_paths({ "diff", "--cached", "--name-only" }, repo)
      return vim.tbl_contains(staged, path)
    end, 10), "stage did not settle for " .. path)

    open_status_and_wait()
    goto_item(path)
    local unstage_mapping = vim.fn.maparg("u", "n", false, true)
    unstage_mapping.callback()
    assert(vim.wait(3000, function()
      return not vim.tbl_contains(changed_paths({ "diff", "--cached", "--name-only" }, repo), path)
    end, 10), "unstage did not settle for " .. path)
    local unstaged = changed_paths({ "diff", "--name-only" }, repo)
    assert(vim.tbl_contains(unstaged, path), "the file should be back to unstaged-modified")

    open_status_and_wait()
    goto_item(path)
    local before_blame_buffer = vim.api.nvim_get_current_buf()
    local blame_mapping = vim.fn.maparg("b", "n", false, true)
    blame_mapping.callback()
    assert(vim.wait(3000, function()
      return vim.api.nvim_get_current_buf() ~= before_blame_buffer and vim.bo.filetype == "git"
    end, 10), "blame did not open for " .. path)
    assert_contains(vim.api.nvim_buf_get_lines(0, 0, -1, false), "one")

    open_status_and_wait()
    goto_item(path)
    local original_select = vim.ui.select
    vim.ui.select = function(_, _, callback) callback("Discard", 1) end
    local discard_mapping = vim.fn.maparg("X", "n", false, true)
    discard_mapping.callback()
    assert(vim.wait(3000, function()
      for _, item in ipairs(vim.b.currantgit_items or {}) do
        if item.path == path then return false end
      end
      return true
    end, 10), "discard did not settle for " .. path)
    vim.ui.select = original_select
    assert(read_file(repo .. "/" .. path) == "one\n", "discard did not revert " .. path)
  end

  for _, path in ipairs(paths) do
    assert(read_file(repo .. "/" .. path) == "one\n", path .. " must be back to its committed content")
  end
  assert(#currantgit.errors() == 0, table.concat(currantgit.errors(), "\n"))

  vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
  vim.fn.delete(repo, "rf")
end

test_cwd_race()
test_glob_pathspec()
test_blame_multiline()
test_diff_trailing_binary()
test_status_rename_and_status_codes()
test_diff_mode_trust()
test_git_command_quoted_args()
test_bare_repository_refuses_cleanly()
test_detached_head()
test_unborn_branch()
test_hunk_stage_no_trailing_newline()
test_hunk_stage_sequential_multi_hunk()
test_hunk_stage_atomic_on_conflict()
test_hunk_stage_pinned_to_render_time_not_worktree()
test_unusual_paths_end_to_end()
assert(#currantgit.errors() == 0, table.concat(currantgit.errors(), "\n"))
print("CurrantGit safety: ok")
