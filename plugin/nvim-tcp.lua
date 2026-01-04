-- Make sure not to load multiple times
if vim.g.loaded_nvim_tcp then
	return
end
vim.g.loaded_nvim_tcp = 1

vim.api.nvim_create_user_command("ServerStart", function()
	require("nvim-tcp").server_start()
end, {})

vim.api.nvim_create_user_command("ServerJoin", function(opts)
	require("nvim-tcp").server_join(opts.args ~= "" and opts.args or nil)
end, { nargs = "?" })

vim.api.nvim_create_user_command("ReviewChanges", function()
	require("nvim-tcp").review_changes()
end, {})

vim.api.nvim_create_user_command("RemoteFiles", function()
	require("nvim-tcp").remote_files()
end, {})
