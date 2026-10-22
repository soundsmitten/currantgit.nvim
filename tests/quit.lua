-- `gq` quits every CurrantGit surface: it closes the surface's window when
-- the tab has others, and otherwise returns to the buffer it replaced.
local currantgit = require("currantgit")
local original_cwd = vim.fn.getcwd()

local function git(args, cwd)
  local result = vim.system(vim.list_extend({ "git" }, args), { cwd = cwd, text = true }):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout or "")
end

local function wait_for(predicate, message)
  assert(vim.wait(8000, predicate, 10), message)
  assert(#currantgit.errors() == 0, table.concat(currantgit.errors(), "\n"))
end

local function press(keys)
  assert(vim.fn.maparg(keys, "n", false, true).buffer == 1,
    "missing local mapping " .. keys .. " in " .. tostring(vim.b.currantgit_title))
  vim.api.nvim_feedkeys(vim.keycode(keys), "xt", false)
end

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
git({ "init", "-q", "-b", "main" }, dir)
git({ "config", "user.name", "CurrantGit Quit" }, dir)
git({ "config", "user.email", "quit@currantgit.invalid" }, dir)
vim.fn.writefile({ "one" }, dir .. "/a.txt")
vim.fn.writefile({ "gone" }, dir .. "/gone.txt")
git({ "add", "-A" }, dir)
git({ "commit", "-q", "-m", "base" }, dir)
vim.fn.writefile({ "two" }, dir .. "/a.txt")
os.remove(dir .. "/gone.txt")
vim.cmd("cd " .. vim.fn.fnameescape(dir))
vim.cmd("tabnew " .. vim.fn.fnameescape(dir .. "/a.txt"))
local source = vim.api.nvim_get_current_buf()

local function open(title, run)
  run()
  wait_for(function() return vim.b.currantgit_title == title end, title .. " did not open")
end

local function quits_to_source(title)
  press("gq")
  assert(vim.api.nvim_get_current_buf() == source, "gq on " .. title .. " should return to the source buffer")
  assert(#vim.api.nvim_tabpage_list_wins(0) == 1, "gq on " .. title .. " should not leave windows behind")
end

-- Full-window surfaces return to the buffer they replaced.
open("status", function() currantgit.git({}) end)
quits_to_source("status")
open("log", function() currantgit.git({ "log" }) end)
quits_to_source("log")
open("diff", function() currantgit.git({ "diff" }) end)
quits_to_source("diff")
open("activity", function() vim.cmd("GitActivity") end)
quits_to_source("activity")

-- A commit opened from the log, and a deleted file opened from status.
open("log", function() currantgit.git({ "log" }) end)
for line, item in pairs(vim.b.currantgit_line_items or {}) do
  if type(item) == "table" and item.kind == "commit" then
    vim.api.nvim_win_set_cursor(0, { line, 0 })
    break
  end
end
press("<CR>")
wait_for(function() return (vim.b.currantgit_title or ""):find("^commit/") end, "commit did not open")
quits_to_source("commit")
open("status", function() currantgit.git({}) end)
for line, item in pairs(vim.b.currantgit_line_items or {}) do
  if type(item) == "table" and item.path == "gone.txt" then
    vim.api.nvim_win_set_cursor(0, { line, 0 })
    break
  end
end
press("<CR>")
wait_for(function() return vim.b.currantgit_title == "deleted" end, "deleted view did not open")
quits_to_source("deleted")

-- A surface in its own split closes just that window.
open("status", function() currantgit.git({}, "vertical") end)
assert(#vim.api.nvim_tabpage_list_wins(0) == 2)
quits_to_source("split status")

vim.cmd("tabclose")
vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
vim.fn.delete(dir, "rf")
