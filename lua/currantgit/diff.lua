local M = {}

function M.parse(stdout)
  local lines = vim.split(stdout or "", "\n", { plain = true })
  local fold_levels = {}
  local line_items = {}
  local hunks = {}
  local has_hunk = false
  for line, text in ipairs(lines) do
    if text:match("^@@") then
      fold_levels[line] = ">1"
      has_hunk = true
      local old_start, old_count, new_start, new_count = text:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
      local hunk = {
        id = "diff:hunk:" .. (#hunks + 1),
        kind = "hunk",
        header = text,
        old_start = tonumber(old_start),
        old_count = tonumber(old_count ~= "" and old_count or "1"),
        new_start = tonumber(new_start),
        new_count = tonumber(new_count ~= "" and new_count or "1"),
        capabilities = { "collapse", "stage", "unstage" },
      }
      hunks[#hunks + 1] = hunk
      line_items[line] = hunk
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
  return lines, fold_levels, line_items, hunks
end

return M
