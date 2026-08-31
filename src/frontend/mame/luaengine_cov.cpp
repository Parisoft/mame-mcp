// license:BSD-3-Clause
// copyright-holders:mame-mcp
/***************************************************************************

    luaengine_cov.cpp

    Lua bindings for execution coverage: PC tracking, memory-write
    attribution and the PC history ring.

    Why this needs C++ rather than a Lua wrapper over debug.command:

    MAME's "trackpc" console command is a write-only switch. It turns
    tracking on and off, but nothing in src/emu/debug/debugcmd.cpp ever
    reads the resulting set back out -- the only consumer of the data is
    dvdisasm.cpp, which calls device_debug::track_pc_visited(pc) one
    address at a time to shade the disassembly view. There is no "dump
    the visited set" command, so from Lua the coverage was unreachable.

    These bindings expose the per-address query, plus a sweep that walks
    an address range through the disassembler and returns the visited
    addresses as ranges. That turns coverage into something an automated
    consumer can diff between two runs, which is the fastest way to
    partition an unknown ROM into functional regions.

    "trackmem" is different: it already has a readback path in the form
    of the "pcatmem" command, but that returns formatted console text,
    so the raw accessor is bound here too.

***************************************************************************/

#include "emu.h"
#include "luaengine.ipp"

#include "debug/debugbuf.h"
#include "debug/debugcpu.h"
#include "debugger.h"

#include <algorithm>
#include <vector>


//-------------------------------------------------
//  initialize_cov - register coverage functions
//-------------------------------------------------

void lua_engine::initialize_cov(sol::table &emu)
{
	auto dbg_type = sol().registry()["device_debug"];
	if (!dbg_type.valid())
		return;
	sol::usertype<device_debug> dd = dbg_type;

/*  coverage additions to device_debug
 *
 * dev.debug:set_track_pc(bool)   - start/stop recording executed PCs
 * dev.debug:track_pc_clear()     - discard recorded coverage
 * dev.debug:visited(pc)          - was this address executed?
 * dev.debug:visited_ranges(first, last, [limit], [mode])
 *                                - sweep a range and return the visited
 *                                  addresses coalesced into ranges.
 *                                  mode is "byte" (default, exhaustive)
 *                                  or "instruction" (faster, may miss)
 *
 * dev.debug:set_track_mem(bool)  - record which PC wrote each address
 * dev.debug:track_mem_clear()
 * dev.debug:pc_at(space, addr, [data])
 *                                - the PC that last wrote addr, or nil
 *
 * dev.debug:history(count)       - the most recent PCs executed
 */

	dd.set_function("set_track_pc", &device_debug::set_track_pc);
	dd.set_function("track_pc_clear", &device_debug::track_pc_data_clear);
	dd.set_function("set_track_mem", &device_debug::set_track_mem);
	dd.set_function("track_mem_clear", &device_debug::track_mem_data_clear);

	dd.set_function(
			"visited",
			[] (device_debug &d, offs_t pc)
			{
				return d.track_pc_visited(pc);
			});

	dd.set_function(
			"mark_visited",
			[] (device_debug &d, offs_t pc)
			{
				d.set_track_pc_visited(pc);
			});

	// Walk a range and collect the executed addresses as [start, end]
	// ranges.
	//
	// Two stepping modes, and the difference matters:
	//
	//   byte (default) - probe every address. track_pc_visited() keys on
	//       (address, opcode crc32) so it only ever returns true for real
	//       executed instruction starts; probing the gaps simply returns
	//       false. This cannot miss anything.
	//
	//   instruction - step via the disassembler. Faster over large
	//       ranges, but the alignment it derives from `first` need not
	//       match the alignment the CPU actually executed, so it can walk
	//       straight past executed addresses. Verified in practice: on a
	//       machine whose PC history showed execution at 0xA39C, an
	//       instruction-stepped sweep from 0x0000 never landed on it.
	//
	// Byte mode is therefore the default; instruction mode is opt-in for
	// when a range is too large to probe exhaustively.
	dd.set_function(
			"visited_ranges",
			[this] (device_debug &d, sol::this_state s, offs_t first, offs_t last, sol::object limit_obj, sol::object mode_obj)
			{
				u32 limit = limit_obj.is<u32>() ? limit_obj.as<u32>() : 200000;
				limit = std::clamp<u32>(limit, 1, 5000000);
				bool const by_instruction =
						mode_obj.is<std::string>() && (mode_obj.as<std::string>() == "instruction");

				debug_disasm_buffer buffer(d.device());

				sol::table ranges = sol().create_table();
				unsigned nranges = 0;
				u64 visited = 0;
				u64 examined = 0;

				bool in_run = false;
				offs_t run_start = 0;
				offs_t run_end = 0;

				offs_t pc = first;
				for (u32 i = 0; (i < limit) && (pc <= last); i++)
				{
					examined++;
					bool const hit = d.track_pc_visited(pc);
					if (hit)
					{
						visited++;
						if (!in_run)
						{
							in_run = true;
							run_start = pc;
						}
						run_end = pc;
					}
					else if (in_run)
					{
						sol::table r = sol().create_table();
						r["first"] = run_start;
						r["last"] = run_end;
						ranges[++nranges] = r;
						in_run = false;
					}

					offs_t next;
					if (by_instruction)
					{
						next = buffer.next_pc(pc, 1);
						if (next <= pc) // wrapped or stuck
							break;
					}
					else
					{
						next = pc + 1;
						if (next < pc) // wrapped
							break;
					}
					pc = next;
				}
				if (in_run)
				{
					sol::table r = sol().create_table();
					r["first"] = run_start;
					r["last"] = run_end;
					ranges[++nranges] = r;
				}

				sol::table result = sol().create_table();
				result["ranges"] = ranges;
				result["range_count"] = nranges;
				result["visited"] = visited;
				result["examined"] = examined;
				result["truncated"] = (pc <= last);
				result["mode"] = by_instruction ? "instruction" : "byte";
				return result;
			});

	dd.set_function(
			"pc_at",
			[] (device_debug &d, int space, offs_t address, sol::object data_obj) -> sol::optional<offs_t>
			{
				u64 const data = data_obj.is<u64>() ? data_obj.as<u64>() : 0;
				offs_t const pc = d.track_mem_pc_from_space_address_data(space, address, data);
				if (pc == offs_t(-1))
					return sol::nullopt;
				return pc;
			});

	// The PC history ring: how execution reached the current point.
	dd.set_function(
			"history",
			[this] (device_debug &d, sol::object count_obj)
			{
				int count = count_obj.is<int>() ? count_obj.as<int>() : 16;
				count = std::clamp(count, 1, 256);

				sol::table result = sol().create_table();
				unsigned n = 0;
				for (int i = 0; i < count; i++)
				{
					auto const [pc, valid] = d.history_pc(-i);
					if (!valid)
						break;
					result[++n] = pc;
				}
				return result;
			});
}
