-- Two-pane diff viewer: old | new for one status change row, in native
-- diff mode. The comparison follows the row's section, like `=`:
--   staged   = HEAD:<path> vs :0:<path>
--   unstaged = :0:<path>   vs the real worktree file (editable)
-- Missing sides (added, deleted) are empty labelled scratch buffers.
-- Nothing in this module writes the index or the worktree.
local panes = require("currantgit.panes")

local M = {}

local deps = {}

local FILLER = "CurrantGitDiffFiller"
local SIDE_HIGHLIGHT = {
  old = panes.winhighlight("CurrantGitDiffOld", "CurrantGitDiffOldText", FILLER),
  new = panes.winhighlight("CurrantGitDiffNew", "CurrantGitDiffNewText", FILLER),
}

local function define_highlights()
  panes.define("CurrantGitDiffColors", function(palette)
    local groups = { [FILLER] = { fg = panes.blend(palette.fg, palette.bg, 0.16) } }
    panes.side_groups(groups, "CurrantGitDiffOld", palette.warm, palette)
    return panes.side_groups(groups, "CurrantGitDiffNew", palette.cool, palette)
  end)
end

-- Reads `object` (a `<rev>:<path>` spec); `done(lines, missing)`.
local function show(root, object, done)
  deps.run(root, { "show", object }, function(result)
    if result.code ~= 0 then
      done({ "" }, true)
      return
    end
    done(panes.split_content(result.stdout))
  end)
end

-- What each side of the row's comparison is. `X`/`Y` are the porcelain
-- index/worktree columns (`git help status`); renames and copies read the
-- old side from their source path.
local function plan(item, section)
  local status = item.status or "  "
  local code = section == "staged" and status:sub(1, 1) or status:sub(2, 2)
  local old_path = (code == "R" or code == "C") and item.old_path or item.path
  if section == "staged" then
    return {
      old = { name = "HEAD", object = code ~= "A" and ("HEAD:" .. old_path) or nil },
      -- Explicit stage form, never `:<path>`: see docs/decisions/0012.
      new = { name = "index", object = code ~= "D" and (":0:" .. item.path) or nil },
    }
  end
  return {
    old = { name = "index", object = ":0:" .. old_path },
    new = { name = "worktree", worktree = code ~= "D" },
  }
end

local function label(side, head)
  local name = side.name == "HEAD" and head and ("HEAD " .. head) or side.name
  if side.missing then
    return name .. (side.name == "HEAD" and " (none)" or " (deleted)")
  end
  return name
end

local function load_side(root, side, done)
  if side.worktree then
    done()
  elseif not side.object then
    side.missing = true
    done({ "" })
  else
    show(root, side.object, function(lines, missing)
      side.missing = missing
      done(lines)
    end)
  end
end

-- Opens old | new in a new tab. `section` is the row's status section.
function M.open(item, root, section)
  local sides = plan(item, section)
  deps.run(root, { "rev-parse", "--short", "-q", "--verify", "HEAD" }, function(head_result)
    local head = head_result.code == 0 and vim.trim(head_result.stdout or "") or nil
    load_side(root, sides.old, function(old_lines)
      load_side(root, sides.new, function(new_lines)
        local new_buffer
        if sides.new.worktree then
          vim.cmd("tabnew " .. vim.fn.fnameescape(root .. "/" .. item.path))
          new_buffer = vim.api.nvim_get_current_buf()
        else
          vim.cmd("tabnew")
          local placeholder = vim.api.nvim_get_current_buf()
          new_buffer = panes.side_buffer("diff", sides.new.name, item.path, new_lines, sides.new.missing)
          vim.api.nvim_set_current_buf(new_buffer)
          if vim.api.nvim_buf_is_valid(placeholder) and placeholder ~= new_buffer then
            vim.api.nvim_buf_delete(placeholder, { force = true })
          end
        end
        local new_window = vim.api.nvim_get_current_win()
        local old_buffer = panes.side_buffer("diff", sides.old.name, item.path, old_lines, sides.old.missing)
        vim.wo[new_window].winbar = label(sides.new, head)
        vim.wo[new_window].winhighlight = SIDE_HIGHLIGHT.new
        vim.cmd("leftabove vsplit")
        vim.api.nvim_set_current_buf(old_buffer)
        vim.wo.winbar = label(sides.old, head)
        vim.wo.winhighlight = SIDE_HIGHLIGHT.old
        vim.api.nvim_set_current_win(new_window)
        panes.diff_tab()
        for _, buffer in ipairs({ old_buffer, new_buffer }) do
          vim.b[buffer].currantgit_root = root
        end
        vim.t.currantgit_diff_split = {
          old = old_buffer, new = new_buffer, root = root, path = item.path, section = section,
        }
        panes.map_quit({ old_buffer, new_buffer }, "currantgit_diff_split")
      end)
    end)
  end)
end

-- `options.run(root, args, callback)` is the one Git executor.
function M.setup(options)
  deps = options
  define_highlights()
end

-- `section(buffer)` names the status section of the row under the cursor.
function M.register(actions, section)
  local function comparable(context)
    local kind = context and context.buffer and section(context.buffer)
    return kind == "staged" or kind == "unstaged"
  end
  actions.register({
    id = "item.diff_split",
    label = "diff split",
    key = "D",
    desc = "open old | new side by side in a new tab",
    applies_to = { "change" },
    is_available = comparable,
    run = function(context, item)
      if not comparable(context) then
        return false, "diff split only available for staged or unstaged changes"
      end
      M.open(item, context.root, section(context.buffer))
      return true
    end,
  })
end

return M
