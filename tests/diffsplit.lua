-- Two-pane diff viewer (`item.diff_split`, `D`). Every fixture is a real
-- repository; every interaction ends by asserting that the index and the
-- worktree did not move.
local currantgit = require("currantgit")
local original_cwd = vim.fn.getcwd()

local function git(args, cwd, allow_failure)
  local result = vim.system(vim.list_extend({ "git" }, args), { cwd = cwd, text = true }):wait()
  assert(allow_failure or result.code == 0, result.stderr)
  return vim.trim(result.stdout or "")
end

local function write_file(path, content)
  local file = assert(io.open(path, "wb"))
  file:write(content)
  file:close()
end

local function wait_for(predicate, message)
  assert(vim.wait(8000, predicate, 10), message)
  assert(#currantgit.errors() == 0, table.concat(currantgit.errors(), "\n"))
end

local function press(keys)
  assert(vim.fn.maparg(keys, "n", false, true).buffer == 1, "missing local mapping: " .. keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "xt", false)
end

local function snapshot(dir)
  return {
    git({ "ls-files", "-s", "-z" }, dir),
    git({ "status", "--porcelain=v1", "-z" }, dir),
    git({ "diff", "--binary" }, dir),
    git({ "rev-parse", "HEAD" }, dir),
  }
end

local ODD = "-2:ü [x].txt"

-- One repo holding every row shape: unstaged and staged edits of an
-- unusual path, a staged add, a staged delete and a worktree delete.
local function fixture()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  git({ "init", "-q", "-b", "main" }, dir)
  git({ "config", "user.name", "CurrantGit Split" }, dir)
  git({ "config", "user.email", "split@currantgit.invalid" }, dir)
  write_file(dir .. "/" .. ODD, "one\ntwo\nthree\n")
  write_file(dir .. "/gone-staged.txt", "staged delete\n")
  write_file(dir .. "/gone-worktree.txt", "worktree delete\n")
  git({ "add", "-A" }, dir)
  git({ "commit", "-q", "-m", "base" }, dir)
  write_file(dir .. "/" .. ODD, "one\nTWO\nthree\n")
  git({ "add", "--", ":(literal)" .. ODD }, dir)
  write_file(dir .. "/" .. ODD, "one\nTWO\nthree\nfour\n")
  write_file(dir .. "/new.txt", "fresh\n")
  git({ "add", "--", "new.txt" }, dir)
  git({ "rm", "-q", "--", "gone-staged.txt" }, dir)
  os.remove(dir .. "/gone-worktree.txt")
  return dir
end

local function open_status(dir)
  vim.cmd("cd " .. vim.fn.fnameescape(dir))
  local before = vim.api.nvim_get_current_buf()
  local tick = vim.api.nvim_buf_get_changedtick(before)
  currantgit.git({})
  wait_for(function()
    return vim.b.currantgit_title == "status"
      and (vim.api.nvim_get_current_buf() ~= before or vim.api.nvim_buf_get_changedtick(before) > tick)
  end, "status did not render")
  return vim.api.nvim_get_current_buf()
end

local function row(path, section)
  local sections = vim.b.currantgit_item_sections or {}
  for line, item in pairs(vim.b.currantgit_line_items or {}) do
    if type(item) == "table" and item.kind == "change" and item.path == path and sections[line] == section
      and vim.api.nvim_buf_get_lines(0, line - 1, line, false)[1]:find(path, 1, true) then
      return line
    end
  end
  error("no " .. section .. " row for " .. path)
end

local function text(buffer)
  return table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n")
end

-- Presses `D` on a row and returns the two pane windows/buffers.
local function split(status_buffer, path, section)
  vim.api.nvim_set_current_buf(status_buffer)
  vim.api.nvim_win_set_cursor(0, { row(path, section), 0 })
  local tab = vim.api.nvim_get_current_tabpage()
  press("D")
  wait_for(function()
    return vim.api.nvim_get_current_tabpage() ~= tab and vim.t.currantgit_diff_split ~= nil
  end, "diff split did not open for " .. section .. " " .. path)
  local windows = vim.api.nvim_tabpage_list_wins(0)
  assert(#windows == 2, "diff split should have exactly two panes")
  local panes = vim.t.currantgit_diff_split
  assert(vim.api.nvim_win_get_buf(windows[1]) == panes.old and vim.api.nvim_win_get_buf(windows[2]) == panes.new)
  assert(vim.api.nvim_get_current_win() == windows[2], "focus should land on the new side")
  for _, window in ipairs(windows) do
    assert(vim.wo[window].diff, "pane not in diff mode")
    assert(vim.wo[window].fillchars:find("diff:╱", 1, true), "filler should be hatched")
    assert(vim.wo[window].winhighlight:find("DiffDelete:CurrantGitDiffFiller", 1, true))
  end
  assert(vim.wo[windows[1]].winhighlight:find("DiffAdd:CurrantGitDiffOld", 1, true))
  assert(vim.wo[windows[2]].winhighlight:find("DiffAdd:CurrantGitDiffNew", 1, true))
  assert(vim.bo[panes.old].readonly and not vim.bo[panes.old].modifiable, "old side must be read-only")
  return panes, vim.wo[windows[1]].winbar, vim.wo[windows[2]].winbar
end

local function test_diff_split()
  local dir = fixture()
  local before = snapshot(dir)
  local status_buffer = open_status(dir)
  local head = git({ "rev-parse", "--short", "HEAD" }, dir)

  vim.api.nvim_win_set_cursor(0, { row(ODD, "unstaged"), 0 })
  local discovered = {}
  for _, action in ipairs(currantgit.discovery()) do discovered[action.id] = action.key end
  assert(discovered["item.diff_split"] == "D", "D should be discoverable on a change row")

  -- Unstaged: index (explicit :0:) vs the real, editable worktree file.
  local panes, old_bar, new_bar = split(status_buffer, ODD, "unstaged")
  assert(text(panes.old) == git({ "show", ":0:" .. ODD }, dir), "unstaged old side must be the index")
  assert(vim.fn.resolve(vim.api.nvim_buf_get_name(panes.new)) == vim.fn.resolve(dir .. "/" .. ODD))
  assert(vim.bo[panes.new].buftype == "" and vim.bo[panes.new].modifiable, "worktree side is the real file")
  assert(old_bar:find("index", 1, true) and new_bar:find("worktree", 1, true), old_bar .. " | " .. new_bar)
  -- gq from the worktree side closes the tab, and leaves no mapping behind
  -- on the user's real file.
  local worktree_buffer = panes.new
  press("gq")
  assert(vim.t.currantgit_diff_split == nil and vim.api.nvim_get_current_buf() == status_buffer,
    "gq should close the diff split tab")
  assert(vim.fn.maparg("gq", "n", false, true).buffer ~= 1)
  vim.api.nvim_buf_call(worktree_buffer, function()
    assert(vim.fn.maparg("gq", "n", false, true).buffer ~= 1, "gq must not stay on the real file")
  end)

  -- Staged: HEAD vs index, both read-only.
  panes, old_bar, new_bar = split(status_buffer, ODD, "staged")
  assert(text(panes.old) == git({ "show", "HEAD:" .. ODD }, dir))
  assert(text(panes.new) == git({ "show", ":0:" .. ODD }, dir))
  assert(vim.bo[panes.new].readonly and not vim.bo[panes.new].modifiable)
  assert(old_bar:find("HEAD " .. head, 1, true) and new_bar:find("index", 1, true), old_bar .. " | " .. new_bar)
  vim.cmd("wincmd h")
  press("gq")
  assert(vim.t.currantgit_diff_split == nil, "gq from the old side should close the tab")

  -- Added and deleted files get an empty, labelled side.
  panes, old_bar = split(status_buffer, "new.txt", "staged")
  assert(text(panes.old) == "" and vim.b[panes.old].currantgit_missing == true)
  assert(old_bar:find("none", 1, true) and text(panes.new) == "fresh", old_bar)
  vim.cmd("tabclose")
  panes, _, new_bar = split(status_buffer, "gone-staged.txt", "staged")
  assert(text(panes.old) == "staged delete" and text(panes.new) == "")
  assert(vim.b[panes.new].currantgit_missing == true and new_bar:find("deleted", 1, true), new_bar)
  vim.cmd("tabclose")
  panes, _, new_bar = split(status_buffer, "gone-worktree.txt", "unstaged")
  assert(text(panes.old) == "worktree delete" and text(panes.new) == "")
  assert(vim.bo[panes.new].readonly and new_bar:find("deleted", 1, true), new_bar)
  vim.cmd("tabclose")

  assert(vim.api.nvim_get_current_buf() == status_buffer)
  assert(vim.deep_equal(before, snapshot(dir)), "diff split changed the index or worktree")
  vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
  vim.fn.delete(dir, "rf")
end

test_diff_split()
