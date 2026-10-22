-- Projects the executor's command ledger into the `:GitActivity` buffer:
-- one semantic row per command (newest first) with its output in a native
-- fold underneath. Pure rendering -- no Git, no buffer access.
local M = {}

local SUCCESS = "✓"
local FAILURE = "✗"
local OUTPUT_INDENT = "    "

-- `-z` commands separate records with NUL; a newline is the readable
-- equivalent. Other control bytes (except tab) are spelled out as `<xx>` so
-- the buffer never shows Vim's raw `^@`-style rendering.
function M.sanitize(text)
  text = (text or ""):gsub("\r\n", "\n"):gsub("%z", "\n")
  return (text:gsub("[\1-\8\11-\31\127]", function(byte)
    return string.format("<%02x>", byte:byte())
  end))
end

local function output_lines(text)
  text = vim.trim(M.sanitize(text))
  if text == "" then return {} end
  return vim.split(text, "\n", { plain = true })
end

-- Returns lines, fold_levels, line_items, highlights. `open` maps item IDs
-- to an explicit fold state; rows without one default to expanded only when
-- the command failed.
function M.render(log, open)
  open = open or {}
  local lines = { string.format("CurrantGit activity  %d command%s", #log, #log == 1 and "" or "s") }
  local fold_levels, line_items, highlights, folds = {}, {}, {}, {}
  local function highlight(start_col, end_col, group)
    highlights[#highlights + 1] = { line = #lines, start_col = start_col, end_col = end_col, group = group }
  end
  highlight(0, #"CurrantGit activity", "CurrantGitRepository")
  lines[#lines + 1] = ""
  if #log == 0 then
    lines[#lines + 1] = "  no Git commands recorded"
    return lines, fold_levels, line_items, highlights, folds
  end

  local previous_cwd
  for index = #log, 1, -1 do
    local entry = log[index]
    if entry.cwd ~= previous_cwd then
      if previous_cwd then lines[#lines + 1] = "" end
      lines[#lines + 1] = entry.cwd or "(unknown repository)"
      highlight(0, #lines[#lines], "CurrantGitHeading")
      previous_cwd = entry.cwd
    end

    local failed = entry.code ~= 0
    local marker = failed and FAILURE or SUCCESS
    local time = entry.time and os.date("%H:%M:%S", entry.time) or "--:--:--"
    local duration = string.format("%6dms", entry.duration_ms or 0)
    local command = M.sanitize(table.concat(vim.list_slice(entry.argv, 2), " ")):gsub("\n", " ")
    local prefix = marker .. " " .. time .. " " .. duration .. "  "
    local row = prefix .. command
    if failed then row = row .. "  exit " .. tostring(entry.code) end
    lines[#lines + 1] = row
    local marker_group = failed and "CurrantGitActivityFailure" or "CurrantGitActivitySuccess"
    highlight(0, #marker, marker_group)
    highlight(#marker + 1, #marker + 1 + #time, "CurrantGitActivityTime")
    highlight(#marker + 2 + #time, #marker + 2 + #time + #duration, "CurrantGitActivityDuration")
    highlight(#prefix, #prefix + #command, "CurrantGitActivityCommand")
    if failed then highlight(#prefix + #command + 2, #row, "CurrantGitActivityFailure") end

    local stdout = output_lines(entry.stdout or entry.output)
    local stderr = output_lines(entry.stderr)
    local id = "activity:" .. index
    line_items[#lines] = {
      kind = "activity",
      id = id,
      index = index,
      argv = vim.deepcopy(entry.argv),
      cwd = entry.cwd,
      code = entry.code,
      duration_ms = entry.duration_ms,
      time = entry.time,
      has_output = #stdout + #stderr > 0,
    }
    if #stdout + #stderr > 0 then
      local row_line = #lines
      fold_levels[row_line] = ">1"
      for _, text in ipairs(stdout) do
        lines[#lines + 1] = OUTPUT_INDENT .. text
        fold_levels[#lines] = 1
        highlight(0, #lines[#lines], "CurrantGitActivityOutput")
      end
      for _, text in ipairs(stderr) do
        lines[#lines + 1] = OUTPUT_INDENT .. text
        fold_levels[#lines] = 1
        highlight(0, #lines[#lines], failed and "CurrantGitActivityStderr" or "CurrantGitActivityOutput")
      end
      local expanded = open[id]
      if expanded == nil then expanded = failed end
      folds[#folds + 1] = { line = row_line, open = expanded }
    end
  end
  return lines, fold_levels, line_items, highlights, folds
end

return M
