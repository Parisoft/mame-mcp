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


--=================================================== graphics (phase 3)

-- These wrap the luaengine_gfx.cpp bindings. MAME already knows how to
-- decode each driver's graphics (the gfx_decode_entry layouts); until
-- those bindings existed the only consumer was the interactive F4 tile
-- viewer, so on a headless build the decoded pixels were unreachable.

local function handlers_gfx(rpc)
	local function gfx_sets(dev)
		local ok, sets = pcall(function() return dev.gfx end)
		if not ok or not sets then return {} end
		return sets
	end

	reg(rpc, 'gfx', {
		list_sets = function(p)
			local out = {}
			local function scan(dev)
				for idx, g in pairs(gfx_sets(dev)) do
					out[#out + 1] = {
						device = dev.tag, index = idx,
						width = g.width, height = g.height,
						elements = g.elements, depth = g.depth,
						colors = g.colors, granularity = g.granularity,
						colorbase = g.colorbase, has_palette = g.has_palette,
					}
				end
			end
			if p.device then scan(util.device(p.device))
			else
				for _, dev in pairs(machine().devices) do scan(dev) end
			end
			table.sort(out, function(a, b)
				if a.device ~= b.device then return a.device < b.device end
				return a.index < b.index
			end)
			return { sets = out, count = #out }
		end,

		-- The headless equivalent of MAME's F4 tile viewer.
		render_tiles = function(p)
			local dev = util.device(p.device)
			local sets = gfx_sets(dev)
			local idx = p.index or 0
			local g = sets[idx]
			if not g then
				local avail = {}
				for k, _ in pairs(sets) do avail[#avail + 1] = tostring(k) end
				table.sort(avail)
				util.fail('no gfx set %s on "%s"; available: %s', tostring(idx), dev.tag,
					#avail > 0 and table.concat(avail, ', ') or '(none)')
			end
			local file = p.filename or string.format('%s/mcp_gfx_%d.png', M.workdir, idx)
			local first = util.clamp(p.first or 0, 0, math.max(0, g.elements - 1))
			local count = util.clamp(p.count or math.min(256, g.elements - first), 1, 4096)
            local cols  = util.clamp(p.columns or 16, 1, 256)
			local color = util.clamp(p.color or 0, 0, math.max(0, (g.colors or 1) - 1))
			local w, h, drawn, usedcols = g:sheet(file, first, count, cols, color)
			return {
				file = file, width = w, height = h,
				tiles = drawn, columns = usedcols,
				device = dev.tag, index = idx,
				tile_width = g.width, tile_height = g.height,
				first = first, color = color,
			}
		end,

		list_tilemaps = function()
			local tms = machine().tilemaps
			local out = {}
			for i = 0, (tms.count or 0) - 1 do
				local t = tms[i]
				if t then
					out[#out + 1] = { index = i, width = t.width, height = t.height,
						enabled = t.enabled }
				end
			end
			return { tilemaps = out, count = #out }
		end,

		render_tilemap = function(p)
			local tms = machine().tilemaps
			local idx = p.index or 0
			local t = tms[idx]
			if not t then
				util.fail('no tilemap %s (machine has %d)', tostring(idx), tms.count or 0)
			end
			local file = p.filename or string.format('%s/mcp_tilemap_%d.png', M.workdir, idx)
			local w, h = t:render(file)
			return { file = file, width = w, height = h, index = idx }
		end,

		palette = function(p)
			local dev = util.device(p.device)
			local pal
			local ok = pcall(function() pal = dev.palette end)
			if not ok or not pal then
				-- fall back to the first palette device in the machine
				for _, d in pairs(machine().palettes) do pal = d break end
			end
			if not pal then util.fail('no palette found') end
			local limit = util.clamp(p.limit or 256, 1, 65536)
			local entries = math.min(pal.entries, limit)
			local colors = {}
			for i = 0, entries - 1 do
				local c = pal:pen_color(i)
				colors[#colors + 1] = string.format('#%06X', c & 0xFFFFFF)
			end
			return { entries = pal.entries, returned = entries, colors = colors }
		end,
	})
end


--============================================== disassembly (phase 3)

-- Backed by luaengine_dasm.cpp -> debug_disasm_buffer. The older
-- cpu.disassemble route shells out to the "dasm" console command, which
-- writes a file we parse back and which loses the STEP_OVER/STEP_OUT
-- flags. Those flags are what make control-flow following possible.

local function handlers_dasm(rpc)
	local function disasm_for(dev)
		local d = dev.disasm
		if not d then
			util.fail('device "%s" cannot disassemble (no disasm interface)', dev.tag)
		end
		return d
	end

	reg(rpc, 'dasm', {
		at = function(p)
			local dev = util.device(p.device)
			local d = disasm_for(dev)
			local addr = util.address(p.address, dev)
			local e = d:at(addr)
			return {
				device = dev.tag,
				address = string.format('0x%X', e.address),
				bytes = e.bytes, text = e.text, size = e.size,
				next_pc = string.format('0x%X', e.next_pc),
				step_over = e.step_over, step_out = e.step_out,
			}
		end,

		range = function(p)
			local dev = util.device(p.device)
			local d = disasm_for(dev)
			local addr = util.address(
				p.address or (dev.state['PC'] and dev.state['PC'].value) or 0, dev)
			local count = util.clamp(p.count or 16, 1, 4096)
			local list = d:range(addr, count)
			local out = {}
			for i = 1, #list do
				local e = list[i]
				out[#out + 1] = {
					address = string.format('0x%X', e.address),
					bytes = e.bytes, text = e.text, size = e.size,
					step_over = e.step_over, step_out = e.step_out,
				}
			end
			return { device = dev.tag, address = string.format('0x%X', addr),
				count = #out, instructions = out }
		end,

		-- Linear sweep from an entry point, stopping at the first
		-- unconditional end-of-flow (STEP_OUT), and collecting the call
		-- targets seen on the way. Deliberately simple and clearly
		-- labelled: it does not follow branches.
		["function"] = function(p)
			local dev = util.device(p.device)
			local d = disasm_for(dev)
			local addr = util.address(p.address, dev)
			local limit = util.clamp(p.limit or 256, 1, 4096)
			local out, calls = {}, {}
			local pc = addr
			local terminated = false
			for _ = 1, limit do
				local e = d:at(pc)
				out[#out + 1] = {
					address = string.format('0x%X', e.address),
					bytes = e.bytes, text = e.text,
					step_over = e.step_over, step_out = e.step_out,
				}
				if e.step_over then
					-- a call: record any absolute target in the text
					local t = e.text:match('%$(%x+)') or e.text:match('0x(%x+)')
					if t then calls[#calls + 1] = '0x' .. t:upper() end
				end
				if e.step_out then terminated = true break end
				if e.next_pc == pc then break end
				pc = e.next_pc
			end
			return {
				device = dev.tag,
				entry = string.format('0x%X', addr),
				instructions = out, count = #out,
				calls = calls,
				terminated = terminated,
				note = terminated and 'stopped at end-of-flow instruction'
					or 'hit instruction limit without reaching a return; may be incomplete',
			}
		end,
	})
end


--============================================== coverage (phase 3b)

-- Backed by luaengine_cov.cpp. MAME's "trackpc" console command is a
-- write-only switch: nothing in debugcmd.cpp reads the visited set back
-- (only dvdisasm.cpp queries it, one address at a time, to shade the
-- disassembly view). So coverage was unreachable from Lua until those
-- bindings existed -- debug.command can start tracking but can never
-- tell you the result.

local function handlers_cov(rpc)
	reg(rpc, 'cov', {
		-- Record every address the CPU executes.
		track_pc_start = function(p)
			local dev = util.device(p.device)
			require_debugger()
			if p.clear then dev.debug:track_pc_clear() end
			dev.debug:set_track_pc(true)
			return { ok = true, device = dev.tag, cleared = p.clear or false }
		end,

		track_pc_stop = function(p)
			local dev = util.device(p.device)
			require_debugger()
			dev.debug:set_track_pc(false)
			return { ok = true, device = dev.tag }
		end,

		track_pc_clear = function(p)
			local dev = util.device(p.device)
			require_debugger()
			dev.debug:track_pc_clear()
			return { ok = true, device = dev.tag }
		end,

		visited = function(p)
			local dev = util.device(p.device)
			local addr = util.address(p.address, dev)
			return {
				device = dev.tag,
				address = string.format('0x%X', addr),
				visited = dev.debug:visited(addr),
			}
		end,

		-- The payload tool: sweep a range and return executed regions.
		-- Diffing two of these (e.g. attract mode vs in-game) is the
		-- fastest way to partition an unknown ROM.
		visited_map = function(p)
			local dev = util.device(p.device)
			require_debugger()
			local sp = util.space(dev, p.space)
			local first = util.address(p.start or 0, dev)
			local last = util.address(p['end'] or sp.address_mask, dev)
			if last < first then util.fail('end (0x%X) is before start (0x%X)', last, first) end
			local limit = util.clamp(p.limit or 200000, 1, 5000000)
			if p.mode and p.mode ~= 'byte' and p.mode ~= 'instruction' then
				util.fail('mode must be "byte" or "instruction"')
			end

			local res = dev.debug:visited_ranges(first, last, limit, p.mode)
			local ranges = {}
			for i = 1, res.range_count do
				local r = res.ranges[i]
				ranges[#ranges + 1] = {
					first = string.format('0x%X', r.first),
					last = string.format('0x%X', r.last),
					size = r.last - r.first + 1,
				}
			end
			return {
				device = dev.tag,
				start = string.format('0x%X', first),
				['end'] = string.format('0x%X', last),
				ranges = ranges,
				range_count = res.range_count,
				visited_instructions = res.visited,
				examined_instructions = res.examined,
				truncated = res.truncated,
				mode = res.mode,
				note = res.visited == 0
					and 'no coverage recorded; call cov.track_pc_start and let the game run'
					or nil,
			}
		end,

		-- Which PC last wrote a given address. Needs track_mem.
		track_mem_start = function(p)
			local dev = util.device(p.device)
			require_debugger()
			if p.clear then dev.debug:track_mem_clear() end
			dev.debug:set_track_mem(true)
			return { ok = true, device = dev.tag }
		end,

		track_mem_stop = function(p)
			local dev = util.device(p.device)
			require_debugger()
			dev.debug:set_track_mem(false)
			return { ok = true, device = dev.tag }
		end,

		pc_at = function(p)
			local dev = util.device(p.device)
			local sp, spname = util.space(dev, p.space)
			local addr = util.address(p.address, dev)
			local pc = dev.debug:pc_at(sp.index, addr, p.data or 0)
			return {
				device = dev.tag, space = spname,
				address = string.format('0x%X', addr),
				pc = pc and string.format('0x%X', pc) or nil,
				found = pc ~= nil,
				note = pc == nil
					and 'no writer recorded; call cov.track_mem_start first, then let the game run'
					or nil,
			}
		end,

		-- How execution reached the current point.
		history = function(p)
			local dev = util.device(p.device)
			require_debugger()
			local n = util.clamp(p.count or 16, 1, 256)
			local h = dev.debug:history(n)
			local out = {}
            for i = 1, #h do out[#out + 1] = string.format('0x%X', h[i]) end
			return { device = dev.tag, count = #out, history = out,
				note = 'most recent first' }
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
	handlers_gfx(rpc)
	handlers_dasm(rpc)
	handlers_cov(rpc)
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
