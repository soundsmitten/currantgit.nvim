local function assert_contains(lines, needle)
  for _, line in ipairs(lines) do
    if line:find(needle, 1, true) then
      return
    end
  end
  error("expected buffer to contain: " .. needle)
end

local currantgit = require("currantgit")
local navigation = require("currantgit.navigation")

-- A valid reused buffer can become shorter while another view is current.
-- Back/forward navigation must reconcile its saved cursor and view with the
-- buffer's current contents instead of replaying stale coordinates verbatim.
do
  local window = vim.api.nvim_get_current_win()
  local original_buffer = vim.api.nvim_get_current_buf()
  local shrinking_buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(window, shrinking_buffer)
  local long_lines = {}
  for line = 1, 100 do long_lines[line] = "line " .. line .. " with a long tail" end
  vim.api.nvim_buf_set_lines(shrinking_buffer, 0, -1, false, long_lines)
  vim.api.nvim_win_set_cursor(window, { 90, 20 })
  vim.cmd("normal! zt")
  navigation.reset(window)
  navigation.visit(window)

  local destination_buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(window, destination_buffer)
  vim.api.nvim_buf_set_lines(destination_buffer, 0, -1, false, { "destination" })
  navigation.visit(window)
  vim.api.nvim_buf_set_lines(shrinking_buffer, 0, -1, false, { "short" })

  local back_mapping = vim.fn.maparg("<C-O>", "n", false, true)
  assert(back_mapping.callback, "navigation regression back mapping was not registered")
  back_mapping.callback()
  assert(vim.api.nvim_get_current_buf() == shrinking_buffer, "back did not restore the shortened buffer")
  assert(vim.deep_equal(vim.api.nvim_win_get_cursor(window), { 1, 4 }), "back did not clamp the stale cursor")
  local restored_view = vim.fn.winsaveview()
  assert(restored_view.lnum == 1 and restored_view.topline == 1, "back did not clamp the stale saved view")

  local forward_mapping = vim.fn.maparg("<C-S-I>", "n", false, true)
  assert(forward_mapping.callback, "navigation regression forward mapping was not registered")
  forward_mapping.callback()
  assert(vim.api.nvim_get_current_buf() == destination_buffer, "forward did not restore the destination buffer")

  vim.api.nvim_buf_set_lines(shrinking_buffer, 0, -1, false, {})
  back_mapping = vim.fn.maparg("<C-O>", "n", false, true)
  back_mapping.callback()
  assert(vim.deep_equal(vim.api.nvim_win_get_cursor(window), { 1, 0 }), "back did not handle an empty projection")

  navigation.reset(window)
  local first_buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(window, first_buffer)
  navigation.visit(window)
  local deleted_buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(window, deleted_buffer)
  navigation.visit(window)
  local last_buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(window, last_buffer)
  navigation.visit(window)
  vim.api.nvim_buf_delete(deleted_buffer, { force = true })
  back_mapping = vim.fn.maparg("<C-O>", "n", false, true)
  back_mapping.callback()
  assert(vim.api.nvim_get_current_buf() == first_buffer, "back did not skip an invalid history buffer")
  forward_mapping = vim.fn.maparg("<C-S-I>", "n", false, true)
  forward_mapping.callback()
  assert(vim.api.nvim_get_current_buf() == last_buffer, "forward did not skip an invalid history buffer")

  navigation.reset(window)
  vim.api.nvim_win_set_buf(window, original_buffer)
  vim.api.nvim_buf_delete(shrinking_buffer, { force = true })
  vim.api.nvim_buf_delete(destination_buffer, { force = true })
  vim.api.nvim_buf_delete(first_buffer, { force = true })
  vim.api.nvim_buf_delete(last_buffer, { force = true })
end

