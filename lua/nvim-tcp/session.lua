local buffer_utils = require("nvim-tcp.buffer")
local transport = require("nvim-tcp.transport")
local ui = require("nvim-tcp.ui")

local M = {}

-- Default config
M.config = {
	port = 8080,
	name = "Jaakko",
	cursor_name = {
		pos = "right_align",
		hl_group = "Cursor",
	},
}

M.state = {
	role = nil, -- "HOST" or "CLIENT"
	clients = {}, -- ID -> Metadata, like name
	pending_changes = {}, -- Path -> { content, client_id }
	cursor_namespace = vim.api.nvim_create_namespace("share-cursor"), -- Not sure where else
}

local handlers = {}

-- Event to host by cliet to ask for filetree to send to client that requested it
function handlers.LIST_REQ(client_id)
	local files = buffer_utils.scan_dir()
	transport.send("FILE_LIST", files, client_id)
end

-- Event received by client after LIST_REQ that contains host's filetree
function handlers.FILE_LIST(_, payload)
	vim.schedule(function()
		ui.show_remote_files(payload, function(path)
			transport.send("GET_REQ", { path = path })
		end)
	end)
end

-- Event requived by host from client. Host responds with asked file content and path
function handlers.GET_REQ(client_id, payload)
	vim.schedule(function()
		local path = payload.path
		-- Priority: current buffer > pending > disk
		local content = buffer_utils.get_buffer_content(path)
			or (M.state.pending_changes[path] and M.state.pending_changes[path].content)
			or buffer_utils.read_file(path)

		if content then
			transport.send("FILE_RES", { path = path, content = content }, client_id)
		end
	end)
end

-- Event received by client from host that contains asked file content
function handlers.FILE_RES(_, payload)
	local path = payload.path
	local content = payload.content

	vim.schedule(function()
		-- Create a scratch buffer for client to put file contents to
		local buf = buffer_utils.create_scratch_buf(path, content)

		-- Add listener for cursor movement
		vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
			desc = "Notifies host when cursor is moved",
			callback = function()
				local current_id = 1
				local pos = vim.api.nvim_win_get_cursor(0)
				local data = {
					path = path,
					position = pos,
					id = nil,
					name = nil,
					-- id and names are tracked by host so they will get added later
					-- when this message passes through the host
				}
				-- Broadcast to host, who will inform others
				transport.send("CURSOR", data)
			end,
		})

		-- Attach listener for subsequent edits, if so send update to host that contains updated content
		buffer_utils.attach_change_listener(buf, function(p, c)
			transport.send("UPDATE", { path = p, content = c })
		end)
	end)
end

-- Event received by host that contains updated content, this is forwarded to other clients
function handlers.UPDATE(client_id, payload)
	local path = payload.path
	local change = payload.content

	vim.schedule(function()
		-- Get the "base" text to apply the patch to
		-- Existing cache (pending) > live buffer > disk
		local base_text = (M.state.pending_changes[path] and M.state.pending_changes[path].content)
			or buffer_utils.get_buffer_content(path)
			or buffer_utils.read_file(path)
			or ""

		-- Apply the patch to the full text string
		local full_text = buffer_utils.patch_text(base_text, change)

		-- Update pending chnages to include new stuff
		M.state.pending_changes[path] = { content = full_text, client_id = client_id }
		-- If buffer is open apply to it
		buffer_utils.apply_patch_to_buf(path, change)

		transport.broadcast("UPDATE", { path = path, content = change }, client_id)
	end)
end

-- Event received by host that contains client name
function handlers.NAME(client_id, payload)
	M.state.clients[client_id] = { name = payload.name }
	local message
	if math.random(100) <= 5 then
		message = "Wild " .. payload.name .. " appeared!"
	else
		message = payload.name .. " joined"
	end

	print(message)
end

