local M = {}

local histories = {}

local function state_for(window)
  histories[window] = histories[window] or { entries = {}, index = 0 }
  return histories[window]
end

local function capture(window)
  local buffer = vim.api.nvim_win_get_buf(window)
  return {
    buffer = buffer,
    cursor = vim.api.nvim_win_get_cursor(window),
    view = vim.fn.winsaveview(),
  }
end

local function same_position(left, right)
  return left.buffer == right.buffer
    and left.cursor[1] == right.cursor[1]
    and left.cursor[2] == right.cursor[2]
end

local function restore(window, entry)
  if not vim.api.nvim_buf_is_valid(entry.buffer) then
    return false
  end
  vim.api.nvim_win_set_buf(window, entry.buffer)
  vim.api.nvim_win_set_cursor(window, entry.cursor)
  vim.fn.winrestview(entry.view)
  return true
end

function M.attach(window)
  local buffer = vim.api.nvim_win_get_buf(window)
  vim.keymap.set("n", "<C-O>", function()
    M.back(window)
  end, { buffer = buffer, silent = true, desc = "CurrantGit back" })
  vim.keymap.set("n", "<C-S-I>", function()
    M.forward(window)
  end, { buffer = buffer, silent = true, desc = "CurrantGit forward" })
end

function M.visit(window)
  local history = state_for(window)
  local entry = capture(window)
  local current = history.entries[history.index]
  if current and same_position(current, entry) then
    current.view = entry.view
    return
  end
  for index = #history.entries, history.index + 1, -1 do
    history.entries[index] = nil
  end
  history.entries[#history.entries + 1] = entry
  history.index = #history.entries
  M.attach(window)
end

function M.update(window)
  local history = state_for(window)
  local current = history.entries[history.index]
  if current then
    local entry = capture(window)
    current.buffer = entry.buffer
    current.cursor = entry.cursor
    current.view = entry.view
  end
end

function M.back(window)
  local history = state_for(window)
  M.update(window)
  if history.index <= 1 then
    vim.api.nvim_feedkeys(vim.keycode("<C-O>"), "n", false)
    return false
  end
  history.index = history.index - 1
  return restore(window, history.entries[history.index])
end

function M.forward(window)
  local history = state_for(window)
  M.update(window)
  if history.index >= #history.entries then
    vim.api.nvim_feedkeys(vim.keycode("<C-I>"), "n", false)
    return false
  end
  history.index = history.index + 1
  return restore(window, history.entries[history.index])
end

function M.reset(window)
  histories[window] = nil
end

return M
