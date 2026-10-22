-- Shared pieces of CurrantGit's native-diff-mode views (conflict resolver,
-- diff split): read-only `currantgit://` side buffers, hatched filler,
-- per-side tints and the highlight palette they are mixed from.
local M = {}

local function hl_color(name, key)
  return vim.api.nvim_get_hl(0, { name = name, link = false })[key]
end

-- Mixes two 0xRRGGBB colors: `alpha` of `a` over `b`.
function M.blend(a, b, alpha)
  local result = 0
  for shift = 0, 16, 8 do
    local x, y = bit.band(bit.rshift(a, shift), 0xff), bit.band(bit.rshift(b, shift), 0xff)
    result = result + bit.lshift(math.floor(x * alpha + y * (1 - alpha) + 0.5), shift)
  end
  return result
end

-- The colorscheme colors every pane tint is mixed from: info (cool) and
-- warning (warm) stay apart even where DiffAdd and DiffChange look alike.
function M.palette()
  local light = vim.o.background == "light"
  local bg = hl_color("Normal", "bg") or (light and 0xffffff or 0x1c1c1c)
  local fg = hl_color("Normal", "fg") or (light and 0x1c1c1c or 0xd0d0d0)
  return {
    bg = bg,
    fg = fg,
    cool = hl_color("DiagnosticInfo", "fg") or hl_color("Function", "fg") or 0x5f87d7,
    warm = hl_color("DiagnosticWarn", "fg") or hl_color("Constant", "fg") or 0xd7875f,
    comment = hl_color("Comment", "fg") or M.blend(fg, bg, 0.5),
  }
end

-- The standard side tint set for `prefix` .. `name` over `color`: a line
-- tint, a stronger changed-text tint and a label color.
function M.side_groups(groups, prefix, color, palette)
  groups[prefix] = { bg = M.blend(color, palette.bg, 0.2) }
  groups[prefix .. "Text"] = { bg = M.blend(color, palette.bg, 0.38) }
  groups[prefix .. "Label"] = { fg = color }
  return groups
end

-- Defines `build(palette)`'s groups now and on every ColorScheme. All are
-- `default`, so a user's own definition of any of them wins.
function M.define(augroup, build)
  local function apply()
    for name, spec in pairs(build(M.palette())) do
      spec.default = true
      vim.api.nvim_set_hl(0, name, spec)
    end
  end
  apply()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup(augroup, { clear = true }),
    callback = apply,
  })
end

-- A 'winhighlight' value painting this pane's diff colors with `group`
-- (and `group .. "Text"` for DiffText). In diff mode DiffDelete only paints
-- filler, which here means "the other side has lines here", so it gets the
-- neutral `filler` group rather than red.
function M.winhighlight(group, text_group, filler)
  return "DiffAdd:" .. group .. ",DiffChange:" .. group .. ",DiffText:" .. text_group
    .. ",DiffDelete:" .. filler
end

function M.split_content(content)
  local lines = vim.split(content or "", "\n", { plain = true })
  if lines[#lines] == "" then lines[#lines] = nil end
  return lines
end

local function find_buffer(name)
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(buffer) == name then return buffer end
  end
end

-- A read-only scratch buffer named `currantgit://<kind>/<side>/<path>`,
-- reused if it already exists. `missing` marks an empty stand-in side.
function M.side_buffer(kind, side, path, lines, missing)
  local name = "currantgit://" .. kind .. "/" .. side .. "/" .. path
  local buffer = find_buffer(name)
  if not buffer then
    buffer = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buffer, name)
  end
  vim.bo[buffer].buftype = "nofile"
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].readonly = false
  vim.bo[buffer].modifiable = true
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.bo[buffer].modifiable = false
  vim.bo[buffer].readonly = true
  vim.bo[buffer].filetype = vim.filetype.match({ filename = path }) or ""
  vim.b[buffer].currantgit_missing = missing or false
  return buffer
end

function M.fill_with_hatching(window)
  local entries = {}
  for entry in (vim.wo[window].fillchars or ""):gmatch("[^,]+") do
    if not vim.startswith(entry, "diff:") then entries[#entries + 1] = entry end
  end
  entries[#entries + 1] = "diff:╱"
  vim.wo[window].fillchars = table.concat(entries, ",")
end

-- Puts every window of the current tab in diff mode with hatched filler.
function M.diff_tab()
  for _, window in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    vim.api.nvim_win_call(window, function() vim.cmd("diffthis") end)
    M.fill_with_hatching(window)
  end
end

-- `gq` closes the view's tab from any of its panes. The mapping is removed
-- when a buffer leaves its window, so the user's real file doesn't keep it.
function M.map_quit(buffers, tab_var)
  local function quit()
    if vim.t[tab_var] == nil then return end
    if #vim.api.nvim_list_tabpages() > 1 then
      vim.cmd("tabclose")
    else
      vim.cmd("only")
    end
  end
  for _, buffer in ipairs(buffers) do
    vim.keymap.set("n", "gq", quit, { buffer = buffer, silent = true, desc = "CurrantGit: close view" })
    vim.api.nvim_create_autocmd("BufWinLeave", {
      buffer = buffer,
      once = true,
      callback = function() pcall(vim.keymap.del, "n", "gq", { buffer = buffer }) end,
    })
  end
end

return M
