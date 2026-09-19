local repo = vim.env.CURRANTGIT_ROOT
assert(repo and repo ~= "", "CURRANTGIT_ROOT is required")

vim.opt.loadplugins = true
vim.opt.swapfile = false
vim.opt.writebackup = false
vim.opt.shadafile = "NONE"
vim.opt.rtp:prepend(repo)

require("currantgit").setup()
