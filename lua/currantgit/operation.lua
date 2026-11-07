-- The Git operation in progress (rebase, merge, cherry-pick, revert), read
-- from the git dir the way Git's own contrib/completion/git-prompt.sh does,
-- in the same order. `am` and bisect are not recognized (not supported).
-- Pure file reads, no Git process; `git_dir` must come from
-- `git rev-parse --absolute-git-dir` so linked worktrees read their own state.

local M = {}

local function read(path)
  local file = io.open(path, "rb")
  if not file then return nil end
  local text = file:read("*a")
  file:close()
  return vim.trim(text)
end

local function exists(path)
  return vim.uv.fs_stat(path) ~= nil
end

-- Returns nil, or { kind = "rebase"|"merge"|"cherry-pick"|"revert", ... }.
function M.read(git_dir)
  if not git_dir then return nil end
  local function at(name) return vim.fs.joinpath(git_dir, name) end
  if exists(at("rebase-merge")) then
    return {
      kind = "rebase",
      head_name = read(at("rebase-merge/head-name")),
      onto = read(at("rebase-merge/onto")),
      step = tonumber(read(at("rebase-merge/msgnum")) or ""),
      total = tonumber(read(at("rebase-merge/end")) or ""),
    }
  end
  if exists(at("rebase-apply")) then
    if not exists(at("rebase-apply/rebasing")) then return nil end
    return {
      kind = "rebase",
      head_name = read(at("rebase-apply/head-name")),
      onto = read(at("rebase-apply/onto")),
      step = tonumber(read(at("rebase-apply/next")) or ""),
      total = tonumber(read(at("rebase-apply/last")) or ""),
    }
  end
  if exists(at("MERGE_HEAD")) then
    return { kind = "merge", commit = (read(at("MERGE_HEAD")) or ""):match("^%x+") }
  end
  if exists(at("CHERRY_PICK_HEAD")) then
    return { kind = "cherry-pick", commit = (read(at("CHERRY_PICK_HEAD")) or ""):match("^%x+") }
  end
  if exists(at("REVERT_HEAD")) then
    return { kind = "revert", commit = (read(at("REVERT_HEAD")) or ""):match("^%x+") }
  end
  local todo = read(at("sequencer/todo"))
  if todo then
    local command, commit = todo:match("^(%a+)%s+(%x+)")
    if command == "p" or command == "pick" then return { kind = "cherry-pick", commit = commit } end
    if command == "revert" then return { kind = "revert", commit = commit } end
  end
  return nil
end

-- One status header line, e.g. "Rebasing side onto 1a2b3c4 (2/3)".
function M.describe(op)
  local function short(sha) return sha and sha:sub(1, 7) or "?" end
  if op.kind == "rebase" then
    local branch = op.head_name and op.head_name:gsub("^refs/heads/", "") or "HEAD"
    local progress = (op.step and op.total) and (" (%d/%d)"):format(op.step, op.total) or ""
    return ("Rebasing %s onto %s%s"):format(branch, short(op.onto), progress)
  end
  local verb = ({ merge = "Merging", ["cherry-pick"] = "Cherry-picking", revert = "Reverting" })[op.kind]
  return verb .. " " .. short(op.commit)
end

-- Same operation? Used to refuse a key press against a stale status.
function M.same(a, b)
  if not a or not b then return a == b end
  return a.kind == b.kind and a.commit == b.commit and a.head_name == b.head_name and a.onto == b.onto
    and a.step == b.step
end

return M
