-- Slice 1 of docs/issues/0010: read-only conflict items and resolver view.
-- Every fixture is a real Git merge; every interaction ends by asserting
-- that Git's own index/worktree state did not move.
local currantgit = require("currantgit")
local conflict = require("currantgit.conflict")
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

local function read_file(path)
  local file = assert(io.open(path, "rb"))
  local content = file:read("*a")
  file:close()
  return content
end

local function wait_for(predicate, message)
  assert(vim.wait(8000, predicate, 10), message)
  assert(#currantgit.errors() == 0, table.concat(currantgit.errors(), "\n"))
end

local function press(keys)
  assert(vim.fn.maparg(keys, "n", false, true).buffer == 1, "missing local mapping: " .. keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "xt", false)
end

-- Builds base -> (ours on the default branch, theirs on `other`) and runs a
-- real `git merge` that is expected to conflict. `files` maps a path to
-- { base = content|nil, ours = content|nil, theirs = content|nil }; nil
-- means the file is absent on that side.
local function conflicted_repo(files, style)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  git({ "init", "-q", "-b", "main" }, dir)
  git({ "config", "user.name", "CurrantGit Conflict" }, dir)
  git({ "config", "user.email", "conflict@currantgit.invalid" }, dir)
  if style then git({ "config", "merge.conflictStyle", style }, dir) end
  local function stage(side)
    for path, sides in pairs(files) do
      if sides[side] then
        write_file(dir .. "/" .. path, sides[side])
        git({ "add", "--", ":(literal)" .. path }, dir)
      elseif vim.loop.fs_stat(dir .. "/" .. path) then
        git({ "rm", "-q", "--", ":(literal)" .. path }, dir)
      end
    end
    git({ "commit", "-q", "--allow-empty", "-m", side }, dir)
  end
  stage("base")
  git({ "checkout", "-q", "-b", "other" }, dir)
  stage("theirs")
  git({ "checkout", "-q", "main" }, dir)
  stage("ours")
  git({ "merge", "-q", "other" }, dir, true)
  assert(git({ "ls-files", "-u" }, dir) ~= "", "fixture did not conflict")
  return dir
end

local function snapshot(dir)
  return {
    git({ "ls-files", "-s", "-z" }, dir),
    git({ "ls-files", "-u", "-z" }, dir),
    git({ "status", "--porcelain=v1", "-z" }, dir),
    git({ "rev-parse", "HEAD", "MERGE_HEAD" }, dir),
  }
end

local function load(dir, path)
  local loaded
  conflict.load(dir, { path = path, status = "UU" }, function(item) loaded = item end)
  wait_for(function() return loaded ~= nil end, "conflict load did not finish: " .. path)
  return loaded
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
end

local function status_row(path)
  for line, item in pairs(vim.b.currantgit_line_items or {}) do
    if type(item) == "table" and item.kind == "conflict-file" and item.path == path then
      return line, item, vim.api.nvim_buf_get_lines(0, line - 1, line, false)[1]
    end
  end
  error("no conflict-file row for " .. path)
end

local BASE = "a\nb\nc\nd\ne\n"
local OURS = "a\nX\nZ\nc\nd\nOE\n"
local THEIRS = "a\nX\nY\nc\nd\nTE\n"

-- 1. Pure marker parsing: the three documented merge.conflictStyle shapes,
-- labels, an unterminated region, and marker-lookalike lines.
local function test_parse_markers()
  local merge = conflict.parse_markers({
    "a", "<<<<<<< HEAD", "o1", "o2", "=======", "t1", ">>>>>>> other", "z",
  })
  assert(#merge == 1)
  assert(merge[1].start == 2 and merge[1].finish == 7)
  assert(vim.deep_equal(merge[1].ours, { "o1", "o2" }) and vim.deep_equal(merge[1].theirs, { "t1" }))
  assert(merge[1].base == nil and merge[1].ours_label == "HEAD" and merge[1].theirs_label == "other")

  local diff3 = conflict.parse_markers({
    "<<<<<<< HEAD", "o", "||||||| 8188004", "b", "=======", ">>>>>>> other",
    "<<<<<<<", "=======", ">>>>>>>",
  })
  assert(#diff3 == 2)
  assert(vim.deep_equal(diff3[1].base, { "b" }) and diff3[1].base_label == "8188004")
  assert(#diff3[1].theirs == 0 and diff3[2].start == 7 and #diff3[2].ours == 0)

  -- Unterminated region, and lines that only look like markers.
  local loose = conflict.parse_markers({
    "<<<<<<<< eight", "=======x", ">>>>>>>", "<<<<<<< HEAD", "x", "=======", "y",
  })
  assert(#loose == 0, "lookalike or unterminated markers must not form a region")
end

-- 2. Region count follows merge.conflictStyle: `merge` style coalesces two
-- nearby conflicts that diff3/zdiff3 keep separate (verified against real
-- Git, docs/gotchas.md). The re-merge of the index stages must agree with
-- the worktree in every style.
local function test_styles_and_counts()
  for style, expected in pairs({ merge = 1, diff3 = 2, zdiff3 = 2 }) do
    local dir = conflicted_repo({ ["f.txt"] = { base = BASE, ours = OURS, theirs = THEIRS } }, style)
    local before = snapshot(dir)
    local item = load(dir, "f.txt")
    assert(item.id == "conflict-file:f.txt" and item.kind == "conflict-file")
    assert(item.total == expected and item.unresolved == expected and item.resolved == 0,
      style .. ": expected " .. expected .. " regions, got " .. tostring(item.total))
    assert(#item.regions == expected)
    for n, region in ipairs(item.regions) do
      assert(region.id == "conflict:f.txt:" .. n and region.kind == "conflict")
      assert(region.state == "unresolved" and region.result_range)
    end
    if style ~= "merge" then
      assert(vim.deep_equal(item.regions[2].base, { "e" }), style .. ": base comes from stage 1")
      assert(vim.deep_equal(item.regions[2].ours, { "OE" }) and vim.deep_equal(item.regions[2].theirs, { "TE" }))
    end
    -- Resolving the first region in the worktree moves it to resolved.
    local lines = vim.split(read_file(dir .. "/f.txt"), "\n", { plain = true })
    local first = item.regions[1].result_range
    local kept = {}
    for index, line in ipairs(lines) do
      if index < first[1] or index > first[2] then kept[#kept + 1] = line
      elseif index == first[1] then kept[#kept + 1] = "RESOLVED" end
    end
    write_file(dir .. "/f.txt", table.concat(kept, "\n"))
    local after = load(dir, "f.txt")
    assert(after.total == expected and after.unresolved == expected - 1 and after.resolved == 1)
    assert(after.regions[1].state == "edited" and not after.regions[1].result_range)
    if expected == 2 then
      assert(after.regions[2].id == "conflict:f.txt:2" and after.regions[2].state == "unresolved",
        "a resolved earlier region must not renumber a later one")
    end
    before[3] = nil
    local now = snapshot(dir)
    now[3] = nil
    assert(vim.deep_equal(before, now), "loading conflicts changed the index")
    vim.fn.delete(dir, "rf")
  end
end

-- 3. add/add has no stage 1; delete/modify has no stage 2 or 3; binary
-- content cannot be re-merged. None of these may error or invent regions.
local function test_missing_stages_and_binary()
  local dir = conflicted_repo({
    ["added.txt"] = { ours = "a\nOURS\nc\n", theirs = "a\nTHEIRS\nc\n" },
    ["deleted-by-them.txt"] = { base = BASE, ours = OURS },
    ["deleted-by-us.txt"] = { base = BASE, theirs = THEIRS },
    ["blob.bin"] = { base = "\0base\n", ours = "\0ours\n", theirs = "\0theirs\n" },
  })
  local added = load(dir, "added.txt")
  assert(added.stages[1] == nil and added.stages[2] and added.stages[3])
  assert(added.total == 1 and added.unresolved == 1 and added.regions[1].base == nil)
  local by_them = load(dir, "deleted-by-them.txt")
  assert(by_them.stages[3] == nil and by_them.total == nil and #by_them.regions == 0)
  assert(by_them.missing == "theirs")
  local by_us = load(dir, "deleted-by-us.txt")
  assert(by_us.stages[2] == nil and by_us.missing == "ours" and by_us.total == nil)
  local binary = load(dir, "blob.bin")
  assert(binary.binary and binary.total == nil and #binary.regions == 0)

  local before = snapshot(dir)
  open_status(dir)
  local _, _, added_row = status_row("added.txt")
  assert(added_row:find("0/1", 1, true), "add/add row should show 0/1: " .. added_row)
  local _, _, them_row = status_row("deleted-by-them.txt")
  assert(them_row:find("deleted by them", 1, true), them_row)
  local _, _, us_row = status_row("deleted-by-us.txt")
  assert(us_row:find("deleted by us", 1, true), us_row)
  local _, _, binary_row = status_row("blob.bin")
  assert(binary_row:find("binary", 1, true), binary_row)

  -- The resolver opens for a delete/modify file with an empty, labelled
  -- missing side instead of failing.
  local line = status_row("deleted-by-them.txt")
  vim.api.nvim_win_set_cursor(0, { line, 0 })
  press("<CR>")
  wait_for(function() return vim.t.currantgit_conflict ~= nil end, "delete/modify resolver did not open")
  local panes = vim.t.currantgit_conflict
  assert(vim.api.nvim_buf_get_name(panes.theirs):find("currantgit://conflict/theirs/", 1, true))
  assert(vim.b[panes.theirs].currantgit_missing == true)
  assert(vim.api.nvim_buf_line_count(panes.theirs) == 1
    and vim.api.nvim_buf_get_lines(panes.theirs, 0, 1, false)[1] == "")
  vim.cmd("tabclose")
  assert(vim.deep_equal(before, snapshot(dir)), "missing-stage interactions changed repository state")
  vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
  vim.fn.delete(dir, "rf")
end

-- 4. End-to-end interactions on a path built to break naive handling:
-- leading dash, digit-colon (decisions/0012), space, unicode, glob byte.
local function test_resolver_interactions()
  local odd = "-2:ü [x].txt"
  local dir = conflicted_repo({
    [odd] = { base = BASE, ours = OURS, theirs = THEIRS },
    ["plain.txt"] = { base = "1\n", ours = "1o\n", theirs = "1t\n" },
    ["clean.txt"] = { base = "c\n", ours = "c\n", theirs = "c2\n" },
  }, "diff3")
  local before = snapshot(dir)
  open_status(dir)
  local status_buffer = vim.api.nvim_get_current_buf()
  local odd_line, odd_item, odd_row = status_row(odd)
  assert(odd_item.id == "conflict-file:" .. odd and odd_item.change_kind == "conflict")
  assert(odd_row:find("0/2", 1, true), "status row should show resolved/total: " .. odd_row)
  local plain_line = status_row("plain.txt")
  assert(currantgit.which_key()["]x"], "]x should be discoverable while conflicts exist")

  -- ]x / [x walk conflict rows in status, without wrapping.
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  press("]x")
  local first_line = math.min(odd_line, plain_line)
  local second_line = math.max(odd_line, plain_line)
  assert(vim.api.nvim_win_get_cursor(0)[1] == first_line, "]x did not reach the first conflict")
  press("]x")
  assert(vim.api.nvim_win_get_cursor(0)[1] == second_line, "]x did not reach the second conflict")
  press("]x")
  assert(vim.api.nvim_win_get_cursor(0)[1] == second_line, "]x must stop at the last conflict")
  press("[x")
  assert(vim.api.nvim_win_get_cursor(0)[1] == first_line, "[x did not move back")

  -- <CR> opens ours | result | theirs in native diff mode.
  vim.api.nvim_win_set_cursor(0, { odd_line, 0 })
  local discovered = {}
  for _, action in ipairs(currantgit.discovery()) do discovered[action.id] = action.key end
  assert(discovered["conflict.open"] == "<CR>" and not discovered["item.open"])
  assert(not discovered["item.discard"] and not discovered["item.diff_toggle"])
  press("<CR>")
  wait_for(function() return vim.t.currantgit_conflict ~= nil end, "resolver did not open")
  local panes = vim.t.currantgit_conflict
  assert(#vim.api.nvim_tabpage_list_wins(0) == 3, "resolver should have exactly three panes")
  local windows = vim.api.nvim_tabpage_list_wins(0)
  assert(vim.api.nvim_win_get_buf(windows[1]) == panes.ours)
  assert(vim.api.nvim_win_get_buf(windows[2]) == panes.result)
  assert(vim.api.nvim_win_get_buf(windows[3]) == panes.theirs)
  assert(vim.api.nvim_get_current_win() == windows[2], "focus should land in the result pane")
  for _, window in ipairs(windows) do assert(vim.wo[window].diff, "pane not in diff mode") end
  assert(vim.fn.resolve(vim.api.nvim_buf_get_name(panes.result)) == vim.fn.resolve(dir .. "/" .. odd),
    "result must be the real file")
  assert(vim.bo[panes.result].modifiable and vim.bo[panes.result].buftype == "")
  for side, stage in pairs({ ours = 2, theirs = 3 }) do
    local buffer = panes[side]
    assert(vim.bo[buffer].readonly and not vim.bo[buffer].modifiable, side .. " must be read-only")
    local expected = git({ "show", ":" .. stage .. ":" .. odd }, dir)
    local shown = table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n")
    assert(vim.trim(shown) == expected, side .. " pane must come from index stage " .. stage)
  end
  local file_item = vim.b[panes.result].currantgit_conflict
  assert(file_item.id == "conflict-file:" .. odd and file_item.total == 2)

  -- Presentation: each side has its own colors, filler is hatched, marker
  -- lines keep their real text plus an end-of-line label, and the result
  -- winbar tracks resolution live.
  assert(vim.wo[windows[1]].winhighlight:find("DiffAdd:CurrantGitConflictOurs", 1, true))
  assert(vim.wo[windows[3]].winhighlight:find("DiffAdd:CurrantGitConflictTheirs", 1, true))
  for _, window in ipairs(windows) do
    assert(vim.wo[window].fillchars:find("diff:╱", 1, true))
    assert(vim.wo[window].winhighlight:find("DiffDelete:CurrantGitConflictFiller", 1, true),
      "filler must not use the red 'deleted' color")
  end
  assert(vim.wo[windows[1]].winbar:find("ours", 1, true) and vim.wo[windows[1]].winbar:find("main", 1, true))
  assert(vim.wo[windows[3]].winbar:find("theirs", 1, true) and vim.wo[windows[3]].winbar:find("other", 1, true))
  assert(vim.wo[windows[2]].winbar:find("0 of 2 resolved", 1, true), vim.wo[windows[2]].winbar)
  local namespace = vim.api.nvim_create_namespace("currantgit_conflict")
  local groups, labels = {}, {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(panes.result, namespace, 0, -1, { details = true })) do
    if mark[4].line_hl_group then groups[mark[4].line_hl_group] = true end
    for _, chunk in ipairs(mark[4].virt_text or {}) do labels[#labels + 1] = chunk[1] end
  end
  assert(groups.CurrantGitConflictOurs and groups.CurrantGitConflictTheirs and groups.CurrantGitConflictBase)
  assert(groups.CurrantGitConflictMarker)
  assert(table.concat(labels, " "):find("ours", 1, true) and table.concat(labels, " "):find("theirs", 1, true))
  local first_region = conflict.parse_markers(vim.api.nvim_buf_get_lines(panes.result, 0, -1, false))[1]
  local saved = vim.api.nvim_buf_get_lines(panes.result, 0, -1, false)
  vim.api.nvim_buf_set_lines(panes.result, first_region.start - 1, first_region.finish, false, { "picked" })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = panes.result })
  assert(vim.wo[windows[2]].winbar:find("1 of 2 resolved", 1, true), vim.wo[windows[2]].winbar)
  vim.api.nvim_buf_set_lines(panes.result, 0, -1, false, saved)
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = panes.result })
  vim.bo[panes.result].modified = false

  -- ]x / [x jump between region items in the result pane.
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  press("]x")
  local regions = conflict.parse_markers(vim.api.nvim_buf_get_lines(0, 0, -1, false))
  assert(vim.api.nvim_win_get_cursor(0)[1] == regions[1].start)
  assert(conflict.current_region(panes.result).id == "conflict:" .. odd .. ":1")
  press("]x")
  assert(vim.api.nvim_win_get_cursor(0)[1] == regions[2].start)
  assert(conflict.current_region(panes.result).id == "conflict:" .. odd .. ":2")
  press("]x")
  assert(vim.api.nvim_win_get_cursor(0)[1] == regions[2].start, "]x must stop at the last region")
  press("[x")
  assert(vim.api.nvim_win_get_cursor(0)[1] == regions[1].start)

  -- gb toggles a read-only base view (stage 1), outside diff mode.
  press("gb")
  wait_for(function() return #vim.api.nvim_tabpage_list_wins(0) == 4 end, "base view did not open")
  assert(vim.api.nvim_get_current_win() == windows[2], "base toggle must keep focus in result")
  local base_buffer = vim.t.currantgit_conflict.base
  assert(vim.bo[base_buffer].readonly and not vim.bo[base_buffer].modifiable)
  assert(vim.trim(table.concat(vim.api.nvim_buf_get_lines(base_buffer, 0, -1, false), "\n"))
    == git({ "show", ":1:" .. odd }, dir))
  assert(not vim.wo[vim.fn.bufwinid(base_buffer)].diff, "base view must not join the 3-way diff")
  press("gb")
  assert(#vim.api.nvim_tabpage_list_wins(0) == 3, "second gb should close the base view")

  -- Nothing here wrote the file or touched the index.
  assert(not vim.bo[panes.result].modified)
  vim.cmd("tabclose")
  assert(vim.api.nvim_get_current_buf() == status_buffer)
  assert(vim.deep_equal(before, snapshot(dir)), "resolver interactions changed repository state")
  vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
  vim.fn.delete(dir, "rf")
end

test_parse_markers()
test_styles_and_counts()
test_missing_stages_and_binary()
test_resolver_interactions()
