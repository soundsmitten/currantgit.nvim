-- Read-only conflict model and resolver view (docs/issues/0010, slice 1).
--
-- Two sources, never confused:
--   * sides (ours/base/theirs, and how many regions the file started with)
--     come from the index stages -- `git ls-files -u` for which stages
--     exist, `git merge-file --object-id` to re-merge them, `git show
--     :<n>:<path>` for the panes -- so they survive the user editing the
--     worktree file;
--   * region locations come from the conflict markers still present in the
--     worktree (or the live result buffer).
-- Nothing in this module writes the index or the worktree.
local M = {}

local deps = {}
local namespace = vim.api.nvim_create_namespace("currantgit_conflict")

local function hl_color(name, key)
  return vim.api.nvim_get_hl(0, { name = name, link = false })[key]
end

-- Mixes two 0xRRGGBB colors: `alpha` of `a` over `b`.
local function blend(a, b, alpha)
  local result = 0
  for shift = 0, 16, 8 do
    local x, y = bit.band(bit.rshift(a, shift), 0xff), bit.band(bit.rshift(b, shift), 0xff)
    result = result + bit.lshift(math.floor(x * alpha + y * (1 - alpha) + 0.5), shift)
  end
  return result
end

-- Ours and theirs get their own tints, mixed from the colorscheme's info
-- (cool) and warning (warm) colors over its background, so they stay apart
-- even where DiffAdd and DiffChange look alike. Everything is `default`, so
-- a user's own definition of any of these groups wins.
local function define_highlights()
  local light = vim.o.background == "light"
  local bg = hl_color("Normal", "bg") or (light and 0xffffff or 0x1c1c1c)
  local fg = hl_color("Normal", "fg") or (light and 0x1c1c1c or 0xd0d0d0)
  local cool = hl_color("DiagnosticInfo", "fg") or hl_color("Function", "fg") or 0x5f87d7
  local warm = hl_color("DiagnosticWarn", "fg") or hl_color("Constant", "fg") or 0xd7875f
  local comment = hl_color("Comment", "fg") or blend(fg, bg, 0.5)
  local groups = {
    CurrantGitConflictOurs = { bg = blend(cool, bg, 0.2) },
    CurrantGitConflictOursText = { bg = blend(cool, bg, 0.38) },
    CurrantGitConflictOursLabel = { fg = cool },
    CurrantGitConflictTheirs = { bg = blend(warm, bg, 0.2) },
    CurrantGitConflictTheirsText = { bg = blend(warm, bg, 0.38) },
    CurrantGitConflictTheirsLabel = { fg = warm },
    CurrantGitConflictBase = { fg = comment, italic = true },
    CurrantGitConflictBaseLabel = { fg = comment },
    CurrantGitConflictMarker = { fg = blend(fg, bg, 0.4) },
    CurrantGitConflictFiller = { fg = blend(fg, bg, 0.16) },
    CurrantGitConflictResult = {},
  }
  for name, spec in pairs(groups) do
    spec.default = true
    vim.api.nvim_set_hl(0, name, spec)
  end
end

-- In diff mode DiffDelete only paints filler; in a conflict the gap means
-- "the other side has lines here", not "deleted", so it gets a neutral color.
local FILLER_HIGHLIGHT = "DiffDelete:CurrantGitConflictFiller"
local SIDE_HIGHLIGHT = {
  -- The result pane is colored only by CurrantGit's region marks.
  result = "DiffAdd:CurrantGitConflictResult,DiffChange:CurrantGitConflictResult,"
    .. "DiffText:CurrantGitConflictResult," .. FILLER_HIGHLIGHT,
  ours = "DiffAdd:CurrantGitConflictOurs,DiffChange:CurrantGitConflictOurs,DiffText:CurrantGitConflictOursText,"
    .. FILLER_HIGHLIGHT,
  theirs = "DiffAdd:CurrantGitConflictTheirs,DiffChange:CurrantGitConflictTheirs,"
    .. "DiffText:CurrantGitConflictTheirsText," .. FILLER_HIGHLIGHT,
}

