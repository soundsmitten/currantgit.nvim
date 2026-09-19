local M = {}

local registry = {}
local order = {}

local function applies_to(action, item)
  if not item then
    return action.applies_to == nil or vim.tbl_contains(action.applies_to, "*")
  end
  if not action.applies_to then
    return true
  end
  return vim.tbl_contains(action.applies_to, "*")
    or vim.tbl_contains(action.applies_to, item.kind)
end

function M.register(action)
  assert(type(action) == "table", "CurrantGit action must be a table")
  assert(type(action.id) == "string" and action.id ~= "", "CurrantGit action needs an id")
  assert(type(action.label) == "string" and action.label ~= "", "CurrantGit action needs a label")
  assert(type(action.run) == "function", "CurrantGit action needs a run function")

  if not registry[action.id] then
    order[#order + 1] = action.id
  end
  registry[action.id] = action
  return action
end

function M.get(id)
  return registry[id]
end

function M.available(item, context)
  local result = {}
  for _, id in ipairs(order) do
    local action = registry[id]
    if applies_to(action, item) and (not action.is_available or action.is_available(context, item)) then
      result[#result + 1] = action
    end
  end
  return result
end

function M.discovery(item, context)
  local result = {}
  for _, action in ipairs(M.available(item, context)) do
    if action.key then
      result[#result + 1] = {
        id = action.id,
        key = action.key,
        label = action.label,
        desc = action.desc or action.label,
      }
    end
  end
  return result
end

function M.which_key(item, context)
  local result = {}
  for _, action in ipairs(M.available(item, context)) do
    if action.key then
      result[action.key] = {
        desc = action.desc or action.label,
        action = function()
          return M.dispatch(action.id, context, item)
        end,
      }
    end
  end
  return result
end

function M.dispatch(id, context, item)
  local action = registry[id]
  assert(action, "CurrantGit action not found: " .. id)
  if not applies_to(action, item) or action.is_available and not action.is_available(context, item) then
    return false, "action unavailable: " .. id
  end
  return action.run(context, item)
end

return M
