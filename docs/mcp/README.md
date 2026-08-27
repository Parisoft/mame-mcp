# mame-mcp

Drive a **headless MAME** from an AI agent over the
[Model Context Protocol](https://modelcontextprotocol.io) to debug and reverse-engineer
arcade ROMs — breakpoints, watchpoints, memory, registers, disassembly, screenshots and
WAV capture, with **no X server and no framebuffer**.

> Phase 1 of [`PLAN.md`](PLAN.md). See [`tools.md`](tools.md) for the full tool reference.

---

## How it fits together

```
 Agent  ──MCP (stdio, JSON-RPC 2.0)──▶  tools/mcp-server (Node)
                                          │  spawns + supervises
                                          │  NDJSON JSON-RPC over a UNIX socket
                                          ▼
                                   mame -debug -debugger none -plugin mcp
                                          └── plugins/mcp (Lua)
```

The split is deliberate:

* **MAME writes to stdout/stderr all over the place.** An MCP stdio server must keep that
  stream clean, so the supervisor captures MAME's output and re-exposes it through
  `session.status` / `debug.console_log` instead.
* **Blocking belongs outside the emulator.** `exec.wait_for_stop` long-polls in the
  supervisor; blocking inside MAME's loop would deadlock the pump that services requests.
* **Session lifecycle** (start/stop/crash/restart) is far easier in a supervisor.

### Why a Lua plugin works at all

`debugger_cpu::wait_for_debugger()` calls `emulator_info::periodic_check()` →
`lua_engine::on_periodic()` *inside its stop loop* (`src/emu/debug/debugcpu.cpp:453`).
So the plugin's pump keeps servicing RPC **while the CPU is halted at a breakpoint** —
which is the whole ballgame for an interactive debugger.

---

## Quick start

### 1. Build a headless MAME

On a normal machine with `apt`:

```bash
sudo apt-get install -y libsdl2-dev libsdl2-ttf-dev libfontconfig-dev libegl1-mesa-dev
make SUBTARGET=tiny OSD=sdl \
     NO_X11=1 NO_USE_XINPUT=1 NO_OPENGL=1 USE_QTDEBUG=0 \
     NO_USE_MIDI=1 NO_USE_PORTAUDIO=1 NO_USE_PULSEAUDIO=1 NO_USE_PIPEWIRE=1 \
     NOWERROR=1 ARCHOPTS_CXX=-DUSE_OZONE=1 ARCHOPTS_C=-DUSE_OZONE=1 \
     -j$(nproc)
```

In a sandbox where `apt` is blocked, `tools/dev/bootstrap-headless-build.sh` stages the
dependencies from GitHub/PyPI and prints the same command.

⚠️ **Build gotchas** (all explained in [`PLAN.md` §11.5](PLAN.md)):

| Flag | Why |
|---|---|
| `ARCHOPTS_CXX` / `ARCHOPTS_C`, **not** `ARCHOPTS` | `ARCHOPTS` overrides the arch flag and silently produces a broken `-m32` build |
| `-DUSE_OZONE=1` | bgfx is linked unconditionally and its EGL header pulls in `X11/Xlib.h` even with `NO_X11=1` |
| `NOWERROR=1` | GCC 12 `-Werror=restrict` false positives; it is a *generate*-time option |
| `-j1` under ~3 GB RAM/job | GCC needs >2 GB on `emumem_aspace.cpp`; at `-j2` on 4 GB it OOM-thrashes |

### 2. Install the server

```bash
cd tools/mcp-server && npm install
```

### 3. Point it at your ROMs and run

```bash
export MAME_DIR=/path/to/mame-mcp        # defaults to the repo root
export MAME_BINARY=$MAME_DIR/mametiny
export MAME_ROMPATH=$MAME_DIR/roms
node tools/mcp-server/src/index.mjs
```

### 4. Register with an MCP client

```json
{
  "mcpServers": {
    "mame": {
      "command": "node",
      "args": ["/path/to/mame-mcp/tools/mcp-server/src/index.mjs"],
      "env": {
        "MAME_DIR": "/path/to/mame-mcp",
        "MAME_BINARY": "/path/to/mame-mcp/mametiny",
        "MAME_ROMPATH": "/path/to/roms"
      }
    }
  }
}
```

---

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `MAME_BINARY` | `./mametiny` | MAME executable |
| `MAME_DIR` | repo root | working directory; also where `plugins/` is found |
| `MAME_ROMPATH` | `roms` | ROM search path |
| `MAME_MCP_ARTIFACTS` | `$TMPDIR/mame-mcp-artifacts` | screenshots, save states, scratch files |
| `MAME_MCP_SOCKET` | `domain.<tmp>/mame-mcp-*.sock` | plugin socket (set by the supervisor) |
| `SDL_VIDEODRIVER` | `dummy` | not strictly required — SDL autodetects `offscreen` — but avoids probing x11/wayland/KMSDRM at every start |

---

## The agent loop

The intended usage pattern, and what the tool descriptions steer a model toward:

```
session.start          →  boot the driver headless
machine.describe       →  the memory map the driver already knows
bp.set / wp.set        →  arm a trap
exec.resume            →  let it run
exec.wait_for_stop     →  block until it traps (supervisor-side)
cpu.registers          →  who did it?
mem.read               →  what did they see?
cpu.disassemble        →  what is the code?
annot.add              →  record the finding (MAME persists it per-ROM)
```

Memory and registers are only coherent while **stopped**. `mem.read` on a free-running CPU
returns a torn snapshot.

---

## Testing

```bash
# 1. Pure Lua logic: base64, hexdump, address parsing, JSON-RPC framing.
#    No MAME required. Needs any Lua 5.4.
lua54 plugins/mcp/test/test_util.lua

# 2. MCP protocol: tool registration, schemas, annotations, error handling.
#    No MAME binary required.
cd tools/mcp-server && node test/protocol.mjs

# 3. End-to-end agent workflow. Needs a build and ROMs.
MAME_SMOKE_DRIVER=wrally node test/smoke.mjs

# 4. Coverage audit: invoke every registered tool, fail if any is missed.
MAME_SWEEP_DRIVER=wrally node test/full-sweep.mjs
```

---

## Phase 3: graphics, disassembly and coverage bindings

Two C++ modules add capabilities that had no Lua route at all:

* **`src/frontend/mame/luaengine_gfx.cpp`** — binds `gfx_element`,
  `device_gfx_interface` and `tilemap_t`. MAME already decodes each driver's graphics,
  but the only consumer was the interactive F4 tile viewer, and there is no `gfx`
  debugger command — so on a headless build the decoded pixels were unreachable.
  Powers `gfx.list_sets`, `gfx.render_tiles`, `gfx.list_tilemaps`, `gfx.render_tilemap`
  and `gfx.palette`. Tile sheets come back as inline PNGs, so a multimodal agent can
  *see* what a ROM contains.
* **`src/frontend/mame/luaengine_dasm.cpp`** — binds `debug_disasm_buffer`, giving
  structured `{address, bytes, text, size, step_over, step_out}` records. Those two
  flags come from the disassembler itself, which is what makes control-flow following
  possible without parsing mnemonics. Powers `dasm.at`, `dasm.range` and
  `dasm.function`.

Hooking these in touched only six lines of existing code (two each in
`luaengine.h`, `luaengine.cpp` and `scripts/src/mame/frontend.lua`); the accessors
(`device.gfx`, `device.disasm`, `machine.tilemaps`) are registered from inside the new
modules themselves.

* **`src/frontend/mame/luaengine_cov.cpp`** — binds PC-coverage tracking, memory-write
  attribution and the PC history ring. MAME's `trackpc` console command is a *write-only
  switch*: nothing in `debugcmd.cpp` ever reads the visited set back (only `dvdisasm.cpp`
  queries it one address at a time to shade the disassembly view), so `debug.command`
  could start tracking but never report the result. Powers `cov.track_pc_start/stop`,
  `cov.visited_map`, `cov.visited`, `cov.track_mem_start/stop`, `cov.pc_at` and
  `cov.history`.

`cpu.disassemble` is retained for compatibility but `dasm.range` is preferred.

### An upstream bug this surfaced

`device_debug::compute_debug_flags()` did not consider `m_track_pc` / `m_track_mem` when
deciding whether to request `DEBUG_FLAG_CALL_HOOK`. Since coverage is recorded inside
`instruction_hook()`, enabling tracking **silently recorded nothing** unless some other
feature (a breakpoint, a trace, single-stepping) happened to have requested the hook
already. Fixed in `src/emu/debug/debugcpu.cpp`, and `set_track_pc()`/`set_track_mem()`
now recompute the flags so the change takes effect immediately.

### Coverage sweep accuracy

`cov.visited_map` defaults to an exhaustive **byte-wise** probe. `track_pc_visited()` keys
on *(address, opcode crc32)*, so probing non-instruction addresses simply returns false and
nothing can be missed. A faster `mode:"instruction"` steps via the disassembler, but its
alignment need not match what the CPU actually executed — measured in practice: a machine
whose PC history showed execution at `0xA39C` had that address skipped entirely by an
instruction-stepped sweep starting at `0x0000`.

Note that `limit` caps how many **addresses** are examined, not how many are found. Set it
to cover the whole requested range or the sweep truncates early and under-reports; the
result reports `truncated` so you can tell.

## Verified end-to-end against a real ROM

Run on 2026-08-27 with **World Rally** (Gaelco 1993 — 68000 + DS5002FP, 16384 sprites,
2 tilemaps, OKIM6295) on the `OSD=headless` build, no X and no framebuffer:

```
tools registered : 67
tools invoked    : 67
  succeeded      : 71
  FAILED         : 0
ALL TOOLS EXERCISED SUCCESSFULLY
```

`tools/mcp-server/test/full-sweep.mjs` is a coverage audit rather than a workflow test:
it invokes **every registered tool** and fails if any is left uninvoked, so a tool cannot
silently rot.

Highlights from that run:

* boots at ~800 % of real time; screenshot is a genuine 368×232 frame with 84 distinct
  colours (verified by decoding the PNG's IDAT, not just its header)
* `gfx.render_tiles` → 256×128 sheet from a 16×16 ×16384 16bpp sprite set
* `gfx.render_tilemap` → 1024×512 composed tilemap
* `dasm.range` → real 68000, e.g. `move.b $fec1fc.l, D0` / `beq $2770`
* `dasm.function` → swept 19 instructions, `terminated=true`, 2 call targets

### The coverage workflow, for real

The reason `cov.*` exists — diffing execution between two game phases:

| phase | addresses | ranges |
|---|---|---|
| A: boot / attract | 536 | 536 |
| B: after coin + start | 1008 | 1008 |
| **new in B only** | **472** | — |

472 addresses of code that only runs once a credit is inserted, isolated in one step and
immediately disassemblable. That is the "partition an unknown ROM" workflow working on
real hardware.

### ROM notes

MAME is strict about ROM sets, and two wrinkles are worth knowing:

* This MAME revision renamed wrally's two 68000 program ROMs
  (`worldr16.c22`/`worldr17.c23` → `invers_taula_c22/c23_...`). The data is identical;
  only the expected filenames changed.
* The `plds` region (3 PALs/GALs) is **documentation-only** — the driver never reads it,
  and one entry is `NO_DUMP`, so a "complete" set cannot exist. MAME still refuses to boot
  without the files present, so placeholders are required. They cannot affect emulation.

## Known limitations

* **Stop events are detected by scraping the debugger console log** for
  `"Stopped at breakpoint N"`, exactly as `plugins/gdbstub` does. `triggered_breakpoint()` /
  `triggered_watchpoint()` are not exposed to Lua. This is the most brittle part of the stack.
* **Bulk memory reads are byte-at-a-time through Lua**, so very large reads are slow.
* **One session per server process.**
* **`dasm.function` is a linear sweep**, not a control-flow walk: it stops at the first
  end-of-flow instruction and does not follow branches, so treat its extent as a first
  approximation.

### Upstream bug worth knowing

`cpu.debug:bpset(addr)` **segfaults** MAME: the binding at
`src/frontend/mame/luaengine_debug.cpp:415` takes `char const *cond, char const *act`
with no defaults, so the one-argument form passes null pointers. The plugin therefore
**always** passes all three arguments. The same shape affects `wpset`.
A proper fix is `sol::optional` defaults upstream.