-- `git help merge-file`: markers are 7 characters by default. A marker is
-- the marker run alone or followed by a space and a label; a longer run
-- (`<<<<<<<<`) or trailing text without the space is ordinary content.
local MARKER_SIZE = 7

local function marker(line, char)
  local run = string.rep(char, MARKER_SIZE)
  if line == run then return true, nil end
  if line:sub(1, MARKER_SIZE + 1) == run .. " " then return true, line:sub(MARKER_SIZE + 2) end
  return false
end

-- Parses `merge`, `diff3` and `zdiff3` style markers (`git help config`,
-- merge.conflictStyle). Returns regions with 1-based marker line numbers;
-- an unterminated region is dropped rather than guessed at.
function M.parse_markers(lines)
  local regions = {}
  local current
  local part
  for index, line in ipairs(lines) do
    local is_open, open_label = marker(line, "<")
    if is_open then
      current = { start = index, ours = {}, theirs = {}, ours_label = open_label }
      part = "ours"
    elseif current then
      local is_base, base_label = marker(line, "|")
      local is_close, close_label = marker(line, ">")
      if is_base and part == "ours" then
        current.base, current.base_label, current.base_marker, part = {}, base_label, index, "base"
      elseif line == string.rep("=", MARKER_SIZE) and (part == "ours" or part == "base") then
        current.separator, part = index, "theirs"
      elseif is_close and part == "theirs" then
        current.finish, current.theirs_label = index, close_label
        regions[#regions + 1] = current
        current, part = nil, nil
      else
        local target = current[part]
        target[#target + 1] = line
      end
    end
  end
  return regions
end

local function split_content(content)
  local lines = vim.split(content or "", "\n", { plain = true })
  if lines[#lines] == "" then lines[#lines] = nil end
  return lines
end

local function same_sides(stage_region, live)
  return vim.deep_equal(stage_region.ours, live.ours) and vim.deep_equal(stage_region.theirs, live.theirs)
end

-- Matches live marker regions onto the regions the stages re-merge into, in
-- order. A region whose markers are gone is resolved ("edited" until slice
-- 2 can say which side won); a live region with no stage counterpart is
-- still listed so nothing the user can see is hidden.
function M.match(path, stage_regions, live_regions)
  local items = {}
  local next_stage = 1
  local extra = {}
  local matched = {}
  for _, live in ipairs(live_regions) do
    local found
    for candidate = next_stage, #stage_regions do
      if same_sides(stage_regions[candidate], live) then
        found = candidate
        break
      end
    end
    if found then
      matched[found] = live
      next_stage = found + 1
    else
      extra[#extra + 1] = live
    end
  end
  local function region_item(n, sides, live)
    return {
      id = "conflict:" .. path .. ":" .. n,
      kind = "conflict",
      path = path,
      index = n,
      ours = sides.ours,
      theirs = sides.theirs,
      base = sides.base,
      result_range = live and { live.start, live.finish } or nil,
      state = live and "unresolved" or "edited",
    }
  end
  for n, stage_region in ipairs(stage_regions) do
    items[n] = region_item(n, stage_region, matched[n])
  end
  for _, live in ipairs(extra) do
    items[#items + 1] = region_item(#items + 1, live, live)
  end
  return items
end

local function parse_unmerged(stdout, path)
  local stages = {}
  for _, entry in ipairs(vim.split(stdout or "", "\0", { plain = true })) do
    -- `git help ls-files`: `<mode> SP <object> SP <stage> TAB <file>`.
    local object, stage, file = entry:match("^%d+ (%x+) (%d)\t(.*)$")
    if object and file == path then stages[tonumber(stage)] = object end
  end
  return stages
end

local function read_worktree(root, path)
  local file = io.open(root .. "/" .. path, "rb")
  if not file then return nil end
  local content = file:read("*a")
  file:close()
  return content
end

-- Loads one conflicted file into a `conflict-file:<path>` item. `status` is
-- the status row it came from (for its XY code); `done(item)` always fires.
function M.load(root, status, done)
  local path = status.path
  local item = {
    id = "conflict-file:" .. path,
    kind = "conflict-file",
    change_kind = "conflict",
    path = path,
    status = status.status,
    stages = {},
    regions = {},
  }
  local function finish(stage_regions)
    local content = read_worktree(root, path)
    item.exists = content ~= nil
    if content and content:find("\0", 1, true) then item.binary = true end
    if item.missing or item.binary or not stage_regions then
      item.unresolved = 0
      done(item)
      return
    end
    item.regions = M.match(path, stage_regions, M.parse_markers(split_content(content)))
    item.total = #item.regions
    item.unresolved = 0
    for _, region in ipairs(item.regions) do
      if region.state == "unresolved" then item.unresolved = item.unresolved + 1 end
    end
    item.resolved = item.total - item.unresolved
    done(item)
  end
  local function merge(base)
    -- merge-file honors merge.conflictStyle, which decides how many
    -- regions there are (`merge` coalesces nearby conflicts that
    -- diff3/zdiff3 keep apart), so this agrees with what `git merge` wrote.
    -- Exit status is the conflict count, or >127 on error (binary files).
    deps.run(root, { "merge-file", "--object-id", "-p", "-q", "-L", "ours", "-L", "base", "-L", "theirs",
      item.stages[2], base, item.stages[3] }, function(result)
      if result.code < 0 or result.code > 127 then
        if (result.stderr or ""):lower():find("binary", 1, true) then item.binary = true end
        finish(nil)
        return
      end
      finish(M.parse_markers(split_content(result.stdout)))
    end)
  end
  deps.run(root, { "ls-files", "-u", "-z", "--", ":(literal)" .. path }, function(result)
    if result.code ~= 0 then
      finish(nil)
      return
    end
    item.stages = parse_unmerged(result.stdout, path)
    if not item.stages[2] and not item.stages[3] then
      item.missing = "both"
    elseif not item.stages[2] then
      item.missing = "ours"
    elseif not item.stages[3] then
      item.missing = "theirs"
    end
    if item.missing then
      finish(nil)
    elseif item.stages[1] then
      merge(item.stages[1])
    else
      -- add/add: no common ancestor, so merge against the empty blob. Ask
      -- Git for its id rather than hardcoding the SHA-1 one.
      deps.run(root, { "hash-object", "-t", "blob", "--stdin" }, function(hashed)
        if hashed.code ~= 0 then finish(nil) return end
        merge(vim.trim(hashed.stdout or ""))
      end, "")
    end
  end)
end

-- Loads every conflict row in place (they are the same tables the status
-- sections hold) and calls `done` once all have settled.
function M.annotate(root, items, done)
  local remaining = #items
  if remaining == 0 then
    done()
    return
  end
  for _, status_item in ipairs(items) do
    M.load(root, status_item, function(loaded)
      for key, value in pairs(loaded) do status_item[key] = value end
      remaining = remaining - 1
      if remaining == 0 then done() end
    end)
  end
end

-- Short status-row annotation: `resolved/total`, or why there is no count.
function M.describe(item)
  if item.missing == "both" then return "deleted by both" end
  if item.missing == "ours" then return "deleted by us" end
  if item.missing == "theirs" then return "deleted by them" end
  if item.binary then return "binary" end
  if item.total then return string.format("%d/%d", item.resolved, item.total) end
  return nil
end

local function find_buffer(name)
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(buffer) == name then return buffer end
  end
end

local function side_buffer(side, path, lines, missing)
  local name = "currantgit://conflict/" .. side .. "/" .. path
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
  vim.b[buffer].currantgit_conflict_pane = side
  return buffer
end

local function show_stage(root, item, stage, done)
  if not item.stages[stage] then
    done({ "" }, true)
    return
  end
  -- Explicit stage form, never the bare `:<path>` shorthand: see
  -- docs/decisions/0012 for the digit-colon path ambiguity.
  deps.run(root, { "show", ":" .. stage .. ":" .. item.path }, function(result)
    if result.code ~= 0 then
      done({ "" }, true)
      return
    end
    done(split_content(result.stdout))
  end)
end

local function label(side, item, names)
  if item.missing == side then return side .. " (deleted)" end
  local name = names[side]
  return name and (side .. " · " .. name) or side
end

-- Branch/commit names for the winbars: ours is HEAD; theirs is whichever
-- operation head exists. Failures only cost the decoration.
local function side_names(root, done)
  local names = {}
  local function short(revision, callback)
    deps.run(root, { "rev-parse", "--short", "-q", "--verify", revision }, function(result)
      callback(result.code == 0 and vim.trim(result.stdout or "") or nil)
    end)
  end
  deps.run(root, { "symbolic-ref", "--short", "-q", "HEAD" }, function(branch)
    short("HEAD", function(head)
      local ours = vim.trim(branch.code == 0 and branch.stdout or "")
      names.ours = vim.trim(((ours ~= "" and ours) or "HEAD") .. " " .. (head or ""))
      local heads = { "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "REBASE_HEAD" }
      local function try(index)
        if index > #heads then
          done(names)
          return
        end
        short(heads[index], function(theirs)
          if theirs then
            names.theirs_sha = theirs
            done(names)
          else
            try(index + 1)
          end
        end)
      end
      try(1)
    end)
  end)
end

local function fill_with_hatching(window)
  local entries = {}
  for entry in (vim.wo[window].fillchars or ""):gmatch("[^,]+") do
    if not vim.startswith(entry, "diff:") then entries[#entries + 1] = entry end
  end
  entries[#entries + 1] = "diff:╱"
  vim.wo[window].fillchars = table.concat(entries, ",")
end

-- Colors each live region by side and labels its marker lines at end of
-- line. The marker text itself stays visible: it is real buffer content the
-- user is about to edit. Also refreshes the "n of m resolved" winbar.
local function decorate(buffer)
  if not vim.api.nvim_buf_is_valid(buffer) then return end
  vim.api.nvim_buf_clear_namespace(buffer, namespace, 0, -1)
  local item = vim.b[buffer].currantgit_conflict
  local live = M.parse_markers(vim.api.nvim_buf_get_lines(buffer, 0, -1, false))
  local function line(row, group, text, label_group)
    vim.api.nvim_buf_set_extmark(buffer, namespace, row - 1, 0, {
      line_hl_group = group,
      virt_text = text and { { text, label_group } } or nil,
      virt_text_pos = text and "eol" or nil,
      priority = 4200,
    })
  end
  local function span(first, last, group)
    for row = first, last do line(row, group) end
  end
  for _, region in ipairs(live) do
    local ours_end = (region.base_marker or region.separator) - 1
    line(region.start, "CurrantGitConflictMarker", "  ours", "CurrantGitConflictOursLabel")
    span(region.start + 1, ours_end, "CurrantGitConflictOurs")
    if region.base_marker then
      line(region.base_marker, "CurrantGitConflictMarker", "  base", "CurrantGitConflictBaseLabel")
      -- A text highlight, not a line one: it has to beat the line colors.
      for row = region.base_marker + 1, region.separator - 1 do
        local text = vim.api.nvim_buf_get_lines(buffer, row - 1, row, false)[1] or ""
        vim.api.nvim_buf_set_extmark(buffer, namespace, row - 1, 0, {
          end_col = #text, hl_group = "CurrantGitConflictBase", priority = 4300,
        })
      end
    end
    line(region.separator, "CurrantGitConflictMarker")
    span(region.separator + 1, region.finish - 1, "CurrantGitConflictTheirs")
    line(region.finish, "CurrantGitConflictMarker", "  theirs", "CurrantGitConflictTheirsLabel")
  end
  local window = vim.fn.bufwinid(buffer)
  if window ~= -1 and item then
    local unresolved = 0
    for _, region in ipairs(M.match(item.path, item.regions or {}, live)) do
      if region.state == "unresolved" then unresolved = unresolved + 1 end
    end
    local total = math.max(#(item.regions or {}), unresolved)
    local path = item.path:gsub("%%", "%%%%")
    vim.wo[window].winbar = total > 0
      and string.format("%s — %d of %d resolved", path, total - unresolved, total)
      or path
  end
end

local function attach_pane(buffer, run_action)
  local function map(lhs, id)
    vim.keymap.set("n", lhs, function() run_action(buffer, id) end, {
      buffer = buffer, silent = true, desc = "CurrantGit conflict",
    })
  end
  if vim.b[buffer].currantgit_conflict_pane == "result" then
    map("]x", "conflict.next")
    map("[x", "conflict.prev")
  end
  map("gb", "conflict.base_toggle")
end

-- Opens ours | result | theirs in a new tab with native diff mode. The
-- result pane is the real worktree file, so saving and undo are Vim's own.
function M.open(status_item, root)
  M.load(root, status_item, function(item)
    if not item.exists then
      vim.notify("CurrantGit: " .. item.path .. " is not in the worktree", vim.log.levels.WARN)
      return
    end
    side_names(root, function(names)
    show_stage(root, item, 2, function(ours, ours_missing)
      show_stage(root, item, 3, function(theirs, theirs_missing)
        vim.cmd("tabnew " .. vim.fn.fnameescape(root .. "/" .. item.path))
        local result = vim.api.nvim_get_current_buf()
        local result_window = vim.api.nvim_get_current_win()
        vim.b[result].currantgit_conflict = item
        vim.b[result].currantgit_conflict_pane = "result"
        vim.b[result].currantgit_root = root
        local ours_buffer = side_buffer("ours", item.path, ours, ours_missing)
        local theirs_buffer = side_buffer("theirs", item.path, theirs, theirs_missing)
        vim.cmd("leftabove vsplit")
        vim.api.nvim_set_current_buf(ours_buffer)
        vim.wo.winbar = label("ours", item, names)
        vim.wo.winhighlight = SIDE_HIGHLIGHT.ours
        vim.api.nvim_set_current_win(result_window)
        vim.cmd("rightbelow vsplit")
        vim.api.nvim_set_current_buf(theirs_buffer)
        local first = M.parse_markers(vim.api.nvim_buf_get_lines(result, 0, -1, false))[1]
        names.theirs = vim.trim(((first and first.theirs_label) or "") .. " " .. (names.theirs_sha or ""))
        if names.theirs == "" then names.theirs = nil end
        vim.wo.winbar = label("theirs", item, names)
        vim.wo.winhighlight = SIDE_HIGHLIGHT.theirs
        vim.api.nvim_set_current_win(result_window)
        vim.wo.winhighlight = SIDE_HIGHLIGHT.result
        for _, window in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          vim.api.nvim_win_call(window, function() vim.cmd("diffthis") end)
          fill_with_hatching(window)
        end
        decorate(result)
        local group = vim.api.nvim_create_augroup("CurrantGitConflict" .. result, { clear = true })
        vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
          group = group, buffer = result, callback = function() decorate(result) end,
        })
        -- The result is the user's real file: drop the decorations once it
        -- leaves the resolver, so it doesn't stay painted elsewhere.
        vim.api.nvim_create_autocmd("BufWinLeave", {
          group = group, buffer = result,
          callback = function()
            vim.api.nvim_buf_clear_namespace(result, namespace, 0, -1)
            vim.api.nvim_del_augroup_by_id(group)
          end,
        })
        vim.t.currantgit_conflict = {
          ours = ours_buffer, result = result, theirs = theirs_buffer, root = root, path = item.path,
        }
        for _, buffer in ipairs({ ours_buffer, result, theirs_buffer }) do
          vim.b[buffer].currantgit_root = root
          attach_pane(buffer, deps.dispatch)
        end
      end)
    end)
    end)
  end)
end

-- Toggles a read-only stage-1 view under the result pane. It stays out of
-- diff mode: a fourth diff buffer would only blur the ours/theirs picture.
function M.toggle_base()
  local panes = vim.t.currantgit_conflict
  if not panes then return false end
  if panes.base and vim.api.nvim_buf_is_valid(panes.base) and vim.fn.bufwinid(panes.base) ~= -1 then
    vim.api.nvim_win_close(vim.fn.bufwinid(panes.base), true)
    panes.base = nil
    vim.t.currantgit_conflict = panes
    return true
  end
  local item = vim.b[panes.result].currantgit_conflict
  show_stage(panes.root, item, 1, function(lines, missing)
    local origin = vim.api.nvim_get_current_win()
    local result_window = vim.fn.bufwinid(panes.result)
    if result_window == -1 then return end
    local buffer = side_buffer("base", item.path, lines, missing)
    vim.api.nvim_win_call(result_window, function()
      vim.cmd("rightbelow split")
      vim.api.nvim_set_current_buf(buffer)
      vim.wo.diff = false
      vim.wo.winbar = missing and "base (none)" or "base"
    end)
    vim.api.nvim_set_current_win(origin)
    attach_pane(buffer, deps.dispatch)
    local current = vim.t.currantgit_conflict
    current.base = buffer
    vim.t.currantgit_conflict = current
  end)
  return true
end

-- The region item under the cursor in a result buffer, by stable id.
function M.current_region(buffer)
  local item = vim.b[buffer].currantgit_conflict
  if not item or not item.regions then return nil end
  local window = vim.fn.bufwinid(buffer)
  if window == -1 then return nil end
  local line = vim.api.nvim_win_get_cursor(window)[1]
  local live = M.parse_markers(vim.api.nvim_buf_get_lines(buffer, 0, -1, false))
  for _, region in ipairs(M.match(item.path, item.regions, live)) do
    local range = region.result_range
    if range and line >= range[1] and line <= range[2] then return region end
  end
end

local function jump_lines(buffer)
  if vim.b[buffer].currantgit_conflict_pane == "result" then
    local starts = {}
    for _, region in ipairs(M.parse_markers(vim.api.nvim_buf_get_lines(buffer, 0, -1, false))) do
      starts[#starts + 1] = region.start
    end
    return starts
  end
  local starts = {}
  local line_items = vim.b[buffer].currantgit_line_items or {}
  for line = 1, vim.api.nvim_buf_line_count(buffer) do
    local item = line_items[line]
    if type(item) == "table" and item.kind == "conflict-file" then starts[#starts + 1] = line end
  end
  return starts
end

-- Moves to the next/previous conflict item: conflict-file rows in status,
-- region starts in a result pane. Stops at the ends, like `]c`.
function M.jump(buffer, direction)
  local window = vim.fn.bufwinid(buffer)
  if window == -1 then return false end
  local line = vim.api.nvim_win_get_cursor(window)[1]
  local starts = jump_lines(buffer)
  local target
  if direction > 0 then
    for _, start in ipairs(starts) do
      if start > line then target = start break end
    end
  else
    for index = #starts, 1, -1 do
      if starts[index] < line then target = starts[index] break end
    end
  end
  if target then vim.api.nvim_win_set_cursor(window, { target, 0 }) end
  return true
end

local function has_conflicts(context)
  return context and context.buffer and #jump_lines(context.buffer) > 0
end

-- `options.run(root, args, callback, input)` is the one Git executor;
-- `options.dispatch(buffer, id)` routes pane mappings back through actions.
function M.setup(options)
  deps = options
  define_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("CurrantGitConflictColors", { clear = true }),
    callback = define_highlights,
  })
end

function M.register(actions, open)
  actions.register({
    id = "conflict.open",
    label = "resolve",
    key = "<CR>",
    desc = "open the three-pane conflict resolver",
    applies_to = { "conflict-file" },
    run = function(context, item)
      open(item, context.root)
      return true
    end,
  })
  actions.register({
    id = "conflict.next",
    label = "next conflict",
    key = "]x",
    applies_to = { "*" },
    is_available = has_conflicts,
    run = function(context) return M.jump(context.buffer, 1) end,
  })
  actions.register({
    id = "conflict.prev",
    label = "previous conflict",
    key = "[x",
    applies_to = { "*" },
    is_available = has_conflicts,
    run = function(context) return M.jump(context.buffer, -1) end,
  })
  actions.register({
    id = "conflict.base_toggle",
    label = "toggle base",
    key = "gb",
    desc = "show or hide the merge base (stage 1)",
    applies_to = { "*" },
    is_available = function(context)
      return context and context.buffer and vim.b[context.buffer].currantgit_conflict_pane ~= nil
    end,
    run = function() return M.toggle_base() end,
  })
end

return M
