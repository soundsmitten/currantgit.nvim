local M = {}

-- Keep output-changing options on the unrestricted command surface. Only
-- known selection options may share the machine-readable log format.
function M.arguments(args)
  local selection = {}
  local index = 2
  while index <= #args do
    local arg = args[index]
    if arg == "--" then
      for path_index = index, #args do selection[#selection + 1] = args[path_index] end
      break
    elseif arg == "-n" or arg == "--max-count" then
      index = index + 1
      if not args[index] or not args[index]:match("^%d+$") then return nil end
      selection[#selection + 1] = arg
      selection[#selection + 1] = args[index]
    elseif arg == "--all" or arg == "--reverse" or arg == "--first-parent"
      or arg == "--no-merges" or arg == "--merges"
      or arg:match("^%-%d+$") or arg:match("^%-n%d+$")
      or arg:match("^%-%-max%-count=%d+$") or arg:match("^%-%-skip=%d+$")
      or arg:match("^%-%-since=.+") or arg:match("^%-%-until=.+")
      or arg:match("^%-%-author=.+") or arg:match("^%-%-grep=.+")
      or arg:sub(1, 1) ~= "-" then
      selection[#selection + 1] = arg
    else
      return nil
    end
    index = index + 1
  end
  local command = {
    "log", "-n", "50", "--no-patch", "--no-color", "--no-decorate",
    "--no-show-signature", "--no-notes", "-z",
    "--format=%H%x00%P%x00%an%x00%ae%x00%aI%x00%s",
  }
  for _, arg in ipairs(selection) do command[#command + 1] = arg end
  return command
end

function M.parse(stdout, repository)
  local items = {}
  local consumed = 0
  for commit, parents, author, email, date, subject in (stdout or ""):gmatch(
    "([^%z]+)%z([^%z]*)%z([^%z]*)%z([^%z]*)%z([^%z]*)%z([^%z]*)%z"
  ) do
    consumed = consumed + #commit + #parents + #author + #email + #date + #subject + 6
    if not commit:match("^[0-9a-f]+$") or (#commit ~= 40 and #commit ~= 64) then
      return nil, "invalid commit record in Git log"
    end
    local parent_ids = {}
    for parent in parents:gmatch("%S+") do parent_ids[#parent_ids + 1] = parent end
    items[#items + 1] = {
      id = "commit:" .. commit,
      kind = "commit",
      repository = repository,
      commit = commit,
      parents = parent_ids,
      author = author,
      email = email,
      date = date,
      subject = subject,
      capabilities = { "open", "show" },
    }
  end
  if consumed ~= #(stdout or "") then return nil, "incomplete commit record in Git log" end
  return items
end

local function display(value)
  return (value:gsub("[%c]", " "))
end

function M.render(items)
  local lines = { "Log" }
  local line_items = {}
  for _, item in ipairs(items) do
    lines[#lines + 1] = string.format("%s  %s  %s  %s",
      item.commit:sub(1, 8), item.date:sub(1, 10), display(item.author), display(item.subject))
    line_items[#lines] = item
  end
  if #items == 0 then lines[#lines + 1] = "  no commits" end
  lines[#lines + 1] = ""
  return lines, line_items
end

return M
