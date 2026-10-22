local M = {}
local config = require("currantgit.config")
local actions = require("currantgit.actions")
local activity = require("currantgit.activity")
local blame = require("currantgit.blame")
local conflict = require("currantgit.conflict")
local diff = require("currantgit.diff")
local git_log = require("currantgit.log")
local navigation = require("currantgit.navigation")
local rpc = require("currantgit.rpc")

local state = {
  configured = false,
  opts = {},
  errors = {},
  command_log = {},
  log_request = 0,
  status_request = 0,
}

local open_status
local open_diff
local open_deleted
local open_blame
local open_activity
local open_commit
local open_log
local open_diff_args
local combined_hunk_patch
local set_buffer
local attach_diff
local attach_log
local toggle_status_help
local attach_activity

local status_namespace = vim.api.nvim_create_namespace("currantgit_status")

local function define_highlights()
  local links = {
    CurrantGitRepository = "Title",
    CurrantGitBranch = "Identifier",
    CurrantGitHeading = "Directory",
    CurrantGitCount = "Number",
    CurrantGitStatusAdded = "DiffAdd",
    CurrantGitStatusDeleted = "DiffDelete",
    CurrantGitStatusModified = "DiffChange",
    CurrantGitStatusRenamed = "Special",
    CurrantGitStatusUntracked = "Comment",
    CurrantGitPath = "Normal",
    CurrantGitAction = "SpecialKey",
    CurrantGitHelpHeading = "Title",
    CurrantGitHelpKey = "SpecialKey",
    CurrantGitHelpDescription = "Comment",
    CurrantGitActivitySuccess = "DiagnosticOk",
    CurrantGitActivityFailure = "DiagnosticError",
    CurrantGitActivityTime = "Comment",
    CurrantGitActivityDuration = "Number",
    CurrantGitActivityCommand = "Statement",
    CurrantGitActivityOutput = "Comment",
    CurrantGitActivityStderr = "DiagnosticWarn",
  }
  for group, target in pairs(links) do
    vim.api.nvim_set_hl(0, group, { default = true, link = target })
  end
end

local function apply_status_highlights(buffer, highlights, start_line)
  start_line = start_line or 0
  vim.api.nvim_buf_clear_namespace(buffer, status_namespace, start_line, -1)
  for _, highlight in ipairs(highlights or {}) do
    if highlight.line - 1 >= start_line then
      vim.api.nvim_buf_set_extmark(buffer, status_namespace, highlight.line - 1, highlight.start_col, {
        end_col = highlight.end_col,
        hl_group = highlight.group,
      })
    end
  end
end

