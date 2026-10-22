-- Visual-mode (`x`) multi-select actions: `s`/`u`/`-`/`X` across every
-- unique item on the selected status lines, and `s`/`u` across every
-- selected hunk in a diff surface or inline `=` diff. Every assertion
-- re-derives the index from Git itself (`git diff --cached --name-only -z`),
-- never from CurrantGit's own rendering.
local currantgit = require("currantgit")
local original_cwd = vim.fn.getcwd()

local function git(args, cwd)
  local result = vim.system(vim.list_extend({ "git" }, args), { cwd = cwd, text = true }):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout or "")
end

local function changed_paths(args, cwd)
  local result = vim.system(vim.list_extend({ "git" }, vim.list_extend(vim.deepcopy(args), { "-z" })), {
    cwd = cwd, text = true,
  }):wait()
  assert(result.code == 0, result.stderr)
  local paths = {}
  for _, entry in ipairs(vim.split(result.stdout or "", "\0", { plain = true })) do
    if entry ~= "" then paths[#paths + 1] = entry end
  end
  table.sort(paths)
  return paths
end

local function staged(repo) return changed_paths({ "diff", "--cached", "--name-only" }, repo) end
local function unstaged(repo) return changed_paths({ "diff", "--name-only" }, repo) end

local function same(actual, expected, message)
  table.sort(expected)
  assert(vim.deep_equal(actual, expected), message .. ": expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual))
end

local function write_file(path, content)
  local file = assert(io.open(path, "w"))
  file:write(content)
  file:close()
end

local function make_repo(files)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  git({ "init", "-q" }, dir)
  git({ "config", "user.name", "CurrantGit Visual" }, dir)
  git({ "config", "user.email", "visual@currantgit.invalid" }, dir)
  for path, content in pairs(files) do write_file(dir .. "/" .. path, content) end
  git({ "add", "." }, dir)
  git({ "commit", "-q", "-m", "base" }, dir)
  return dir
end

local function leave(repo)
  vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
  vim.fn.delete(repo, "rf")
end

local function wait_render(trigger, expected_filetype)
  local buffer = vim.api.nvim_get_current_buf()
  local tick = vim.api.nvim_buf_get_changedtick(buffer)
  trigger()
  assert(vim.wait(5000, function()
    return vim.bo.filetype == expected_filetype
      and (vim.api.nvim_get_current_buf() ~= buffer or vim.api.nvim_buf_get_changedtick(buffer) > tick)
  end, 10), "surface did not render as " .. expected_filetype)
end

local function open_status(repo)
  vim.cmd("cd " .. vim.fn.fnameescape(repo))
  wait_render(function() currantgit.git({}) end, "currantgit")
  assert(vim.b.currantgit_title == "status")
end

-- Line of `path` under the section heading starting with `heading`.
local function item_line(path, heading)
  local current
  for line, text in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
    if text:match("^%u%l+ .* %(%d+%)$") then current = text end
    local item = vim.b.currantgit_line_items[line]
    if type(item) == "table" and item.kind == "change" and item.path == path
      and current and vim.startswith(current, heading) then
      return line
    end
  end
  error("no " .. path .. " under " .. heading)
end

local function hunk_lines()
  local lines = {}
  for line, item in pairs(vim.b.currantgit_line_items or {}) do
    if type(item) == "table" and item.kind == "hunk" and item.header and vim.startswith(
      vim.api.nvim_buf_get_lines(0, line - 1, line, false)[1] or "", "@@") then
      lines[#lines + 1] = line
    end
  end
  table.sort(lines)
  return lines
end

-- Select lines first..last linewise and press `key` through real typeahead,
-- so the `x`-mode mapping itself is what runs. Waits for the post-action
-- re-render, which only happens once that action's Git call has finished.
local function visual(first, last, key, filetype, git_predicate)
  vim.api.nvim_win_set_cursor(0, { first, 0 })
  wait_render(function()
    vim.api.nvim_feedkeys("V" .. (last > first and (tostring(last - first) .. "j") or "") .. key, "x", false)
  end, filetype or "currantgit")
  if git_predicate then
    assert(vim.wait(3000, git_predicate, 10), "Git state did not settle after visual " .. key)
  end
  assert(vim.fn.mode() == "n", "visual action should return to normal mode")
end

local function capture_notify(callback)
  local messages = {}
  local original = vim.notify
  vim.notify = function(message, level) messages[#messages + 1] = { message = message, level = level } end
  local ok, error_message = pcall(callback)
  vim.notify = original
  assert(ok, error_message)
  return messages
end

-- Status: visual `s` stages every applicable file in one call, keeps
-- glob characters literal, and reports the rows it skipped.
local function test_visual_stage_files()
  local repo = make_repo({ ["a.txt"] = "a\n", ["[ab].txt"] = "glob\n", ["b.txt"] = "b\n", ["keep.txt"] = "k\n" })
  write_file(repo .. "/a.txt", "A\n")
  write_file(repo .. "/[ab].txt", "GLOB\n")
  write_file(repo .. "/b.txt", "B\n")
  git({ "add", "--", "b.txt" }, repo)
  write_file(repo .. "/keep.txt", "K\n")
  write_file(repo .. "/new.txt", "new\n")
  open_status(repo)
  assert(vim.fn.maparg("s", "x") ~= "", "visual s mapping was not registered")

  -- Staged b.txt is selected too: it has nothing left to stage, so it is
  -- skipped rather than failing the whole batch.
  local messages = capture_notify(function()
    visual(item_line("b.txt", "Staged"), item_line("a.txt", "Unstaged"), "s", nil, function()
      return #staged(repo) == 3
    end)
  end)
  -- Unstaged rows sort as `[ab].txt`, `a.txt`, `keep.txt`.
  same(staged(repo), { "[ab].txt", "a.txt", "b.txt" }, "exactly the selected files should be staged")
  local skipped = false
  for _, entry in ipairs(messages) do
    if entry.message:find("skipped", 1, true) and entry.message:find("b.txt", 1, true) then skipped = true end
  end
  assert(skipped, "skipped items should be reported: " .. vim.inspect(messages))

  local first = item_line("keep.txt", "Unstaged")
  visual(first, item_line("new.txt", "Untracked"), "s", nil, function() return #staged(repo) == 5 end)
  same(staged(repo), { "[ab].txt", "a.txt", "b.txt", "keep.txt", "new.txt" }, "selection should stage literally")
  same(unstaged(repo), {}, "nothing should be left unstaged")
  leave(repo)
end

local function test_visual_unstage_toggle_discard()
  local repo = make_repo({ ["a.txt"] = "a\n", ["b.txt"] = "b\n", ["c.txt"] = "c\n", ["d.txt"] = "d\n" })
  for _, name in ipairs({ "a", "b", "c", "d" }) do write_file(repo .. "/" .. name .. ".txt", name:upper() .. "\n") end
  git({ "add", "--", "a.txt", "b.txt" }, repo)
  open_status(repo)

  visual(item_line("a.txt", "Staged"), item_line("b.txt", "Staged"), "u", nil, function() return #staged(repo) == 0 end)
  same(unstaged(repo), { "a.txt", "b.txt", "c.txt", "d.txt" }, "visual u should unstage both files")

  git({ "add", "--", "a.txt" }, repo)
  open_status(repo)
  -- `-` flips each selected file: staged a.txt unstages, unstaged b/c stage.
  visual(item_line("a.txt", "Staged"), item_line("c.txt", "Unstaged"), "-", nil, function()
    return vim.deep_equal(staged(repo), { "b.txt", "c.txt" })
  end)
  same(staged(repo), { "b.txt", "c.txt" }, "visual - should toggle each file once")

  local prompts = {}
  local original_select = vim.ui.select
  vim.ui.select = function(choices, options, callback)
    prompts[#prompts + 1] = options.prompt
    callback(choices[1], 1)
  end
  local ok, error_message = pcall(function()
    visual(item_line("a.txt", "Unstaged"), item_line("d.txt", "Unstaged"), "X", nil, function()
      return #unstaged(repo) == 0
    end)
  end)
  vim.ui.select = original_select
  assert(ok, error_message)
  assert(#prompts == 1, "X should confirm exactly once, got " .. #prompts)
  for _, name in ipairs({ "a.txt", "d.txt" }) do
    assert(prompts[1]:find(name, 1, true), "confirmation should list " .. name .. ": " .. prompts[1])
  end
  same(staged(repo), { "b.txt", "c.txt" }, "discard must not touch the index")
  assert(git({ "show", ":b.txt" }, repo) == "B", "staged content must survive discard")
  leave(repo)
end

local function numbered(count, changes)
  local lines = {}
  for index = 1, count do lines[index] = changes[index] or tostring(index) end
  return table.concat(lines, "\n") .. "\n"
end

-- Diff surface: visual s/u apply every selected hunk as one patch.
local function test_visual_diff_hunks()
  local repo = make_repo({ ["f.txt"] = numbered(30, {}), ["g.txt"] = numbered(30, {}) })
  write_file(repo .. "/f.txt", numbered(30, { [2] = "TWO", [15] = "FIFTEEN", [28] = "TWENTY-EIGHT" }))
  write_file(repo .. "/g.txt", numbered(30, { [3] = "THREE" }))
  vim.cmd("cd " .. vim.fn.fnameescape(repo))
  wait_render(function() currantgit.git({ "diff" }) end, "diff")
  assert(vim.fn.maparg("s", "x") ~= "", "visual s mapping was not registered on the diff surface")
  local hunks = hunk_lines()
  assert(#hunks == 4, "expected four hunks, got " .. #hunks)

  -- Select from inside f's second hunk through g's only hunk: f hunks 2, 3
  -- and g hunk 1 are staged, f hunk 1 is not.
  visual(hunks[2] + 1, hunks[4], "s", "diff", function() return #staged(repo) == 2 end)
  local index_f = git({ "show", ":f.txt" }, repo)
  assert(not index_f:find("TWO") and index_f:find("FIFTEEN") and index_f:find("TWENTY%-EIGHT"),
    "exactly the selected f.txt hunks should be staged: " .. index_f)
  assert(git({ "show", ":g.txt" }, repo):find("THREE"), "g.txt hunk should be staged")

  wait_render(function() currantgit.git({ "diff", "--cached" }) end, "diff")
  hunks = hunk_lines()
  assert(#hunks == 3, "expected three staged hunks, got " .. #hunks)
  -- Unstage f's TWENTY-EIGHT hunk and g's hunk; f's FIFTEEN stays staged.
  visual(hunks[2], hunks[3], "u", "diff", function() return vim.deep_equal(staged(repo), { "f.txt" }) end)
  index_f = git({ "show", ":f.txt" }, repo)
  assert(index_f:find("FIFTEEN") and not index_f:find("TWENTY%-EIGHT"), "only the selected staged hunks should unstage")
  assert(not git({ "show", ":g.txt" }, repo):find("THREE"), "g.txt should be fully unstaged")
  leave(repo)
end

-- Atomicity: if any selected hunk no longer applies, none of them do.
local function test_visual_hunks_atomic()
  local repo = make_repo({ ["f.txt"] = numbered(30, {}) })
  write_file(repo .. "/f.txt", numbered(30, { [2] = "TWO", [28] = "TWENTY-EIGHT" }))
  vim.cmd("cd " .. vim.fn.fnameescape(repo))
  wait_render(function() currantgit.git({ "diff" }) end, "diff")
  local hunks = hunk_lines()
  -- Make the second hunk's patch stale against the index behind the
  -- rendered diff's back.
  vim.system({ "git", "update-index", "--cacheinfo",
    "100644," .. vim.trim(vim.system({ "git", "hash-object", "-w", "--stdin" }, {
      cwd = repo, text = true, stdin = numbered(30, { [28] = "OTHER" }),
    }):wait().stdout) .. ",f.txt" }, { cwd = repo }):wait()
  local before = git({ "show", ":f.txt" }, repo)
  local messages = capture_notify(function()
    vim.api.nvim_win_set_cursor(0, { hunks[1], 0 })
    vim.api.nvim_feedkeys("V" .. (hunks[2] - hunks[1]) .. "js", "x", false)
    vim.wait(500)
  end)
  assert(git({ "show", ":f.txt" }, repo) == before, "a failed multi-hunk apply must leave the index unchanged")
  local errored = false
  for _, entry in ipairs(messages) do
    if entry.level == vim.log.levels.ERROR then errored = true end
  end
  assert(errored, "a failed apply should surface an error")
  leave(repo)
end

-- Status inline `=` diffs: s/u on a hunk resolve to hunk.stage/unstage
-- (regression: they used to dispatch item.stage), and the status surface
-- re-renders afterwards rather than replacing itself with a diff.
local function test_status_inline_hunks()
  local repo = make_repo({ ["f.txt"] = numbered(30, {}), ["g.txt"] = numbered(30, {}) })
  write_file(repo .. "/f.txt", numbered(30, { [2] = "TWO", [28] = "TWENTY-EIGHT" }))
  write_file(repo .. "/g.txt", numbered(30, { [3] = "THREE", [20] = "TWENTY" }))
  open_status(repo)
  local function expand(path)
    vim.api.nvim_win_set_cursor(0, { item_line(path, "Unstaged"), 0 })
    local count = vim.api.nvim_buf_line_count(0)
    vim.fn.maparg("=", "n", false, true).callback()
    assert(vim.wait(2000, function() return vim.api.nvim_buf_line_count(0) > count end, 10), path .. " did not expand")
  end
  expand("f.txt")
  vim.api.nvim_win_set_cursor(0, { hunk_lines()[1] + 1, 0 })
  wait_render(function() vim.api.nvim_feedkeys("s", "x", false) end, "currantgit")
  assert(vim.wait(3000, function() return #staged(repo) == 1 end, 10), "normal s on an inline hunk should stage it")
  assert(vim.b.currantgit_title == "status", "status should refresh in place, not open a diff")
  local index_f = git({ "show", ":f.txt" }, repo)
  assert(index_f:find("TWO") and not index_f:find("TWENTY%-EIGHT"), "only the hunk under the cursor should stage")

  -- Select both of g's inline hunks (a selection crossing a file row is
  -- a mixed selection; see below).
  expand("g.txt")
  local unstaged_hunks = {}
  for _, line in ipairs(hunk_lines()) do
    local hunk = vim.b.currantgit_line_items[line]
    if hunk.mode == "working" and hunk.path == "g.txt" then unstaged_hunks[#unstaged_hunks + 1] = line end
  end
  assert(#unstaged_hunks == 2, "expected two unstaged g.txt hunks, got " .. #unstaged_hunks)
  visual(unstaged_hunks[1], unstaged_hunks[2] + 1, "s", nil, function()
    return vim.deep_equal(unstaged(repo), { "f.txt" })
  end)
  assert(vim.b.currantgit_title == "status")
  same(staged(repo), { "f.txt", "g.txt" }, "both g.txt hunks should stage")
  local index_g = git({ "show", ":g.txt" }, repo)
  assert(index_g:find("THREE") and index_g:find("TWENTY"), "both g.txt hunks should be in the index")

  -- Mixed file rows and hunks in one selection are refused, not guessed at.
  write_file(repo .. "/g.txt", numbered(30, { [3] = "THREE", [20] = "TWENTY", [25] = "TWENTY-FIVE" }))
  open_status(repo)
  expand("g.txt")
  local before = staged(repo)
  local before_blob = git({ "show", ":g.txt" }, repo)
  local messages = capture_notify(function()
    local row = item_line("g.txt", "Unstaged")
    local first_hunk
    for _, line in ipairs(hunk_lines()) do
      if line > row and not first_hunk then first_hunk = line end
    end
    vim.api.nvim_win_set_cursor(0, { row, 0 })
    vim.api.nvim_feedkeys("V" .. (first_hunk - row) .. "js", "x", false)
    vim.wait(300)
  end)
  same(staged(repo), before, "a mixed selection must not change the index")
  assert(git({ "show", ":g.txt" }, repo) == before_blob, "a mixed selection must not change the index")
  assert(#messages > 0, "a mixed selection should explain the refusal")
  leave(repo)
end

-- Adversarial: a hunk ending in `\ No newline at end of file` followed by
-- another file's hunk in one combined patch must keep exact bytes; and a
-- deleted file is staged and discarded correctly as part of a batch.
local function test_visual_edge_cases()
  local repo = make_repo({ ["a.txt"] = "1\n2", ["b.txt"] = "x\n", ["gone.txt"] = "gone\n", ["z.txt"] = "z\n" })
  write_file(repo .. "/a.txt", "1\nTWO")
  write_file(repo .. "/b.txt", "X\n")
  vim.cmd("cd " .. vim.fn.fnameescape(repo))
  wait_render(function() currantgit.git({ "diff" }) end, "diff")
  local hunks = hunk_lines()
  visual(hunks[1], hunks[2], "s", "diff", function() return #staged(repo) == 2 end)
  assert(git({ "cat-file", "blob", ":a.txt" }, repo) == "1\nTWO", "no-newline hunk must stage byte-exactly")
  local raw = vim.system({ "git", "cat-file", "blob", ":a.txt" }, { cwd = repo, text = true }):wait().stdout
  assert(raw == "1\nTWO", "staged blob must not gain a trailing newline: " .. vim.inspect(raw))
  git({ "reset", "-q" }, repo)

  os.remove(repo .. "/gone.txt")
  write_file(repo .. "/z.txt", "Z\n")
  open_status(repo)
  visual(item_line("a.txt", "Unstaged"), item_line("gone.txt", "Unstaged"), "s", nil, function() return #staged(repo) == 3 end)
  assert(git({ "diff", "--cached", "--name-status", "--", "gone.txt" }, repo):match("^D"), "deletion should be staged")
  git({ "reset", "-q" }, repo)
  open_status(repo)
  local original_select = vim.ui.select
  vim.ui.select = function(choices, _, callback) callback(choices[1], 1) end
  local ok, error_message = pcall(visual, item_line("gone.txt", "Unstaged"), item_line("z.txt", "Unstaged"), "X", nil,
    function() return #unstaged(repo) == 2 end)
  vim.ui.select = original_select
  assert(ok, error_message)
  same(unstaged(repo), { "a.txt", "b.txt" }, "only the selected files should be discarded")
  assert(vim.fn.filereadable(repo .. "/gone.txt") == 1, "discard should restore the deleted file")
  leave(repo)
end

test_visual_stage_files()
test_visual_edge_cases()
test_visual_unstage_toggle_discard()
test_visual_diff_hunks()
test_visual_hunks_atomic()
test_status_inline_hunks()
assert(#currantgit.errors() == 0, table.concat(currantgit.errors(), "\n"))
print("CurrantGit visual: ok")
