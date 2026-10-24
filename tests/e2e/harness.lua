-- End-to-end harness: every scenario gets its own Git fixture and its own
-- `nvim --embed --headless` child. The driver only talks to the child the way
-- a user would (`nvim_input` keystrokes through the real key loop: mappings,
-- prompts, cmdline) and reads Git state back with its own `git` calls, so a
-- plugin bug cannot also hide its own evidence. RPC reads of the child
-- (current line, filetype, mode) are observation only, never a shortcut
-- around the keys under test.

local M = {}

local repo_root = assert(vim.env.CURRANTGIT_ROOT, "CURRANTGIT_ROOT is required")
local work_root = vim.fn.tempname() .. "-currantgit-e2e"
vim.fn.mkdir(work_root, "p")

-- Isolate both processes from the user's Git config (conflictStyle, hooks,
-- signing, default branch) so fixtures behave identically on every machine.
local empty_gitconfig = work_root .. "/gitconfig"
vim.fn.writefile({}, empty_gitconfig)
local git_env = {
  GIT_CONFIG_NOSYSTEM = "1",
  GIT_CONFIG_GLOBAL = empty_gitconfig,
  GIT_AUTHOR_NAME = "CurrantGit E2E",
  GIT_AUTHOR_EMAIL = "e2e@currantgit.invalid",
  GIT_COMMITTER_NAME = "CurrantGit E2E",
  GIT_COMMITTER_EMAIL = "e2e@currantgit.invalid",
}

M.timeout = tonumber(vim.env.CURRANTGIT_E2E_TIMEOUT or "") or 5000

local Session = {}
Session.__index = Session

-- Runs git in the fixture from the driver side and returns trimmed stdout.
function Session:git(args, opts)
  opts = opts or {}
  local command = vim.list_extend({ "git", "-C", self.dir }, args)
  local result = vim.system(command, { env = git_env, text = true }):wait()
  if result.code ~= 0 and not opts.allow_failure then
    error(("git %s failed (%d): %s"):format(table.concat(args, " "), result.code, result.stderr), 2)
  end
  return vim.trim(result.stdout or ""), result.code
end

function Session:write(path, text)
  local full = self.dir .. "/" .. path
  vim.fn.mkdir(vim.fs.dirname(full), "p")
  local file = assert(io.open(full, "wb"))
  file:write(text)
  file:close()
end

function Session:read(path)
  local file = io.open(self.dir .. "/" .. path, "rb")
  if not file then return nil end
  local text = file:read("a")
  file:close()
  return text
end

function Session:start()
  self.home = self.dir .. ".home"
  local env = vim.tbl_extend("force", git_env, {
    CURRANTGIT_ROOT = repo_root,
    HOME = self.home,
    XDG_CONFIG_HOME = self.home .. "/config",
    XDG_DATA_HOME = self.home .. "/data",
    XDG_STATE_HOME = self.home .. "/state",
    XDG_CACHE_HOME = self.home .. "/cache",
    NVIM_APPNAME = "currantgit-e2e",
  })
  self.channel = vim.fn.jobstart({
    vim.v.progpath, "--embed", "--headless", "--noplugin",
    "-u", repo_root .. "/tests/minimal-init.lua",
    "--cmd", "cd " .. vim.fn.fnameescape(self.dir),
  }, { rpc = true, env = env })
  assert(self.channel > 0, "could not start child nvim")
  -- Startup has finished once the plugin's :Git command exists.
  self:wait("child startup", function()
    return self:eval("vim.fn.exists(':Git') == 2")
  end)
end

function Session:stop()
  if self.channel then
    pcall(vim.fn.jobstop, self.channel)
    self.channel = nil
  end
end

-- Observation only: evaluates a Lua expression in the child.
function Session:eval(expression, ...)
  return vim.rpcrequest(self.channel, "nvim_exec_lua", "return " .. expression, { ... })
end

function Session:mode()
  return vim.rpcrequest(self.channel, "nvim_get_mode")
end

-- Queues keys exactly as typed (`<CR>`, `<Esc>` notation), through the
-- child's real input loop.
function Session:keys(keys)
  vim.rpcrequest(self.channel, "nvim_input", keys)
end

function Session:wait(what, predicate, timeout)
  local last_error
  local ok = vim.wait(timeout or M.timeout, function()
    local success, value = pcall(predicate)
    if not success then last_error = value end
    return success and value
  end, 15)
  if not ok then
    error(("timed out waiting for %s%s"):format(what, last_error and (": " .. tostring(last_error)) or ""), 2)
  end
end

-- A snapshot that only changes once a render actually lands: the current
-- buffer and its changedtick. A reused buffer that still carries the old
-- filetype or title cannot satisfy it (docs/gotchas.md).
function Session:render_mark()
  return self:eval("{ vim.api.nvim_get_current_buf(), vim.api.nvim_buf_get_changedtick(0) }")
