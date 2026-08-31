-- license:BSD-3-Clause
-- copyright-holders:mame-mcp
--
-- util.lua - shared helpers: device/space resolution, address parsing,
-- base64, hexdump. Kept in one place so every handler resolves arguments
-- identically and produces identical error text.

local util = {}

--------------------------------------------------------------------- errors

-- Raise a message the supervisor turns into an MCP tool-execution error.
-- Per MCP SEP-1303 these should be actionable so the model can self-correct.
function util.fail(fmt, ...)
	error(select('#', ...) > 0 and string.format(fmt, ...) or fmt, 0)
end

--------------------------------------------------------------------- devices

-- The "visible CPU" is what the debugger considers current; it is the natural
-- default so the agent does not have to name a device on every call.
function util.visible_cpu()
	local dbg = manager.machine.debugger
	return dbg and dbg.visible_cpu or nil
end

function util.device(tag)
	if tag == nil or tag == '' then
		local d = util.visible_cpu()
		if d then return d end
		local first = manager.machine.devices[':maincpu']
		if first then return first end
		util.fail('no device specified and no visible CPU; pass "device"')
	end
	local d = manager.machine.devices[tag]
	if not d then
		local names, n = {}, 0
		for t, _ in pairs(manager.machine.devices) do
			n = n + 1
			if n <= 40 then names[#names + 1] = t end
		end
		table.sort(names)
		util.fail('no device "%s"; e.g. %s%s', tag,
			table.concat(names, ', '), n > 40 and ', ...' or '')
	end
	return d
end

local SPACE_ALIASES = {
	p = 'program', prog = 'program', program = 'program',
	d = 'data',    data = 'data',
	i = 'io',      io = 'io',
	o = 'opcodes', op = 'opcodes', opcodes = 'opcodes',
}

function util.space(dev, name)
	local want = SPACE_ALIASES[string.lower(tostring(name or 'program'))]
	if not want then
		util.fail('unknown space "%s"; use program, data, io or opcodes', tostring(name))
	end
	local sp = dev.spaces[want]
	if not sp then
		local have = {}
		for k, _ in pairs(dev.spaces) do have[#have + 1] = k end
		table.sort(have)
		if #have == 0 then
			util.fail('device "%s" has no address spaces', dev.tag)
		end
		util.fail('no address space "%s" on "%s"; available: %s',
			want, dev.tag, table.concat(have, ', '))
	end
	return sp, want
end

-------------------------------------------------------------------- addresses

-- Accepts 0x1a2c / $1a2c / 1a2c (hex-ish), decimal, or any debugger
-- expression ("pc", "pc+4", "maincpu.pc"). Always returns a number, and the
-- caller echoes the resolved value back so the agent can see what happened.
function util.address(v, dev)
	if type(v) == 'number' then return math.floor(v) end
	if type(v) ~= 'string' or v:match('^%s*$') then
		util.fail('missing address')
	end
	local s = v:gsub('%s', '')

	local hex = s:match('^0[xX](%x+)$') or s:match('^%$(%x+)$')
	if hex then return tonumber(hex, 16) end
	if s:match('^%d+$') then return tonumber(s, 10) end
	if s:match('^%x+$') then return tonumber(s, 16) end -- bare hex, MAME convention

	-- Fall back to the debugger expression evaluator.
	local ok, res = pcall(function()
		local symtab = dev and emu.symbol_table(dev) or emu.symbol_table(manager.machine)
		return emu.parsed_expression(symtab, s):evaluate()
	end)
	if ok and type(res) == 'number' then return math.floor(res) end
	util.fail('cannot parse address "%s" (tried hex, decimal and expression)', v)
end

---------------------------------------------------------------------- base64

local B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

function util.b64encode(data)
	local out = {}
	local n = #data
	local i = 1
	while i + 2 <= n do
		local a, b, c = data:byte(i, i + 2)
		local x = a * 65536 + b * 256 + c
		out[#out + 1] = B64:sub((x >> 18 & 63) + 1, (x >> 18 & 63) + 1)
			.. B64:sub((x >> 12 & 63) + 1, (x >> 12 & 63) + 1)
			.. B64:sub((x >> 6 & 63) + 1, (x >> 6 & 63) + 1)
			.. B64:sub((x & 63) + 1, (x & 63) + 1)
		i = i + 3
	end
	local rem = n - i + 1
	if rem == 1 then
		local a = data:byte(i)
		local x = a * 65536
		out[#out + 1] = B64:sub((x >> 18 & 63) + 1, (x >> 18 & 63) + 1)
			.. B64:sub((x >> 12 & 63) + 1, (x >> 12 & 63) + 1) .. '=='
	elseif rem == 2 then
		local a, b = data:byte(i, i + 1)
		local x = a * 65536 + b * 256
		out[#out + 1] = B64:sub((x >> 18 & 63) + 1, (x >> 18 & 63) + 1)
			.. B64:sub((x >> 12 & 63) + 1, (x >> 12 & 63) + 1)
			.. B64:sub((x >> 6 & 63) + 1, (x >> 6 & 63) + 1) .. '='
	end
	return table.concat(out)
end

local B64INV = {}
for i = 1, #B64 do B64INV[B64:sub(i, i)] = i - 1 end

function util.b64decode(s)
	s = tostring(s):gsub('[^A-Za-z0-9+/=]', '')
	local out = {}
	for i = 1, #s, 4 do
		local c1, c2, c3, c4 = s:sub(i, i), s:sub(i + 1, i + 1), s:sub(i + 2, i + 2), s:sub(i + 3, i + 3)
		local n1, n2 = B64INV[c1] or 0, B64INV[c2] or 0
		local n3, n4 = B64INV[c3], B64INV[c4]
		local x = n1 * 262144 + n2 * 4096 + (n3 or 0) * 64 + (n4 or 0)
		out[#out + 1] = string.char(x >> 16 & 255)
		if c3 ~= '=' and c3 ~= '' then out[#out + 1] = string.char(x >> 8 & 255) end
		if c4 ~= '=' and c4 ~= '' then out[#out + 1] = string.char(x & 255) end
	end
	return table.concat(out)
end

--------------------------------------------------------------------- hexdump

-- A compact hex+ASCII rendering. The supervisor caps how much of this it
-- forwards; the base64 payload is the authoritative data.
function util.hexdump(bytes, base, width)
	width = width or 16
	local lines = {}
	for off = 0, #bytes - 1, width do
		local chunk = bytes:sub(off + 1, off + width)
		local hex, asc = {}, {}
		for i = 1, #chunk do
			local b = chunk:byte(i)
			hex[#hex + 1] = string.format('%02X', b)
			asc[#asc + 1] = (b >= 32 and b < 127) and string.char(b) or '.'
		end
		for _ = #chunk + 1, width do hex[#hex + 1] = '  ' end
		lines[#lines + 1] = string.format('%08X  %s  |%s|',
			base + off, table.concat(hex, ' '), table.concat(asc))
	end
	return table.concat(lines, '\n')
end

------------------------------------------------------------------ misc

function util.clamp(v, lo, hi)
	v = tonumber(v) or lo
	if v < lo then return lo end
	if v > hi then return hi end
	return math.floor(v)
end

-- Sorted key list, for stable output the agent can diff between calls.
function util.sorted_keys(t)
	local ks = {}
	for k, _ in pairs(t) do ks[#ks + 1] = k end
	table.sort(ks)
	return ks
end

return util
