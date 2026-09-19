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
assert(defaults.ui.title == "CurrantGit", "configuration defaults are not loaded")
assert(defaults.ui.icons.modified == "M", "configuration icon defaults are not loaded")

vim.cmd("Git")
vim.wait(5000, function()
  return vim.bo.filetype == "currantgit"
end)

assert(vim.bo.filetype == "currantgit", "Git status did not open a CurrantGit surface")
local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
assert_contains(lines, "CurrantGit")
assert_contains(lines, "Changes")
assert(vim.b.currantgit_items, "status surface did not expose semantic items")
assert(#vim.b.currantgit_items >= 2, "fixture should expose modified and untracked items")

vim.fn.search("tracked.txt")
local actions = require("currantgit.actions").available(vim.b.currantgit_items[1], { buffer = 0 })
local action_ids = {}
for _, action in ipairs(actions) do
  action_ids[action.id] = true
end
assert(action_ids["item.open"], "change item is missing the open action")
assert(action_ids["item.diff"], "change item is missing the diff action")
assert(action_ids["surface.refresh"], "surface is missing the refresh action")
assert_contains(vim.api.nvim_buf_get_lines(0, -2, -1, false), "Actions:")

vim.cmd("Git status")
vim.wait(5000, function()
  return vim.bo.filetype == "currantgit" and vim.b.currantgit_title == "status"
end)
assert(vim.b.currantgit_title == "status", ":Git status did not use the status projection")

print("CurrantGit smoke: ok")
vim.cmd("qa!")
