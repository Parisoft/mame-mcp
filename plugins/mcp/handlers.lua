-- license:BSD-3-Clause
-- copyright-holders:mame-mcp
--
-- handlers.lua - the actual tool implementations, registered onto an rpc
-- object. Every handler runs on the emulation thread (called from the pump),
-- so handlers must be quick and must never block.
--
-- Naming mirrors docs/mcp/PLAN.md section 5: <domain>.<verb>.

local util = require('mcp/util')

local M = {}

--------------------------------------------------------------------- helpers

local function machine() return manager.machine end
local function debugger() return manager.machine.debugger end

local function require_debugger()
	local d = debugger()
	if not d then
		util.fail('debugger not enabled; relaunch the session with -debug')
	end
	return d
end

local function exec_state()
	local d = debugger()
	if not d then return machine().paused and 'paused' or 'running' end
	if d.execution_state == 'stop' then return 'stopped' end
	return machine().paused and 'paused' or 'running'
end

-- Register a table of handlers with a common prefix.
local function reg(rpc, prefix, tbl)
	for name, fn in pairs(tbl) do
		rpc:on(prefix .. '.' .. name, fn)
	end
end

--=========================================================== session / machine

local function device_summary(dev)
	local out = { tag = dev.tag, name = dev.name, shortname = dev.shortname }
	local spaces = {}
	local ok = pcall(function()
		for nm, sp in pairs(dev.spaces) do
			spaces[#spaces + 1] = {
				name = nm,
				data_width = sp.data_width,
				address_mask = string.format('0x%x', sp.address_mask),
				endianness = sp.endianness,
			}
		end
	end)
	if ok and #spaces > 0 then
		table.sort(spaces, function(a, b) return a.name < b.name end)
		out.spaces = spaces
	end
	return out
end

