-- Simple dev environment to test changes to this plugin
-- Requires the latest Neovim 0.12+ due to the usage of vim.pack
-- https://neovim.io/doc/user/pack.html

-- Point XDG directories that neovim uses under a temp dev directory
-- https://neovim.io/doc/user/starting.html#standard-path
local dev_root = vim.fn.stdpath("cache") .. "/nvim-tcp-dev-pack"
local data_dir = dev_root .. "/data"
local config_dir = dev_root .. "/config"

vim.env.XDG_DATA_HOME = data_dir
vim.env.XDG_CONFIG_HOME = config_dir
vim.env.XDG_STATE_HOME = dev_root .. "/state"

-- Prepend required dirs for plugins
-- vim.pack manages plugins in $XDG_DATA_HOME/nvim/site/pack/core/opt
vim.opt.packpath:prepend(data_dir .. "/nvim/site")
vim.opt.rtp:prepend(vim.fn.getcwd())

vim.pack.add({
	"https://github.com/nvim-lua/plenary.nvim",
	"https://github.com/nvim-telescope/telescope.nvim",
})

print("In dev environment: " .. dev_root)
