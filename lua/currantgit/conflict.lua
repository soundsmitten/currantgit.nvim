-- Conflict model and resolver view (docs/issues/0010, slices 1-2).
--
-- Two sources, never confused:
--   * sides (ours/base/theirs, and how many regions the file started with)
--     come from the index stages -- `git ls-files -u` for which stages
--     exist, `git merge-file --object-id` to re-merge them, `git show
--     :<n>:<path>` for the panes -- so they survive the user editing the
--     worktree file;
--   * region locations come from the conflict markers still present in the
--     worktree (or the live result buffer).
-- Region choices (slice 2) edit only the result buffer, as one undo step
-- each; nothing in this module writes the index or saves the file.
local M = {}

local panes = require("currantgit.panes")

local deps = {}
local namespace = vim.api.nvim_create_namespace("currantgit_conflict")
-- Tracks where each chosen side was inserted; extmarks follow later edits.
local resolved_namespace = vim.api.nvim_create_namespace("currantgit_conflict_resolved")
local registry

-- Ours and theirs get their own tints (lua/currantgit/panes.lua).
local function define_highlights()
  panes.define("CurrantGitConflictColors", function(palette)
    local groups = {
      CurrantGitConflictBase = { fg = palette.comment, italic = true },
      CurrantGitConflictBaseLabel = { fg = palette.comment },
      CurrantGitConflictMarker = { fg = panes.blend(palette.fg, palette.bg, 0.4) },
      CurrantGitConflictFiller = { fg = panes.blend(palette.fg, palette.bg, 0.16) },
      CurrantGitConflictResult = {},
      CurrantGitConflictResolvedLabel = { fg = palette.comment, bold = true },
    }
    panes.side_groups(groups, "CurrantGitConflictOurs", palette.cool, palette)
    return panes.side_groups(groups, "CurrantGitConflictTheirs", palette.warm, palette)
  end)
end

