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
    elseif current and vim.startswith(line, "author-time ") then
      current.author_time = tonumber(line:sub(13))
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

local UNCOMMITTED = string.rep("0", 40)

local function hsl_to_hex(hue, saturation, lightness)
  local chroma = (1 - math.abs(2 * lightness - 1)) * saturation
  local x = chroma * (1 - math.abs((hue / 60) % 2 - 1))
  local m = lightness - chroma / 2
  local r, g, b
  if hue < 60 then r, g, b = chroma, x, 0
  elseif hue < 120 then r, g, b = x, chroma, 0
  elseif hue < 180 then r, g, b = 0, chroma, x
  elseif hue < 240 then r, g, b = 0, x, chroma
  elseif hue < 300 then r, g, b = x, 0, chroma
  else r, g, b = chroma, 0, x end
  return string.format("#%02x%02x%02x",
    math.floor((r + m) * 255 + 0.5), math.floor((g + m) * 255 + 0.5), math.floor((b + m) * 255 + 0.5))
end

-- One highlight group per commit, so a commit's runs share a colour wherever
-- they appear (fugitive does the same). The hue comes from the hash; the
-- lightness is fixed per 'background' because a raw hash used as a colour
-- (fugitive's approach) is often too dark or too bright to read.
function M.commit_group(commit)
  if commit == UNCOMMITTED then
    return "CurrantGitBlameUncommitted"
  end
  local group = "CurrantGitBlameHash" .. commit:sub(1, 8)
  if vim.o.termguicolors then
    local hue = tonumber(commit:sub(1, 4), 16) % 360
    local lightness = vim.o.background == "light" and 0.35 or 0.7
    vim.api.nvim_set_hl(0, group, { fg = hsl_to_hex(hue, 0.6, lightness) })
  else
    vim.api.nvim_set_hl(0, group, { link = "CurrantGitBlameHash" })
  end
  return group
end

-- Renders annotation rows only -- the source text stays in the source
-- window, which is scroll-bound to this one. The first row of each
-- same-commit run names the commit; the rest show a guide in that commit's
-- colour, so each run reads as one block.
function M.render(rows)
  local author_width = 0
  for _, row in ipairs(rows) do
    author_width = math.max(author_width, math.min(vim.fn.strdisplaywidth(row.author), 20))
  end
  local lines = {}
  local highlights = {}
  local previous
  for index, row in ipairs(rows) do
    local group = M.commit_group(row.commit)
    if row.commit ~= previous then
      local author = vim.fn.strcharpart(row.author, 0, 20)
      author = author .. string.rep(" ", author_width - vim.fn.strdisplaywidth(author))
      local date = row.author_time and os.date("%Y-%m-%d", row.author_time) or ""
      local hash = row.commit:sub(1, 8)
      lines[index] = hash .. " " .. author .. " " .. date
      highlights[#highlights + 1] = { line = index, start_col = 0, end_col = #hash, group = group }
      highlights[#highlights + 1] = {
        line = index, start_col = #hash + 1, end_col = #hash + 1 + #author, group = "CurrantGitBlameAuthor",
      }
      highlights[#highlights + 1] = {
        line = index, start_col = #lines[index] - #date, end_col = #lines[index], group = "CurrantGitBlameDate",
      }
    else
      lines[index] = "│"
      highlights[#highlights + 1] = { line = index, start_col = 0, end_col = #lines[index], group = group }
    end
    previous = row.commit
  end
  return lines, highlights
end

return M
