local M = {}
local config = require("currantgit.config")
local actions = require("currantgit.actions")
local blame = require("currantgit.blame")
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
}

local open_status
local open_diff
local open_deleted
local open_blame
local open_activity
local open_commit
local open_log
local open_diff_args
local set_buffer
local attach_diff
local attach_log

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
    output = output:sub(1, 2000),
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

local function current_item(buffer)
  local line = vim.api.nvim_win_get_cursor(0)[1]
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
  local line = #labels > 0 and "Actions: " .. table.concat(labels, "   ") or "Actions: r refresh   g? help"
  set_modifiable(buffer, function()
    vim.api.nvim_buf_set_lines(buffer, -2, -1, false, { line })
  end)
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
  local function refresh()
    if vim.b[buffer].currantgit_title == "log" then
      open_log(vim.b[buffer].currantgit_log_args, root)
    else
      open_status(root)
    end
  end
  return {
    buffer = buffer,
    root = root,
    refresh = refresh,
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
      apply_hunk(item, { "apply", "--cached", "--unidiff-zero" }, function()
        open_diff_args(vim.b[buffer].currantgit_diff_args, root)
      end)
    end,
    unstage_hunk = function(item)
      apply_hunk(item, { "apply", "--cached", "--unidiff-zero", "--reverse" }, function()
        open_diff_args(vim.b[buffer].currantgit_diff_args, root)
      end)
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
end

open_deleted = function(item, root)
  local error_message
  if not root then root, error_message = repository_root() end
  if not root then
    vim.notify("CurrantGit: " .. error_message, vim.log.levels.ERROR)
    return
  end
  local revision = item.status:sub(1, 1) == "D" and "HEAD" or ":"
  local target = revision == ":" and (revision .. item.path) or (revision .. ":" .. item.path)
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

local function attach_status(buffer)
  navigation.visit(0)
  local map = function(mode, lhs, rhs)
    vim.keymap.set(mode, lhs, rhs, { buffer = buffer, silent = true, desc = "CurrantGit" })
  end
  map("n", "<CR>", function() dispatch_current(buffer, "item.open") end)
  map("n", "d", function() dispatch_current(buffer, "item.diff") end)
  map("n", "b", function() dispatch_current(buffer, "item.blame") end)
  map("n", "s", function() dispatch_current(buffer, "item.stage") end)
  map("n", "u", function() dispatch_current(buffer, "item.unstage") end)
  map("n", "-", function() dispatch_current(buffer, "item.toggle") end)
  map("n", "X", function() dispatch_current(buffer, "item.discard") end)
  map("n", "r", function() dispatch_current(buffer, "surface.refresh") end)
  map("n", "g?", function() dispatch_current(buffer, "surface.help") end)
  local group = vim.api.nvim_create_augroup("CurrantGitStatus" .. buffer, { clear = true })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    buffer = buffer,
    callback = function()
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

set_buffer = function(lines, items, title, line_items, root, fold_levels)
  local name = "currantgit://" .. title
  local buffer = vim.fn.bufnr(name)
  if buffer < 0 or not vim.api.nvim_buf_is_valid(buffer) then
    buffer = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buffer, name)
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
  vim.wo.foldmethod = (title == "status" or title == "diff") and "expr" or "manual"
  if title == "status" or title == "diff" then
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
  end
  return buffer
end

open_log = function(args, root)
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
      local buffer = set_buffer(lines, items, "log", line_items, root)
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

open_diff_args = function(args, root)
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
      local lines, fold_levels, line_items, hunks = diff.parse(result.stdout or "", { mode = mode, path = path })
      navigation.update(0)
      set_buffer(lines, hunks, "diff", line_items, root, fold_levels)
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