-- Event recieved by host or client that contains cursor position
function handlers.CURSOR(client_id, payload)
	if M.state.role == "HOST" then
		payload.id = client_id
		payload.name = M.state.clients[client_id] and M.state.clients[client_id].name or "?"

		transport.broadcast("CURSOR", payload, client_id)
	end

	local row = payload.position[1] - 1
	local col = payload.position[2]
	local name = payload.name
	local path = payload.path
	local mark_id = payload.id + 1 -- host id is 0 which is not allowed :)

	-- If in currently opened buffer
	if path == buffer_utils.rel_path(0) then
		local options = {
			id = mark_id,
			end_col = col + 1,
			hl_group = "TermCursor",
			virt_text = {
				{ name, M.config.cursor_name.hl_group }, -- Cursor for visibility
			},
			strict = false,
		}
		-- Position config
		if M.config.cursor_name.pos == "follow" then
			options.virt_text_win_col = col + 2
		else
			options.virt_text_pos = M.config.cursor_name.pos
		end

		vim.api.nvim_buf_set_extmark(0, M.state.cursor_namespace, row, col, options)
	else -- Try to delete just in case we changed files halfway through
		vim.api.nvim_buf_del_extmark(0, M.state.cursor_namespace, mark_id)
	end
end

-- Executes correct handler above based on server message
function M.process_msg(client_id, cmd, payload)
	if handlers[cmd] then
		handlers[cmd](client_id, payload)
	end
end

function M.start_host()
	if M.state.role then
		return print("Already running")
	end

	transport.start_server(M.config.port, function(client_id, cmd, data)
		M.process_msg(client_id, cmd, data)
	end, function(id, connected)
		if connected then
			-- TODO: use config
			M.state.clients[id] = { name = "Host" }
		end
	end)

	M.state.role = "HOST"
	print("Server started on port " .. M.config.port)

	-- Auto share local buffers on open
	vim.api.nvim_create_autocmd("BufReadPost", {
		callback = function(ev)
			local path = buffer_utils.rel_path(ev.file)

			-- If we have pending changes for this file, apply them now
			local pending = M.state.pending_changes[path]
			if pending then
				vim.schedule(function()
					buffer_utils.apply_patch_to_buf(ev.file, pending.content)
					print("Applied pending changes for " .. path .. "to current buffer")
				end)
			end

			-- Attach listeners
			buffer_utils.attach_change_listener(ev.buf, function(p, c)
				transport.broadcast("UPDATE", { path = p, content = c }, nil)
			end)

			-- On save, update the snapshot (clean state)
			vim.api.nvim_create_autocmd("BufWritePost", {
				buffer = ev.buf,
				callback = function()
					-- If host saves clear the pending changes on that buffer
					M.state.pending_changes[path] = nil
				end,
			})
		end,
	})
	-- Track mouse movement and inform all clients
	vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
		desc = "Notifies clients when cursor is moved",
		callback = function()
			local pos = vim.api.nvim_win_get_cursor(0)
			local path = buffer_utils.rel_path(0)
			local data = {
				path = path,
				position = pos,
				id = 0, -- Host is id 0 (essentially)
				name = "host",
			}
			-- Broadcast to all clients
			transport.broadcast("CURSOR", data, 0)
		end,
	})
end

function M.join_server(ip)
	if M.state.role then
		return print("Already joined")
	end

	transport.connect_to_host(ip, M.config.port, function(cmd, data)
		M.process_msg(nil, cmd, data)
	end)

	M.state.role = "CLIENT"
	transport.send("NAME", { name = M.config.name })
	print("Connected to " .. ip)
end

function M.list_remote_files()
	if M.state.role ~= "CLIENT" then
		return print("Only clients can request files")
	end
	transport.send("LIST_REQ", {})
end

function M.review_pending()
	if M.state.role ~= "HOST" then
		return print("Host only")
	end
	ui.review_changes(M.state.pending_changes, function(path, content)
		buffer_utils.write_file(path, content)
		M.state.pending_changes[path] = nil
		print("Saved " .. path)
	end)
end

function M.stop()
	transport.close()
	M.state.role = nil
end

return M