-- A history entry's buffer can be valid but unloaded (`:bunload` without
-- `!`) when navigation returns to it. Its line count reads as 0 until the
-- window is switched to it, which previously reconciled the stale cursor
-- against that 0-line count before the buffer was reloaded.
do
  local window = vim.api.nvim_get_current_win()
  local original_buffer = vim.api.nvim_get_current_buf()
  local unloadable_buffer = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(unloadable_buffer, 0, -1, false, { "one", "two", "three", "four", "five" })
  vim.api.nvim_win_set_buf(window, unloadable_buffer)
  vim.api.nvim_win_set_cursor(window, { 5, 0 })
  navigation.reset(window)
  navigation.visit(window)

  local other_buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(window, other_buffer)
  navigation.visit(window)

  vim.bo[unloadable_buffer].modified = false
  vim.cmd("bunload " .. unloadable_buffer)
  assert(vim.api.nvim_buf_is_valid(unloadable_buffer), "unload regression requires a still-valid buffer")
  assert(not vim.api.nvim_buf_is_loaded(unloadable_buffer), "unload regression requires an unloaded buffer")

  local back_mapping = vim.fn.maparg("<C-O>", "n", false, true)
  local ok = pcall(back_mapping.callback)
  assert(ok, "back crashed restoring a valid-but-unloaded history buffer")
  assert(vim.api.nvim_get_current_buf() == unloadable_buffer, "back did not restore the unloaded buffer")

  navigation.reset(window)
  vim.api.nvim_win_set_buf(window, original_buffer)
  vim.api.nvim_buf_delete(unloadable_buffer, { force = true })
  vim.api.nvim_buf_delete(other_buffer, { force = true })
end

-- discovery()/which_key() accept an explicit buffer argument, so they must
-- read the cursor from a window actually showing that buffer, not from
-- whichever window happens to be focused.
do
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "header", "item-a", "item-b" })
  vim.b[buffer].currantgit_line_items = { [2] = { id = "marker-a" }, [3] = { id = "marker-b" } }
  local window = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(window, buffer)
  vim.api.nvim_win_set_cursor(window, { 2, 0 })

  vim.cmd("split")
  local other_window = vim.api.nvim_get_current_win()
  local other_buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(other_buffer, 0, -1, false, { "x", "y", "z" })
  vim.api.nvim_win_set_buf(other_window, other_buffer)
  vim.api.nvim_win_set_cursor(other_window, { 3, 0 })

  local actions_module = require("currantgit.actions")
  local captured_item
  local original_discovery = actions_module.discovery
  actions_module.discovery = function(item, ctx)
    captured_item = item
    return original_discovery(item, ctx)
  end
  currantgit.discovery(buffer)
  actions_module.discovery = original_discovery
  assert(captured_item and captured_item.id == "marker-a",
    "discovery() should read the cursor from the requested buffer's own window, not the focused window")

  vim.cmd("close")
  vim.api.nvim_buf_delete(buffer, { force = true })
  vim.api.nvim_buf_delete(other_buffer, { force = true })
end

local ordinary_buffer = vim.api.nvim_get_current_buf()
assert(vim.b[ordinary_buffer].currantgit_line_items == nil, "API regression requires an ordinary buffer")
local discovery_ok, ordinary_discovery = pcall(currantgit.discovery, ordinary_buffer)
assert(discovery_ok, "public discovery crashed outside a CurrantGit buffer")
assert(vim.tbl_isempty(ordinary_discovery), "public discovery should be empty outside a CurrantGit buffer")
local which_key_ok, ordinary_which_key = pcall(currantgit.which_key, ordinary_buffer)
assert(which_key_ok, "public which_key crashed outside a CurrantGit buffer")
assert(vim.tbl_isempty(ordinary_which_key), "public which_key should be empty outside a CurrantGit buffer")
local invalid_buffer = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_delete(invalid_buffer, { force = true })
assert(vim.tbl_isempty(currantgit.discovery(invalid_buffer)), "public discovery should be empty for an invalid buffer")
assert(vim.tbl_isempty(currantgit.which_key(invalid_buffer)), "public which_key should be empty for an invalid buffer")

local defaults = currantgit.get_config()
assert(defaults.ui.title == nil, "status headers should default to the repository name")
assert(defaults.ui.icons.modified == "M", "configuration icon defaults are not loaded")