end

function Session:wait_render(mark, what)
  self:wait(what or "a new render", function()
    local now = self:render_mark()
    return now[1] ~= mark[1] or now[2] > mark[2]
  end)
end

-- Presses keys and waits until the surface re-rendered because of them.
function Session:press(keys, what)
  local mark = self:render_mark()
  self:keys(keys)
  self:wait_render(mark, what or ("render after " .. keys))
end

function Session:surface()
  return self:eval("vim.b.currantgit_title"), self:eval("vim.bo.filetype")
end

function Session:line()
  return self:eval("vim.api.nvim_get_current_line()")
end

function Session:lines()
  return self:eval("vim.api.nvim_buf_get_lines(0, 0, -1, false)")
end

-- Moves the cursor with a real `/` search, then confirms where it landed.
function Session:search(text)
  -- \V keeps the text literal; "\" and the "/" that would end the search are
  -- escaped, and "<" is spelled <lt> so nvim_input does not read a key name.
  local pattern = text:gsub("\\", "\\\\"):gsub("/", "\\/"):gsub("<", "<lt>")
  self:keys("gg/\\V" .. pattern .. "<CR>")
  self:wait("cursor on " .. text, function()
    return self:line():find(text, 1, true) ~= nil and self:mode().mode == "n"
  end)
end

function Session:open_status()
  self:keys(":Git<CR>")
  self:wait("status surface", function()
    return self:eval("vim.b.currantgit_title") == "status" and self:eval("vim.bo.filetype") == "currantgit"
  end)
  self:settle()
end

-- Waits until the child is idle in normal mode with no subprocess (Git) in
-- flight, so the next keypress cannot race a running Git process. The
-- process tree is observed from outside; the plugin exposes no such state.
function Session:settle()
  local pid = vim.fn.jobpid(self.channel)
  local quiet_since
  self:wait("child to settle", function()
    local mode = self:mode()
    local idle = mode.mode == "n" and not mode.blocking and #vim.api.nvim_get_proc_children(pid) == 0
    if not idle then
      quiet_since = nil
      return false
    end
    -- A callback can chain a second Git command right after the first exits;
    -- require a short quiet window rather than a single idle sample.
    quiet_since = quiet_since or vim.uv.hrtime()
    return (vim.uv.hrtime() - quiet_since) / 1e6 >= 60
  end)
end

function Session:errors()
  local errors = self:eval("require('currantgit').errors()")
  local errmsg = self:eval("vim.v.errmsg")
  if errmsg ~= "" then table.insert(errors, "v:errmsg: " .. errmsg) end
  return errors
end

function Session:diagnostics()
  local ok, messages = pcall(function() return self:eval("vim.api.nvim_exec2('messages', { output = true }).output") end)
  local ok_lines, lines = pcall(function() return self:lines() end)
  return table.concat({
    "--- child :messages", ok and messages or "(unavailable)",
    "--- current buffer", ok_lines and table.concat(lines, "\n") or "(unavailable)",
  }, "\n")
end

local function new_session(name)
  local dir = work_root .. "/" .. name:gsub("[^%w]+", "-")
  vim.fn.mkdir(dir, "p")
  local session = setmetatable({ dir = dir, name = name }, Session)
  session:git({ "init", "-q", "-b", "main" })
  return session
end

function M.expect(condition, message, ...)
  if not condition then error(message:format(...), 2) end
end

function M.equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(("%s\n  expected: %s\n  actual:   %s"):format(message, vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

-- Runs each scenario in isolation; one failure does not stop the rest.
function M.run(scenarios, filter)
  local failed, ran = {}, 0
  for _, scenario in ipairs(scenarios) do
    if not filter or scenario.name:find(filter, 1, true) then
      ran = ran + 1
      local session = new_session(scenario.name)
      local ok, err = xpcall(function()
        if scenario.fixture then scenario.fixture(session) end
        session:start()
        scenario.run(session)
        session:settle()
        local errors = session:errors()
        M.equal(errors, {}, "scenario left CurrantGit errors behind")
      end, debug.traceback)
      if ok then
        io.stdout:write(("  ok   %s\n"):format(scenario.name))
      else
        io.stdout:write(("  FAIL %s\n%s\n%s\n"):format(scenario.name, err, session.channel and session:diagnostics() or ""))
        table.insert(failed, scenario.name)
      end
      session:stop()
    end
  end
  vim.fn.delete(work_root, "rf")
  if ran == 0 then
    io.stdout:write("CurrantGit e2e: no scenario matched " .. tostring(filter) .. "\n")
    return false
  end
  if #failed > 0 then
    io.stdout:write(("CurrantGit e2e: %d of %d failed: %s\n"):format(#failed, ran, table.concat(failed, ", ")))
    return false
  end
  io.stdout:write(("CurrantGit e2e: ok (%d scenarios)\n"):format(ran))
  return true
end

return M
