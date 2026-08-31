// license:BSD-3-Clause
// copyright-holders:mame-mcp
/***************************************************************************

    luaengine_dasm.cpp

    Lua bindings for programmatic disassembly.

    Previously the only way to disassemble from Lua was the debugger's
    "dasm" console command, which writes a text file that the caller then
    has to read back and parse. That works but loses the structure the
    disassembler already computed -- in particular the STEP_OVER and
    STEP_OUT flags, which are what make automated control-flow analysis
    (call graphs, function extents) possible rather than guesswork.

    This exposes debug_disasm_buffer directly, so a consumer gets
    { address, bytes, text, size, step_over, step_out } per instruction.

***************************************************************************/

#include "emu.h"
#include "luaengine.ipp"

#include "debug/debugbuf.h"
#include "debugger.h"

#include "disasmintf.h"

#include <string>
#include <vector>


namespace {

//-------------------------------------------------
//  disasm_wrapper
//
//  debug_disasm_buffer is constructed per device and is cheap, but it
//  caches decoded data, so keeping one alive across a run of
//  instructions is worthwhile.
//-------------------------------------------------

struct disasm_wrapper
{
	disasm_wrapper(device_t &dev)
		: device(&dev), buffer(dev)
	{ }

	device_t *device;
	debug_disasm_buffer buffer;
};

} // anonymous namespace


//-------------------------------------------------
//  initialize_dasm - register disassembly classes
//-------------------------------------------------

void lua_engine::initialize_dasm(sol::table &emu)
{

/*  disasm library
 *
 * emu.disasm(device)  - create a disassembler bound to a device
 *
 * d:at(addr)          - disassemble one instruction; returns a table
 *                       { address, address_str, bytes, text, size,
 *                         next_pc, step_over, step_out }
 * d:range(addr, n)    - disassemble n instructions from addr; returns an
 *                       array of the same tables
 * d:next_pc(addr, n)  - advance n instructions from addr
 */

	auto disasm_type = emu.new_usertype<disasm_wrapper>(
			"disasm",
			sol::call_constructor, sol::factories(
				[] (device_t &dev) { return std::make_shared<disasm_wrapper>(dev); }));

	disasm_type["device"] = sol::property([] (disasm_wrapper const &d) { return d.device; });

	auto const decode_one =
			[this] (disasm_wrapper &d, offs_t pc)
			{
				std::string instruction;
				offs_t next_pc = pc;
				offs_t size = 0;
				u32 info = 0;
				d.buffer.disassemble(pc, instruction, next_pc, size, info);

				sol::table entry = sol().create_table();
				entry["address"] = pc;
				entry["address_str"] = d.buffer.pc_to_string(pc);
				entry["bytes"] = d.buffer.data_to_string(pc, size, true);
				entry["text"] = instruction;
				entry["size"] = size;
				entry["next_pc"] = next_pc;
				// These are the reason this binding exists: they let a
				// caller follow calls/returns without parsing mnemonics.
				entry["step_over"] = bool(info & util::disasm_interface::STEP_OVER);
				entry["step_out"] = bool(info & util::disasm_interface::STEP_OUT);
				return std::make_pair(entry, next_pc);
			};

	disasm_type.set_function(
			"at",
			[decode_one] (disasm_wrapper &d, offs_t pc)
			{
				return decode_one(d, pc).first;
			});

	disasm_type.set_function(
			"range",
			[this, decode_one] (disasm_wrapper &d, offs_t pc, sol::object count_obj)
			{
				u32 count = count_obj.is<u32>() ? count_obj.as<u32>() : 16;
				if (count > 65536)
					count = 65536;

				sol::table result = sol().create_table();
				offs_t addr = pc;
				for (u32 i = 0; i < count; i++)
				{
					auto const [entry, next] = decode_one(d, addr);
					result[i + 1] = entry;
					if (next == addr) // degenerate instruction; avoid spinning
						break;
					addr = next;
				}
				return result;
			});

	disasm_type.set_function(
			"next_pc",
			[] (disasm_wrapper &d, offs_t pc, sol::object step_obj)
			{
				offs_t const step = step_obj.is<offs_t>() ? step_obj.as<offs_t>() : 1;
				return d.buffer.next_pc(pc, step);
			});

	disasm_type.set_function(
			"data_at",
			[] (disasm_wrapper &d, offs_t pc, offs_t size, sol::object opcode_obj)
			{
				bool const opcode = opcode_obj.is<bool>() ? opcode_obj.as<bool>() : true;
				return d.buffer.data_to_string(pc, size, opcode);
			});


/*  device convenience accessor
 *
 * Registered here so this module stays self-contained.
 *
 * manager.machine.devices[tag].disasm  - a disassembler for that device,
 *                                        or nil if it cannot disassemble
 */

	auto device_type = sol().registry()["device"];
	if (device_type.valid())
	{
		sol::usertype<device_t> dev = device_type;
		dev["disasm"] = sol::property(
				[] (device_t &d) -> std::shared_ptr<disasm_wrapper>
				{
					device_disasm_interface *intf = nullptr;
					if (!d.interface(intf))
						return nullptr;
					return std::make_shared<disasm_wrapper>(d);
				});
	}
}
