-- Git's editor, routed into this Neovim (docs/decisions/0015).
--
-- Every asynchronous Git command CurrantGit runs gets GIT_EDITOR and
-- GIT_SEQUENCE_EDITOR pointing at git_editor_shim.lua. When Git needs a
-- message (commit, merge, tag -a, rebase -i ...), it starts the shim, which
-- asks this Neovim over RPC to open the file in a split, then waits. Closing
-- that buffer -- `:wq`, `:q!`, anything that wipes it -- lets the shim exit 0
-- and Git reads the file as it is on disk, exactly as with a terminal editor.
-- Git keeps every rule of its own: templates, merge messages, hooks, and
-- aborting on an empty message.

local M = {}

local sessions = {}
local next_id = 0

local shim = vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "git_editor_shim.lua")

local function shell_quote(text)
  return "'" .. text:gsub("'", [['\'']]) .. "'"
end

-- Environment for a Git process. Without a server address there is nothing
-- to edit in, so the editor fails fast instead of starting a terminal editor
-- with no terminal.
function M.env()
  local server = vim.v.servername
  if type(server) ~= "string" or server == "" then
    return { GIT_EDITOR = "false", GIT_SEQUENCE_EDITOR = "false" }
  end
  local command = table.concat({
    shell_quote(vim.v.progpath), "--headless", "--clean", "-l", shell_quote(shim),
  }, " ")
  return { GIT_EDITOR = command, GIT_SEQUENCE_EDITOR = command, CURRANTGIT_SERVER = server }
end

local function same_file(a, b)
  local real_a, real_b = vim.uv.fs_realpath(a), vim.uv.fs_realpath(b)
  return real_a ~= nil and real_a == real_b
end

local function open_buffer(id)
  local session = sessions[id]
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buffer)
    if name ~= "" and same_file(name, session.file) then
      if vim.bo[buffer].modified then
        vim.notify("CurrantGit: " .. session.file .. " has unsaved changes in another buffer; Git's edit was not opened",
          vim.log.levels.ERROR)
        session.state = "failed"
        return
      end
      -- A stale copy from an earlier edit; Git has rewritten the file.
      vim.api.nvim_buf_delete(buffer, { force = true })
    end
  end
  local ok, err = pcall(vim.cmd, "split " .. vim.fn.fnameescape(session.file))
  if not ok then
    vim.notify("CurrantGit: could not open Git's editor file: " .. tostring(err), vim.log.levels.ERROR)
    session.state = "failed"
    return
  end
  local buffer = vim.api.nvim_get_current_buf()
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].swapfile = false
  vim.b[buffer].currantgit_git_editor = id
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buffer,
    once = true,
    callback = function() session.state = "done" end,
  })
  session.state = "editing"
end

-- Called by the shim over RPC. Returns a session id to poll with state().
function M.open(file)
  next_id = next_id + 1
  local id = next_id
  sessions[id] = { file = file, state = "opening" }
  -- Not inside the RPC request: the user may be mid-command or in a prompt.
  vim.schedule(function() open_buffer(id) end)
  return id
end

-- "opening", "editing", "done" or "failed". A finished session is forgotten
-- once reported.
function M.state(id)
  local session = sessions[id]
  if not session then return "failed" end
  if session.state == "done" or session.state == "failed" then
    sessions[id] = nil
  end
  return session.state
end

return M
