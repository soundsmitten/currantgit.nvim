local M = {}

-- Git C-quotes/octal-escapes a `diff --git`/`---`/`+++` header path when it
-- contains "unusual" bytes (tabs, newlines, quotes, backslashes, or --
-- unconditionally under the default `core.quotePath=true` -- any byte above
-- 0x80, i.e. any non-ASCII/unicode path). `git help config`, core.quotePath:
-- "Double-quotes, backslash and control characters are always escaped
-- regardless of the setting of this variable." There is no `-z`-equivalent
-- for unified-diff header lines specifically (`-z` only affects
-- `--raw`/`--numstat`/`--name-only`/`--name-status`, per `git help diff`),
-- so a header path must be unquoted here rather than assumed to be raw.
local function unquote_diff_path(text)
  -- A path containing a literal space (but nothing else "unusual" enough to
  -- trigger quoting) gets a single trailing tab appended instead, to
  -- disambiguate the path from a possible trailing text field in strict
  -- unified-diff format. Verified empirically: exactly one trailing tab,
  -- independent of how many embedded spaces the path has, and independent
  -- of the quoting below (quoting and the tab suffix are separate
  -- mechanisms and can combine).
  local trimmed = text:gsub("\t$", "")
  local body = trimmed:match('^"(.*)"$')
  if not body then
    return trimmed
  end
  body = body:gsub("\\([0-7][0-7][0-7])", function(octal)
    return string.char(tonumber(octal, 8))
  end)
  body = body:gsub("\\(.)", function(escaped)
    if escaped == "t" then return "\t"
    elseif escaped == "n" then return "\n"
    elseif escaped == '"' then return '"'
    elseif escaped == "\\" then return "\\"
    else return escaped end
  end)
  return body
end

function M.parse(stdout, options)
  options = options or {}
  local lines = vim.split(stdout or "", "\n", { plain = true })
  local fold_levels = {}
  local line_items = {}
  local hunks = {}
  local header_lines = {}
  local current_hunk
  local has_hunk = false
  for line, text in ipairs(lines) do
    if text:match("^diff %-%-git ") then
      if current_hunk then current_hunk.end_line = line - 1 end
      header_lines = { text }
      current_hunk = nil
    elseif current_hunk == nil and not text:match("^@@") and #header_lines > 0 then
      header_lines[#header_lines + 1] = text
    elseif text:match("^@@") then
      if current_hunk then current_hunk.end_line = line - 1 end
      fold_levels[line] = ">1"
      has_hunk = true
      local old_start, old_count, new_start, new_count = text:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
      local hunk_header = vim.deepcopy(header_lines)
      if #hunk_header == 0 and options.path then
        hunk_header = { "--- a/" .. options.path, "+++ b/" .. options.path }
      end
      local path = options.path
      for _, header in ipairs(hunk_header) do
        local raw_header_path = header:match("^%+%+%+ (.+)$")
        local header_path = raw_header_path and unquote_diff_path(raw_header_path):match("^b/(.+)")
        if header_path then path = header_path end
      end
      local hunk = {
        id = "diff:hunk:" .. (#hunks + 1),
        kind = "hunk",
        header = text,
        old_start = tonumber(old_start),
        old_count = tonumber(old_count ~= "" and old_count or "1"),
        new_start = tonumber(new_start),
        new_count = tonumber(new_count ~= "" and new_count or "1"),
        start_line = line,
        -- Do not default to "working": a caller that forgot to classify
        -- the diff should get a hunk that offers no stage/unstage action,
        -- not one that silently claims to represent the live index.
        mode = options.mode or "historical",
        path = path,
        header_lines = hunk_header,
        capabilities = { "collapse", "stage", "unstage" },
      }
      hunks[#hunks + 1] = hunk
      line_items[line] = hunk
      current_hunk = hunk
    elseif has_hunk and text ~= "" then
      fold_levels[line] = 2
      line_items[line] = current_hunk
    else
      fold_levels[line] = 0
    end
  end
  if has_hunk then
    if current_hunk then
      current_hunk.end_line = #lines
    end
    for _, hunk in ipairs(hunks) do
      local patch_lines = vim.deepcopy(hunk.header_lines)
      for line = hunk.start_line, #lines do
        if line > hunk.start_line and (lines[line]:match("^diff %-%-git ") or lines[line]:match("^@@")) then
          break
        end
        patch_lines[#patch_lines + 1] = lines[line]
      end
      hunk.patch = table.concat(patch_lines, "\n") .. "\n"
    end
    fold_levels[#lines + 1] = "<1"
    lines[#lines + 1] = ""
  end
  return lines, fold_levels, line_items, hunks
end

return M