local FILLER = "CurrantGitConflictFiller"
local SIDE_HIGHLIGHT = {
  -- The result pane is colored only by CurrantGit's region marks.
  result = panes.winhighlight("CurrantGitConflictResult", "CurrantGitConflictResult", FILLER),
  ours = panes.winhighlight("CurrantGitConflictOurs", "CurrantGitConflictOursText", FILLER),
  theirs = panes.winhighlight("CurrantGitConflictTheirs", "CurrantGitConflictTheirsText", FILLER),
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

local split_content = panes.split_content

local function same_sides(stage_region, live)
  return vim.deep_equal(stage_region.ours, live.ours) and vim.deep_equal(stage_region.theirs, live.theirs)
end

-- Matches live marker regions onto the regions the stages re-merge into, in
-- order. A region whose markers are gone is resolved ("edited" until slice
-- 2 can say which side won); a live region with no stage counterpart is
-- still listed so nothing the user can see is hidden.
function M.match(path, stage_regions, live_regions, choices)
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
      state = live and "unresolved" or (choices and choices[tostring(n)]) or "edited",
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

local function side_buffer(side, path, lines, missing)
  local buffer = panes.side_buffer("conflict", side, path, lines, missing)
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

local LABELS = {
  ours = "ours", theirs = "theirs", base = "base",
  both_ours_first = "ours + theirs", both_theirs_first = "theirs + ours",
}

-- Choices for regions whose markers came back (undo, or retyped by hand)
-- no longer apply; drop them along with their position marks.
local function prune_choices(buffer, item, live)
  local choices = vim.b[buffer].currantgit_conflict_choices or {}
  local marks = vim.b[buffer].currantgit_conflict_marks or {}
  for _, region in ipairs(M.match(item.path, item.regions or {}, live)) do
    local key = tostring(region.index)
    if region.state == "unresolved" and choices[key] then
      choices[key] = nil
      if marks[key] then pcall(vim.api.nvim_buf_del_extmark, buffer, resolved_namespace, marks[key]) end
      marks[key] = nil
    end
  end
  vim.b[buffer].currantgit_conflict_choices = choices
  vim.b[buffer].currantgit_conflict_marks = marks
  return choices, marks
end

-- Colors each live region by side and labels its marker lines at end of
-- line; the region under the cursor gets the stronger tints. The marker
-- text itself stays visible: it is real buffer content. Resolved regions
-- get a "✓ <choice>" label. Also refreshes the "n of m resolved" winbar.
local function decorate(buffer)
  if not vim.api.nvim_buf_is_valid(buffer) then return end
  vim.api.nvim_buf_clear_namespace(buffer, namespace, 0, -1)
  local item = vim.b[buffer].currantgit_conflict
  local live = M.parse_markers(vim.api.nvim_buf_get_lines(buffer, 0, -1, false))
  local window = vim.fn.bufwinid(buffer)
  local cursor = window ~= -1 and vim.api.nvim_win_get_cursor(window)[1] or 0
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
    local current = cursor >= region.start and cursor <= region.finish
    local suffix = current and "Text" or ""
    local ours_end = (region.base_marker or region.separator) - 1
    line(region.start, "CurrantGitConflictMarker", "  ours", "CurrantGitConflictOursLabel")
    span(region.start + 1, ours_end, "CurrantGitConflictOurs" .. suffix)
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
    span(region.separator + 1, region.finish - 1, "CurrantGitConflictTheirs" .. suffix)
    line(region.finish, "CurrantGitConflictMarker", "  theirs", "CurrantGitConflictTheirsLabel")
  end
  if not item then return end
  local choices, marks = prune_choices(buffer, item, live)
  for key, state in pairs(choices) do
    local mark = marks[key] and vim.api.nvim_buf_get_extmark_by_id(buffer, resolved_namespace, marks[key], {})
    if mark and mark[1] then
      local row = math.min(mark[1], vim.api.nvim_buf_line_count(buffer) - 1)
      vim.api.nvim_buf_set_extmark(buffer, namespace, row, 0, {
        virt_text = { { "  ✓ " .. (LABELS[state] or state), "CurrantGitConflictResolvedLabel" } },
        virt_text_pos = "eol",
        priority = 4200,
      })
    end
  end
  if window ~= -1 then
    local unresolved = 0
    for _, region in ipairs(M.match(item.path, item.regions or {}, live, choices)) do
      if region.state == "unresolved" then unresolved = unresolved + 1 end
    end
    local total = math.max(#(item.regions or {}), unresolved)
    local path = item.path:gsub("%%", "%%%%")
    vim.wo[window].winbar = total > 0
      and string.format("%s — %d of %d resolved", path, total - unresolved, total)
      or path
  end
end

-- Region items for a result buffer, with each one's current state.
function M.regions(buffer)
  local item = vim.b[buffer].currantgit_conflict
  if not item then return {} end
  local live = M.parse_markers(vim.api.nvim_buf_get_lines(buffer, 0, -1, false))
  return M.match(item.path, item.regions or {}, live, vim.b[buffer].currantgit_conflict_choices)
end

local CHOICES = {
  ours = function(region) return region.ours end,
  theirs = function(region) return region.theirs end,
  both_ours_first = function(region) return vim.list_extend(vim.deepcopy(region.ours), region.theirs) end,
  both_theirs_first = function(region) return vim.list_extend(vim.deepcopy(region.theirs), region.ours) end,
  base = function(region) return region.base end,
}

-- Replaces the region (markers included) with the chosen side(s): one
-- nvim_buf_set_lines call, so one `u` brings the markers back.
function M.take(buffer, region, state)
  local lines = CHOICES[state](region)
  if not lines then
    vim.notify("CurrantGit: this region has no base (merge-style markers); gb shows the base file",
      vim.log.levels.WARN)
    return false
  end
  local range = region.result_range
  vim.api.nvim_buf_set_lines(buffer, range[1] - 1, range[2], false, lines)
  local key = tostring(region.index)
  local marks = vim.b[buffer].currantgit_conflict_marks or {}
  if marks[key] then pcall(vim.api.nvim_buf_del_extmark, buffer, resolved_namespace, marks[key]) end
  local row = math.min(range[1] - 1, math.max(vim.api.nvim_buf_line_count(buffer) - 1, 0))
  marks[key] = vim.api.nvim_buf_set_extmark(buffer, resolved_namespace, row, 0, {})
  local choices = vim.b[buffer].currantgit_conflict_choices or {}
  choices[key] = state
  vim.b[buffer].currantgit_conflict_choices = choices
  vim.b[buffer].currantgit_conflict_marks = marks
  local window = vim.fn.bufwinid(buffer)
  if window ~= -1 then vim.api.nvim_win_set_cursor(window, { row + 1, 0 }) end
  decorate(buffer)
  return true
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
    -- Region keys only mean something inside a region. Everywhere else
    -- they are Vim's own `c{motion}`, replayed unmapped with any count.
    for lhs, id in pairs({
      co = "conflict.take_ours", ct = "conflict.take_theirs", cb = "conflict.take_both",
      cB = "conflict.take_both_theirs_first", c0 = "conflict.take_base",
    }) do
      vim.keymap.set("n", lhs, function()
        local region = M.current_region(buffer)
        if not region then
          local count = vim.v.count > 0 and tostring(vim.v.count) or ""
          vim.api.nvim_feedkeys(count .. lhs, "in", false)
          return
        end
        local ok, message = registry.dispatch(id, { buffer = buffer }, region)
        if not ok and message then vim.notify("CurrantGit: " .. message, vim.log.levels.WARN) end
      end, { buffer = buffer, silent = true, desc = "CurrantGit conflict" })
    end
  end
  map("gb", "conflict.base_toggle")
  map("gl", "conflict.layout_toggle")
end

-- Adds ours | … | theirs around the result window and turns on native
-- diff mode. The side contents were fetched once, when the view opened.
local function show_sides(view)
  local result_window = vim.fn.bufwinid(view.result)
  if result_window == -1 then return end
  local origin = vim.api.nvim_get_current_win()
  local item = vim.b[view.result].currantgit_conflict
  local ours = side_buffer("ours", item.path, view.lines.ours, view.lines.ours_missing)
  local theirs = side_buffer("theirs", item.path, view.lines.theirs, view.lines.theirs_missing)
  vim.api.nvim_win_call(result_window, function()
    vim.cmd("leftabove vsplit")
    vim.api.nvim_set_current_buf(ours)
    vim.wo.winbar = label("ours", item, view.names)
    vim.wo.winhighlight = SIDE_HIGHLIGHT.ours
  end)
  vim.api.nvim_win_call(result_window, function()
    vim.cmd("rightbelow vsplit")
    vim.api.nvim_set_current_buf(theirs)
    vim.wo.winbar = label("theirs", item, view.names)
    vim.wo.winhighlight = SIDE_HIGHLIGHT.theirs
  end)
  for _, buffer in ipairs({ ours, view.result, theirs }) do
    vim.api.nvim_win_call(vim.fn.bufwinid(buffer), function() vim.cmd("diffthis") end)
    panes.fill_with_hatching(vim.fn.bufwinid(buffer))
  end
  for _, buffer in ipairs({ ours, theirs }) do
    vim.b[buffer].currantgit_root = view.root
    attach_pane(buffer, deps.dispatch)
  end
  panes.map_quit({ ours, theirs }, "currantgit_conflict")
  vim.api.nvim_set_current_win(origin)
  view.ours, view.theirs = ours, theirs
end

local function hide_sides(view)
  for _, side in ipairs({ "ours", "theirs" }) do
    local buffer = view[side]
    local window = buffer and vim.api.nvim_buf_is_valid(buffer) and vim.fn.bufwinid(buffer) or -1
    if window ~= -1 then vim.api.nvim_win_close(window, true) end
    view[side] = nil
  end
  local result_window = vim.fn.bufwinid(view.result)
  if result_window ~= -1 then
    vim.api.nvim_win_call(result_window, function() vim.cmd("diffoff") end)
  end
end

-- Opens the resolver in a new tab: ours | result | theirs in native diff
-- mode, or the result alone (`conflict.layout = "single"`). The result is
-- the real worktree file, so saving and undo are Vim's own.
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
        vim.b[result].currantgit_conflict = item
        vim.b[result].currantgit_conflict_pane = "result"
        vim.b[result].currantgit_conflict_choices = {}
        vim.b[result].currantgit_conflict_marks = {}
        vim.b[result].currantgit_root = root
        local first = M.parse_markers(vim.api.nvim_buf_get_lines(result, 0, -1, false))[1]
        names.theirs = vim.trim(((first and first.theirs_label) or "") .. " " .. (names.theirs_sha or ""))
        if names.theirs == "" then names.theirs = nil end
        vim.wo.winhighlight = SIDE_HIGHLIGHT.result
        local view = {
          result = result, root = root, path = item.path, names = names,
          lines = { ours = ours, ours_missing = ours_missing, theirs = theirs, theirs_missing = theirs_missing },
        }
        if (deps.layout and deps.layout() or "three") == "three" then show_sides(view) end
        vim.t.currantgit_conflict = view
        decorate(result)
        local group = vim.api.nvim_create_augroup("CurrantGitConflict" .. result, { clear = true })
        vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "CursorMoved" }, {
          group = group, buffer = result, callback = function() decorate(result) end,
        })
        -- The result is the user's real file: drop the decorations once it
        -- leaves the resolver, so it doesn't stay painted elsewhere.
        vim.api.nvim_create_autocmd("BufWinLeave", {
          group = group, buffer = result,
          callback = function()
            vim.api.nvim_buf_clear_namespace(result, namespace, 0, -1)
            vim.api.nvim_buf_clear_namespace(result, resolved_namespace, 0, -1)
            vim.api.nvim_del_augroup_by_id(group)
          end,
        })
        attach_pane(result, deps.dispatch)
        panes.map_quit({ result }, "currantgit_conflict")
      end)
    end)
    end)
  end)
