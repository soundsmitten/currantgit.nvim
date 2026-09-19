local M = {}
local config = require("currantgit.config")
local actions = require("currantgit.actions")
local navigation = require("currantgit.navigation")

local state = {
  configured = false,
  opts = {},
  errors = {},
}

local open_status

local function schedule(callback)
  vim.schedule(function()
    local ok, error_message = xpcall(callback, debug.traceback)
    if not ok then
      state.errors[#state.errors + 1] = error_message
      vim.notify("CurrantGit: " .. error_message, vim.log.levels.ERROR)
    end
  end)
end

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
  local function action(args, callback)
    local result_root, error_message = repository_root()
    if not result_root then
      vim.notify("CurrantGit: " .. error_message, vim.log.levels.ERROR)
      return
    end
    vim.system(vim.list_extend({ git_command() }, args), {
      cwd = result_root,
      text = true,
    }, function(result)
      schedule(function()
        if result.code ~= 0 then
          vim.notify("CurrantGit: " .. (result.stderr or "git action failed"), vim.log.levels.ERROR)
          return
        end
        callback()
      end)
    end)
  end
  return {
    buffer = buffer,
    root = root,
    refresh = function()
      open_status()
    end,
    open = function(item)
      navigation.update(0)
      vim.cmd("edit " .. vim.fn.fnameescape(root .. "/" .. item.path))
      navigation.visit(0)
    end,
    diff = function(item)
      M.git({ "diff", "--", item.path })
    end,
    stage = function(item)
      action({ "add", "--", item.path }, open_status)
    end,
    unstage = function(item)
      action({ "restore", "--staged", "--", item.path }, open_status)
    end,
    discard = function(item)
      vim.ui.select({ "Discard", "Cancel" }, {
        prompt = "Discard working-tree changes to " .. item.path .. "?",
      }, function(choice)
        if choice ~= "Discard" then
          return
        end
        action({ "restore", "--worktree", "--", item.path }, open_status)
      end)
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
  navigation.visit(0)
  local map = function(mode, lhs, rhs)
    vim.keymap.set(mode, lhs, rhs, { buffer = buffer, silent = true, desc = "CurrantGit" })
  end
  map("n", "<CR>", function() dispatch_current(buffer, "item.open") end)
  map("n", "d", function() dispatch_current(buffer, "item.diff") end)
  map("n", "s", function() dispatch_current(buffer, "item.stage") end)
  map("n", "u", function() dispatch_current(buffer, "item.unstage") end)
  map("n", "-", function() dispatch_current(buffer, "item.toggle") end)
  map("n", "X", function() dispatch_current(buffer, "item.discard") end)
  map("n", "r", function() dispatch_current(buffer, "surface.refresh") end)
  map("n", "g?", function() dispatch_current(buffer, "surface.help") end)
  local group = vim.api.nvim_create_augroup("CurrantGitStatus" .. buffer, { clear = true })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    buffer = buffer,
    callback = function()
      update_discovery(buffer)
    end,
  })
  update_discovery(buffer)
end

local function set_buffer(lines, items, title, line_items, root, fold_levels)
  local name = "currantgit://" .. title
  local buffer = vim.fn.bufnr(name)
  if buffer < 0 or not vim.api.nvim_buf_is_valid(buffer) then
    buffer = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buffer, name)
  end
  vim.api.nvim_set_current_buf(buffer)
  vim.bo[buffer].buftype = "nofile"
  vim.bo[buffer].bufhidden = "hide"
  vim.bo[buffer].modifiable = true
  vim.bo[buffer].filetype = "currantgit"
  set_modifiable(buffer, function()
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  end)
  vim.bo[buffer].modifiable = false
  vim.bo[buffer].readonly = true
  vim.b[buffer].currantgit_items = items
  vim.b[buffer].currantgit_line_items = line_items or {}
  vim.b[buffer].currantgit_fold_levels = fold_levels or {}
  vim.b[buffer].currantgit_root = root
  vim.b[buffer].currantgit_title = title
  vim.wo.foldmethod = title == "status" and "expr" or "manual"
  if title == "status" then
    vim.wo.foldexpr = "v:lua.require'currantgit'.foldexpr(v:lnum)"
    vim.wo.foldlevel = 99
    vim.wo.foldenable = true
  end
  if title == "status" then
    attach_status(buffer)
  end
  return buffer
end

