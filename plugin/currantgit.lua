if vim.g.loaded_currantgit then
  return
end

vim.g.loaded_currantgit = true
require("currantgit").setup()
