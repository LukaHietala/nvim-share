local uv = vim.uv
local M = {}

-- TCP handle (server or client)
M.handle = nil
-- List of alive clients { id: handle } (handle being TCP one)
M.clients = {}
-- For clients, auto increment ids
M.next_id = 1

-- Decodes json safely
local function decode_json(str)
	local ok, res = pcall(vim.json.decode, str)
	return ok and res or nil
end

local function attach_line_reader(socket, callback)
	-- Collect streamed data to chunks
	local chunks = {}
	socket:read_start(function(err, chunk)
		-- Close the socket on error or disconnect
		if err or not chunk then
			socket:close()
			return
		end

		-- Add read chunk to cunks
		table.insert(chunks, chunk)

		-- Combine chunks to string for processing
		local buffer = table.concat(chunks)
		local start_pos = 1

		-- Get all full lines from buffer
		while true do
			-- Find next newline char from start pos
			local newline_pos = string.find(buffer, "\n", start_pos, true)
			-- If no newline found break the loop for now and resume collecting chunks
			if not newline_pos then
				break
			end

			-- Get full line between start and end pos
			local line = string.sub(buffer, start_pos, newline_pos - 1)
			-- Put full line to queue for other logic to use in main thread
			vim.schedule(function()
				callback(line)
			end)
			-- Move one to the next line
			start_pos = newline_pos + 1
		end
		-- Cleanup processed lines
		chunks = { string.sub(buffer, start_pos) }
	end)
end

-- Send data to spesified client
function M.send(cmd, payload, id)
	local msg = vim.json.encode({ cmd = cmd, data = payload }) .. "\n"

	if M.clients[id] then
		-- As server, send to spesified client
		-- 0 indicates it comes from host
		M.clients[id]:write("0:" .. msg)
	elseif M.handle and not next(M.clients) then
		-- If handle and no clients list assume we are client
		M.handle:write(msg)
	end
end

-- Sends data to every client other than self
function M.broadcast(cmd, payload, sender_id)
	for id, _ in pairs(M.clients) do
		if id ~= sender_id then
			M.send(cmd, payload, id)
		end
	end
end

function M.start_server(port, on_msg, on_connect)
	-- Start server TCP server
	M.handle = uv.new_tcp()
	M.handle:bind("0.0.0.0", port)
	M.handle:listen(128, function(err)
		if err then
			return print("Listen error: " .. err)
		end

		-- Accept new clients
		local client = uv.new_tcp()
		M.handle:accept(client)

		-- Add newly connected client
		local id = M.next_id
		M.next_id = M.next_id + 1
		M.clients[id] = client

		-- Notify on_connect callback
		if on_connect then
			on_connect(id, true)
		end

		attach_line_reader(client, function(line)
			-- targetId:payload" If targetIs is missing, it's for host
			local target, body = line:match("^(%d+):(.*)")
			-- Try to decode body with target or just line without target
			local decoded = decode_json(body or line)
			if decoded then
				on_msg(id, decoded.cmd, decoded.data)
			end
		end)
	end)
end

-- Client connects to host and starts listening to it
function M.connect_to_host(host, port, on_msg)
	M.handle = uv.new_tcp()
	M.handle:connect(host, port, function(err)
		if err then
			return print("Connection failed")
		end

		attach_line_reader(M.handle, function(line)
			-- Strip target if present ("0:{...}")
			local _, body = line:match("^(%d+):(.*)")
			local decoded = decode_json(body or line)
			if decoded then
				on_msg(decoded.cmd, decoded.data)
			end
		end)
	end)
end

function M.close()
	if M.handle then
		M.handle:close()
	end
	for _, c in pairs(M.clients) do
		c:close()
	end
	M.clients = {}
end

return M
