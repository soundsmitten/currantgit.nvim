local M = {}

function M.parse(stdout)
  local lines = vim.split(stdout or "", "\n", { plain = true })
  local fold_levels = {}
  local has_hunk = false
  for line, text in ipairs(lines) do
    if text:match("^@@") then
      fold_levels[line] = ">1"
      has_hunk = true
    elseif has_hunk and text ~= "" then
      fold_levels[line] = 2
    else
      fold_levels[line] = 0
    end
  end
  if has_hunk then
    fold_levels[#lines + 1] = "<1"
    lines[#lines + 1] = ""
  end
  return lines, fold_levels
end

return M
