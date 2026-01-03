local uv = vim.uv

local M = {}

M.role = nil  -- "HOST" or "CLIENT"
M.client = nil  -- TCP client

local PORT = 8080

-- Sends raw data over TCP
local function send_raw(data)
	if M.client then
		M.client:write(data)
	end
end

-- Sends a json encoded message
local function send_json(cmd, payload)
	local msg = cmd .. ":" .. vim.json.encode(payload) .. "\n"
	send_raw(msg)
end

-- Sends a message to a specific client (host only)
local function send_to(client_id, cmd, payload)
	local msg = client_id .. ":" .. cmd .. ":" .. vim.json.encode(payload) .. "\n"
	send_raw(msg)
end

-- Broadcasts an update to all connected clients except exclude_id (usually the sender)
local function broadcast_update(path, content, exclude_id)
	for id, _ in pairs(M.connected_clients) do
		if id ~= exclude_id then
			send_to(id, "UPDATE", { path = path, content = content })
		end
	end
end

local function connect(host, callback)
	M.client = uv.new_tcp()
	M.client:connect(host, PORT, function(err)
		if err then
			vim.schedule(function() print(err) end)
			return
		end
		
		vim.schedule(callback)
	end)
end

function M.server_start()
	-- Start the server
	local job_id = vim.fn.jobstart({"./build/server"}, {
		detach = false,
		on_exit = function() print("Server exited") end
	})

	-- Kill server on exit
	vim.api.nvim_create_autocmd("VimLeave", {
		callback = function()
			vim.fn.jobstop(job_id)
		end
	})

    -- Connect to server after a short delay to allow it to start up
    vim.defer_fn(function()
		connect("127.0.0.1", function()
			print("Server is ready")
        end)
    end, 500)
end

vim.api.nvim_create_user_command("TcpServerStart", function()
    M.server_start()
end, {})

return M