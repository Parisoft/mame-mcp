-- license:BSD-3-Clause
-- copyright-holders:mame-mcp
--
-- MCP bridge plugin.
--
-- Exposes MAME's debugging surface as line-delimited JSON-RPC 2.0 on a
-- socket. An external MCP server (mcp-server) is the only client; it
-- translates between MCP-over-stdio and this protocol.
--
-- Why a plugin and not a C++ debug_module (phase 1 of docs/mcp/PLAN.md):
-- everything needed already has Lua bindings, and crucially
-- debugger_cpu::wait_for_debugger() calls emulator_info::periodic_check() ->
-- lua_engine::on_periodic() inside its stop loop. That means our pump keeps
-- servicing requests while the CPU is halted at a breakpoint, which is the
-- whole ballgame for an interactive debugger.
--
-- Configuration (environment, read at startup):
--   MAME_MCP_SOCKET   socket spec, default "socket.127.0.0.1:4321"
--                     (a UNIX socket is "domain./path/to.sock")
--   MAME_MCP_WORKDIR  scratch dir for transient files, default "/tmp"

local exports = {
	name = 'mcp',
	version = '0.1.0',
	description = 'MCP bridge: JSON-RPC control surface for headless debugging',
	license = 'BSD-3-Clause',
	author = { name = 'mame-mcp' },
}

local mcp = exports

function mcp.startplugin()
	local rpclib  = require('mcp/rpc')
	local handlers = require('mcp/handlers')

	local address = os.getenv('MAME_MCP_SOCKET') or 'socket.127.0.0.1:4321'
	local workdir = os.getenv('MAME_MCP_WORKDIR') or '/tmp'

	local rpc                  -- transport, created on machine reset
	local last_state           -- for stop/resume edge detection
	local last_console         -- consolelog high-water mark
	local reset_sub, stop_sub, frame_sub

	local function current_state()
		local dbg = manager.machine.debugger
		if not dbg then return manager.machine.paused and 'paused' or 'running' end
		if dbg.execution_state == 'stop' then return 'stopped' end
		return manager.machine.paused and 'paused' or 'running'
	end

	-- Build the stop event. Ideally we would read
	-- device_debug::triggered_breakpoint()/triggered_watchpoint(), but those
	-- are not bound to Lua, so we scrape the console log the way
	-- plugins/gdbstub does. This is the known-brittle part and is the main
	-- reason PLAN.md phase 3 moves the pump into C++.
	local function stop_reason()
		local dbg = manager.machine.debugger
		if not dbg then return {} end
		local log = dbg.consolelog
		local info = { reason = 'unknown' }
		for i = #log, math.max(1, #log - 12), -1 do
			local line = log[i]
			local bp = line:match('Stopped at breakpoint (%d+)')
			if bp then
				info.reason, info.index = 'breakpoint', tonumber(bp)
				break
			end
			local wp, wdata, waddr = line:match('Stopped at watchpoint (%d+) writing (%x+) to (%x+)')
			if not wp then
				wp, waddr = line:match('Stopped at watchpoint (%d+) reading %x+ from (%x+)')
			end
			if wp then
				info.reason, info.index = 'watchpoint', tonumber(wp)
				if waddr then info.address = '0x' .. waddr end
				if wdata then info.data = '0x' .. wdata end
				break
			end
			if line:match('Stopped at') then
				info.reason = 'step'
				break
			end
		end
		local cpu = dbg.visible_cpu
		if cpu then
			info.device = cpu.tag
			local pc = cpu.state['PC'] or cpu.state['PCA'] or cpu.state['CURPC']
			if pc then info.pc = string.format('0x%X', pc.value) end
		end
		return info
	end

	-- The pump. Called from register_periodic, which fires both during normal
	-- execution and from inside wait_for_debugger's stop loop.
	local function pump()
		if not rpc then return end

		rpc:pump()

		-- Emit an event on running -> stopped and stopped -> running edges so
		-- the supervisor can implement exec.wait_for_stop without polling.
		local st = current_state()
		if st ~= last_state then
			if st == 'stopped' then
				rpc:notify('mcp/stopped', stop_reason())
			else
				rpc:notify('mcp/running', { state = st })
			end
			last_state = st
		end

		-- Forward new console output as a log stream.
		local dbg = manager.machine.debugger
		if dbg then
			local log = dbg.consolelog
			local n = #log
			if last_console and n > last_console then
				local lines = {}
				for i = last_console + 1, n do lines[#lines + 1] = log[i] end
				rpc:notify('mcp/log', { lines = lines })
			end
			last_console = n
		end
	end

	reset_sub = emu.add_machine_reset_notifier(function ()
		rpc = rpclib.new(address)
		if not rpc:ok() then
			emu.print_error('mcp: cannot open ' .. address .. ': ' .. tostring(rpc.openerror))
			rpc = nil
			return
		end
		handlers.install(rpc, { workdir = workdir })
		last_state = current_state()
		last_console = manager.machine.debugger and #manager.machine.debugger.consolelog or 0
		emu.print_info('mcp: listening on ' .. address)
		rpc:notify('mcp/ready', {
			driver = manager.machine.system.name,
			description = manager.machine.system.description,
			debugger = manager.machine.debugger ~= nil,
			app_version = emu.app_version(),
		})
	end)

	stop_sub = emu.add_machine_stop_notifier(function ()
		if rpc then
			rpc:notify('mcp/exiting', {})
			rpc:pump()
		end
		rpc = nil
	end)

	frame_sub = emu.add_machine_frame_notifier(function ()
		handlers.tick_releases()
	end)

	emu.register_periodic(pump)
end

return exports
