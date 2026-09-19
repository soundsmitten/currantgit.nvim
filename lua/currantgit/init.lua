local M = {}
local config = require("currantgit.config")

local state = {
  configured = false,
  opts = {},
}

local function split_args(args)
  if args == "" then
    return {}
  end
  return vim.fn.split(args, [[\s\+]], true)
end

local function git_command()
  return config.get().git.command
end

local function repository_root()
  local result = vim.system({ git_command(), "rev-parse", "--show-toplevel" }, {
    text = true,
  }):wait()

  if result.code ~= 0 then
    return nil, result.stderr or "not a Git repository"
  end

  return vim.trim(result.stdout)
end

local function set_buffer(lines, items, title)
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buffer, "currantgit://" .. title)
  vim.api.nvim_set_current_buf(buffer)
  vim.bo[buffer].buftype = "nofile"
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].modifiable = true
  vim.bo[buffer].filetype = "currantgit"
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.bo[buffer].modifiable = false
  vim.bo[buffer].readonly = true
  vim.b[buffer].currantgit_items = items
  vim.b[buffer].currantgit_title = title
  return buffer
end

local function parse_status(stdout)
  local items = {}
  local ui = config.get().ui
  local lines = { ui.title .. "  " .. vim.fn.fnamemodify(vim.fn.getcwd(), ":t") }
  local branch = ""
  local changes = {}

  for line in (stdout .. "\n"):gmatch("(.-)\n") do
    if vim.startswith(line, "## ") then
      branch = line:sub(4)
    elseif line ~= "" then
      local status = line:sub(1, 2)
      local path = vim.trim(line:sub(4))
      local change_kind = status:find("R", 1, true) and "renamed"
        or status:find("D", 1, true) and "deleted"
        or status:find("A", 1, true) and "added"
        or status:find("?", 1, true) and "untracked"
        or "modified"
      local item = {
        id = "change:" .. path,
        kind = "change",
        change_kind = change_kind,
        path = path,
        status = status,
        capabilities = { "open", "diff", "stage" },
      }
      items[#items + 1] = item
      changes[#changes + 1] = string.format("  %s  %s", ui.icons[change_kind] or status, path)
    end
  end

  if ui.show_branch then
    lines[#lines + 1] = "Branch: " .. (branch ~= "" and branch or "detached")
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = ui.show_counts and string.format("Changes (%d)", #items) or "Changes"
  if #changes > 0 then
    vim.list_extend(lines, changes)
  elseif ui.show_clean then
    lines[#lines + 1] = "  clean"
  end
  return lines, items
end

local function open_status()
  local root, error_message = repository_root()
  if not root then
    vim.notify("CurrantGit: " .. error_message, vim.log.levels.ERROR)
    return
  end

  vim.system({ git_command(), "status", "--short", "--branch" }, {
    cwd = root,
    text = true,
  }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        vim.notify("CurrantGit: " .. (result.stderr or "git status failed"), vim.log.levels.ERROR)
        return
      end
      local lines, items = parse_status(result.stdout or "")
      set_buffer(lines, items, "status")
    end)
  end)
end

local function run_git(args)
  local root, error_message = repository_root()
  if not root then
    vim.notify("CurrantGit: " .. error_message, vim.log.levels.ERROR)
    return
  end

  vim.system(vim.list_extend({ git_command() }, args), {
    cwd = root,
    text = true,
  }, function(result)
    vim.schedule(function()
      local output = result.stdout or ""
      if result.code ~= 0 then
        output = (result.stderr or "git command failed") .. "\n" .. output
      end
      set_buffer(vim.split(vim.trim(output), "\n", { plain = true }), {}, "command")
    end)
  end)
end

function M.git(args)
  if #args == 0 or args[1] == "status" then
    open_status()
  else
    run_git(args)
  end
end

function M.setup(opts)
  state.opts = config.setup(opts)
  if state.configured then
    return M
  end

  vim.api.nvim_create_user_command("Git", function(command)
    M.git(split_args(command.args))
  end, {
    bang = true,
    nargs = "*",
    complete = "shellcmd",
  })
  state.configured = true
  return M
end

function M.get_config()
  return config.get()
end

return M