local function parse_status(stdout)
  local items = {}
  local ui = config.get().ui
  local repository_name = vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
  local header = ui.title and (ui.title .. "  " .. repository_name) or repository_name
  local lines = { header }
  local branch = ""
  local line_items = {}
  local fold_levels = {}
  local section_nodes = {}
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
        id = "change:" .. path,
        kind = "change",
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

  if ui.show_branch then
    lines[#lines + 1] = "Branch: " .. (branch ~= "" and branch or "detached")
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = ui.show_counts and string.format("Changes (%d)", #items) or "Changes"
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
      line_items[#lines] = node
      fold_levels[#lines] = ">1"
      for _, item in ipairs(section.items) do
        local label = item.old_path and (item.old_path .. " -> " .. item.path) or item.path
        lines[#lines + 1] = string.format("  %s  %s", ui.icons[item.change_kind] or item.status, label)
        line_items[#lines] = item
        fold_levels[#lines] = 2
      end
    end
  end
  if #items == 0 and ui.show_clean then
    lines[#lines + 1] = "  clean"
    fold_levels[#lines] = 0
  end
  lines[#lines + 1] = ""
  fold_levels[#lines] = "<1"
  lines[#lines + 1] = ""
  fold_levels[#lines] = 0
  return lines, items, line_items, fold_levels, section_nodes
end

open_status = function(root)
  local error_message
  if not root then
    root, error_message = repository_root()
  end
  if not root then
    vim.notify("CurrantGit: " .. error_message, vim.log.levels.ERROR)
    return
  end

  execute({ git_command(), "status", "--porcelain=v1", "-z", "--branch" }, {
    cwd = root,
    text = true,
  }, function(result)
    schedule(function()
      if result.code ~= 0 then
        vim.notify("CurrantGit: " .. (result.stderr or "git status failed"), vim.log.levels.ERROR)
        return
      end
      local lines, items, line_items, fold_levels, section_nodes = parse_status(result.stdout or "")
      set_buffer(lines, items, "status", line_items, root, fold_levels)
      vim.b.currantgit_sections = section_nodes
    end)
  end)
end

local function run_git(args)
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
      set_buffer(vim.split(vim.trim(output), "\n", { plain = true }), {}, "command")
    end)
  end)
end

open_activity = function()
  local lines = { "CurrantGit activity", "" }
  if #state.command_log == 0 then
    lines[#lines + 1] = "  no Git commands recorded"
  else
    for index, entry in ipairs(state.command_log) do
      lines[#lines + 1] = string.format(
        "%3d  %4dms  [%d]  %s",
        index,
        entry.duration_ms,
        entry.code,
        table.concat(entry.argv, " ")
      )
      if entry.output ~= "" then
        for output_line in (entry.output .. "\n"):gmatch("(.-)\n") do
          lines[#lines + 1] = "      " .. output_line
        end
      end
    end
  end
  navigation.update(0)
  set_buffer(lines, {}, "activity", {}, vim.fn.getcwd())
  vim.b.currantgit_command_log = state.command_log
  navigation.visit(0)
end

function M.git(args)
  if #args == 0 or args[1] == "status" then
    open_status()
  elseif args[1] == "diff" then
    open_diff_args(args)
  elseif args[1] == "blame" then
    local path = args[2] or vim.fn.expand("%:~:.")
    if path == "" or vim.bo.filetype == "currantgit" then
      vim.notify("CurrantGit: :Git blame needs a file path from a source buffer", vim.log.levels.WARN)
      return
    end
    open_blame(path)
  elseif args[1] == "log" and git_log.arguments(args) then
    open_log(args)
  else
    run_git(args)
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
    applies_to = { "change" },
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
    applies_to = { "change" },
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
    id = "surface.help",
    label = "help",
    key = "g?",
    run = function(context, item)
      local labels = {}
      for _, action in ipairs(actions.discovery(item, context)) do
        labels[#labels + 1] = action.key .. " " .. action.label
      end
      vim.notify("CurrantGit: " .. table.concat(labels, "   "), vim.log.levels.INFO)
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
    applies_to = { "change" },
    run = function(context, item)
      context.diff(item)
      return true
    end,
  })
  actions.register({
    id = "item.blame",
    label = "blame",
    key = "b",
    applies_to = { "change" },
    is_available = function(_, item)
      return item.change_kind ~= "deleted"
    end,
    run = function(context, item)
      context.blame(item)
      return true
    end,
  })

  vim.api.nvim_create_user_command("Git", function(command)
    local args, error_message = split_args(command.args)
    if not args then
      vim.notify("CurrantGit: " .. error_message, vim.log.levels.ERROR)
      return
    end
    M.git(args)
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
  return actions.discovery(current_item(buffer), { buffer = buffer })
end

function M.which_key(buffer)
  buffer = buffer or vim.api.nvim_get_current_buf()
  return actions.which_key(current_item(buffer), action_context(buffer))
end

function M.foldexpr(line)
  return vim.b.currantgit_fold_levels[line] or 0
end

return M
