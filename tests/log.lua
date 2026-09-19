local currantgit = require("currantgit")
local log = require("currantgit.log")
local root = vim.fn.getcwd()

local function git(args, cwd)
  local result = vim.system(vim.list_extend({ "git" }, args), { cwd = cwd or root, text = true }):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout)
end

local function wait_for(predicate, message)
  assert(vim.wait(5000, predicate, 10), message)
  assert(#currantgit.errors() == 0, table.concat(currantgit.errors(), "\n"))
end

local function press(keys)
  assert(vim.fn.maparg(keys, "n", false, true).buffer == 1, "missing local mapping: " .. keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "xt", false)
end

local function open(args)
  local before = vim.api.nvim_buf_get_changedtick(vim.api.nvim_get_current_buf())
  local buffer = vim.api.nvim_get_current_buf()
  vim.cmd("Git log" .. (args and " " .. args or ""))
  wait_for(function()
    return vim.b.currantgit_title == "log"
      and (vim.api.nvim_get_current_buf() ~= buffer or vim.api.nvim_buf_get_changedtick(buffer) > before)
  end, "log request did not render: " .. (args or ""))
end

local function snapshot()
  return {
    git({ "rev-parse", "HEAD" }),
    git({ "status", "--porcelain=v1", "-z" }),
    git({ "diff", "--binary", "--no-ext-diff" }),
    git({ "diff", "--cached", "--binary", "--no-ext-diff" }),
  }
end

-- The parser owns commit identity and metadata, never display positions.
local oid, parent = string.rep("a", 40), string.rep("b", 40)
local record = table.concat({ oid, parent .. " " .. oid, "Zoë\tExample", "zoe@example.invalid",
  "2026-09-19T12:30:00-05:00", "subject\nwith control characters" }, "\0") .. "\0"
local parsed = assert(log.parse(record, root))
assert(parsed[1].id == "commit:" .. oid and parsed[1].kind == "commit")
assert(parsed[1].repository == root and #parsed[1].parents == 2)
assert(parsed[1].email == "zoe@example.invalid" and parsed[1].subject:find("\n"))
local rendered, line_items = log.render(parsed)
assert(#rendered == 3 and not rendered[2]:find("[%c]"))
assert(line_items[2] == parsed[1] and not line_items[1] and not line_items[3])
assert(log.parse(record:sub(1, -2)) == nil, "truncated log record must fail")
assert(log.parse("junk\0" .. record) == nil, "malformed log must fail")
assert(#log.parse("") == 0)
local sha256 = table.concat({ string.rep("c", 64), "", "", "", "", "" }, "\0") .. "\0"
assert(#log.parse(sha256)[1].commit == 64, "SHA-256 and empty fields must parse")
assert(log.arguments({ "log", "--graph" }) == nil)
assert(log.arguments({ "log", "--oneline" }) == nil)
assert(log.arguments({ "log", "--format=%s" }) == nil)
assert(log.arguments({ "log", "-n" }) == nil)

local unchanged = snapshot()
open()
local buffer = vim.api.nvim_get_current_buf()
assert(vim.bo.buftype == "nofile" and vim.bo.readonly and not vim.bo.modifiable)
assert(#vim.b.currantgit_items == 3, "fixture should expose three commits")
local first = vim.b.currantgit_items[1]
assert(first.commit == git({ "rev-parse", "HEAD" }) and first.subject == "fixture latest")
assert(first.id == "commit:" .. first.commit and first.repository == root)
assert(first.author == "CurrantGit Harness" and first.email == "harness@currantgit.invalid")
assert(first.parents[1] == git({ "rev-parse", "HEAD^" }))
assert(vim.api.nvim_win_get_cursor(0)[1] == 2, "opening log should select a commit")
local discovered = {}
for _, action in ipairs(currantgit.discovery()) do discovered[action.id] = true end
assert(discovered["commit.open"] and discovered["surface.refresh"] and discovered["surface.help"])
assert(not discovered["item.stage"] and not discovered["item.discard"])
assert(currantgit.which_key()["<CR>"].desc == "open commit")
assert(vim.api.nvim_buf_get_lines(0, -2, -1, false)[1]:find("<CR> open commit", 1, true))

local notifications = {}
local notify = vim.notify
vim.notify = function(message) notifications[#notifications + 1] = message end
press("g?")
assert(notifications[#notifications]:find("<CR> open commit", 1, true))
assert(not notifications[#notifications]:find("stage", 1, true), "log help advertised mutations")
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buffer })
assert(not vim.api.nvim_buf_get_lines(0, -2, -1, false)[1]:find("<CR>", 1, true))
press("<CR>")
assert(vim.b.currantgit_title == "log", "header must not open a commit")
press("g?")
assert(not notifications[#notifications]:find("<CR>", 1, true))
vim.notify = notify

-- Native search/yank and mapped opening operate on the same semantic row.
vim.cmd("normal! gg")
assert(vim.fn.search("fixture second", "W") == 3)
vim.cmd('normal! "ayy')
assert(vim.fn.getreg("a"):find("fixture second", 1, true))
local selected = vim.b.currantgit_line_items[3]
press("<CR>")
wait_for(function() return vim.b.currantgit_title == "commit/" .. selected.commit:sub(1, 8) end,
  "mapped Enter did not open selected commit")
assert(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("fixture second", 1, true))
assert(vim.bo.readonly and not vim.bo.modifiable)
press("<C-O>")
assert(vim.api.nvim_get_current_buf() == buffer and vim.api.nvim_win_get_cursor(0)[1] == 3)
press("<C-S-I>")
assert(vim.b.currantgit_title == "commit/" .. selected.commit:sub(1, 8))
press("<C-O>")

-- Refresh keeps its repository, original arguments, and semantic selection.
local other = vim.fn.tempname()
vim.fn.mkdir(other, "p")
git({ "init", "-q" }, other)
vim.cmd("cd " .. vim.fn.fnameescape(other))
for _ = 1, 2 do
  local tick = vim.api.nvim_buf_get_changedtick(buffer)
  press("r")
  wait_for(function() return vim.api.nvim_buf_get_changedtick(buffer) > tick end, "mapped refresh did not finish")
  assert(vim.api.nvim_get_current_buf() == buffer and vim.b.currantgit_root == root)
  assert(vim.deep_equal(vim.b.currantgit_log_args, { "log" }), "refresh accumulated internal options")
  assert(vim.b.currantgit_line_items[vim.api.nvim_win_get_cursor(0)[1]].id == selected.id)
end
press("<CR>")
wait_for(function() return vim.b.currantgit_title == "commit/" .. selected.commit:sub(1, 8) end,
  "commit opening lost its repository after cwd changed")
press("<C-O>")
vim.cmd("cd " .. vim.fn.fnameescape(root))
vim.fn.delete(other, "rf")

open("-n 1")
assert(vim.api.nvim_get_current_buf() == buffer and #vim.b.currantgit_items == 1)
local tick = vim.api.nvim_buf_get_changedtick(buffer)
press("r")
wait_for(function() return vim.api.nvim_buf_get_changedtick(buffer) > tick end, "filtered refresh did not finish")
assert(#vim.b.currantgit_items == 1 and vim.deep_equal(vim.b.currantgit_log_args, { "log", "-n", "1" }))
open("--reverse HEAD -- tracked.txt")
assert(#vim.b.currantgit_items == 1 and vim.b.currantgit_items[1].subject == "fixture base")
open("HEAD~2..HEAD")
assert(#vim.b.currantgit_items == 2)
open("--max-count=0")
assert(#vim.b.currantgit_items == 0)
assert(vim.api.nvim_buf_get_lines(0, 1, 2, false)[1] == "  no commits")
assert(not currantgit.which_key()["<CR>"], "empty log must not advertise opening")

-- Git errors retain the last good projection; custom formatting stays raw.
open()
notifications = {}
vim.notify = function(message) notifications[#notifications + 1] = message end
local old_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
vim.cmd("Git log currantgit-missing-revision")
wait_for(function() return #notifications > 0 end, "failed log was not reported")
vim.notify = notify
assert(vim.deep_equal(old_lines, vim.api.nvim_buf_get_lines(0, 0, -1, false)))
assert(vim.deep_equal(vim.b.currantgit_log_args, { "log" }))
vim.cmd("Git log --oneline -n 1")
wait_for(function() return vim.b.currantgit_title == "command" end, "formatted log lost escape hatch")
assert(vim.api.nvim_buf_line_count(0) == 1)
assert(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]:find("fixture latest", 1, true))
assert(vim.deep_equal(unchanged, snapshot()), "log interactions changed repository state")

-- A new commit shifts the selected row; refresh follows its stable identity.
open()
vim.api.nvim_win_set_cursor(0, { 3, 0 })
selected = vim.b.currantgit_line_items[3]
git({ "commit", "-q", "--allow-empty", "--only", "-m", "fixture refresh" })
tick = vim.api.nvim_buf_get_changedtick(buffer)
press("r")
wait_for(function() return vim.api.nvim_buf_get_changedtick(buffer) > tick end, "new commit refresh did not finish")
assert(#vim.b.currantgit_items == 4 and vim.api.nvim_win_get_cursor(0)[1] == 4)
assert(vim.b.currantgit_line_items[4].id == selected.id, "refresh moved the semantic selection")

-- Deliver controlled responses out of order through the real executor seam.
local system = vim.system
local pending = {}
vim.system = function(args, opts, callback)
  if args[2] == "log" and callback then
    pending[#pending + 1] = { callback = callback, result = system(args, opts):wait() }
    return {}
  end
  return system(args, opts, callback)
end
currantgit.git({ "log", "-n", "1" })
currantgit.git({ "log", "-n", "2" })
pending[2].callback(pending[2].result)
wait_for(function() return #vim.b.currantgit_items == 2 end, "newest query did not render")
local function deliver(entry)
  local drained = false
  entry.callback(entry.result)
  vim.schedule(function() drained = true end)
  wait_for(function() return drained end, "log callback was not drained")
end
deliver(pending[1])
assert(#vim.b.currantgit_items == 2, "older query overwrote the newer result")
currantgit.git({ "log" })
vim.cmd("enew")
local destination = vim.api.nvim_get_current_buf()
deliver(pending[3])
assert(vim.api.nvim_get_current_buf() == destination, "late log stole the current buffer")
vim.system = system
print("CurrantGit log: ok")
