local uv = vim.uv
local M = {}

M.applying_change = false
M.buffer_last_sent = {}
M.buffer_last_received = {}

local DEBOUNCE_MS = 50

-- Applies content to a buffer if it differs from current content
function M.apply_changes(path, content)
	local buf = vim.fn.bufnr(path)
	if buf == -1 or not vim.api.nvim_buf_is_loaded(buf) then
		return false
	end

	local current_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local current_text = table.concat(current_lines, "\n")

	if current_text == content then
		return false
	end

	-- Track received content to prevent echoing it back, very hacky but works
	M.buffer_last_received[buf] = content
	M.applying_change = true

	-- Save cursor position to restore later
	local cursor = vim.api.nvim_win_get_cursor(0)

	-- Apply changes
	pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, vim.split(content, "\n"))

	-- Restore cursor if we are in that buffer
	if vim.api.nvim_get_current_buf() == buf then
		local line_count = vim.api.nvim_buf_line_count(buf)
		if cursor[1] > line_count then
			cursor[1] = line_count
		end
		pcall(vim.api.nvim_win_set_cursor, 0, cursor)
	end

	vim.bo[buf].modified = false
	M.applying_change = false
	return true
end

-- Attaches listeners to a buffer to detect and send changes, with debouncing
function M.attach_listeners(buf, path, callback)
	local timer = uv.new_timer()

	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		buffer = buf,
		callback = function()
			if M.applying_change then
				return
			end

			timer:stop()
			timer:start(
				DEBOUNCE_MS,
				0,
				vim.schedule_wrap(function()
					if not vim.api.nvim_buf_is_valid(buf) then
						return
					end
					if M.applying_change then
						return
					end

					local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
					local text = table.concat(lines, "\n")

					-- Only send if content differs from what we last sent or received
					if text ~= M.buffer_last_sent[buf] and text ~= M.buffer_last_received[buf] then
						M.buffer_last_sent[buf] = text
						callback(path, text)
					end
				end)
			)
		end,
	})

	-- Make sure that everything is cleared when closing buffer so they don't linger
	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = buf,
		callback = function()
			if not timer:is_closing() then
				timer:close()
			end
			M.buffer_last_sent[buf] = nil
			M.buffer_last_received[buf] = nil
		end,
	})
end

return M