local function parse_status(stdout)
  local items = {}
  local ui = config.get().ui
  local repository_name = vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
  local header = ui.title and (ui.title .. "  " .. repository_name) or repository_name
  local lines = { header }
  local branch = ""
  local line_items = {}
  local fold_levels = {}
  local section_nodes = {}
  local sections = {
    staged = { label = "Staged changes", items = {} },
    unstaged = { label = "Unstaged changes", items = {} },
    untracked = { label = "Untracked files", items = {} },
    conflicts = { label = "Conflicts", items = {} },
  }

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
      local is_untracked = status == "??"
      local is_conflict = status:find("[DAU][DAU]", 1) ~= nil
      local item = {
        id = "change:" .. path,
        kind = "change",
        change_kind = is_conflict and "conflict" or change_kind,
        path = path,
        status = status,
        capabilities = { "open", "diff", "stage" },
      }
      items[#items + 1] = item
      if is_conflict then
        sections.conflicts.items[#sections.conflicts.items + 1] = item
      elseif is_untracked then
        sections.untracked.items[#sections.untracked.items + 1] = item
      else
        if status:sub(1, 1) ~= " " then
          sections.staged.items[#sections.staged.items + 1] = item
        end
        if status:sub(2, 2) ~= " " then
          sections.unstaged.items[#sections.unstaged.items + 1] = item
        end
      end
    end
  end

  if ui.show_branch then
    lines[#lines + 1] = "Branch: " .. (branch ~= "" and branch or "detached")
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = ui.show_counts and string.format("Changes (%d)", #items) or "Changes"
  fold_levels[#lines] = 0
  local section_order = { "staged", "unstaged", "untracked", "conflicts" }
  for _, section_kind in ipairs(section_order) do
    local section = sections[section_kind]
    if #section.items > 0 then
      local node = {
        id = "status:section:" .. section_kind,
        kind = "section",
        section_kind = section_kind,
        label = section.label,
        count = #section.items,
        children = section.items,
        capabilities = { "collapse" },
      }
      section_nodes[#section_nodes + 1] = node
      lines[#lines + 1] = string.format("%s (%d)", section.label, #section.items)
      line_items[#lines] = node
      fold_levels[#lines] = ">1"
      for _, item in ipairs(section.items) do
        lines[#lines + 1] = string.format("  %s  %s", ui.icons[item.change_kind] or item.status, item.path)
        line_items[#lines] = item
        fold_levels[#lines] = 2
      end
    end
  end
  if #items == 0 and ui.show_clean then
    lines[#lines + 1] = "  clean"
    fold_levels[#lines] = 0
  end
  lines[#lines + 1] = ""
  fold_levels[#lines] = "<1"
  lines[#lines + 1] = ""
  fold_levels[#lines] = 0
  return lines, items, line_items, fold_levels, section_nodes
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
    schedule(function()
      if result.code ~= 0 then
        vim.notify("CurrantGit: " .. (result.stderr or "git status failed"), vim.log.levels.ERROR)
        return
      end
      local lines, items, line_items, fold_levels, section_nodes = parse_status(result.stdout or "")
      set_buffer(lines, items, "status", line_items, root, fold_levels)
      vim.b.currantgit_sections = section_nodes
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
    schedule(function()
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
    id = "item.stage",
    label = "stage",
    key = "s",
    applies_to = { "change" },
    is_available = function(_, item)
      return item.status == "??" or item.status:sub(2, 2) ~= " "
    end,
    run = function(context, item)
      context.stage(item)
      return true
    end,
  })
  actions.register({
    id = "item.unstage",
    label = "unstage",
    key = "u",
    applies_to = { "change" },
    is_available = function(_, item)
      return item.status ~= "??" and item.status:sub(1, 1) ~= " "
    end,
    run = function(context, item)
      context.unstage(item)
      return true
    end,
  })
  actions.register({
    id = "item.toggle",
    label = "toggle staged",
    key = "-",
    applies_to = { "change" },
    run = function(context, item)
      if item.status ~= "??" and item.status:sub(1, 1) ~= " " then
        context.unstage(item)
      else
        context.stage(item)
      end
      return true
    end,
  })
  actions.register({
    id = "item.discard",
    label = "discard",
    key = "X",
    applies_to = { "change" },
    is_available = function(_, item)
      return item.status ~= "??" and item.status:sub(2, 2) ~= " "
    end,
    run = function(context, item)
      context.discard(item)
      return true
    end,
  })
  actions.register({
    id = "surface.help",
    label = "help",
    key = "g?",
    run = function()
      vim.notify("CurrantGit: <CR> open   d diff   s stage   u unstage   - toggle   X discard   r refresh", vim.log.levels.INFO)
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

function M.errors()
  return state.errors
end

function M.foldexpr(line)
  return vim.b.currantgit_fold_levels[line] or 0
end

return M
