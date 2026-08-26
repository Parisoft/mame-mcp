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

# 3. End-to-end against a real emulator. Needs a build (and ideally ROMs).
MAME_SMOKE_DRIVER=gridlee node test/smoke.mjs
```

---

## Known limitations (Phase 1)

These are the things Phase 3 of the plan addresses by moving into C++:

* **Stop events are detected by scraping the debugger console log** for
  `"Stopped at breakpoint N"`, exactly as `plugins/gdbstub` does. `triggered_breakpoint()` /
  `triggered_watchpoint()` are not exposed to Lua. This is the most brittle part of Phase 1.
* **Disassembly goes through the `dasm` command**, which writes a file we then parse back.
  There is no Lua binding for `debug_disasm_buffer`.
* **No decoded-graphics tools.** `gfx_element`, `device_gfx_interface` and `tilemap_t` have
  no Lua bindings, so `gfx.render_tiles` / `gfx.render_tilemap` are not available yet.
  These are among the highest-value tools for ROM work — see [`PLAN.md` §10](PLAN.md).
* **Coverage tracking** (`trackpc`, `trackmem`) is reachable only via `debug.command`.
* **Bulk memory reads are byte-at-a-time through Lua**, so very large reads are slow.
* **One session per server process.**

### Upstream bug worth knowing

`cpu.debug:bpset(addr)` **segfaults** MAME: the binding at
`src/frontend/mame/luaengine_debug.cpp:415` takes `char const *cond, char const *act`
with no defaults, so the one-argument form passes null pointers. The plugin therefore
**always** passes all three arguments. The same shape affects `wpset`.
A proper fix is `sol::optional` defaults upstream.