local function schedule(callback)
  vim.schedule(function()
    local ok, error_message = xpcall(callback, debug.traceback)
    if not ok then
      state.errors[#state.errors + 1] = error_message
      vim.notify("CurrantGit: " .. error_message, vim.log.levels.ERROR)
    end
  end)
end

local function record_command(args, cwd, result, started)
  local output = vim.trim((result.stdout or "") .. (result.stderr or ""))
  state.command_log[#state.command_log + 1] = {
    argv = vim.deepcopy(args),
    cwd = cwd,
    code = result.code,
    duration_ms = math.floor((vim.loop.hrtime() - started) / 1000000),
    time = os.time(),
    output = output:sub(1, 2000),
    stdout = (result.stdout or ""):sub(1, 2000),
    stderr = (result.stderr or ""):sub(1, 2000),
  }
end

local function execute(args, opts, callback, input)
  local started = vim.loop.hrtime()
  local process_opts = vim.deepcopy(opts)
  if input then process_opts.stdin = true end
  local process = vim.system(args, process_opts, function(result)
    record_command(args, opts.cwd, result, started)
    callback(result)
  end)
  if input then
    process:write(input)
    process:write(nil)
  end
end

-- `command.args` (the Lua-callback equivalent of `<args>`, confirmed via
-- `:help nvim_create_user_command()`) is the raw, unprocessed text typed
-- after `:Git` -- Neovim does no quote-aware tokenization on it before this
-- function ever sees it (that's what the *separate* `<q-args>`/`<f-args>`
-- escape sequences are for, and neither is in play here). A naive
-- whitespace-only split therefore breaks any argument containing spaces:
-- `:Git commit -m "two words"` would become
-- `{"commit", "-m", "\"two", "words\""}` instead of
-- `{"commit", "-m", "two words"}`. This performs basic POSIX-shell-like word
-- splitting instead: single quotes are literal, double quotes allow `\"`
-- and `\\` escapes, and a bare backslash outside quotes escapes the next
-- character. An unterminated quote is treated as malformed input and
-- refused outright (Git safety doctrine: failure should be boring) rather
-- than guessed at.
local function split_args(args)
  if args == "" then
    return {}
  end
  local result = {}
  local current
  local quote
  local index = 1
  local length = #args
  while index <= length do
    local char = args:sub(index, index)
    if quote then
      if char == quote then
        quote = nil
      elseif char == "\\" and quote == '"' and index < length
        and (args:sub(index + 1, index + 1) == '"' or args:sub(index + 1, index + 1) == "\\") then
        index = index + 1
        current = (current or "") .. args:sub(index, index)
      else
        current = (current or "") .. char
      end
    elseif char == '"' or char == "'" then
      quote = char
      current = current or ""
    elseif char == "\\" and index < length then
      index = index + 1
      current = (current or "") .. args:sub(index, index)
    elseif char:match("%s") then
      if current then
        result[#result + 1] = current
        current = nil
      end
    else
      current = (current or "") .. char
    end
    index = index + 1
  end
  if quote then
    return nil, "unterminated " .. quote .. " quote in arguments"
  end
  if current then
    result[#result + 1] = current
  end
  return result
end

local function git_command()
  return config.get().git.command
end

local function repository_root()
  local started = vim.loop.hrtime()
  local result = vim.system({ git_command(), "rev-parse", "--show-toplevel" }, {
    text = true,
  }):wait()
  record_command({ git_command(), "rev-parse", "--show-toplevel" }, vim.fn.getcwd(), result, started)

  if result.code ~= 0 then
    return nil, result.stderr or "not a Git repository"
  end

  return vim.trim(result.stdout)
end

local function set_modifiable(buffer, callback)
  local was_modifiable = vim.bo[buffer].modifiable
  local was_readonly = vim.bo[buffer].readonly
  vim.bo[buffer].readonly = false
  vim.bo[buffer].modifiable = true
  callback()
  vim.bo[buffer].modifiable = was_modifiable
  vim.bo[buffer].readonly = was_readonly
end

local function is_currantgit_buffer(buffer)
  return vim.api.nvim_buf_is_valid(buffer) and type(vim.b[buffer].currantgit_line_items) == "table"
end

local function current_item(buffer)
  if not is_currantgit_buffer(buffer) then
    return nil
  end
  -- Read the cursor from a window actually showing `buffer`, not window 0:
  -- callers (M.discovery/M.which_key) accept an explicit buffer argument,
  -- and window 0's cursor belongs to whatever buffer is currently focused,
  -- which need not be `buffer` when it's shown in a background split or not
  -- shown at all.
  local window = vim.fn.bufwinid(buffer)
  if window == -1 then
    return nil
  end
  local line = vim.api.nvim_win_get_cursor(window)[1]
  local item = vim.b[buffer].currantgit_line_items[line]
  return type(item) == "table" and item or nil
end

local function update_discovery(buffer)
  if not vim.api.nvim_buf_is_valid(buffer) or vim.bo[buffer].filetype ~= "currantgit" then
    return
  end
  local item = current_item(buffer)
  local available = actions.discovery(item, { buffer = buffer })
  local labels = {}
  for _, action in ipairs(available) do
    if action.key then
      labels[#labels + 1] = action.key .. " " .. action.label
    end
  end
  local discovery = #labels > 0 and "Actions: " .. table.concat(labels, "   ") or "Actions: r refresh   g? help"
  local footer_start = vim.b[buffer].currantgit_footer_start
  if type(footer_start) ~= "number" then
    footer_start = vim.api.nvim_buf_line_count(buffer)
    vim.b[buffer].currantgit_footer_start = footer_start
  end
  local lines = { discovery }
  local highlights = {
    { line = footer_start, start_col = 0, end_col = #discovery, group = "CurrantGitAction" },
  }
  if vim.b[buffer].currantgit_help_open then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Available actions"
    highlights[#highlights + 1] = {
      line = footer_start + #lines - 1,
      start_col = 0,
      end_col = #lines[#lines],
      group = "CurrantGitHelpHeading",
    }
    for _, action in ipairs(available) do
      if action.key then
        local help_line = action.key .. "   " .. action.desc
        lines[#lines + 1] = help_line
        highlights[#highlights + 1] = {
          line = footer_start + #lines - 1,
          start_col = 0,
          end_col = #action.key,
          group = "CurrantGitHelpKey",
        }
        highlights[#highlights + 1] = {
          line = footer_start + #lines - 1,
          start_col = #action.key + 3,
          end_col = #help_line,
          group = "CurrantGitHelpDescription",
        }
      end
    end
  end
  local line_count = vim.api.nvim_buf_line_count(buffer)
  set_modifiable(buffer, function()
    vim.api.nvim_buf_set_lines(buffer, footer_start - 1, line_count, false, lines)
  end)
  -- vim.b[buffer].x returns a fresh copy on each index, so mutating the
  -- table in place would silently discard the changes; copy, mutate, then
  -- write the whole table back with a direct assignment.
  local fold_levels = vim.deepcopy(vim.b[buffer].currantgit_fold_levels or {})
  for line = footer_start, line_count + #lines do fold_levels[line] = nil end
  for offset = 0, #lines - 1 do fold_levels[footer_start + offset] = 0 end
  vim.b[buffer].currantgit_fold_levels = fold_levels
  apply_status_highlights(buffer, highlights, footer_start - 1)
end

toggle_status_help = function(buffer)
  local title = vim.api.nvim_buf_is_valid(buffer) and vim.b[buffer].currantgit_title
  if title ~= "status" and title ~= "activity" then
    return false
  end
  vim.b[buffer].currantgit_help_open = not vim.b[buffer].currantgit_help_open
  update_discovery(buffer)
  return true
end

local function literal_pathspecs(paths)
  local pathspecs = {}
  for index, path in ipairs(paths) do pathspecs[index] = ":(literal)" .. path end
  return pathspecs
end

-- Joins hunks into one patch with each file's header emitted once and its
-- hunks in ascending pre-image order -- exactly the shape `git diff` itself
-- emits, so every hunk's line numbers refer to the same pre-image. Repeating
-- the header per hunk also applied correctly in testing (Git re-anchors each
-- section against the already-patched file), but that is not the shape the
-- hunks were generated in, so it isn't relied on.
combined_hunk_patch = function(hunks)
  local by_header, header_order = {}, {}
  for _, hunk in ipairs(hunks) do
    if type(hunk.patch) ~= "string" or hunk.patch == "" or type(hunk.header_lines) ~= "table" then
      return nil, "hunk has no applyable patch"
    end
    local header = table.concat(hunk.header_lines, "\n")
    if not by_header[header] then
      by_header[header] = {}
      header_order[#header_order + 1] = header
    end
    table.insert(by_header[header], hunk)
  end
  local lines = {}
  for _, header in ipairs(header_order) do
    lines[#lines + 1] = header
    table.sort(by_header[header], function(a, b) return a.old_start < b.old_start end)
    for _, hunk in ipairs(by_header[header]) do
      local body = vim.split(hunk.patch, "\n", { plain = true })
      -- diff.parse leaves trailing empty strings (the patch's final
      -- newline, and the last hunk's buffer padding). A bare empty line
      -- mid-patch would be read as an empty context line, so drop them;
      -- real context lines always carry their leading space.
      local last = #body
      while last > #hunk.header_lines and body[last] == "" do last = last - 1 end
      for index = #hunk.header_lines + 1, last do lines[#lines + 1] = body[index] end
    end
  end
  return table.concat(lines, "\n") .. "\n"
end

local function action_context(buffer)
  local root = vim.b[buffer].currantgit_root
  local function action(args, callback, input)
    -- Deliberately reuse the repository root captured when this buffer was
    -- populated, rather than re-deriving it from the live editor cwd. If we
    -- re-resolved here, a `:cd` to a different repository between issuing
    -- and confirming/completing a destructive action (e.g. the async gap
    -- while `vim.ui.select` is awaiting a discard confirmation) would run
    -- the mutation against the WRONG repository. See docs/audit for details.
    if not root then
      vim.notify("CurrantGit: unknown repository root for this buffer", vim.log.levels.ERROR)
      return
    end
    execute(vim.list_extend({ git_command() }, args), {
      cwd = root,
      text = true,
    }, function(result)
      schedule(function()
        if result.code ~= 0 then
          vim.notify("CurrantGit: " .. (result.stderr or "git action failed"), vim.log.levels.ERROR)
          return
        end
        callback()
      end)
    end, input)
  end
  local function apply_hunk(item, args, callback)
    if type(item.patch) ~= "string" or item.patch == "" then
      vim.notify("CurrantGit: hunk has no applyable patch", vim.log.levels.ERROR)
      return
    end
    action(args, callback, item.patch)
  end
  -- Hunks live in a diff surface or in a status buffer's inline `=` diffs;
  -- re-render whichever surface the hunk came from.
  local function refresh_hunk_surface()
    if vim.b[buffer].currantgit_title == "diff" then
      open_diff_args(vim.b[buffer].currantgit_diff_args, root)
    else
      open_status(root)
    end
  end
  local function refresh()
    if vim.b[buffer].currantgit_title == "log" then
      open_log(vim.b[buffer].currantgit_log_args, root)
    elseif vim.b[buffer].currantgit_title == "activity" then
      open_activity()
    else
      open_status(root)
    end
  end
  local context
  context = {
    buffer = buffer,
    root = root,
    refresh = refresh,
    help = function(item)
      if toggle_status_help(buffer) then return end
      -- Pass the full context (not just `buffer`) so this fallback matches
      -- what actions.discovery receives everywhere else the action
      -- registry is consulted, in case an is_available predicate ever
      -- inspects context fields beyond `buffer`.
      local labels = {}
      for _, available_action in ipairs(actions.discovery(item, context)) do
        labels[#labels + 1] = available_action.key .. " " .. available_action.label
      end
      vim.notify("CurrantGit: " .. table.concat(labels, "   "), vim.log.levels.INFO)
    end,
    open = function(item)
      navigation.update(0)
      if item.change_kind == "deleted" then
        open_deleted(item, root)
      else
        vim.cmd("edit " .. vim.fn.fnameescape(root .. "/" .. item.path))
        navigation.visit(0)
      end
    end,
    diff = function(item)
      open_diff(item, root)
    end,
    blame = function(item)
      open_blame(item.path, root)
    end,
    stage = function(item)
      -- The `:(literal)` pathspec magic prefix disables Git's default
      -- wildcard/glob pathspec interpretation (see gitglossary(7),
      -- PATHSPECS). Without it, a real filename containing `*`, `?`, or `[`
      -- is treated as a glob and can silently apply this action to a
      -- completely different, unrelated file.
      action({ "add", "--", ":(literal)" .. item.path }, function() open_status(root) end)
    end,
    unstage = function(item)
      action({ "restore", "--staged", "--", ":(literal)" .. item.path }, function() open_status(root) end)
    end,
    stage_hunk = function(item)
      apply_hunk(item, { "apply", "--cached", "--unidiff-zero" }, refresh_hunk_surface)
    end,
    unstage_hunk = function(item)
      apply_hunk(item, { "apply", "--cached", "--unidiff-zero", "--reverse" }, refresh_hunk_surface)
    end,
    -- Batch variants for visual selections: one Git call per batch, one
    -- `:(literal)` pathspec per path.
    stage_paths = function(paths, callback)
      action(vim.list_extend({ "add", "--" }, literal_pathspecs(paths)), callback or function() open_status(root) end)
    end,
    unstage_paths = function(paths, callback)
      action(vim.list_extend({ "restore", "--staged", "--" }, literal_pathspecs(paths)),
        callback or function() open_status(root) end)
    end,
    discard_paths = function(paths)
      vim.ui.select({ "Discard", "Cancel" }, {
        prompt = "Discard working-tree changes to " .. #paths .. " file(s)?\n  " .. table.concat(paths, "\n  ") .. "\n",
      }, function(choice)
        if choice ~= "Discard" then
          return
        end
        action(vim.list_extend({ "restore", "--worktree", "--" }, literal_pathspecs(paths)), function() open_status(root) end)
      end)
    end,
    -- All selected hunks go to Git as ONE patch, so `git apply` either
    -- applies every one of them or none (`git help apply`: it "fails the
    -- whole patch" when any hunk does not apply).
    apply_hunks = function(hunks, reverse)
      local patch, error_message = combined_hunk_patch(hunks)
      if not patch then
        vim.notify("CurrantGit: " .. error_message, vim.log.levels.ERROR)
        return
      end
      local args = { "apply", "--cached", "--unidiff-zero" }
      if reverse then args[#args + 1] = "--reverse" end
      action(args, refresh_hunk_surface, patch)
    end,
    commit = function(item)
      open_commit(item.commit, root)
    end,
    discard = function(item)
      vim.ui.select({ "Discard", "Cancel" }, {
        prompt = "Discard working-tree changes to " .. item.path .. "?",
      }, function(choice)
        if choice ~= "Discard" then
          return
        end
        action({ "restore", "--worktree", "--", ":(literal)" .. item.path }, function() open_status(root) end)
      end)
    end,
  }
  return context
end

open_deleted = function(item, root)
  local error_message
  if not root then root, error_message = repository_root() end
  if not root then
    vim.notify("CurrantGit: " .. error_message, vim.log.levels.ERROR)
    return
  end
  -- `git help gitrevisions`: `:[<n>:]<path>` optionally reads a leading
  -- stage number (0-3) followed by a colon before the path. The shorthand
  -- with no stage number (bare `:<path>`) is ambiguous for a real filename
  -- that itself starts with a digit 0-3 followed by a colon (e.g.
  -- `2:file.txt`): Git parses `:2:file.txt` as "stage 2, path file.txt",
  -- not "stage 0, path 2:file.txt". The explicit `:0:<path>` form has no
  -- such ambiguity -- Git only strips one stage-number prefix, not a
  -- repeated one, so it still resolves correctly even when the path itself
  -- starts with a digit-colon sequence.
  local is_staged_delete = item.status:sub(1, 1) == "D"
  local target = is_staged_delete and ("HEAD:" .. item.path) or (":0:" .. item.path)
  execute({ git_command(), "show", target }, {
    cwd = root,
    text = true,
  }, function(result)
    schedule(function()
      if result.code ~= 0 then
        vim.notify("CurrantGit: " .. (result.stderr or "could not read deleted file"), vim.log.levels.ERROR)
        return
      end
      local name = "currantgit://deleted/" .. item.path
      local buffer = vim.fn.bufnr(name)
      if buffer < 0 or not vim.api.nvim_buf_is_valid(buffer) then
        buffer = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_name(buffer, name)
      end
      vim.api.nvim_set_current_buf(buffer)
      set_modifiable(buffer, function()
        vim.api.nvim_buf_set_lines(buffer, 0, -1, false, vim.split(result.stdout or "", "\n", { plain = true }))
      end)
      vim.bo[buffer].buftype = "nofile"
      vim.bo[buffer].bufhidden = "hide"
      vim.bo[buffer].modifiable = false
      vim.bo[buffer].readonly = true
      vim.bo[buffer].filetype = vim.filetype.match({ filename = item.path }) or ""
      vim.b[buffer].currantgit_title = "deleted"
      vim.b[buffer].currantgit_item = item
      navigation.visit(0)
    end)
  end)
end

open_blame = function(path, root)
  local error_message
  if not root then root, error_message = repository_root() end
  if not root then
    vim.notify("CurrantGit: " .. error_message, vim.log.levels.ERROR)
    return
  end
  local source_buffer = vim.api.nvim_get_current_buf()
  if vim.fn.fnamemodify(vim.api.nvim_buf_get_name(source_buffer), ":.") ~= path then
    vim.cmd("edit " .. vim.fn.fnameescape(root .. "/" .. path))
    source_buffer = vim.api.nvim_get_current_buf()
  end
  execute({ git_command(), "blame", "--line-porcelain", "--", path }, {
    cwd = root,
    text = true,
  }, function(result)
    schedule(function()
      if result.code ~= 0 then
        vim.notify("CurrantGit: " .. (result.stderr or "git blame failed"), vim.log.levels.ERROR)
        return
      end
      local rows = blame.parse(result.stdout or "")
      vim.cmd("botright vsplit")
      local buffer = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_current_buf(buffer)
      vim.api.nvim_buf_set_name(buffer, "currantgit://blame/" .. path)
      vim.api.nvim_buf_set_lines(buffer, 0, -1, false, blame.render(rows))
      vim.bo[buffer].buftype = "nofile"
      vim.bo[buffer].bufhidden = "hide"
      vim.bo[buffer].modifiable = false
      vim.bo[buffer].readonly = true
      vim.bo[buffer].filetype = "git"
      vim.b[buffer].currantgit_title = "blame"
      vim.b[buffer].currantgit_blame_rows = rows
      vim.b[buffer].currantgit_blame_source = source_buffer
      vim.b[buffer].currantgit_root = root
      vim.keymap.set("n", "<CR>", function()
        local row = vim.b[buffer].currantgit_blame_rows[vim.api.nvim_win_get_cursor(0)[1]]
        if row then open_commit(row.commit, vim.b[buffer].currantgit_root) end
      end, { buffer = buffer, silent = true, desc = "Open blamed commit" })
      vim.keymap.set("n", "gq", function() vim.cmd("close") end, {
        buffer = buffer,
        silent = true,
        desc = "Close blame and return",
      })
      local group = vim.api.nvim_create_augroup("CurrantGitBlame" .. buffer, { clear = true })
      vim.api.nvim_create_autocmd("CursorMoved", {
        group = group,
        buffer = buffer,
        callback = function()
          local row = vim.b[buffer].currantgit_blame_rows[vim.api.nvim_win_get_cursor(0)[1]]
          if row and vim.api.nvim_buf_is_valid(source_buffer) then
            vim.api.nvim_win_set_cursor(0, { row.line, 0 })
          end
        end,
      })
      navigation.visit(0)
    end)
  end)
end

open_commit = function(commit, root)
  local error_message
  if not root then root, error_message = repository_root() end
  if not root then
    vim.notify("CurrantGit: " .. error_message, vim.log.levels.ERROR)
    return
  end
  execute({ git_command(), "show", "--stat", "--patch", "--decorate", commit }, {
    cwd = root,
    text = true,
  }, function(result)
    schedule(function()
      if result.code ~= 0 then
        vim.notify("CurrantGit: " .. (result.stderr or "git show failed"), vim.log.levels.ERROR)
        return
      end
      navigation.update(0)
      set_buffer(vim.split(vim.trim(result.stdout or ""), "\n", { plain = true }), {}, "commit/" .. commit:sub(1, 8), {}, root)
      navigation.visit(0)
    end)
  end)
end

local function dispatch_current(buffer, id)
  local item = current_item(buffer)
  local ok, error_message = actions.dispatch(id, action_context(buffer), item)
  if not ok and error_message then
    vim.notify("CurrantGit: " .. error_message, vim.log.levels.WARN)
  end
end

-- Some physical keys resolve to a different action depending on the kind of
-- item under the cursor (e.g. `=` toggles a section's native fold on a
-- heading, but toggles a change item's inline diff on a file row). Resolve
-- through the same which_key() projection the discovery bar and WhichKey
-- integration already use, instead of hardcoding one action id per key.
local function dispatch_current_key(buffer, key)
  local item = current_item(buffer)
  local binding = actions.which_key(item, action_context(buffer))[key]
  if binding then
    binding.action()
  end
end

-- Every unique item on the visual selection's lines, in buffer order. File
-- rows dedupe by path (a mixed file's staged and unstaged rows are one
-- pathspec); hunks by mode and patch text, since inline diffs of
-- different files each number their hunks from 1.
local function selected_items(buffer)
  local first, last = vim.fn.line("v"), vim.fn.line(".")
  if first > last then first, last = last, first end
  vim.cmd("normal! " .. vim.api.nvim_replace_termcodes("<Esc>", true, false, true))
  local line_items = vim.b[buffer].currantgit_line_items or {}
  local seen, items = {}, {}
  for line = first, last do
    local item = line_items[line]
    if type(item) == "table" and (item.kind == "change" or item.kind == "hunk") then
      local key = item.kind == "change" and ("change\0" .. item.path)
        or ("hunk\0" .. tostring(item.mode) .. "\0" .. tostring(item.patch))
      if not seen[key] then
        seen[key] = true
        items[#items + 1] = item
      end
    end
  end
  return items
end

local function is_available(id, context, item)
  for _, action in ipairs(actions.available(item, context)) do
    if action.id == id then return true end
  end
  return false
end

local function report_skipped(skipped, reason)
  if #skipped > 0 then
    vim.notify("CurrantGit: skipped " .. table.concat(skipped, ", ") .. " (" .. reason .. ")", vim.log.levels.WARN)
  end
end

-- Visual `s`/`u`/`-`/`X`. `key` names the action family; each selected
-- item is checked against the same registry predicate its normal-mode
-- action uses, and anything that does not qualify is skipped and reported.
local function dispatch_selection(buffer, key)
  local items = selected_items(buffer)
  local context = action_context(buffer)
  local files, hunks = {}, {}
  for _, item in ipairs(items) do
    if item.kind == "change" then files[#files + 1] = item else hunks[#hunks + 1] = item end
  end
  if #files > 0 and #hunks > 0 then
    vim.notify("CurrantGit: selection mixes files and hunks; select one or the other", vim.log.levels.WARN)
    return
  end
  if #files == 0 and #hunks == 0 then
    return
  end
  if #hunks > 0 then
    local id = ({ s = "hunk.stage", u = "hunk.unstage" })[key]
    if not id then
      vim.notify("CurrantGit: " .. key .. " does not apply to hunks", vim.log.levels.WARN)
      return
    end
    local chosen, skipped = {}, {}
    for _, hunk in ipairs(hunks) do
      if is_available(id, context, hunk) then
        chosen[#chosen + 1] = hunk
      else
        skipped[#skipped + 1] = tostring(hunk.path) .. " " .. tostring(hunk.header)
      end
    end
    report_skipped(skipped, id .. " unavailable")
    if #chosen > 0 then context.apply_hunks(chosen, key == "u") end
    return
  end
  local function partition(id)
    local chosen, skipped = {}, {}
    for _, item in ipairs(files) do
      if is_available(id, context, item) then
        chosen[#chosen + 1] = item.path
      else
        skipped[#skipped + 1] = item.path
      end
    end
    report_skipped(skipped, id .. " unavailable")
    return chosen
  end
  if key == "s" then
    local paths = partition("item.stage")
    if #paths > 0 then context.stage_paths(paths) end
  elseif key == "u" then
    local paths = partition("item.unstage")
    if #paths > 0 then context.unstage_paths(paths) end
  elseif key == "X" then
    local paths = partition("item.discard")
    if #paths > 0 then context.discard_paths(paths) end
  elseif key == "-" then
    -- Same per-item rule as item.toggle: anything with staged content
    -- unstages, everything else stages. At most two Git calls.
    local to_stage, to_unstage = {}, {}
    for _, item in ipairs(files) do
      if item.status ~= "??" and item.status:sub(1, 1) ~= " " then
        to_unstage[#to_unstage + 1] = item.path
      else
        to_stage[#to_stage + 1] = item.path
      end
    end
    local function stage()
      if #to_stage > 0 then context.stage_paths(to_stage) else context.refresh() end
    end
    if #to_unstage > 0 then context.unstage_paths(to_unstage, stage) else stage() end
  end
end

local function attach_status(buffer)
  navigation.visit(0)
  local map = function(mode, lhs, rhs)
    vim.keymap.set(mode, lhs, rhs, { buffer = buffer, silent = true, desc = "CurrantGit" })
  end
  map("n", "<CR>", function() dispatch_current_key(buffer, "<CR>") end)
  map("n", "]x", function() dispatch_current(buffer, "conflict.next") end)
  map("n", "[x", function() dispatch_current(buffer, "conflict.prev") end)
  map("n", "d", function() dispatch_current(buffer, "item.diff") end)
  map("n", "b", function() dispatch_current(buffer, "item.blame") end)
  -- `s`/`u` resolve per item kind: a file row stages the file, a hunk in
  -- an inline `=` diff stages just that hunk.
  map("n", "s", function() dispatch_current_key(buffer, "s") end)
  map("n", "u", function() dispatch_current_key(buffer, "u") end)
  map("n", "-", function() dispatch_current(buffer, "item.toggle") end)
  map("n", "X", function() dispatch_current(buffer, "item.discard") end)
  map("n", "r", function() dispatch_current(buffer, "surface.refresh") end)
  map("n", "g?", function() dispatch_current(buffer, "surface.help") end)
  map("n", "=", function() dispatch_current_key(buffer, "=") end)
  for _, key in ipairs({ "s", "u", "-", "X" }) do
    map("x", key, function() dispatch_selection(buffer, key) end)
  end
  local group = vim.api.nvim_create_augroup("CurrantGitStatus" .. buffer, { clear = true })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    buffer = buffer,
    callback = function()
      -- Skip while the cursor is inside the footer/help region itself: it
      -- has no line item, so recomputing discovery there would collapse
      -- open inline help (whose text the user may be reading or yanking)
      -- back down to the single default line out from under the cursor.
      local footer_start = vim.b[buffer].currantgit_footer_start
      local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
      if type(footer_start) == "number" and cursor_line >= footer_start then
        return
      end
      update_discovery(buffer)
    end,
  })
  update_discovery(buffer)
end

attach_diff = function(buffer)
  vim.keymap.set("n", "s", function() dispatch_current(buffer, "hunk.stage") end, {
    buffer = buffer, silent = true, desc = "Stage diff hunk",
  })
  vim.keymap.set("n", "u", function() dispatch_current(buffer, "hunk.unstage") end, {
    buffer = buffer, silent = true, desc = "Unstage diff hunk",
  })
  vim.keymap.set("x", "s", function() dispatch_selection(buffer, "s") end, {
    buffer = buffer, silent = true, desc = "Stage selected diff hunks",
  })
  vim.keymap.set("x", "u", function() dispatch_selection(buffer, "u") end, {
    buffer = buffer, silent = true, desc = "Unstage selected diff hunks",
  })
end

attach_log = function(buffer)
  vim.keymap.set("n", "<CR>", function() dispatch_current(buffer, "commit.open") end, {
    buffer = buffer, silent = true, desc = "Open commit",
  })
  vim.keymap.set("n", "r", function() dispatch_current(buffer, "surface.refresh") end, {
    buffer = buffer, silent = true, desc = "Refresh log",
  })
  vim.keymap.set("n", "g?", function() dispatch_current(buffer, "surface.help") end, {
    buffer = buffer, silent = true, desc = "Log help",
  })
  local group = vim.api.nvim_create_augroup("CurrantGitLog" .. buffer, { clear = true })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group, buffer = buffer,
    callback = function() update_discovery(buffer) end,
  })
  update_discovery(buffer)
end

set_buffer = function(lines, items, title, line_items, root, fold_levels, highlights, mods, status_extra)
  local name = "currantgit://" .. title
  local buffer = vim.fn.bufnr(name)
  local reused_buffer = buffer >= 0 and vim.api.nvim_buf_is_valid(buffer)
  if not reused_buffer then
    buffer = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buffer, name)
  end
  mods = mods or ""
  -- Mirrors fugitive's :Git: if this surface is already open in some
  -- window, focus that window instead of opening a duplicate view --
  -- checked before applying a split modifier, same priority fugitive
  -- gives window reuse over `:vertical`/`:horizontal`/etc (`:tab` still
  -- widens the search to every tab instead of skipping reuse).
  local existing_window
  if reused_buffer then
    if mods:find("tab", 1, true) then
      existing_window = vim.fn.win_findbuf(buffer)[1]
    else
      local window = vim.fn.bufwinid(buffer)
      existing_window = window ~= -1 and window or nil
    end
  end
  if existing_window then
    vim.api.nvim_set_current_tabpage(vim.api.nvim_win_get_tabpage(existing_window))
    vim.api.nvim_set_current_win(existing_window)
  elseif mods ~= "" then
    -- Mirrors fugitive: `:vertical Git`/`:tab Git` open the surface in a
    -- split/tab the same way `:vertical edit`/`:tab edit` would. Only the
    -- top-level :Git command threads a `mods` argument down to here --
    -- internal navigation (refresh, stage, opening a diff from status, ...)
    -- always passes nothing, so it never triggers a split.
    vim.cmd(mods .. " split")
  end
  vim.api.nvim_set_current_buf(buffer)
  vim.bo[buffer].buftype = "nofile"
  vim.bo[buffer].bufhidden = "hide"
  vim.bo[buffer].modifiable = true
  vim.bo[buffer].filetype = title == "diff" and "diff" or "currantgit"
  set_modifiable(buffer, function()
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  end)
  vim.bo[buffer].modifiable = false
  vim.bo[buffer].readonly = true
  vim.b[buffer].currantgit_items = items
  vim.b[buffer].currantgit_line_items = line_items or {}
  vim.b[buffer].currantgit_fold_levels = fold_levels or {}
  vim.b[buffer].currantgit_root = root
  vim.b[buffer].currantgit_title = title
  if title == "status" or title == "log" or title == "activity" then
    vim.b[buffer].currantgit_footer_start = #lines
  end
  if title == "status" then
    -- Preserve an already-open help panel across a reused buffer's refresh
    -- (`r`, stage/unstage/discard, ...): defaulting unconditionally to
    -- false here closes help on every refresh, contradicting the
    -- documented "pressing g? again removes it" toggle contract.
    vim.b[buffer].currantgit_help_open = vim.b[buffer].currantgit_help_open or false
    vim.b[buffer].currantgit_status_highlights = highlights or {}
    apply_status_highlights(buffer, highlights)
    vim.b[buffer].currantgit_item_sections = (status_extra and status_extra.item_sections) or {}
    if status_extra and status_extra.parsed then
      vim.b[buffer].currantgit_status_parsed = status_extra.parsed
    end
    vim.b[buffer].currantgit_expanded = (status_extra and status_extra.expanded) or {}
  end
  local expr_folds = title == "status" or title == "diff" or title == "activity"
  vim.wo.foldmethod = expr_folds and "expr" or "manual"
  -- Activity rows are their own fold heading: an empty 'foldtext' shows the
  -- row itself (with highlights) instead of "+-- N lines".
  vim.wo.foldtext = title == "activity" and "" or "foldtext()"
  if expr_folds then
    vim.wo.foldexpr = "v:lua.require'currantgit'.foldexpr(v:lnum)"
    vim.wo.foldlevel = 99
    vim.wo.foldenable = true
  end
  if title == "status" then
    attach_status(buffer)
  elseif title == "diff" then
    attach_diff(buffer)
  elseif title == "log" then
    attach_log(buffer)
  elseif title == "activity" then
    attach_activity(buffer)
  end
  return buffer
end

open_log = function(args, root, mods)
  local error_message
  if not root then root, error_message = repository_root() end
  if not root then
    vim.notify("CurrantGit: " .. error_message, vim.log.levels.ERROR)
    return
  end
  local log_args = vim.deepcopy(args or { "log" })
  local origin = vim.api.nvim_get_current_buf()
  local window = vim.api.nvim_get_current_win()
  local refreshing = vim.b[origin].currantgit_title == "log"
    and vim.b[origin].currantgit_root == root
    and vim.deep_equal(vim.b[origin].currantgit_log_args, log_args)
  local selected = refreshing and current_item(origin)
  local view = refreshing and vim.fn.winsaveview()
  state.log_request = state.log_request + 1
  local request = state.log_request
  execute(vim.list_extend({ git_command() }, git_log.arguments(log_args)), {
    cwd = root,
    text = false,
  }, function(result)
    schedule(function()
      if request ~= state.log_request or not vim.api.nvim_win_is_valid(window)
        or vim.api.nvim_get_current_win() ~= window
        or vim.api.nvim_win_get_buf(window) ~= origin then return end
      if result.code ~= 0 then
        vim.notify("CurrantGit: " .. (result.stderr or "git log failed"), vim.log.levels.ERROR)
        return
      end
      local items, parse_error = git_log.parse(result.stdout or "", root)
      if not items then
        vim.notify("CurrantGit: " .. parse_error, vim.log.levels.ERROR)
        return
      end
      local lines, line_items = git_log.render(items)
      navigation.update(0)
      local buffer = set_buffer(lines, items, "log", line_items, root, nil, nil, mods)
      vim.b.currantgit_log_args = log_args
      if view then
        if selected then
          for line, item in pairs(line_items) do
            if item.id == selected.id then
              view.topline = math.max(1, view.topline + line - view.lnum)
              view.lnum = line
              break
            end
          end
        end
        view.lnum = math.min(view.lnum, #lines)
        vim.fn.winrestview(view)
        navigation.update(0)
      else
        vim.api.nvim_win_set_cursor(0, { #items > 0 and 2 or 1, 0 })
        navigation.visit(0)
      end
      update_discovery(buffer)
    end)
  end)
end

-- A hunk is only safe to stage/unstage when the diff it came from is
-- actually a comparison against the live index: plain `git diff` (working
-- tree vs index) or plain `git diff --cached`/`--staged` (index vs HEAD).
-- `git diff <rev>`, `git diff <rev1> <rev2>`, or `git diff --cached <rev>`
-- compare against an arbitrary revision instead, and `git apply --cached`
-- on one of their hunks would mutate the index based on that unrelated
-- comparison rather than the change the user actually asked to stage. Any
-- argument beyond the bare `--cached`/`--staged` flag (or a trailing `--
-- <pathspec>`) disqualifies staging entirely; refusing is the safe default.
local function classify_diff_mode(args)
  local before_pathspec = {}
  for _, arg in ipairs(args) do
    if arg == "--" then break end
    if arg ~= "diff" then before_pathspec[#before_pathspec + 1] = arg end
  end
  if #before_pathspec == 0 then
    return "working"
  end
  if #before_pathspec == 1 and (before_pathspec[1] == "--cached" or before_pathspec[1] == "--staged") then
    return "staged"
  end
  return "historical"
end

open_diff_args = function(args, root, mods)
  local error_message
  if not root then
    root, error_message = repository_root()
  end
  if not root then
    vim.notify("CurrantGit: " .. error_message, vim.log.levels.ERROR)
    return
  end
  execute(vim.list_extend({ git_command() }, args), {
    cwd = root,
    text = true,
  }, function(result)
    schedule(function()
      if result.code ~= 0 then
        vim.notify("CurrantGit: " .. (result.stderr or "git diff failed"), vim.log.levels.ERROR)
        return
      end
      local mode = classify_diff_mode(args)
      local path
      for index, arg in ipairs(args) do
        if arg == "--" then path = args[index + 1] end
      end
      -- `path` here is only a fallback for the (practically unreachable for
      -- real `git diff` output) case where a hunk has no preceding `diff
      -- --git` header at all -- see diff.lua. Strip CurrantGit's own
      -- `:(literal)` pathspec-magic prefix so that fallback, if it is ever
      -- actually used, still gets the real filename rather than the raw
      -- constructed pathspec.
      if path then
        path = path:gsub("^:%(literal%)", "")
      end
      local lines, fold_levels, line_items, hunks = diff.parse(result.stdout or "", { mode = mode, path = path })
      navigation.update(0)
      set_buffer(lines, hunks, "diff", line_items, root, fold_levels, nil, mods)
      vim.b.currantgit_diff_hunks = hunks
      vim.b.currantgit_diff_args = args
      navigation.visit(0)
    end)
  end)
end

open_diff = function(item, root)
  -- CurrantGit-constructed pathspec: guard against Git's default pathspec
  -- glob magic (gitglossary(7), PATHSPECS) so a literal filename containing
  -- `*`, `?`, or `[` cannot unexpectedly match unrelated files.
  open_diff_args({ "diff", "--", ":(literal)" .. item.path }, root)
end

-- Exactly the "unmerged" XY codes documented by `git help status` (Short
-- Format table). Do not approximate this with a character class: some real,
-- non-conflict codes (e.g. `AD`, staged-add then worktree-delete) are built
-- from the same D/A/U letters and would otherwise be misclassified.
local UNMERGED_STATUS_CODES = {
  DD = true, AU = true, UD = true, UA = true, DU = true, AA = true, UU = true,
}

-- Parses raw `git status` output into semantic data only (header, branch,
-- items grouped by section) -- no buffer lines/folds/highlights. Kept
-- separate from render_status_body() so toggling a single item's inline
-- diff (or re-showing already-expanded diffs after a refresh) can re-render
-- the body from the last real `git status` result without re-running it.
local function parse_status_fields(stdout)
  local items = {}
  local ui = config.get().ui
  local repository_name = vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
  local header = ui.title and (ui.title .. "  " .. repository_name) or repository_name
  local branch = ""
  local sections = {
    staged = { label = "Staged changes", items = {} },
    unstaged = { label = "Unstaged changes", items = {} },
    untracked = { label = "Untracked files", items = {} },
    conflicts = { label = "Conflicts", items = {} },
  }

  -- `--porcelain=v1 -z` is used instead of the human `--short` format: NUL
  -- separates every field so paths are never truncated, unquoted paths with
  -- unicode/tab/space bytes come through raw, and rename/copy entries are an
  -- unambiguous `to\0from\0` pair instead of one string containing " -> "
  -- (see `git help status`, Porcelain Format Version 1).
  local fields = vim.split(stdout or "", "\0", { plain = true })
  local index = 1
  if fields[index] and vim.startswith(fields[index], "## ") then
    branch = fields[index]:sub(4)
    index = index + 1
  end

  while index <= #fields do
    local entry = fields[index]
    index = index + 1
    if entry ~= "" then
      local status = entry:sub(1, 2)
      local path = entry:sub(4)
      local old_path
      if status:sub(1, 1) == "R" or status:sub(1, 1) == "C"
        or status:sub(2, 2) == "R" or status:sub(2, 2) == "C" then
        old_path = fields[index]
        index = index + 1
      end
      local change_kind = (status:sub(1, 1) == "R" or status:sub(2, 2) == "R") and "renamed"
        or (status:sub(1, 1) == "C" or status:sub(2, 2) == "C") and "copied"
        or status:find("D", 1, true) and "deleted"
        or status:find("A", 1, true) and "added"
        or status:find("?", 1, true) and "untracked"
        or "modified"
      local is_untracked = status == "??"
      local is_conflict = UNMERGED_STATUS_CODES[status] == true
      local item = {
        id = (is_conflict and "conflict-file:" or "change:") .. path,
        kind = is_conflict and "conflict-file" or "change",
        change_kind = is_conflict and "conflict" or change_kind,
        path = path,
        old_path = old_path,
        status = status,
        capabilities = { "open", "diff", "stage" },
      }
      items[#items + 1] = item
      if is_conflict then
        sections.conflicts.items[#sections.conflicts.items + 1] = item
      elseif is_untracked then
        sections.untracked.items[#sections.untracked.items + 1] = item
      else
        if status:sub(1, 1) ~= " " then
          sections.staged.items[#sections.staged.items + 1] = item
        end
        if status:sub(2, 2) ~= " " then
          sections.unstaged.items[#sections.unstaged.items + 1] = item
        end
      end
    end
  end

  return header, branch, sections, items
end

-- A file with both staged and unstaged changes appears as two separate rows
-- (one per section) sharing the same item identity, so inline-diff
-- expansion is keyed by (section, path), not by path alone -- matching
-- docs/issues/0004's requirement that each row use its own section's
-- comparison.
local function status_expand_key(section_kind, path)
  return section_kind .. "\0" .. path
end

local function find_item_in_section(sections, section_kind, path)
  local section = sections[section_kind]
  if not section then return nil end
  for _, item in ipairs(section.items) do
    if item.path == path then return item end
  end
  return nil
end

-- Only staged/unstaged rows have a well-defined single comparison: staged
-- is index-vs-HEAD, unstaged is worktree-vs-index. Untracked/conflict items
-- are deliberately not offered inline diff (see docs/issues/0004).
local function fetch_item_diff(root, section_kind, item, callback)
  local args = section_kind == "staged"
    and { "diff", "--cached", "--", ":(literal)" .. item.path }
    or { "diff", "--", ":(literal)" .. item.path }
  local mode = section_kind == "staged" and "staged" or "working"
  execute(vim.list_extend({ git_command() }, args), {
    cwd = root,
    text = true,
  }, function(result)
    schedule(function()
      if result.code ~= 0 then
        callback(nil, result.stderr or "git diff failed")
        return
      end
      local diff_lines, diff_fold_levels, diff_line_items = diff.parse(result.stdout or "", { mode = mode, path = item.path })
      callback({ lines = diff_lines, fold_levels = diff_fold_levels, line_items = diff_line_items })
    end)
  end)
end

-- Offsets a diff.parse() fold-level value (relative to its own line 1) by
-- `depth`, so an embedded diff's own hunk folds nest correctly inside the
-- status buffer's existing section(level 1)/item(level 2) fold structure
-- instead of colliding with it. Verified against Neovim's foldexpr engine:
-- ">n"/"<n" are absolute levels, not relative increments (:help fold-expr).
local function offset_fold_level(level, depth)
  if type(level) == "number" then
    return level + depth
  end
  if type(level) == "string" then
    local marker, value = level:sub(1, 1), tonumber(level:sub(2))
    if value then
      return marker .. (value + depth)
    end
  end
  return level
end

-- Renders semantic status data (+ any expanded inline diffs) into buffer
-- lines/folds/highlights/line-items. Never runs Git -- callers that already
-- have `sections` (a fresh `git status`, or a cached one from
-- currantgit_status_parsed) can call this directly to re-render without a
-- round-trip, which is what makes toggling a single item's inline diff (or
-- restoring expansion state after a refresh) cheap.
local function render_status_body(header, branch, sections, items, expanded)
  local ui = config.get().ui
  local lines = { header }
  local line_items = {}
  local fold_levels = {}
  local section_nodes = {}
  local highlights = {}
  local item_sections = {}
  local function highlight(line, start_col, end_col, group)
    highlights[#highlights + 1] = {
      line = line,
      start_col = start_col,
      end_col = end_col,
      group = group,
    }
  end

  if ui.show_branch then
    lines[#lines + 1] = "Branch: " .. (branch ~= "" and branch or "detached")
    highlight(#lines, 0, #lines[#lines], "CurrantGitBranch")
  end
  highlight(1, 0, #header, "CurrantGitRepository")
  -- Fugitive's status buffer omits a section entirely when it's empty
  -- (`s:AddSection`/`s:AddDiffSection` both early-return on an empty list),
  -- rather than announcing a zero count. A clean repo gets the same
  -- treatment here: no "Changes (0)" heading and no "clean" placeholder,
  -- just the repository/branch header.
  if #items > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = ui.show_counts and string.format("Changes (%d)", #items) or "Changes"
    highlight(#lines, 0, #lines[#lines], "CurrantGitHeading")
    local count_start = lines[#lines]:find("(", 1, true)
    if count_start then highlight(#lines, count_start - 1, #lines[#lines], "CurrantGitCount") end
    fold_levels[#lines] = 0
    local section_order = { "staged", "unstaged", "untracked", "conflicts" }
    for _, section_kind in ipairs(section_order) do
      local section = sections[section_kind]
      if #section.items > 0 then
        local node = {
          id = "status:section:" .. section_kind,
          kind = "section",
          section_kind = section_kind,
          label = section.label,
          count = #section.items,
          children = section.items,
          capabilities = { "collapse" },
        }
        section_nodes[#section_nodes + 1] = node
        lines[#lines + 1] = string.format("%s (%d)", section.label, #section.items)
        highlight(#lines, 0, #lines[#lines], "CurrantGitHeading")
        local section_count_start = lines[#lines]:find("(", 1, true)
        if section_count_start then highlight(#lines, section_count_start - 1, #lines[#lines], "CurrantGitCount") end
        line_items[#lines] = node
        fold_levels[#lines] = ">1"
        for _, item in ipairs(section.items) do
          local label = item.old_path and (item.old_path .. " -> " .. item.path) or item.path
          local marker = ui.icons[item.change_kind] or item.status
          local note = item.kind == "conflict-file" and conflict.describe(item)
          lines[#lines + 1] = string.format("%s %s", marker, label) .. (note and "  " .. note or "")
          local marker_group = ({
            added = "CurrantGitStatusAdded",
            deleted = "CurrantGitStatusDeleted",
            modified = "CurrantGitStatusModified",
            renamed = "CurrantGitStatusRenamed",
            copied = "CurrantGitStatusRenamed",
            untracked = "CurrantGitStatusUntracked",
            conflict = "CurrantGitStatusDeleted",
          })[item.change_kind] or "CurrantGitStatusModified"
          highlight(#lines, 0, #marker, marker_group)
          highlight(#lines, #marker + 1, #marker + 1 + #label, "CurrantGitPath")
          if note then highlight(#lines, #lines[#lines] - #note, #lines[#lines], "CurrantGitCount") end
          line_items[#lines] = item
          item_sections[#lines] = section_kind
          local expansion = expanded and expanded[status_expand_key(section_kind, item.path)]
          if expansion then
            -- ">2" (not plain 2, which every other item row still uses):
            -- an explicit fold-start makes this row + its diff an
            -- independently closeable fold nested in the section's fold,
            -- instead of merging into the flat run of sibling item rows.
            fold_levels[#lines] = ">2"
            local offset = #lines
            for diff_line, text in ipairs(expansion.lines) do
              lines[offset + diff_line] = text
              fold_levels[offset + diff_line] = offset_fold_level(expansion.fold_levels[diff_line], 2)
              local diff_item = expansion.line_items[diff_line]
              if diff_item then
                line_items[offset + diff_line] = diff_item
                item_sections[offset + diff_line] = section_kind
              end
            end
          else
            fold_levels[#lines] = 2
          end
        end
      end
    end
    lines[#lines + 1] = ""
    fold_levels[#lines] = "<1"
  end
  lines[#lines + 1] = ""
  fold_levels[#lines] = 0
  return lines, line_items, fold_levels, section_nodes, highlights, item_sections
end

-- Which section (staged/unstaged/untracked/conflicts) the row under the
-- cursor belongs to. A file with both staged and unstaged changes renders
-- as two separate rows sharing one item identity, so this -- not the item
-- itself -- is what disambiguates which comparison a `=` press means.
local function current_item_section(buffer)
  local window = vim.fn.bufwinid(buffer)
  if window == -1 then
    return nil
  end
  local line = vim.api.nvim_win_get_cursor(window)[1]
  local item_sections = vim.b[buffer].currantgit_item_sections
  return item_sections and item_sections[line]
end

-- Re-renders the status body from the last real `git status` result
-- (currantgit_status_parsed) plus the current expansion state, without
-- re-running Git. Used after toggling a single item's inline diff, where
-- the file list itself hasn't changed. Cursor/view are preserved: expanding
-- or collapsing only ever inserts/removes lines *after* the toggled row, so
-- the row the cursor was on keeps the same line number; the clamp below
-- only matters if the toggle happened to be the last row and the buffer
-- shrank out from under the cursor.
local function rerender_status(buffer)
  local parsed = vim.b[buffer].currantgit_status_parsed
  if not parsed then
    return
  end
  -- Bumping here (not just at fetch-kickoff in toggle_item_diff) means ANY
  -- render -- a different toggle, or a full refresh landing via
  -- open_status -- invalidates whatever single-item fetches were still in
  -- flight when it started, not just the one that triggered this render.
  vim.b[buffer].currantgit_status_generation = (vim.b[buffer].currantgit_status_generation or 0) + 1
  local expanded = vim.b[buffer].currantgit_expanded or {}
  local window = vim.fn.bufwinid(buffer)
  local cursor = window ~= -1 and vim.api.nvim_win_get_cursor(window)
  local lines, line_items, fold_levels, section_nodes, highlights, item_sections =
    render_status_body(parsed.header, parsed.branch, parsed.sections, parsed.items, expanded)
  set_buffer(lines, parsed.items, "status", line_items, parsed.root, fold_levels, highlights, nil, {
    item_sections = item_sections,
    expanded = expanded,
    parsed = parsed,
  })
  vim.b[buffer].currantgit_sections = section_nodes
  if window ~= -1 and cursor then
    local line_count = vim.api.nvim_buf_line_count(buffer)
    local line = math.min(cursor[1], line_count)
    local text = vim.api.nvim_buf_get_lines(buffer, line - 1, line, false)[1] or ""
    local column = math.min(cursor[2], math.max(#text - 1, 0))
    pcall(vim.api.nvim_win_set_cursor, window, { line, column })
  end
end

-- Toggles inline diff display for one (section, item) pair. Collapsing is
-- synchronous (just drops the cached diff and re-renders); expanding fetches
-- the diff first and only re-renders on success, so a failed `git diff`
-- leaves the status projection and repository untouched, per
-- docs/issues/0004's safety boundary. `generation` guards against a
-- slow-to-arrive expand response being applied after a newer render (a
-- refresh, or a different toggle) has already superseded it.
local function toggle_item_diff(buffer, section_kind, item)
  local key = status_expand_key(section_kind, item.path)
  local expanded = vim.b[buffer].currantgit_expanded or {}
  if expanded[key] then
    expanded[key] = nil
    vim.b[buffer].currantgit_expanded = expanded
    rerender_status(buffer)
    return
  end
  local parsed = vim.b[buffer].currantgit_status_parsed
  if not parsed then
    return
  end
  local generation = vim.b[buffer].currantgit_status_generation or 0
  fetch_item_diff(parsed.root, section_kind, item, function(result, fetch_error)
    if not vim.api.nvim_buf_is_valid(buffer) or vim.b[buffer].currantgit_status_generation ~= generation then
      return
    end
    if not result then
      vim.notify("CurrantGit: " .. (fetch_error or "git diff failed"), vim.log.levels.ERROR)
      return
    end
    local current_expanded = vim.b[buffer].currantgit_expanded or {}
    current_expanded[key] = result
    vim.b[buffer].currantgit_expanded = current_expanded
    rerender_status(buffer)
  end)
end

-- Re-fetches the diff for every previously-expanded item that still exists
-- in the freshly parsed `sections` (docs/issues/0004: "should survive a
-- refresh when the corresponding change still exists"), refetching rather
-- than reusing stale cached content since a refresh commonly follows the
-- very stage/unstage/discard action that changed what that diff shows.
-- Items whose change vanished are silently dropped. `done` fires once with
-- the resulting expansion table (possibly empty) after every fetch settles.
local function refresh_expanded_diffs(root, sections, previous_expanded, done)
  local pending = {}
  for key in pairs(previous_expanded or {}) do
    -- `%z` (not a literal \0) matches the embedded NUL byte: LuaJIT/Lua 5.1
    -- pattern parsing truncates a pattern string at a literal embedded \0,
    -- even though the *subject* string handles embedded NULs fine -- `%z`
    -- is the documented Lua 5.1 escape for matching one within a pattern.
    -- Verified empirically: `key:match("^(.-)\0(.*)$")` silently returns
    -- ("", nil) instead of splitting on the NUL.
    local section_kind, path = key:match("^(.-)%z(.*)$")
    local item = find_item_in_section(sections, section_kind, path)
    if item then
      pending[#pending + 1] = { key = key, section_kind = section_kind, item = item }
    end
  end
  if #pending == 0 then
    done({})
    return
  end
  local expanded = {}
  local remaining = #pending
  for _, entry in ipairs(pending) do
    fetch_item_diff(root, entry.section_kind, entry.item, function(result)
      if result then
        expanded[entry.key] = result
      end
      remaining = remaining - 1
      if remaining == 0 then
        done(expanded)
      end
    end)
  end
end

open_status = function(root, mods)
  local error_message
  if not root then
    root, error_message = repository_root()
  end
  if not root then
    vim.notify("CurrantGit: " .. error_message, vim.log.levels.ERROR)
    return
  end

  state.status_request = state.status_request + 1
  local request = state.status_request

  execute({ git_command(), "status", "--porcelain=v1", "-z", "--branch" }, {
    cwd = root,
    text = true,
  }, function(result)
    schedule(function()
      if request ~= state.status_request then return end
      if result.code ~= 0 then
        vim.notify("CurrantGit: " .. (result.stderr or "git status failed"), vim.log.levels.ERROR)
        return
      end
      local header, branch, sections, items = parse_status_fields(result.stdout or "")
      local previous_buffer = vim.fn.bufnr("currantgit://status")
      local previous_expanded = (previous_buffer >= 0 and vim.api.nvim_buf_is_valid(previous_buffer))
        and vim.b[previous_buffer].currantgit_expanded or nil
      refresh_expanded_diffs(root, sections, previous_expanded, function(expanded)
        if request ~= state.status_request then return end
        conflict.annotate(root, sections.conflicts.items, function()
          if request ~= state.status_request then return end
          local lines, line_items, fold_levels, section_nodes, highlights, item_sections =
            render_status_body(header, branch, sections, items, expanded)
          local buffer = set_buffer(lines, items, "status", line_items, root, fold_levels, highlights, mods, {
            item_sections = item_sections,
            expanded = expanded,
            parsed = { header = header, branch = branch, sections = sections, items = items, root = root },
          })
          -- Invalidate any single-item expand fetch still in flight from
          -- before this refresh landed -- see rerender_status's comment.
          vim.b[buffer].currantgit_status_generation = (vim.b[buffer].currantgit_status_generation or 0) + 1
          vim.b.currantgit_sections = section_nodes
        end)
      end)
    end)
  end)
end

local function run_git(args, mods)
  local root, error_message = repository_root()
  if not root then
    vim.notify("CurrantGit: " .. error_message, vim.log.levels.ERROR)
    return
  end

  execute(vim.list_extend({ git_command() }, args), {
    cwd = root,
    text = true,
  }, function(result)
    schedule(function()
      local output = result.stdout or ""
      if result.code ~= 0 then
        output = (result.stderr or "git command failed") .. "\n" .. output
      end
      set_buffer(vim.split(vim.trim(output), "\n", { plain = true }), {}, "command", nil, nil, nil, nil, mods)
    end)
  end)
end

local function toggle_activity_output(buffer, item)
  local window = vim.fn.bufwinid(buffer)
  if window == -1 then return end
  local line = vim.api.nvim_win_get_cursor(window)[1]
  if not item.has_output or vim.fn.foldlevel(line) == 0 then return end
  local open = vim.b[buffer].currantgit_activity_open or {}
  vim.api.nvim_win_call(window, function()
    if vim.fn.foldclosed(line) ~= -1 then
      vim.cmd(line .. "foldopen")
      open[item.id] = true
    else
      vim.cmd(line .. "foldclose")
      open[item.id] = false
    end
  end)
  vim.b[buffer].currantgit_activity_open = open
end

attach_activity = function(buffer)
  local map = function(lhs, id, desc)
    vim.keymap.set("n", lhs, function() dispatch_current(buffer, id) end, {
      buffer = buffer, silent = true, desc = desc,
    })
  end
  map("<CR>", "activity.toggle_output", "Toggle command output")
  map("=", "activity.toggle_output", "Toggle command output")
  map("r", "surface.refresh", "Refresh activity")
  map("g?", "surface.help", "Activity help")
  local group = vim.api.nvim_create_augroup("CurrantGitActivity" .. buffer, { clear = true })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group, buffer = buffer,
    callback = function() update_discovery(buffer) end,
  })
end

open_activity = function()
  local existing = vim.fn.bufnr("currantgit://activity")
  local open = existing >= 0 and vim.b[existing].currantgit_activity_open or {}
  local lines, fold_levels, line_items, highlights, folds = activity.render(state.command_log, open)
  navigation.update(0)
  local buffer = set_buffer(lines, {}, "activity", line_items, vim.fn.getcwd(), fold_levels)
  vim.b[buffer].currantgit_command_log = state.command_log
  vim.b[buffer].currantgit_activity_open = open
  apply_status_highlights(buffer, highlights)
  vim.wo.foldlevel = 0
  for _, fold in ipairs(folds) do
    if fold.open then vim.cmd(fold.line .. "foldopen") end
  end
  update_discovery(buffer)
  navigation.visit(0)
end

function M.git(args, mods)
  if #args == 0 or args[1] == "status" then
    open_status(nil, mods)
  elseif args[1] == "diff" then
    open_diff_args(args, nil, mods)
  elseif args[1] == "blame" then
    local path = args[2] or vim.fn.expand("%:~:.")
    if path == "" or vim.bo.filetype == "currantgit" then
      vim.notify("CurrantGit: :Git blame needs a file path from a source buffer", vim.log.levels.WARN)
      return
    end
    open_blame(path)
  elseif args[1] == "log" and git_log.arguments(args) then
    open_log(args, nil, mods)
  else
    run_git(args, mods)
  end
end

function M.command_log()
  return vim.deepcopy(state.command_log)
end

function M.rpc(options)
  return rpc.new(options)
end

function M.setup(opts)
  state.opts = config.setup(opts)
  define_highlights()
  if state.configured then
    return M
  end

  actions.register({
    id = "surface.refresh",
    label = "refresh",
    key = "r",
    run = function(context)
      context.refresh()
      return true
    end,
  })
  actions.register({
    id = "commit.open",
    label = "open commit",
    key = "<CR>",
    applies_to = { "commit" },
    run = function(context, item)
      context.commit(item)
      return true
    end,
  })
  actions.register({
    id = "item.stage",
    label = "stage",
    key = "s",
    applies_to = { "change", "conflict-file" },
    is_available = function(_, item)
      return item.status == "??" or item.status:sub(2, 2) ~= " "
    end,
    run = function(context, item)
      context.stage(item)
      return true
    end,
  })
  actions.register({
    id = "item.unstage",
    label = "unstage",
    key = "u",
    applies_to = { "change" },
    is_available = function(_, item)
      return item.status ~= "??" and item.status:sub(1, 1) ~= " "
    end,
    run = function(context, item)
      context.unstage(item)
      return true
    end,
  })
  actions.register({
    id = "item.toggle",
    label = "toggle staged",
    key = "-",
    applies_to = { "change", "conflict-file" },
    run = function(context, item)
      if item.status ~= "??" and item.status:sub(1, 1) ~= " " then
        context.unstage(item)
      else
        context.stage(item)
      end
      return true
    end,
  })
  actions.register({
    id = "item.diff_toggle",
    label = "toggle diff",
    key = "=",
    desc = "toggle inline diff",
    applies_to = { "change" },
    -- Only staged/unstaged rows have one well-defined comparison (index-vs-
    -- HEAD, worktree-vs-index respectively); untracked/conflict items don't
    -- pretend `=` is available, per docs/issues/0004.
    is_available = function(context, _)
      local section_kind = current_item_section(context.buffer)
      return section_kind == "staged" or section_kind == "unstaged"
    end,
    run = function(context, item)
      local section_kind = current_item_section(context.buffer)
      if section_kind ~= "staged" and section_kind ~= "unstaged" then
        return false, "diff toggle only available for staged or unstaged changes"
      end
      toggle_item_diff(context.buffer, section_kind, item)
      return true
    end,
  })
  actions.register({
    id = "section.toggle_fold",
    label = "toggle section",
    key = "=",
    desc = "expand or collapse section",
    applies_to = { "section" },
    run = function(context, _)
      local window = vim.fn.bufwinid(context.buffer)
      if window ~= -1 then
        vim.api.nvim_win_call(window, function()
          vim.cmd("normal! za")
        end)
      end
      return true
    end,
  })
  actions.register({
    id = "item.discard",
    label = "discard",
    key = "X",
    applies_to = { "change" },
    is_available = function(_, item)
      return item.status ~= "??" and item.status:sub(2, 2) ~= " "
    end,
    run = function(context, item)
      context.discard(item)
      return true
    end,
  })
  actions.register({
    id = "hunk.stage",
    label = "stage hunk",
    key = "s",
    applies_to = { "hunk" },
    is_available = function(_, item)
      return item.mode == "working"
    end,
    run = function(context, item)
      context.stage_hunk(item)
      return true
    end,
  })
  actions.register({
    id = "hunk.unstage",
    label = "unstage hunk",
    key = "u",
    applies_to = { "hunk" },
    is_available = function(_, item)
      return item.mode == "staged"
    end,
    run = function(context, item)
      context.unstage_hunk(item)
      return true
    end,
  })
  actions.register({
    id = "activity.toggle_output",
    label = "output",
    desc = "Show or hide this command's output",
    key = "=",
    applies_to = { "activity" },
    run = function(context, item)
      toggle_activity_output(context.buffer, item)
      return true
    end,
  })
  actions.register({
    id = "surface.help",
    label = "help",
    key = "g?",
    run = function(context, item)
      context.help(item)
      return true
    end,
  })
  actions.register({
    id = "item.open",
    label = "open",
    key = "<CR>",
    applies_to = { "change" },
    run = function(context, item)
      context.open(item)
      return true
    end,
  })
  actions.register({
    id = "item.diff",
    label = "diff",
    key = "d",
    applies_to = { "change", "conflict-file" },
    run = function(context, item)
      context.diff(item)
      return true
    end,
  })
  actions.register({
    id = "item.blame",
    label = "blame",
    key = "b",
    applies_to = { "change", "conflict-file" },
    is_available = function(_, item)
      return item.change_kind ~= "deleted"
    end,
    run = function(context, item)
      context.blame(item)
      return true
    end,
  })

  conflict.setup({
    run = function(root, args, callback, input)
      execute(vim.list_extend({ git_command() }, args), { cwd = root, text = true }, function(result)
        schedule(function() callback(result) end)
      end, input)
    end,
    dispatch = dispatch_current,
  })
  conflict.register(actions, conflict.open)

  vim.api.nvim_create_user_command("Git", function(command)
    local args, error_message = split_args(command.args)
    if not args then
      vim.notify("CurrantGit: " .. error_message, vim.log.levels.ERROR)
      return
    end
    M.git(args, command.mods)
  end, {
    bang = true,
    nargs = "*",
    complete = "shellcmd",
  })
  vim.api.nvim_create_user_command("GitActivity", function()
    open_activity()
  end, {})
  state.configured = true
  return M
end

function M.get_config()
  return config.get()
end

function M.errors()
  return state.errors
end

function M.discovery(buffer)
  buffer = buffer or vim.api.nvim_get_current_buf()
  if not is_currantgit_buffer(buffer) then
    return {}
  end
  return actions.discovery(current_item(buffer), { buffer = buffer })
end

function M.which_key(buffer)
  buffer = buffer or vim.api.nvim_get_current_buf()
  if not is_currantgit_buffer(buffer) then
    return {}
  end
  return actions.which_key(current_item(buffer), action_context(buffer))
end

function M.foldexpr(line)
  return vim.b.currantgit_fold_levels[line] or 0
end

return M
