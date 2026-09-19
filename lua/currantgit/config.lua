local M = {}

M.defaults = {
  git = {
    command = "git",
  },
  ui = {
    title = "CurrantGit",
    show_clean = true,
    show_branch = true,
    show_counts = true,
    icons = {
      added = "A",
      deleted = "D",
      modified = "M",
      renamed = "R",
      untracked = "?",
    },
  },
}

local options = vim.deepcopy(M.defaults)

local function validate(config)
  if type(config.git.command) ~= "string" or config.git.command == "" then
    error("CurrantGit: git.command must be a non-empty string")
  end
  if type(config.ui.title) ~= "string" or config.ui.title == "" then
    error("CurrantGit: ui.title must be a non-empty string")
  end
  for _, key in ipairs({ "show_clean", "show_branch", "show_counts" }) do
    if type(config.ui[key]) ~= "boolean" then
      error("CurrantGit: ui." .. key .. " must be a boolean")
    end
  end
  for kind, icon in pairs(config.ui.icons) do
    if type(icon) ~= "string" then
      error("CurrantGit: ui.icons." .. kind .. " must be a string")
    end
  end
end

function M.setup(user_options)
  options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), user_options or {})
  validate(options)
  return options
end

function M.get()
  return options
end

return M
