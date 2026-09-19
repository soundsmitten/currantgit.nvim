local M = {}

function M.parse(stdout)
  local rows = {}
  local current
  for line in (stdout or ""):gmatch("(.-)\n") do
    -- The trailing group-size field is only emitted on the first line of a
    -- contiguous same-commit run (see `git help blame`, --line-porcelain);
    -- it must not be required here or every subsequent line in that run is
    -- silently dropped.
    local commit, original, final = line:match("^([0-9a-f]+) (%d+) (%d+)")
    if commit then
      current = {
        commit = commit,
        original_line = tonumber(original),
        line = tonumber(final),
        author = "",
        summary = "",
      }
    elseif current and vim.startswith(line, "author ") then
      current.author = line:sub(8)
    elseif current and vim.startswith(line, "summary ") then
      current.summary = line:sub(9)
    elseif current and vim.startswith(line, "\t") then
      current.text = line:sub(2)
      rows[#rows + 1] = current
      current = nil
    end
  end
  return rows
end

function M.render(rows)
  local lines = {}
  for _, row in ipairs(rows) do
    lines[#lines + 1] = string.format("%-8s %-16s %s", row.commit:sub(1, 8), row.author, row.text)
  end
  return lines
end

return M
