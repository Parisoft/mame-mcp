-- license:BSD-3-Clause
-- copyright-holders:mame-mcp
--
-- rpc.lua - line-delimited JSON-RPC 2.0 over a MAME emu_file socket.
--
-- Transport notes (see docs/mcp/PLAN.md section 7, risk 3):
--   * osd_file sockets are non-blocking and single-shot: a read returns
--     whatever is available right now, or an error if nothing is. A listening
--     socket "accepts" on its first read and then becomes the connected
--     socket, so only one peer is supported. That is fine -- the supervisor is
--     the only client.
--   * Because reads are partial, messages are newline-delimited (NDJSON) and
--     reassembled across polls.

local json = require('json')

local rpc = {}
rpc.__index = rpc

local NL = string.byte('\n')

function rpc.new(address)
	local self = setmetatable({}, rpc)
	self.address  = address
	self.inbuf    = ''
	self.outbuf   = ''
	self.connected = false
	self.handlers = {}
	self.file = emu.file('', 0x0f) -- READ|WRITE|CREATE|CREATE_PATHS
	local err = self.file:open(address)
	if err then
		self.file = nil
		self.openerror = tostring(err)
	end
	return self
end

function rpc:ok()
	return self.file ~= nil
end

-- Register a method handler: fn(params) -> result  (may error() to signal failure)
function rpc:on(method, fn)
	self.handlers[method] = fn
end

local function encode(obj)
	-- dkjson emits a bare value; keep everything on one line for NDJSON.
	return (json.encode(obj):gsub('[\r\n]', ' '))
end

function rpc:_send(obj)
	self.outbuf = self.outbuf .. encode(obj) .. '\n'
	self:_flush()
end

function rpc:_flush()
	if self.outbuf == '' or not self.file then return end
	local ok, written = pcall(function() return self.file:write(self.outbuf) end)
	if ok and written and written > 0 then
		self.outbuf = self.outbuf:sub(written + 1)
	end
end

-- Push an unsolicited event (JSON-RPC notification) to the supervisor.
function rpc:notify(method, params)
	self:_send({ jsonrpc = '2.0', method = method, params = params or {} })
end

local function err_obj(id, code, message, data)
	return {
		jsonrpc = '2.0',
		id = id,
		error = { code = code, message = message, data = data },
	}
end

function rpc:_dispatch(line)
	if line:match('^%s*$') then return end

	local req, _, perr = json.decode(line)
	if not req then
		self:_send(err_obj(nil, -32700, 'parse error: ' .. tostring(perr)))
		return
	end

	local id     = req.id
	local method = req.method
	local fn     = self.handlers[method]

	if not fn then
		self:_send(err_obj(id, -32601, 'method not found: ' .. tostring(method)))
		return
	end

	-- Handlers run on the emulation thread (from the pump), so a crash here
	-- would take MAME down. Always trap.
	local ok, res = pcall(fn, req.params or {})
	if not ok then
		self:_send(err_obj(id, -32000, tostring(res)))
	elseif id ~= nil then
		-- dkjson turns an empty table into [] ; force {} for object results.
		if type(res) == 'table' and next(res) == nil then
			res = json.decode('{}')
		end
		self:_send({ jsonrpc = '2.0', id = id, result = res })
	end
end

-- Drain the socket and dispatch any complete lines. Safe to call very often;
-- it is invoked from both the running and the stopped hook.
function rpc:pump()
	if not self.file then return end

	self:_flush()

	local ok, chunk = pcall(function() return self.file:read(65536) end)
	if ok and chunk and #chunk > 0 then
		if not self.connected then
			self.connected = true
		end
		self.inbuf = self.inbuf .. chunk
	end

	while true do
		local nl = self.inbuf:find('\n', 1, true)
		if not nl then break end
		local line = self.inbuf:sub(1, nl - 1)
		self.inbuf = self.inbuf:sub(nl + 1)
		self:_dispatch(line)
	end

	-- Guard against a peer that never sends newlines.
	if #self.inbuf > (4 * 1024 * 1024) then
		self.inbuf = ''
		self:notify('mcp/warning', { message = 'input buffer overflow, discarded' })
	end
end

return rpc
