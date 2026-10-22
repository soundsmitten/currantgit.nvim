-- Highlights rendered unified-diff text as the changed file's own language.
--
-- Each hunk is split into its two sides -- old (context + removed lines) and
-- new (context + added lines) -- and each side is parsed as one snippet with
-- the file's treesitter parser, so tokens spanning lines (strings, comments)
-- and the surrounding context parse the way they do in the real file.
-- Captures are projected back onto the diff rows, shifted one column past
-- the +/-/space prefix. Context rows take their highlights from the new
-- side only. Files without a parser still get add/delete line backgrounds.
local diff = require("currantgit.diff")

local M = {}

M.namespace = vim.api.nvim_create_namespace("currantgit_diff_syntax")

-- Beyond this many rows in one region, skip treesitter (line backgrounds
-- only) so a huge generated diff cannot stall a render.
local MAX_SYNTAX_LINES = 5000
local LINE_PRIORITY = 50
local queries = {}

local function highlights_query(lang)
  if queries[lang] == nil then
    local ok, query = pcall(vim.treesitter.query.get, lang, "highlights")
    queries[lang] = ok and query or false
  end
  return queries[lang] or nil
end

local function language_for(path)
  if not path or path == "" then return nil end
  local filetype = vim.filetype.match({ filename = path })
  if not filetype then return nil end
  local lang = vim.treesitter.language.get_lang(filetype) or filetype
  local ok, loaded = pcall(vim.treesitter.language.add, lang)
  if not ok or not loaded or not highlights_query(lang) then return nil end
  return lang
end

local function mark(buffer, row, col, opts)
  pcall(vim.api.nvim_buf_set_extmark, buffer, M.namespace, row, col, opts)
end

-- `rows[i]` is the 0-based buffer row for snippet line i, or false for a
-- line that is parsed for context but must not be highlighted from this side.
local function highlight_side(buffer, lang, texts, rows)
  if #texts == 0 then return end
  local source = table.concat(texts, "\n")
  local ok, parser = pcall(vim.treesitter.get_string_parser, source, lang)
  if not ok then return end
  if not pcall(parser.parse, parser, true) then return end
  parser:for_each_tree(function(tree, language_tree)
    local tree_lang = language_tree:lang()
    local query = highlights_query(tree_lang)
    if not query then return end
    for id, node, metadata in query:iter_captures(tree:root(), source) do
      local name = query.captures[id]
      if not vim.startswith(name, "_") and name ~= "spell" and name ~= "nospell" and name ~= "conceal" then
        local group = "@" .. name .. "." .. tree_lang
        local priority = tonumber(metadata.priority) or vim.hl.priorities.treesitter
        local start_row, start_col, end_row, end_col = node:range()
        for line = start_row, math.min(end_row, #texts - 1) do
          local buffer_row = rows[line + 1]
          local from = line == start_row and start_col or 0
          local to = line == end_row and end_col or #texts[line + 1]
          if buffer_row and to > from then
            mark(buffer, buffer_row, from + 1, { end_col = to + 1, hl_group = group, priority = priority })
          end
        end
      end
    end
  end)
end

local HEADER_PATTERNS = {
  "^diff %-%-git ", "^index ", "^%-%-%- ", "^%+%+%+ ", "^new file mode", "^deleted file mode",
  "^old mode", "^new mode", "^similarity index", "^dissimilarity index", "^rename from", "^rename to",
  "^copy from", "^copy to", "^Binary files ",
}

local function is_header(text)
  for _, pattern in ipairs(HEADER_PATTERNS) do
    if text:find(pattern) then return true end
  end
  return false
end

local function hunk_path(hunk, fallback)
  if hunk.path then return hunk.path end
  for _, header in ipairs(hunk.header_lines or {}) do
    local old = header:match("^%-%-%- (.+)$")
    local path = old and diff.unquote_path(old):match("^a/(.+)")
    if path then return path end
  end
  return fallback
end

function M.clear(buffer)
  vim.api.nvim_buf_clear_namespace(buffer, M.namespace, 0, -1)
end

-- Highlights `lines` (diff text, possibly preceded by non-diff text such as
-- a commit message) rendered at 0-based buffer row `start_row`.
-- `options.path` is the fallback path for hunks without a file header.
function M.apply(buffer, start_row, lines, options)
  options = options or {}
  local _, _, _, hunks = diff.parse(table.concat(lines, "\n"), { path = options.path })
  local syntax = #lines <= MAX_SYNTAX_LINES
  local in_body = {}
  for _, hunk in ipairs(hunks) do
    mark(buffer, start_row + hunk.start_line - 1, 0, {
      end_col = #lines[hunk.start_line], hl_group = "CurrantGitDiffHunk", priority = LINE_PRIORITY,
    })
    local old_side, old_rows, new_side, new_rows = {}, {}, {}, {}
    for line = hunk.start_line + 1, math.min(hunk.end_line, #lines) do
      local text = lines[line]
      local prefix = text:sub(1, 1)
      if prefix ~= " " and prefix ~= "+" and prefix ~= "-" and prefix ~= "\\" then break end
      in_body[line] = true
      local row = start_row + line - 1
      local body = text:sub(2)
      if prefix == "+" then
        mark(buffer, row, 0, { line_hl_group = "CurrantGitDiffAdd", priority = LINE_PRIORITY })
        mark(buffer, row, 0, { end_col = 1, hl_group = "CurrantGitDiffAddSign", priority = LINE_PRIORITY })
        new_side[#new_side + 1], new_rows[#new_rows + 1] = body, row
      elseif prefix == "-" then
        mark(buffer, row, 0, { line_hl_group = "CurrantGitDiffDelete", priority = LINE_PRIORITY })
        mark(buffer, row, 0, { end_col = 1, hl_group = "CurrantGitDiffDeleteSign", priority = LINE_PRIORITY })
        old_side[#old_side + 1], old_rows[#old_rows + 1] = body, row
      elseif prefix == " " then
        new_side[#new_side + 1], new_rows[#new_rows + 1] = body, row
        old_side[#old_side + 1], old_rows[#old_rows + 1] = body, false
      else
        mark(buffer, row, 0, { end_col = #text, hl_group = "CurrantGitDiffHeader", priority = LINE_PRIORITY })
      end
    end
    local lang = syntax and language_for(hunk_path(hunk, options.path))
    if lang then
      highlight_side(buffer, lang, new_side, new_rows)
      highlight_side(buffer, lang, old_side, old_rows)
    end
  end
  -- File headers: from each `diff --git` up to its first hunk.
  local in_header = false
  for line, text in ipairs(lines) do
    if text:find("^diff %-%-git ") then in_header = true end
    if text:find("^@@") then in_header = false end
    if in_header and not in_body[line] and is_header(text) then
      mark(buffer, start_row + line - 1, 0, {
        end_col = #text, hl_group = "CurrantGitDiffHeader", priority = LINE_PRIORITY,
      })
    end
  end
end

return M