local rpc = currantgit.rpc({
  capabilities = { "action.dispatch", "repository.snapshot" },
  handlers = { ping = function(params) return params.value end },
})
local capabilities = rpc:request({ id = 1, method = "rpc.capabilities" })
assert(capabilities.result.version == 1, "RPC capabilities should expose the protocol version")
local ping = rpc:request({ id = 2, method = "ping", params = { value = "pong" } })
assert(ping.result.value == "pong" and ping.result.revision == 1, "RPC handler response is malformed")
local missing = rpc:request({ id = 3, method = "nope" })
assert(missing.error.code == "method_not_found", "RPC should return structured unknown-method errors")

local function assert_no_async_errors()
  assert(#currantgit.errors() == 0, table.concat(currantgit.errors(), "\n"))
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

-- A refresh that reuses the current buffer can leave `filetype`/
-- `currantgit_title` already satisfied from the *previous* render, so
-- waiting on those flags alone can return before the new async status
-- fetch actually finishes. Track the buffer's changedtick (or a genuine
-- buffer switch) so the wait only succeeds once the refresh has landed.
local function wait_for_status_refresh(trigger)
  local buffer = vim.api.nvim_get_current_buf()
  local tick = vim.api.nvim_buf_get_changedtick(buffer)
  trigger()
  assert(vim.wait(5000, function()
    return vim.bo.filetype == "currantgit" and vim.b.currantgit_title == "status"
      and (vim.api.nvim_get_current_buf() ~= buffer or vim.api.nvim_buf_get_changedtick(buffer) > tick)
  end, 10), "status refresh did not settle")
end

vim.cmd("Git")
vim.wait(5000, function()
  return vim.bo.filetype == "currantgit"
end)

assert(vim.bo.filetype == "currantgit", "Git status did not open a CurrantGit surface")
assert_no_async_errors()
local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
assert_contains(lines, "M tracked.txt")
for _, line in ipairs(lines) do
  assert(not line:find("^  M  tracked%.txt$"), "status rows should use compact marker/path spacing")
