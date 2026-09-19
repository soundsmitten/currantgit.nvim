local M = {}
local config = require("currantgit.config")
local actions = require("currantgit.actions")

local state = {
  configured = false,
  opts = {},
}

local open_status

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

local function set_modifiable(buffer, callback)
  local was_modifiable = vim.bo[buffer].modifiable
  local was_readonly = vim.bo[buffer].readonly
  vim.bo[buffer].readonly = false
  vim.bo[buffer].modifiable = true
  callback()
  vim.bo[buffer].modifiable = was_modifiable
  vim.bo[buffer].readonly = was_readonly
end

local function current_item(buffer)
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local item = vim.b[buffer].currantgit_line_items[line]
  return type(item) == "table" and item or nil
end

local function update_discovery(buffer)
  if not vim.api.nvim_buf_is_valid(buffer) or vim.bo[buffer].filetype ~= "currantgit" then
    return
  end
  local item = current_item(buffer)
  local available = actions.available(item, { buffer = buffer })
  local labels = {}
  for _, action in ipairs(available) do
    if action.key then
      labels[#labels + 1] = action.key .. " " .. action.label
    end
  end
  local line = #labels > 0 and "Actions: " .. table.concat(labels, "   ") or "Actions: r refresh   g? help"
  set_modifiable(buffer, function()
    vim.api.nvim_buf_set_lines(buffer, -2, -1, false, { line })
  end)
end

local function action_context(buffer)
  local root = vim.b[buffer].currantgit_root
  return {
    buffer = buffer,
    root = root,
    refresh = function()
      open_status()
    end,
    open = function(item)
      vim.cmd("edit " .. vim.fn.fnameescape(root .. "/" .. item.path))
    end,
    diff = function(item)
      M.git({ "diff", "--", item.path })
    end,
  }
end

local function dispatch_current(buffer, id)
  local item = current_item(buffer)
  local ok, error_message = actions.dispatch(id, action_context(buffer), item)
  if not ok and error_message then
    vim.notify("CurrantGit: " .. error_message, vim.log.levels.WARN)
  end
end

local function attach_status(buffer)
  local map = function(mode, lhs, rhs)
    vim.keymap.set(mode, lhs, rhs, { buffer = buffer, silent = true, desc = "CurrantGit" })
  end
  map("n", "<CR>", function() dispatch_current(buffer, "item.open") end)
  map("n", "d", function() dispatch_current(buffer, "item.diff") end)
  map("n", "r", function() dispatch_current(buffer, "surface.refresh") end)
  map("n", "g?", function() dispatch_current(buffer, "surface.help") end)
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = buffer,
    callback = function()
      update_discovery(buffer)
    end,
  })
  update_discovery(buffer)
end

local function set_buffer(lines, items, title, line_items, root)
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
  vim.b[buffer].currantgit_line_items = line_items or {}
  vim.b[buffer].currantgit_root = root
  vim.b[buffer].currantgit_title = title
  if title == "status" then
    attach_status(buffer)
  end
  return buffer
end

local function parse_status(stdout)
  local items = {}
  local ui = config.get().ui
  local lines = { ui.title .. "  " .. vim.fn.fnamemodify(vim.fn.getcwd(), ":t") }
  local branch = ""
  local changes = {}
  local line_items = {}

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
    for index, change in ipairs(changes) do
      lines[#lines + 1] = change
      line_items[#lines] = items[index]
    end
  elseif ui.show_clean then
    lines[#lines + 1] = "  clean"
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = ""
  return lines, items, line_items
end

open_status = function()
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
      local lines, items, line_items = parse_status(result.stdout or "")
      set_buffer(lines, items, "status", line_items, root)
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

  actions.register({
    id = "surface.refresh",
    label = "refresh",
    key = "r",
    run = function(context)
      context.refresh()
      return true
    end,
  })
  actions.register({
    id = "surface.help",
    label = "help",
    key = "g?",
    run = function()
      vim.notify("CurrantGit: <CR> open   d diff   r refresh", vim.log.levels.INFO)
      return true
    end,
  })
  actions.register({
    id = "item.open",
    label = "open",
    key = "<CR>",
    applies_to = { "change" },
    run = function(context, item)
      context.open(item)
      return true
    end,
  })
  actions.register({
    id = "item.diff",
    label = "diff",
    key = "d",
    applies_to = { "change" },
    run = function(context, item)
      context.diff(item)
      return true
    end,
  })

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
