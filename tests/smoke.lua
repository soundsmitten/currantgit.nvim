local function assert_contains(lines, needle)
  for _, line in ipairs(lines) do
    if line:find(needle, 1, true) then
      return
    end
  end
  error("expected buffer to contain: " .. needle)
end

local currantgit = require("currantgit")
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

vim.cmd("Git")
vim.wait(5000, function()
  return vim.bo.filetype == "currantgit"
end)

assert(vim.bo.filetype == "currantgit", "Git status did not open a CurrantGit surface")
assert_no_async_errors()
local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
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
assert_contains(vim.api.nvim_buf_get_lines(0, -2, -1, false), "Actions:")

local status_buffer = vim.api.nvim_get_current_buf()
local diff_mapping = vim.fn.maparg("d", "n", false, true)
assert(diff_mapping.callback, "diff mapping was not registered")
diff_mapping.callback()
vim.wait(5000, function() return vim.bo.filetype == "diff" end)
assert(vim.bo.filetype == "diff", "diff action did not open a diff surface")
assert_contains(vim.api.nvim_buf_get_lines(0, 0, -1, false), "@@")
local hunk_line = vim.fn.search("^@@")
assert(hunk_line > 0 and vim.fn.foldlevel(hunk_line) == 1, "diff hunk should be a fold root")
vim.cmd("normal! zc")
assert(vim.fn.foldclosed(hunk_line) == hunk_line, "diff hunk should collapse with native fold commands")
vim.cmd("normal! zo")
local diff_back_mapping = vim.fn.maparg("<C-O>", "n", false, true)
assert(diff_back_mapping.callback, "diff back mapping was not registered")
diff_back_mapping.callback()
vim.wait(2000, function() return vim.api.nvim_get_current_buf() == status_buffer end)
assert(vim.api.nvim_get_current_buf() == status_buffer, "diff back navigation did not return to status")

local refresh_mapping = vim.fn.maparg("r", "n", false, true)
assert(refresh_mapping.callback, "refresh mapping was not registered")
refresh_mapping.callback()
vim.wait(5000, function()
  return vim.api.nvim_get_current_buf() == status_buffer and vim.b.currantgit_title == "status"
end)
assert_no_async_errors()
assert(vim.api.nvim_get_current_buf() == status_buffer, "refresh created a duplicate status buffer")

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

vim.cmd("Git status")
vim.wait(5000, function()
  return vim.bo.filetype == "currantgit" and vim.b.currantgit_title == "status"
end)
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

print("CurrantGit smoke: ok")
vim.cmd("qa!")
