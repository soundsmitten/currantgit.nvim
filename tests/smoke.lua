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

vim.cmd("Git status")
vim.wait(5000, function()
  return vim.bo.filetype == "currantgit" and vim.b.currantgit_title == "status"
end)
assert(vim.b.currantgit_title == "status", ":Git status did not use the status projection")

print("CurrantGit smoke: ok")
vim.cmd("qa!")
