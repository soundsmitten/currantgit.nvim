-- Git runs this as its editor: `nvim --headless --clean -l <this file> <file>`
-- (see git_editor.lua). It asks the Neovim at $CURRANTGIT_SERVER to open the
-- file, then waits until that buffer is closed. Exit 0 hands the file back to
-- Git as it is; exit 1 makes Git abort, as a failed editor would.

-- Git prints this after its own "problem with the editor" line, and
-- CurrantGit adds its own prefix when it reports the failure.
local function fail(message)
  io.stderr:write("Neovim editor: " .. message .. "\n")
  os.exit(1)
end

local file, server = arg[1], os.getenv("CURRANTGIT_SERVER")
if not file or file == "" then fail("Git gave the editor no file") end
if not server or server == "" then fail("no Neovim to edit in (CURRANTGIT_SERVER is unset)") end

-- A TCP address is host:port; anything else is a named pipe or socket path.
local mode = server:match("^[^/\\]+:%d+$") and "tcp" or "pipe"
local connected, channel = pcall(vim.fn.sockconnect, mode, server, { rpc = true })
if not connected or channel == 0 then fail("could not reach Neovim at " .. server) end

local function call(name, ...)
  return vim.rpcrequest(channel, "nvim_exec_lua",
    "return require('currantgit.git_editor')." .. name .. "(...)", { ... })
end

-- Git passes a path relative to its own working directory; Neovim's may differ.
local opened, id = pcall(call, "open", vim.fn.fnamemodify(file, ":p"))
if not opened then fail("Neovim refused the edit: " .. tostring(id)) end

while true do
  local ok, state = pcall(call, "state", id)
  if not ok then fail("lost the connection to Neovim") end
  if state == "done" then os.exit(0) end
  if state == "failed" then fail("the edit could not be opened") end
  vim.wait(100)
end