local function handlers_machine(rpc)
	reg(rpc, 'machine', {

		-- The orientation tool: everything an agent needs to start work.
		describe = function()
			local m = machine()
			local res = {
				driver = {
					name        = m.system.name,
					description = m.system.description,
					manufacturer= m.system.manufacturer,
					year        = m.system.year,
					parent      = m.system.parent,
				},
				execution_state = exec_state(),
				time = m.time:as_double(),
			}

			local cpus, devices = {}, {}
			for tag, dev in pairs(m.devices) do
				local s = device_summary(dev)
				devices[#devices + 1] = s
				if s.spaces and dev.state then
					local vis = debugger() and debugger().visible_cpu
					s.visible = (vis ~= nil and vis.tag == dev.tag) or nil
					cpus[#cpus + 1] = s
				end
			end
			table.sort(devices, function(a, b) return a.tag < b.tag end)
			table.sort(cpus,    function(a, b) return a.tag < b.tag end)
			res.cpus = cpus
			res.device_count = #devices
			res.devices = devices

			local regions = {}
			for tag, r in pairs(m.memory.regions) do
				regions[#regions + 1] = {
					tag = tag, size = r.size, bitwidth = r.bitwidth,
					bytewidth = r.bytewidth, endianness = r.endianness,
				}
			end
			table.sort(regions, function(a, b) return a.tag < b.tag end)
			res.regions = regions

			local shares = {}
			for tag, s in pairs(m.memory.shares) do
				shares[#shares + 1] = { tag = tag, size = s.size, bitwidth = s.bitwidth }
			end
			table.sort(shares, function(a, b) return a.tag < b.tag end)
			res.shares = shares

			local screens = {}
			for tag, scr in pairs(m.screens) do
				screens[#screens + 1] = {
					tag = tag, width = scr.width, height = scr.height,
					refresh = scr.refresh, frame_number = scr:frame_number(),
				}
			end
			table.sort(screens, function(a, b) return a.tag < b.tag end)
			res.screens = screens

			return res
		end,

		status = function()
			local m = machine()
			local st = {
				execution_state = exec_state(),
				paused = m.paused,
				time = m.time:as_double(),
				speed_percent = m.video.speed_percent,
			}
			local cpu = util.visible_cpu()
			if cpu then
				st.visible_cpu = cpu.tag
				local pc = cpu.state['PC'] or cpu.state['PCA'] or cpu.state['CURPC']
				if pc then st.pc = string.format('0x%X', pc.value) end
			end
			return st
		end,

		reset = function(p)
			if p.hard then machine():hard_reset() else machine():soft_reset() end
			return { ok = true, kind = p.hard and 'hard' or 'soft' }
		end,
	})
end

--========================================================== execution control

local function handlers_exec(rpc)
	reg(rpc, 'exec', {
		state = function()
			local cpu = util.visible_cpu()
			return { state = exec_state(), visible_cpu = cpu and cpu.tag or nil }
		end,

		-- NOTE: pause/resume live on the emu table, not on running_machine
		-- (luaengine.cpp:1018). machine.paused is a read-only property.
		pause = function() emu.pause(); return { state = exec_state() } end,

		resume = function()
			local d = debugger()
			if d then d.execution_state = 'run' end
			emu.unpause()
			return { state = exec_state() }
		end,

		step = function(p)
			local dev = util.device(p.device)
			require_debugger()
			dev.debug:step(util.clamp(p.count or 1, 1, 1000000))
			return { ok = true }
		end,

		step_over = function(p)
			require_debugger()
			debugger():command(string.format('over %d', util.clamp(p.count or 1, 1, 1000000)))
			return { ok = true }
		end,

		step_out = function()
			require_debugger()
			debugger():command('out')
			return { ok = true }
		end,

		run_to = function(p)
			local dev = util.device(p.device)
			require_debugger()
			local addr = util.address(p.address, dev)
			dev.debug:go(addr)
			return { ok = true, address = string.format('0x%X', addr) }
		end,

		run_until_vblank = function()
			require_debugger(); debugger():command('gv'); return { ok = true }
		end,

		run_until_interrupt = function(p)
			require_debugger()
			debugger():command(p.irq and ('gi ' .. tostring(p.irq)) or 'gi')
			return { ok = true }
		end,

		-- Emulated-time bounded run: the safest "advance a bit" primitive.
		run_for = function(p)
			require_debugger()
			local ms = util.clamp(p.milliseconds or 100, 1, 60000)
			debugger():command(string.format('gtime %d', ms))
			return { ok = true, milliseconds = ms }
		end,

		next_device = function()
			require_debugger(); debugger():command('gni'); return { ok = true }
		end,
	})
end

--=================================================== breakpoints / watchpoints

local function handlers_breakpoints(rpc)
	reg(rpc, 'bp', {
		set = function(p)
			local dev = util.device(p.device)
			require_debugger()
			local addr = util.address(p.address, dev)
			-- NOTE: always pass all three arguments. The 1-arg form of bpset
			-- segfaults upstream (luaengine_debug.cpp binds char const* with
			-- no defaults) -- see docs/mcp/PLAN.md section 11.5 #4.
			local idx = dev.debug:bpset(addr, p.condition or '1', p.action or '')
			return {
				index = idx, device = dev.tag,
				address = string.format('0x%X', addr),
				condition = p.condition or '1', action = p.action or '',
			}
		end,

		list = function(p)
			local out = {}
			local function collect(dev)
				local ok, bps = pcall(function() return dev.debug:bplist() end)
				if not ok or not bps then return end
				for idx, bp in pairs(bps) do
					out[#out + 1] = {
						index = idx, device = dev.tag,
						address = string.format('0x%X', bp.address),
						enabled = bp.enabled, condition = bp.condition, action = bp.action,
					}
				end
			end
			if p.device then collect(util.device(p.device))
			else
				for _, dev in pairs(machine().devices) do
					if pcall(function() return dev.debug end) and dev.debug then collect(dev) end
				end
			end
			table.sort(out, function(a, b) return a.index < b.index end)
			return { breakpoints = out }
		end,

		clear = function(p)
			local dev = util.device(p.device)
			require_debugger()
			if p.index then
				return { ok = dev.debug:bpclear(math.floor(p.index)) }
			end
			dev.debug:bpclear()
			return { ok = true, cleared = 'all' }
		end,

		enable = function(p)
			local dev = util.device(p.device)
			require_debugger()
			if p.index then dev.debug:bpenable(math.floor(p.index))
			else dev.debug:bpenable() end
			return { ok = true }
		end,

		disable = function(p)
			local dev = util.device(p.device)
			require_debugger()
			if p.index then dev.debug:bpdisable(math.floor(p.index))
			else dev.debug:bpdisable() end
			return { ok = true }
		end,
	})

	reg(rpc, 'wp', {
		set = function(p)
			local dev = util.device(p.device)
			require_debugger()
			local sp = util.space(dev, p.space)
			local addr = util.address(p.address, dev)
			local len = util.clamp(p.length or 1, 1, 0x1000000)
			local kind = string.lower(tostring(p.type or 'w'))
			if kind ~= 'r' and kind ~= 'w' and kind ~= 'rw' then
				util.fail('watchpoint type must be "r", "w" or "rw" (got "%s")', tostring(p.type))
			end
			local idx = dev.debug:wpset(sp, kind, addr, len, p.condition or '1', p.action or '')
			return {
				index = idx, device = dev.tag, type = kind,
				address = string.format('0x%X', addr), length = len,
			}
		end,

		list = function(p)
			local dev = util.device(p.device)
			local sp = util.space(dev, p.space)
			local out = {}
			local ok, wps = pcall(function() return dev.debug:wplist(sp) end)
			if ok and wps then
				for idx, wp in pairs(wps) do
					out[#out + 1] = {
						index = idx, device = dev.tag, type = wp.type,
						address = string.format('0x%X', wp.address),
						length = wp.length, enabled = wp.enabled,
						condition = wp.condition, action = wp.action,
					}
				end
			end
			table.sort(out, function(a, b) return a.index < b.index end)
			return { watchpoints = out }
		end,

		clear = function(p)
			local dev = util.device(p.device)
			require_debugger()
			if p.index then return { ok = dev.debug:wpclear(math.floor(p.index)) } end
			dev.debug:wpclear()
			return { ok = true, cleared = 'all' }
		end,
	})

	-- Registerpoints / exceptionpoints have no Lua binding; go via the console.
	reg(rpc, 'rp', {
		set = function(p)
			require_debugger()
			if not p.condition or p.condition == '' then
				util.fail('rp.set requires a "condition" expression, e.g. "A==5"')
			end
			debugger():command(string.format('rpset {%s}%s', p.condition,
				p.action and (',{' .. p.action .. '}') or ''))
			return { ok = true, condition = p.condition }
		end,
		list  = function() require_debugger(); debugger():command('rplist'); return { ok = true } end,
		clear = function(p)
			require_debugger()
			debugger():command(p.index and ('rpclear ' .. math.floor(p.index)) or 'rpclear')
			return { ok = true }
		end,
	})
end

--=================================================================== memory

local READERS = { [1] = 'read_u8', [2] = 'read_u16', [4] = 'read_u32', [8] = 'read_u64' }
local WRITERS = { [1] = 'write_u8', [2] = 'write_u16', [4] = 'write_u32', [8] = 'write_u64' }

local function handlers_memory(rpc)
	reg(rpc, 'mem', {
		read = function(p)
			local dev = util.device(p.device)
			local sp, spname = util.space(dev, p.space)
			local addr = util.address(p.address, dev)
			local len  = util.clamp(p.length or 256, 1, 1024 * 1024)
			local es   = p.element_size or 1
			if not READERS[es] then util.fail('element_size must be 1, 2, 4 or 8') end

			local mode = string.lower(tostring(p.mode or 'logical'))
			local fn
			if mode == 'logical' then fn = READERS[es]
			elseif mode == 'physical' then fn = READERS[es]:gsub('read_', 'readv_')
			elseif mode == 'direct' then fn = READERS[es]:gsub('read_', 'read_direct_')
			else util.fail('mode must be logical, physical or direct') end

			local bytes = {}
			for i = 0, len - 1, es do
				local v = sp[fn](sp, addr + i)
				for b = 0, es - 1 do
					-- little-endian byte order within the element
					bytes[#bytes + 1] = string.char((v >> (8 * b)) & 0xFF)
				end
			end
			local raw = table.concat(bytes):sub(1, len)
			return {
				device = dev.tag, space = spname, mode = mode,
				address = string.format('0x%X', addr), length = #raw,
				element_size = es, encoding = 'base64',
				data = util.b64encode(raw),
				hexdump = util.hexdump(raw, addr),
			}
		end,

		write = function(p)
			local dev = util.device(p.device)
			local sp, spname = util.space(dev, p.space)
			local addr = util.address(p.address, dev)
			local raw
			if p.data then raw = util.b64decode(p.data)
			elseif p.bytes then
				local t = {}
				for _, b in ipairs(p.bytes) do t[#t + 1] = string.char(math.floor(b) & 0xFF) end
				raw = table.concat(t)
			else util.fail('mem.write needs "data" (base64) or "bytes" (array)') end

			for i = 1, #raw do sp:write_u8(addr + i - 1, raw:byte(i)) end
			return {
				ok = true, device = dev.tag, space = spname,
				address = string.format('0x%X', addr), length = #raw,
			}
		end,

		region_read = function(p)
			local tag = p.tag or util.fail('mem.region_read needs "tag"')
			local r = machine().memory.regions[tag]
			if not r then
				util.fail('no region "%s"; available: %s', tag,
					table.concat(util.sorted_keys(machine().memory.regions), ', '))
			end
			local off = util.address(p.offset or 0)
			local len = util.clamp(p.length or 256, 1, 1024 * 1024)
			local raw = r:read(off, len)
			return {
				tag = tag, offset = off, length = #raw, encoding = 'base64',
				region_size = r.size, data = util.b64encode(raw),
				hexdump = util.hexdump(raw, off),
			}
		end,

		list_regions = function()
			local out = {}
			for tag, r in pairs(machine().memory.regions) do
				out[#out + 1] = { tag = tag, size = r.size, bitwidth = r.bitwidth,
					bytewidth = r.bytewidth, endianness = r.endianness }
			end
			table.sort(out, function(a, b) return a.tag < b.tag end)
			return { regions = out }
		end,

		list_shares = function()
			local out = {}
			for tag, s in pairs(machine().memory.shares) do
				out[#out + 1] = { tag = tag, size = s.size, bitwidth = s.bitwidth,
					bytewidth = s.bytewidth, endianness = s.endianness }
			end
			table.sort(out, function(a, b) return a.tag < b.tag end)
			return { shares = out }
		end,

		-- Byte-pattern search over an address range. Returns addresses; the
		-- agent then reads context around the hits.
		search = function(p)
			local dev = util.device(p.device)
			local sp = util.space(dev, p.space)
			local first = util.address(p.start or 0, dev)
			local last  = util.address(p['end'] or sp.address_mask, dev)
			local limit = util.clamp(p.limit or 64, 1, 4096)

			local pat
			if p.data then pat = util.b64decode(p.data)
			elseif p.text then pat = tostring(p.text)
			elseif p.bytes then
				local t = {}
				for _, b in ipairs(p.bytes) do t[#t + 1] = string.char(math.floor(b) & 0xFF) end
				pat = table.concat(t)
			else util.fail('mem.search needs "data" (base64), "text" or "bytes"') end
			if #pat == 0 then util.fail('empty search pattern') end

			-- Chunked scan with overlap so matches spanning a boundary are found.
			local hits, CH = {}, 4096
			local pos = first
			while pos <= last and #hits < limit do
				local n = math.min(CH, last - pos + 1)
				local buf = {}
				for i = 0, n - 1 do buf[#buf + 1] = string.char(sp:read_u8(pos + i) & 0xFF) end
				local s = table.concat(buf)
				local idx = 1
				while true do
					local f = s:find(pat, idx, true)
					if not f then break end
					hits[#hits + 1] = string.format('0x%X', pos + f - 1)
					if #hits >= limit then break end
					idx = f + 1
				end
				pos = pos + n - (#pat - 1)
				if n < CH then break end
			end
			return { matches = hits, count = #hits, truncated = #hits >= limit }
		end,
	})
end

--=========================================== cpu / registers / disassembly

local function handlers_cpu(rpc)
	reg(rpc, 'cpu', {
		list = function()
			local out = {}
			for tag, dev in pairs(machine().devices) do
				local ok = pcall(function() return dev.state end)
				if ok and dev.state then
					local has_space = false
					pcall(function() has_space = dev.spaces['program'] ~= nil end)
					if has_space then
						out[#out + 1] = { tag = tag, name = dev.name, shortname = dev.shortname }
					end
				end
			end
			table.sort(out, function(a, b) return a.tag < b.tag end)
			return { cpus = out }
		end,

		registers = function(p)
			local dev = util.device(p.device)
			if not dev.state then util.fail('device "%s" has no state interface', dev.tag) end
			local out = {}
			for name, entry in pairs(dev.state) do
				local ok, v = pcall(function() return entry.value end)
				if ok then
					out[#out + 1] = {
						name = name,
						value = type(v) == 'number' and math.floor(v) or v,
						hex = type(v) == 'number' and string.format('0x%X', math.floor(v)) or nil,
						writeable = entry.writeable,
					}
				end
			end
			table.sort(out, function(a, b) return a.name < b.name end)
			return { device = dev.tag, registers = out }
		end,

		set_register = function(p)
			local dev = util.device(p.device)
			local name = p.name or util.fail('cpu.set_register needs "name"')
			local e = dev.state[name]
			if not e then util.fail('no register "%s" on "%s"', name, dev.tag) end
			e.value = util.address(p.value, dev)
			return { ok = true, name = name, value = string.format('0x%X', e.value) }
		end,

		-- Disassembly goes through the debugger `dasm` command, which writes a
		-- file, then we parse it back. Ugly but it is the only route from Lua
		-- today; PLAN.md phase 3 replaces this with a debug_disasm_buffer
		-- binding exposed directly.
		disassemble = function(p)
			local dev = util.device(p.device)
			require_debugger()
			local addr  = util.address(p.address or (dev.state['PC'] and dev.state['PC'].value) or 0, dev)
			local count = util.clamp(p.count or 16, 1, 4096)
			local path  = string.format('%s/mcp_dasm_%d.txt', M.workdir, math.floor(addr))

			debugger():command(string.format('dasm "%s",0x%X,%d,1', path, addr, count))

			local f = io.open(path, 'r')
			if not f then util.fail('disassembly failed: could not read %s', path) end
			local lines = {}
			for line in f:lines() do
				local a, rest = line:match('^(%x+):%s+(.*)$')
				if a then
					local bytes, text = rest:match('^([%x%s]-)%s%s+(.*)$')
					lines[#lines + 1] = {
						address = '0x' .. a,
						bytes = bytes and bytes:gsub('%s+$', '') or nil,
						text = (text or rest):gsub('%s+$', ''),
					}
				end
			end
			f:close()
			os.remove(path)
			return { device = dev.tag, address = string.format('0x%X', addr),
				count = #lines, instructions = lines }
		end,
	})

	reg(rpc, 'sym', {
		-- Evaluated through the debugger console rather than a fresh
		-- emu.symbol_table: only the debugger's own table carries the CPU
		-- state symbols (pc, sp, registers), which is what agents will use.
		eval = function(p)
			local d = require_debugger()
			local expr = p.expression or util.fail('sym.eval needs "expression"')
			local log = d.consolelog
			local before = #log
			d:command('print ' .. expr)
			local out = {}
			for i = before + 1, #log do out[#out + 1] = log[i] end
			local last = out[#out]
			if not last then util.fail('cannot evaluate "%s" (no output)', expr) end
			-- Errors come back as console text rather than a Lua error.
			if last:find('nknown symbol') or last:find('rror') or last:find('nvalid') then
				util.fail('cannot evaluate "%s": %s', expr, last)
			end
			local v = tonumber(last, 16) or tonumber(last)
			return {
				expression = expr,
				value = v and math.floor(v) or nil,
				hex = v and string.format('0x%X', math.floor(v)) or nil,
				raw = last,
			}
		end,
	})

	reg(rpc, 'annot', {
		add = function(p)
			local dev = util.device(p.device)
			require_debugger()
			local addr = util.address(p.address, dev)
			local text = p.text or util.fail('annot.add needs "text"')
			debugger():command(string.format('comadd 0x%X,"%s"', addr, text:gsub('"', "'")))
			return { ok = true, address = string.format('0x%X', addr), text = text }
		end,
		list = function()
			require_debugger(); debugger():command('comlist'); return { ok = true }
		end,
		remove = function(p)
			local dev = util.device(p.device)
			require_debugger()
			local addr = util.address(p.address, dev)
			debugger():command(string.format('comdelete 0x%X', addr))
			return { ok = true }
		end,
		save = function()
			require_debugger(); debugger():command('comsave'); return { ok = true }
		end,
	})
end

--============================================================ video / audio

local function handlers_media(rpc)
	reg(rpc, 'video', {
		screenshot = function(p)
			local name = p.filename or string.format('mcp_%d.png', math.floor(machine().time:as_double() * 1000))
			if p.screen then
				local scr = machine().screens[p.screen]
				if not scr then
					util.fail('no screen "%s"; available: %s', p.screen,
						table.concat(util.sorted_keys(machine().screens), ', '))
				end
				scr:snapshot(name)
			else
				machine().video:snapshot()
			end
			return { ok = true, filename = name,
				note = 'written under the snapshot directory (-snapshot_directory)' }
		end,

		screens = function()
			local out = {}
			for tag, s in pairs(machine().screens) do
				out[#out + 1] = { tag = tag, width = s.width, height = s.height,
					refresh = s.refresh, frame_number = s:frame_number() }
			end
			table.sort(out, function(a, b) return a.tag < b.tag end)
			return { screens = out }
		end,

		frame_number = function()
			local _, s = next(machine().screens)
			return { frame = s and s:frame_number() or 0 }
		end,
	})

	reg(rpc, 'audio', {
		record_start = function(p)
			local name = p.filename or 'mcp_capture.wav'
			local ok = machine().sound:start_recording(name)
			if not ok then util.fail('could not start recording (already recording?)') end
			return { ok = true, filename = name }
		end,
		record_stop = function()
			machine().sound:stop_recording()
			return { ok = true }
		end,
		state = function()
			return { recording = machine().sound.recording, muted = machine().sound.muted }
		end,
	})
end

--================================================================ input/state

local function handlers_input_state(rpc)
	reg(rpc, 'input', {
		list_ports = function()
			local out = {}
			for ptag, port in pairs(machine().ioport.ports) do
				local fields = {}
				for fname, f in pairs(port.fields) do
					fields[#fields + 1] = { name = fname, mask = f.mask,
						type = tostring(f.type), player = f.player }
				end
				table.sort(fields, function(a, b) return a.name < b.name end)
				out[#out + 1] = { tag = ptag, fields = fields }
			end
			table.sort(out, function(a, b) return a.tag < b.tag end)
			return { ports = out }
		end,

		-- Hold a field for N frames. The release is scheduled by the pump.
		press = function(p)
			local ptag = p.port or util.fail('input.press needs "port"')
			local fname = p.field or util.fail('input.press needs "field"')
			local port = machine().ioport.ports[ptag]
			if not port then
				util.fail('no port "%s"; available: %s', ptag,
					table.concat(util.sorted_keys(machine().ioport.ports), ', '))
			end
			local f = port.fields[fname]
			if not f then
				util.fail('no field "%s" on port "%s"; available: %s', fname, ptag,
					table.concat(util.sorted_keys(port.fields), ', '))
			end
			f:set_value(p.value or 1)
			M.schedule_release(f, util.clamp(p.frames or 2, 1, 600))
			return { ok = true, port = ptag, field = fname,
				frames = util.clamp(p.frames or 2, 1, 600) }
		end,

		type_text = function(p)
			emu.keypost(tostring(p.text or ''))
			return { ok = true }
		end,
	})

	reg(rpc, 'state', {
		save = function(p)
			local slot = tostring(p.slot or p.filename or '1')
			machine():save(slot)
			return { ok = true, slot = slot }
		end,
		load = function(p)
			local slot = tostring(p.slot or p.filename or '1')
			machine():load(slot)
			return { ok = true, slot = slot }
		end,
	})
end

--=================================================== escape hatch / logging

local function handlers_debug(rpc)
	reg(rpc, 'debug', {
		-- Raw debugger console access. Guarantees the agent is never blocked
		-- by a missing wrapper (PLAN.md 5.11) and is our usage signal for
		-- what to wrap next.
		command = function(p)
			local d = require_debugger()
			local cmd = p.command or util.fail('debug.command needs "command"')
			local log = d.consolelog
			local before = #log
			d:command(cmd)
			local out = {}
			for i = before + 1, #log do out[#out + 1] = log[i] end
			return { command = cmd, output = out }
		end,

		console_log = function(p)
			local d = require_debugger()
			local log = d.consolelog
			local n = util.clamp(p.lines or 50, 1, 2000)
			local out = {}
			for i = math.max(1, #log - n + 1), #log do out[#out + 1] = log[i] end
			return { lines = out, total = #log }
		end,

		error_log = function(p)
			local d = require_debugger()
			local log = d.errorlog
			local n = util.clamp(p.lines or 50, 1, 2000)
			local out = {}
			for i = math.max(1, #log - n + 1), #log do out[#out + 1] = log[i] end
			return { lines = out, total = #log }
		end,
	})
end

--=================================================================== install

function M.install(rpc, opts)
	M.workdir = (opts and opts.workdir) or '/tmp'
	M.releases = {}

	handlers_machine(rpc)
	handlers_exec(rpc)
	handlers_breakpoints(rpc)
	handlers_memory(rpc)
	handlers_cpu(rpc)
	handlers_media(rpc)
	handlers_input_state(rpc)
	handlers_debug(rpc)

	rpc:on('mcp.ping', function() return { pong = true, time = machine().time:as_double() } end)
	rpc:on('mcp.tools', function()
		local names = {}
		for k, _ in pairs(rpc.handlers) do names[#names + 1] = k end
		table.sort(names)
		return { tools = names, count = #names }
	end)
end

-- Deferred input release, ticked once per frame by the plugin.
function M.schedule_release(field, frames)
	M.releases[#M.releases + 1] = { field = field, remaining = frames }
end

function M.tick_releases()
	for i = #M.releases, 1, -1 do
		local r = M.releases[i]
		r.remaining = r.remaining - 1
		if r.remaining <= 0 then
			pcall(function() r.field:set_value(0) end)
			table.remove(M.releases, i)
		end
	end
end

return M