end

-- Switches the open resolver between one pane and three; focus stays on
-- the result.
function M.toggle_layout()
  local view = vim.t.currantgit_conflict
  if not view then return false end
  local result_window = vim.fn.bufwinid(view.result)
  if result_window == -1 then return false end
  if view.ours and vim.api.nvim_buf_is_valid(view.ours) and vim.fn.bufwinid(view.ours) ~= -1 then
    hide_sides(view)
  else
    show_sides(view)
  end
  vim.api.nvim_set_current_win(result_window)
  vim.t.currantgit_conflict = view
  decorate(view.result)
  return true
end

-- Toggles a read-only stage-1 view under the result pane. It stays out of
-- diff mode: a fourth diff buffer would only blur the ours/theirs picture.
function M.toggle_base()
  local view = vim.t.currantgit_conflict
  if not view then return false end
  if view.base and vim.api.nvim_buf_is_valid(view.base) and vim.fn.bufwinid(view.base) ~= -1 then
    vim.api.nvim_win_close(vim.fn.bufwinid(view.base), true)
    view.base = nil
    vim.t.currantgit_conflict = view
    return true
  end
  local item = vim.b[view.result].currantgit_conflict
  show_stage(view.root, item, 1, function(lines, missing)
    local origin = vim.api.nvim_get_current_win()
    local result_window = vim.fn.bufwinid(view.result)
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
  for _, region in ipairs(M.match(item.path, item.regions, live, vim.b[buffer].currantgit_conflict_choices)) do
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
  -- Redraw the current-region tint now rather than on the next CursorMoved.
  if vim.b[buffer].currantgit_conflict_pane == "result" then decorate(buffer) end
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
end

function M.register(actions, open)
  registry = actions
  local function in_result(context)
    return context and context.buffer and vim.b[context.buffer].currantgit_conflict_pane == "result"
  end
  for _, take in ipairs({
    { "conflict.take_ours", "co", "take ours", "ours" },
    { "conflict.take_theirs", "ct", "take theirs", "theirs" },
    { "conflict.take_both", "cb", "take both (ours first)", "both_ours_first" },
    { "conflict.take_both_theirs_first", "cB", "take both (theirs first)", "both_theirs_first" },
    { "conflict.take_base", "c0", "take base", "base" },
  }) do
    actions.register({
      id = take[1],
      label = take[3],
      key = take[2],
      applies_to = { "conflict" },
      is_available = function(context, item) return in_result(context) and item.state == "unresolved" end,
      run = function(context, item) return M.take(context.buffer, item, take[4]) end,
    })
  end
  actions.register({
    id = "conflict.layout_toggle",
    label = "toggle layout",
    key = "gl",
    desc = "switch the resolver between one pane and three",
    applies_to = { "*" },
    is_available = function(context)
      return context and context.buffer and vim.b[context.buffer].currantgit_conflict_pane ~= nil
    end,
    run = function() return M.toggle_layout() end,
  })
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