end
assert(not lines[1]:find("CurrantGit", 1, true), "default status header should not contain the plugin name")
assert_contains(lines, "Changes")
assert(vim.b.currantgit_items, "status surface did not expose semantic items")
assert(#vim.b.currantgit_items >= 5, "fixture should expose staged, modified, discard, deleted, and untracked items")
assert(vim.wo.foldmethod == "expr", "status surface should use native expression folds")
assert(#vim.b.currantgit_sections == 3, "fixture should expose staged, unstaged, and untracked sections")

local unstaged_line = vim.fn.search("Unstaged changes")
assert(unstaged_line > 0, "unstaged section is missing")
assert(vim.fn.foldlevel(unstaged_line) == 1, "section should be a fold root")
assert(vim.fn.foldlevel(unstaged_line + 1) == 2, "section items should be nested under the fold root")
vim.cmd("normal! zc")
assert(vim.fn.foldclosed(unstaged_line) == unstaged_line, "section should collapse with native fold commands")
vim.cmd("normal! zo")

goto_item("tracked.txt")
local current_item = vim.b.currantgit_line_items[vim.api.nvim_win_get_cursor(0)[1]]
local actions = require("currantgit.actions").available(current_item, { buffer = 0 })
local discovery = require("currantgit.actions").discovery(current_item, { buffer = 0 })
local discovered_ids = {}
for _, action in ipairs(discovery) do discovered_ids[action.id] = action end
assert(discovered_ids["item.open"].desc == "open", "discovery metadata should expose action descriptions")
assert(require("currantgit").discovery()[1].key, "public discovery projection should expose keys")
assert(require("currantgit").which_key()["<CR>"].desc == "open", "WhichKey projection should expose the open action")
local action_ids = {}
for _, action in ipairs(actions) do
  action_ids[action.id] = true
end
assert(action_ids["item.open"], "change item is missing the open action")
assert(action_ids["item.diff"], "change item is missing the diff action")
assert(action_ids["item.stage"], "unstaged change is missing the stage action")
assert(action_ids["item.toggle"], "change is missing the toggle action")
assert(action_ids["item.discard"], "unstaged change is missing the discard action")
assert(not action_ids["item.unstage"], "unstaged change should not expose unstage")
assert(action_ids["surface.refresh"], "surface is missing the refresh action")
assert_contains(vim.api.nvim_buf_get_lines(0, 0, -1, false), "Actions:")

local status_buffer = vim.api.nvim_get_current_buf()
local status_namespace = vim.api.nvim_create_namespace("currantgit_status")
local status_marks = vim.api.nvim_buf_get_extmarks(status_buffer, status_namespace, 0, -1, { details = true })
local status_groups = {}
for _, mark in ipairs(status_marks) do status_groups[mark[4].hl_group] = true end
for _, group in ipairs({
  "CurrantGitRepository",
  "CurrantGitBranch",
  "CurrantGitHeading",
  "CurrantGitCount",
  "CurrantGitStatusModified",
  "CurrantGitPath",
  "CurrantGitAction",
}) do
  assert(status_groups[group], "status projection is missing highlight group " .. group)
end

local help_mapping = vim.fn.maparg("g?", "n", false, true)
assert(help_mapping.callback, "status help mapping was not registered")
local notified = false
local original_notify = vim.notify
vim.notify = function() notified = true end
help_mapping.callback()
vim.notify = original_notify
assert(not notified, "status help should render in the buffer instead of notifying")
lines = vim.api.nvim_buf_get_lines(status_buffer, 0, -1, false)
assert_contains(lines, "Available actions")
assert_contains(lines, "s   stage")
local help_line = vim.fn.search("Available actions", "nw")
assert(help_line > 0, "status help should be searchable buffer text")
assert(vim.fn.foldlevel(help_line) == 0, "status help should remain outside status folds")
assert(vim.b[status_buffer].currantgit_line_items[vim.api.nvim_win_get_cursor(0)[1]].id == current_item.id,
  "opening help changed semantic item targeting")
help_mapping.callback()
lines = vim.api.nvim_buf_get_lines(status_buffer, 0, -1, false)
for _, line in ipairs(lines) do assert(line ~= "Available actions", "second g? should close inline help") end

local diff_mapping = vim.fn.maparg("d", "n", false, true)
assert(diff_mapping.callback, "diff mapping was not registered")
diff_mapping.callback()
vim.wait(5000, function() return vim.bo.filetype == "diff" end)
assert(vim.bo.filetype == "diff", "diff action did not open a diff surface")
assert_contains(vim.api.nvim_buf_get_lines(0, 0, -1, false), "@@")
local hunk_line = vim.fn.search("^@@")
assert(hunk_line > 0 and vim.fn.foldlevel(hunk_line) == 1, "diff hunk should be a fold root")
assert(#vim.b.currantgit_diff_hunks == 1, "diff surface should expose semantic hunk nodes")
assert(vim.b.currantgit_line_items[hunk_line].kind == "hunk", "diff hunk row should retain its domain item")
vim.cmd("normal! zc")
assert(vim.fn.foldclosed(hunk_line) == hunk_line, "diff hunk should collapse with native fold commands")
vim.cmd("normal! zo")
local hunk_stage_mapping = vim.fn.maparg("s", "n", false, true)
assert(hunk_stage_mapping.callback, "hunk stage mapping was not registered")
hunk_stage_mapping.callback()
vim.wait(5000, function() return #vim.b.currantgit_diff_hunks == 0 end)
assert(#vim.b.currantgit_diff_hunks == 0, "staging a hunk should reconcile the working diff")
vim.cmd("Git diff --cached")
vim.wait(5000, function() return vim.bo.filetype == "diff" and #vim.b.currantgit_diff_hunks >= 1 end)
for line, item in pairs(vim.b.currantgit_line_items) do
  if type(item) == "table" and item.kind == "hunk" and item.path == "tracked.txt" then
    vim.api.nvim_win_set_cursor(0, { line, 0 })
    break
  end
end
local hunk_unstage_mapping = vim.fn.maparg("u", "n", false, true)
assert(hunk_unstage_mapping.callback, "hunk unstage mapping was not registered")
hunk_unstage_mapping.callback()
vim.wait(5000, function()
  for _, hunk in ipairs(vim.b.currantgit_diff_hunks or {}) do
    if hunk.path == "tracked.txt" then return false end
  end
  return true
end)
for _, hunk in ipairs(vim.b.currantgit_diff_hunks or {}) do
  assert(hunk.path ~= "tracked.txt", "unstaging a hunk should remove that path from the staged diff")
end
local emptied_diff_back_mapping = vim.fn.maparg("<C-O>", "n", false, true)
assert(emptied_diff_back_mapping.callback, "emptied diff back mapping was not registered")
emptied_diff_back_mapping.callback()
local emptied_diff_cursor = vim.api.nvim_win_get_cursor(0)
local emptied_diff_line_count = vim.api.nvim_buf_line_count(0)
assert(emptied_diff_cursor[1] >= 1 and emptied_diff_cursor[1] <= emptied_diff_line_count,
  "back restored an invalid cursor after the staged diff became empty")
local emptied_diff_forward_mapping = vim.fn.maparg("<C-S-I>", "n", false, true)
assert(emptied_diff_forward_mapping.callback, "emptied diff forward mapping was not registered")
emptied_diff_forward_mapping.callback()
local staged_diff_buffer = vim.api.nvim_get_current_buf()
vim.cmd("Git status")
vim.wait(5000, function() return vim.bo.filetype == "currantgit" and vim.b.currantgit_title == "status" end)
local diff_back_mapping = vim.fn.maparg("<C-O>", "n", false, true)
assert(diff_back_mapping.callback, "diff back mapping was not registered")
diff_back_mapping.callback()
vim.wait(2000, function() return vim.api.nvim_get_current_buf() == staged_diff_buffer end)
assert(vim.api.nvim_get_current_buf() == staged_diff_buffer, "diff back navigation did not return to the previous view")
local diff_forward_mapping = vim.fn.maparg("<C-S-I>", "n", false, true)
assert(diff_forward_mapping.callback, "diff forward mapping was not registered")
diff_forward_mapping.callback()
vim.wait(2000, function() return vim.api.nvim_get_current_buf() == status_buffer end)
assert(vim.api.nvim_get_current_buf() == status_buffer, "diff forward navigation did not return to status")

local refresh_mapping = vim.fn.maparg("r", "n", false, true)
assert(refresh_mapping.callback, "refresh mapping was not registered")
wait_for_status_refresh(function() refresh_mapping.callback() end)
assert_no_async_errors()
assert(vim.api.nvim_get_current_buf() == status_buffer, "refresh created a duplicate status buffer")
status_marks = vim.api.nvim_buf_get_extmarks(status_buffer, status_namespace, 0, -1, { details = true })
local unique_status_marks = {}
for _, mark in ipairs(status_marks) do
  local details = mark[4]
  local key = table.concat({ mark[2], mark[3], details.end_col or -1, details.hl_group or "" }, ":")
  assert(not unique_status_marks[key], "status refresh accumulated a duplicate highlight")
  unique_status_marks[key] = true
end

goto_item("tracked.txt")
local stage_mapping = vim.fn.maparg("s", "n", false, true)
assert(stage_mapping.callback, "stage mapping was not registered")
stage_mapping.callback()
vim.wait(5000, function()
  for _, item in ipairs(vim.b.currantgit_items or {}) do
    if item.path == "tracked.txt" then
      return item.status:sub(1, 1) ~= " "
    end
  end
  return false
end)
local staged_item
for _, item in ipairs(vim.b.currantgit_items) do
  if item.path == "tracked.txt" then staged_item = item end
end
assert(staged_item and staged_item.status:sub(1, 1) ~= " ", "stage action did not update the index")

goto_item("tracked.txt")
local unstage_mapping = vim.fn.maparg("u", "n", false, true)
assert(unstage_mapping.callback, "unstage mapping was not registered")
unstage_mapping.callback()
vim.wait(5000, function()
  for _, item in ipairs(vim.b.currantgit_items or {}) do
    if item.path == "tracked.txt" then
      return item.status:sub(1, 1) == " " and item.status:sub(2, 2) ~= " "
    end
  end
  return false
end)
local unstaged_item
for _, item in ipairs(vim.b.currantgit_items) do
  if item.path == "tracked.txt" then unstaged_item = item end
end
assert(unstaged_item and unstaged_item.status:sub(1, 1) == " " and unstaged_item.status:sub(2, 2) ~= " ", "unstage action did not update the index")

goto_item("tracked.txt")
local open_mapping = vim.fn.maparg("<CR>", "n", false, true)
assert(open_mapping.callback, "open mapping was not registered")
open_mapping.callback()
vim.wait(2000, function()
  return vim.api.nvim_buf_get_name(0):find("tracked.txt", 1, true) ~= nil
end)
assert(vim.api.nvim_buf_get_name(0):find("tracked.txt", 1, true), "open action did not enter the file view")
local back_mapping = vim.fn.maparg("<C-O>", "n", false, true)
assert(back_mapping.callback, "back mapping was not registered")
back_mapping.callback()
vim.wait(2000, function()
  return vim.api.nvim_get_current_buf() == status_buffer
end)
assert(vim.api.nvim_get_current_buf() == status_buffer, "Ctrl-O did not return to the status view")
local forward_mapping = vim.fn.maparg("<C-S-I>", "n", false, true)
assert(forward_mapping.callback, "forward mapping was not registered")
forward_mapping.callback()
vim.wait(2000, function()
  return vim.api.nvim_get_current_buf() ~= status_buffer
end)
assert(vim.api.nvim_buf_get_name(0):find("tracked.txt", 1, true), "Ctrl-Shift-I did not return to the file view")

vim.cmd("Git status")
vim.wait(5000, function()
  return vim.bo.filetype == "currantgit" and vim.b.currantgit_title == "status"
end)
assert_no_async_errors()
assert(vim.b.currantgit_title == "status", ":Git status did not use the status projection")

vim.cmd("Git diff --cached")
vim.wait(5000, function() return vim.bo.filetype == "diff" end)
assert(vim.bo.filetype == "diff", ":Git diff --cached should use the diff surface")
assert_contains(vim.api.nvim_buf_get_lines(0, 0, -1, false), "staged.txt")
assert(vim.api.nvim_buf_get_lines(0, 0, -1, false)[1]:find("staged.txt", 1, true), "staged diff should identify its path")
vim.cmd("Git status")
vim.wait(5000, function()
  return vim.bo.filetype == "currantgit" and vim.b.currantgit_title == "status"
end)
assert_no_async_errors()

vim.cmd("GitActivity")
vim.wait(2000, function()
  return vim.b.currantgit_title == "activity"
end)
assert(vim.b.currantgit_title == "activity", ":GitActivity did not open the activity surface")
assert(#require("currantgit").command_log() > 0, "activity log should contain Git commands")
assert_contains(vim.api.nvim_buf_get_lines(0, 0, -1, false), "git status")
local activity_back_mapping = vim.fn.maparg("<C-O>", "n", false, true)
assert(activity_back_mapping.callback, "activity back mapping was not registered")
activity_back_mapping.callback()
vim.wait(2000, function() return vim.bo.filetype == "currantgit" and vim.b.currantgit_title == "status" end)
assert(vim.b.currantgit_title == "status", "activity back navigation did not return to status")

goto_item("discard.txt")
local discard_mapping = vim.fn.maparg("X", "n", false, true)
assert(discard_mapping.callback, "discard mapping was not registered")
local original_select = vim.ui.select
vim.ui.select = function(items, _, callback)
  callback(items[2], 2)
end
discard_mapping.callback()
vim.wait(500, function() return false end)
local cancelled_item
for _, item in ipairs(vim.b.currantgit_items) do
  if item.path == "discard.txt" then cancelled_item = item end
end
assert(cancelled_item, "cancelled discard should preserve the item")

vim.ui.select = function(items, _, callback)
  callback(items[1], 1)
end
discard_mapping.callback()
vim.wait(5000, function()
  for _, item in ipairs(vim.b.currantgit_items or {}) do
    if item.path == "discard.txt" then return false end
  end
  return true
end)
vim.ui.select = original_select
local discarded_item
for _, item in ipairs(vim.b.currantgit_items) do
  if item.path == "discard.txt" then discarded_item = item end
end
assert(not discarded_item, "confirmed discard should remove the item from status")

wait_for_status_refresh(function() vim.cmd("Git status") end)
goto_item("deleted.txt")
local deleted_open_mapping = vim.fn.maparg("<CR>", "n", false, true)
assert(deleted_open_mapping.callback, "deleted-file open mapping was not registered")
deleted_open_mapping.callback()
vim.wait(5000, function()
  return vim.api.nvim_buf_get_name(0):find("currantgit://deleted/deleted.txt", 1, true) ~= nil
end)
assert(vim.api.nvim_buf_get_name(0):find("currantgit://deleted/deleted.txt", 1, true), "deleted file did not open a historical view")
assert_contains(vim.api.nvim_buf_get_lines(0, 0, -1, false), "gone")
assert(vim.bo.readonly, "deleted historical view should be read-only")

vim.cmd("Git status")
vim.wait(5000, function()
  return vim.bo.filetype == "currantgit" and vim.b.currantgit_title == "status"
end)
goto_item("tracked.txt")
local blame_mapping = vim.fn.maparg("b", "n", false, true)
assert(blame_mapping.callback, "blame mapping was not registered")
blame_mapping.callback()
vim.wait(5000, function()
  return vim.api.nvim_buf_get_name(0):find("currantgit://blame/tracked.txt", 1, true) ~= nil
end)
assert(vim.api.nvim_buf_get_name(0):find("currantgit://blame/tracked.txt", 1, true), "blame action did not open a companion buffer")
assert(vim.bo.filetype == "git", "blame surface should use the git filetype")
assert_contains(vim.api.nvim_buf_get_lines(0, 0, -1, false), "CurrantGit Harness")
assert(#vim.api.nvim_list_wins() == 2, "blame should preserve the source in a companion split")
local blame_commit_mapping = vim.fn.maparg("<CR>", "n", false, true)
assert(blame_commit_mapping.callback, "blame commit mapping was not registered")
blame_commit_mapping.callback()
vim.wait(5000, function()
  return vim.b.currantgit_title and vim.b.currantgit_title:find("commit/", 1, true) == 1
end)
assert(vim.b.currantgit_title:find("commit/", 1, true) == 1, "blame commit did not open a commit view")
assert_contains(vim.api.nvim_buf_get_lines(0, 0, -1, false), "fixture base")
local commit_back_mapping = vim.fn.maparg("<C-O>", "n", false, true)
assert(commit_back_mapping.callback, "commit back mapping was not registered")
commit_back_mapping.callback()
vim.wait(2000, function() return vim.b.currantgit_title == "blame" end)
assert(vim.b.currantgit_title == "blame", "commit view did not return to blame")
local blame_close_mapping = vim.fn.maparg("gq", "n", false, true)
assert(blame_close_mapping.callback, "blame close mapping was not registered")
blame_close_mapping.callback()
vim.wait(2000, function() return #vim.api.nvim_list_wins() == 1 end)
assert(#vim.api.nvim_list_wins() == 1, "gq should close blame and return to the source")

dofile(vim.env.CURRANTGIT_ROOT .. "/tests/log.lua")
assert_no_async_errors()
dofile(vim.env.CURRANTGIT_ROOT .. "/tests/safety.lua")
assert_no_async_errors()
print("CurrantGit smoke: ok")
vim.cmd("qa!")
