# MAME‑MCP: turning this MAME fork into a headless MCP server

**Status:** design proposal — *no source changes made*. Phase 0 spike **executed and passing** (§11).

> **Historical note:** this document records the plan as written before implementation, and
> is deliberately left unedited. Paths here say `tools/mcp-server`; the server now lives at
> `mcp-server/` in the repository root. See the root [README](../../README.md) for the
> as-built layout.
**Audience:** maintainers of `Parisoft/mame-mcp`.
**Goal:** let an Arena agent drive MAME to debug and reverse‑engineer arcade ROMs (breakpoints, memory, VRAM, screenshots, audio capture, tracing) over the Model Context Protocol, with **no X server, no Qt, no BGFX/OpenGL, no interactive UI**.

Base commit: `c29715a9` (MAME 0.289 dev tree).

---

## 1. What is actually in the tree today

A quick map of the parts that matter, because the plan is built entirely on top of them.

### 1.1 Layering

```
src/emu/            emulation core — knows nothing about the host
  debug/            the real debugger engine (debugcpu, debugcmd, express, points, dvmemory…)
  video.cpp         frame pump + snapshot renderer (software, target-independent)
  sound.cpp         mixer + WAV writer
  http.cpp/.h       an existing, mostly-unused HTTP+WebSocket server (webpp + asio)
src/frontend/mame/  "the frontend": cli, luaengine, cheat, mame_machine_manager, ui/
  ui/               ~37k lines of interactive menus — the thing we want out of the way
  luaengine*.cpp    ~5.8k lines of sol2 bindings: machine, memory, debugger, render, input
src/osd/            host layer
  sdl/              osd=sdl: SDL2 windows, events, video_init()
  modules/
    debugger/       debug_module implementations: none, gdbstub, imgui, qt, win, osx
    render/         drawnone, drawsdl, drawogl, drawbgfx, d3d…
    sound/ input/ monitor/ font/ output/ netdev/ midi/
plugins/            Lua plugins (console, gdbstub, cheatfind, json, …)
scripts/            GENie build scripts (scripts/src/osd/*.lua, scripts/target/mame/*.lua)
```

### 1.2 The debugger engine is already headless

Nothing in `src/emu/debug/` needs a GUI. The OSD only supplies a `debug_module`
(`src/osd/modules/debugger/debug_module.h`) with three methods:

```cpp
virtual void init_debugger(running_machine &machine) = 0;
virtual void wait_for_debugger(device_t &device, bool firststop) = 0;  // called in a loop while stopped
virtual void debugger_update() = 0;                                    // called per frame while running
```

`debuggdbstub.cpp` (1738 lines) is the existing proof that a **network‑driven, GUI‑free debugger
backend is a first‑class citizen** — it opens a listening socket via `emu_file("socket.host:port")`
and services packets from `wait_for_debugger()`. That is the template for an MCP backend.

`debugger_commands` (`src/emu/debug/debugcmd.cpp`) already registers ~150 commands:

```
bp bpclear bpdisable bpenable bplist bpset  wp wpset wpclear wplist  rp rpset  ep epset
dasm dump dumpd dumpi dumpo  find fill  save saver load loadr  trace traceover traceflush
history trackpc trackmem pcatmem  map mapd mapi mapo memdump symlist  snap
step over out go gvblank gint gtime gp gbf gbt  focus ignore observe  comadd comsave
images mount unmount  input dumpkbd  softreset hardreset statesave stateload  rewind
cheatinit cheatnext cheatrange cheatlist cheatundo
```

Anything the MCP layer does not natively wrap can still be reached through
`debugger_console::execute_command()` — a guaranteed escape hatch.

### 1.3 The Lua engine already exposes ~80 % of what we need

| Need | Existing binding | Source |
|---|---|---|
| breakpoints | `dev.debug:bpset/bpclear/bplist/bpenable` | `luaengine_debug.cpp:405+` |
| watchpoints | `dev.debug:wpset/wpclear/wplist` | `luaengine_debug.cpp:451+` |
| step/go/state | `dev.debug:step/go`, `debugger.execution_state` | `luaengine_debug.cpp:371+` |
| console log | `debugger.consolelog[i]`, `debugger.errorlog` | `luaengine_debug.cpp:398` |
| arbitrary command | `debugger:command("…")` | `luaengine_debug.cpp:372` |
| expressions | `emu.symbol_table`, `parsed_expression` | `luaengine_debug.cpp:241+` |
| memory r/w | `space:read_u8/…`, `read_range`, `readv_*`, `read_direct_*` | `luaengine_mem.cpp:537+` |
| regions/shares/banks | `mem.regions[":gfx1"]:read(off,len)` etc. | `luaengine_mem.cpp:740+` |
| memory taps | `space:install_read_tap/install_write_tap` | `luaengine_mem.cpp:673` |
| CPU registers | `dev.state[":maincpu"].value` | `luaengine.cpp:1717` |
| screenshot (file) | `screen:snapshot(name)`, `video:snapshot()` | `luaengine.cpp:1967`, `2279` |
| screenshot (raw RGB) | `screen:pixels()`, `video:snapshot_pixels()` | `luaengine.cpp:1997`, `2300` |
| WAV capture | `machine.sound:start_recording(f)/stop_recording()` | `luaengine.cpp:2326` |
| AVI capture | `video:begin_recording/end_recording` | `luaengine.cpp:2280` |
| save states | `machine:save/load/buffer_save/buffer_load` | `luaengine.cpp:1532` |
| inputs | `ioport_field:set_value`, `emu.keypost` | `luaengine_input.cpp:269` |
| pause/step/reset | `emu.pause/unpause/step`, `machine:soft_reset` | `luaengine.cpp:1018` |
| sockets & files | `emu.file("", 7)` + `"socket.host:port"` / `"domain.path"` | `luaengine.cpp:1137`, `posixsocket.cpp` |
| background thread | `emu.thread()` (separate Lua state) | `luaengine.cpp:1235` |
| callbacks | `emu.register_periodic`, `add_machine_frame_notifier`, … | `luaengine.cpp:985+` |

**The single most important find for the design:**
`debugger_cpu::wait_for_debugger()` calls `emulator_info::periodic_check()` **inside its stop loop**:

```cpp
// src/emu/debug/debugcpu.cpp:421-455
while (is_stopped())
{
    m_machine.debug_view().flush_osd_updates();
    emulator_info::periodic_check();          // <-- runs lua_engine::on_periodic()
    …
    m_machine.osd().wait_for_debugger(device, firststop);
```

`emulator_info::periodic_check()` → `lua()->on_periodic()` (`mame.cpp:467`). So **Lua
`register_periodic` callbacks keep running while the CPU is halted at a breakpoint.**
A Lua‑based server can therefore answer "read memory at the breakpoint" requests — the
classic reason people assume you need C++.

### 1.4 What is genuinely missing from Lua

These have **no** bindings and will need new C++ (`luaengine_*.cpp`) if we want them as tools:

* `device_gfx_interface` / `gfx_element` — decoded tile/sprite graphics
  (`src/emu/digfx.h:158`, `src/emu/drawgfx.h:152`). Only `src/frontend/mame/ui/viewgfx.cpp`
  uses them, and it is UI‑only.
* `tilemap_t` / `tilemap_manager` — `pixmap()`, `flagsmap()` (`src/emu/tilemap.h:462`).
* `debug_view_*` (`dvdisasm`, `dvmemory`, `dvstate`) — the formatted disassembly/memory views.
* `debug_disasm_buffer` (`src/emu/debug/debugbuf.h`) — clean programmatic disassembly with
  `STEP_OVER` / `STEP_OUT` flags. Today Lua can only get disassembly by shelling out to the
  `dasm` command, which **writes to a file** (`debugcmd.cpp:4180`).
* registerpoints / exceptionpoints (`rpset`, `epset`) — C++ API exists, no Lua binding.
* `device_debug::trace()` / `track_pc` / `track_mem` / `history_pc` — C++ only.

### 1.5 What actually pulls in X / GUI today

| Dependency | Where | How to drop |
|---|---|---|
| X11, Xinerama, Xext, Xi | `scripts/src/osd/sdl.lua:26-44` | `NO_X11=1 NO_USE_XINPUT=1` |
| Qt6 debugger | `modules.lua:545` (`qtdebuggerbuild()`) | `USE_QTDEBUG=0` (auto‑forced off when `NO_X11=1`, `sdl.lua:260`) |
| OpenGL / GL | `osdmodulestargetconf()` | `NO_OPENGL=1` |
| SDL2_ttf + fontconfig | `sdl.lua:46-53`, `sdlmain.cpp` (`FcInit()`) | replaced by `font_none` in a new OSD |
| BGFX/bimg/bx | linked unconditionally in `scripts/src/main.lua:206` | drop from a new OSD target |
| PortAudio / PortMidi | `main.lua:189-201` | `NO_USE_PORTAUDIO=1 NO_USE_MIDI=1` |
| **`SDL_InitSubSystem(SDL_INIT_VIDEO)`** | `src/osd/sdl/osdsdl.cpp:298` — **unconditional** | needs `SDL_VIDEODRIVER=dummy` **or** a new OSD |
| **window creation** | `sdl_osd_interface::video_init()` (`sdl/video.cpp:47`) creates one `sdl_window_info` per screen and calls `SDL_CreateWindow` (`window.cpp:911`) **even with `-video none`** | needs a new OSD |

⚠️ **`-video none` is not enough.** The `none` renderer (`drawnone.cpp`) is only a *renderer*;
the SDL OSD still initialises the SDL video subsystem and still creates windows. Today the only
zero‑display route is `SDL_VIDEODRIVER=dummy` + `-video none -sound none`, which works but keeps a
hard runtime dependency on libSDL2. A purpose‑built OSD removes that.

### 1.6 Good news: screenshots and WAV do **not** need a window

`video_manager` owns its own hidden snapshot target and a pure‑software renderer:

```cpp
// src/emu/video.cpp:161  — created regardless of OSD
m_snap_target = machine.render().target_alloc(*root, RENDER_CREATE_SINGLE_FILE | RENDER_CREATE_HIDDEN);
// src/emu/video.cpp:1064 — software_renderer<u32,…>::draw_primitives(...)
```

`save_snapshot()` → `util::png_write_bitmap()`. `pixels()` fills a caller buffer.
Likewise `sound_manager::m_wavfile` is written from `sound_manager::update()`
(`sound.cpp:2058`) from `m_record_buffer`, which is filled by `output_push()` —
independent of any OSD sound module. **Both features survive a fully headless build.**
(One item to verify in Phase 0: whether `m_nosound_mode` short‑circuits enough of the
mixer that `m_record_buffer` stops being filled — see §7.)

---

## 2. Architecture decision

### 2.1 Options considered

| # | Approach | Pros | Cons |
|---|---|---|---|
| **A** | Pure **Lua plugin** speaking JSON‑RPC over a TCP/UNIX socket; a tiny external Node/Python process bridges MCP‑stdio ⇄ socket | zero C++ changes; ships today; `emu.file("socket.…")` + `register_periodic` already work; runs while stopped at a breakpoint | Lua polling granularity; no gfx/tilemap/disasm‑buffer access; string‑heavy for bulk memory; socket reads are non‑blocking single‑shot |
| **B** | C++ **`debug_module`** (`-debugger mcp`), modelled on `debuggdbstub.cpp` | full C++ API; correct blocking semantics in `wait_for_debugger` | only alive when `-debug` is on; awkward for non‑debug operations (screenshots while running); reimplements a lot Lua already gives us |
| **C** | New **OSD target** (`osd=headless`) + C++ **MCP bridge module** + Lua tool layer + external MCP front process | truly no SDL/X/Qt link; clean `debugger_update` + `wait_for_debugger` hooks; can add the missing bindings; small stable C++ surface | most work; new build target to maintain |

### 2.2 Recommendation

**Ship A first, converge on C.** Concretely:

* **Phase 1 (days):** Lua plugin `plugins/mcp` + Node bridge `tools/mcp-server`. Prove the whole
  agent loop end‑to‑end with a stock `make NO_X11=1 … SDL_VIDEODRIVER=dummy` build.
* **Phase 2 (weeks):** `osd=headless` build target — no SDL, no X, no BGFX, `font_none`,
  `input_none`, `sound_none`/`sound_wav`, `renderer_none`, and a `monitor_none` module (which
  **does not exist yet** — see §3.3).
* **Phase 3:** move hot paths and the missing capabilities into C++ (`luaengine_gfx.cpp`,
  `luaengine_dasm.cpp`, and a `mcp` debug module), keeping the same MCP tool contract so the
  agent never notices.

**Do not delete `src/frontend/mame/ui/` in phase 1 or 2.** `luaengine.cpp` and
`luaengine_render.cpp` `#include "ui/ui.h"`, `mame.cpp` includes `ui/selgame.h`, and `src/emu/`
itself includes `ui/uimain.h` in six places (`machine.cpp`, `video.cpp`, `render.cpp`,
`ioport.cpp`, `romload.cpp`, `rendfont.cpp`). Removing the UI means either stubbing
`mame_ui_manager` or writing an alternative `machine_manager` — `src/zexall/main.cpp` shows
exactly that pattern (its own `machine_manager` + `emulator_info::*` stubs) and is the reference
if we ever want a `SUBTARGET=mcp` with no `frontend` link at all. Treat it as **Phase 4,
optional**: a headless OSD already means the UI code is never *executed*; deleting it only saves
binary size and build time.

### 2.3 Process topology

```
 Arena agent
     │  MCP (stdio, JSON‑RPC 2.0, spec 2025‑11‑25)
     ▼
 tools/mcp-server            ← Node (or Python) supervisor
   • owns the MCP session, schemas, pagination, content encoding
   • spawns/monitors mame processes (one per "session")
   • JSON-RPC over UNIX socket ──────────────┐
   • serves artifacts (png/wav) as MCP        │
     resources or base64 blobs                │
                                              ▼
                              mame -debugger mcp -video none …
                                └ plugins/mcp/init.lua  (phase 1)
                                └ src/osd/modules/debugger/debugmcp.cpp (phase 3)
```

Why an external supervisor rather than making MAME itself speak MCP on stdio:

* MAME writes to stdout/stderr all over the place (`osd_printf_*`) — it would corrupt an
  MCP stdio stream. The supervisor keeps stdio clean and pipes MAME's stderr to MCP `logging`.
* Session lifecycle (start/stop/restart a driver, ROM auditing, crashes) is much easier in a
  supervisor than inside the emulated process.
* Schema validation, pagination, chunking of huge memory dumps, and artifact hosting are
  ergonomic in Node, painful in Lua/C++.
* It keeps the C++ diff small and rebase‑friendly against upstream MAME.

`src/emu/http.cpp` (webpp + asio HTTP/WebSocket, gated by `-http`) is tempting as a transport, but
it is essentially unmaintained in‑tree, single‑threaded against the emu loop, and only reachable
via `http_manager` from `machine_manager`. Prefer a dedicated UNIX socket. Reconsider it only if
we want browser‑visible screenshot streaming.

---

## 3. Build plan

### 3.1 Phase 1 — headless with stock OSD (no source changes)

```makefile
make -j$(nproc) \
  NO_X11=1 NO_USE_XINPUT=1 NO_OPENGL=1 USE_QTDEBUG=0 \
  NO_USE_MIDI=1 NO_USE_PORTAUDIO=1 NO_USE_PULSEAUDIO=1 NO_USE_PIPEWIRE=1 \
  SUBTARGET=arcade SOURCEFILTER=src/mame/mcp.flt TOOLS=1
```

Runtime:

```bash
SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
  ./mamemcp <driver> -debug -debugger none -video none -sound none \
            -nothrottle -window -plugin mcp
```

A `src/mame/mcp.flt` driver filter (same format as `src/mame/ci.flt`, 17 lines) cuts a ~3 h /
40 GB full build down to minutes. Start with the boards the project cares about, expand later.

### 3.2 Phase 2 — `osd=headless`

New files:

```
scripts/src/osd/headless.lua        (from sdl.lua, minus SDL/X/GL/BGFX/Qt/fontconfig)
scripts/src/osd/headless_cfg.lua
src/osd/headless/headlessmain.cpp   (main() → emulator_info::start_frontend)
src/osd/headless/osdheadless.{h,cpp}(osd_common_t subclass; process_events()/has_focus() stubs)
src/osd/modules/monitor/monitor_none.cpp   ← does not exist upstream; needed
```

`makefile` picks the OSD from `OSD` (default `sdl` on Linux, `makefile:455`), and
`scripts/genie.lua:1373` just `dofile`s `src/osd/<osd>.lua`. So `make OSD=headless` works with
no makefile surgery beyond adding the option to the docs.

`osd_headless` must:

* select `renderer_none`, `sound_none` (or a new `sound_wav`), `input_none`, `font_none`,
  `monitor_none`, `output_none`, `netdev_none`, `midi_none`
  (all already registered in `osdobj_common.cpp:217-330`, except `monitor_none`);
* override `video_init()` to **not** create windows (base `osd_common_t::video_init()` already
  returns `true` and creates nothing — `osdobj_common.cpp:751`);
* keep `debugger_update()` being called from `update()` so the MCP module gets a per‑frame tick.

Modules to add:

* `src/osd/modules/monitor/monitor_none.cpp` — a `monitor_module_base` returning one synthetic
  1920×1080 monitor (needed because `pick_monitor()` is called even when no window is made).
* `src/osd/modules/debugger/debugmcp.cpp` — `MODULE_DEFINITION(DEBUG_MCP, …)`, registered next
  to `DEBUG_GDBSTUB` in `osdobj_common.cpp:286`.

What this removes from the link: SDL2, SDL2_ttf, fontconfig, X11/Xinerama/Xext/Xi, GL, BGFX/bimg/bx,
PortAudio, PortMidi. Expect a substantially smaller binary and a container image with **zero**
graphics packages.

### 3.3 CI

Add a `ci-mcp.yml` workflow mirroring `ci-linux.yml` but with `OSD=headless`,
`SOURCEFILTER=src/mame/mcp.flt`, plus a smoke test that boots a driver, connects the MCP
server, and runs a scripted tool sequence (`set_breakpoint` → `resume` → `wait_for_stop` →
`read_memory` → `screenshot`) against a known ROM. Keep the upstream `ci-linux.yml` intact so
rebases stay cheap.

### 3.4 Repository hygiene

`.gitignore` already ignores everything not explicitly allow‑listed (`/*` + `!/src/` …), so new
top‑level dirs need an entry. Add `!/tools/` (or put the Node server under an existing allowed
path) and make sure `node_modules/`, `build/`, `snap/`, `*.png`, `*.wav`, `*.state`, `*.trace`
never get committed — agents will generate a lot of these.

---

## 4. Concurrency & execution model (the hard part)

MAME's main loop is single‑threaded and, when stopped at a breakpoint, it is *inside*
`wait_for_debugger()`. Any MCP design has to define, for every tool, **which of three states it
may run in**:

| State | How we get ticks | Safe operations |
|---|---|---|
| **RUNNING** | `debugger_update()` each frame; `lua on_periodic` | read/write memory (racy but fine), screenshots, WAV start/stop, set breakpoints, inputs, pause |
| **STOPPED** (breakpoint hit) | `emulator_info::periodic_check()` **and** `osd().wait_for_debugger()` inside the stop loop | everything; this is the coherent state for disassembly, registers, stack walking |
| **PAUSED** (`machine:pause()`) | `update()` still runs (`update_in_pause` option) | screenshots, memory reads; scheduler is not advancing |

Design rules:

1. **The socket is drained from both hooks.** In Lua: `emu.register_periodic(pump)`. In C++:
   the same `pump()` called from `debugger_update()` *and* from `wait_for_debugger()`.
   This is exactly what `debuggdbstub` does.
2. **Tool calls are queued, never executed on the socket thread.** No emu API may be touched
   outside the pump.
3. **Two flavours of "run" tools:**
   * *fire‑and‑forget*: `resume`, `step`, `step_over`, `run_to` return immediately with the new
     execution state;
   * *blocking*: `wait_for_stop(timeout_ms)` — implemented in the **supervisor**, not in MAME:
     it long‑polls the socket for a `stopped` event and emits MCP progress notifications so the
     agent's client doesn't time out. Never block inside the emu loop.
4. **Events are pushed, not polled.** The bridge emits `{"event":"stopped","reason":"breakpoint",
   "index":3,"pc":"0x1a2c","device":":maincpu"}` derived from `device_debug::triggered_breakpoint()` /
   `triggered_watchpoint()` (C++) or from parsing `debugger.consolelog` (Lua, as `plugins/gdbstub`
   does today — brittle; a reason to move to C++).
5. **Determinism knobs the agent controls:** `-nothrottle`, `throttle_rate`, `frameskip`,
   `-seconds_to_run`, save‑state checkpointing, `machine:buffer_save()` for cheap
   snapshot/restore around experiments. Also expose the rewind buffer (`-rewind`).

---

## 5. Proposed MCP tool surface

Targeting MCP revision **2025‑11‑25** (structured tool output, resource links, tool annotations).
Naming: `<domain>.<verb>`, snake‑case args. Every tool declares
`annotations: {readOnlyHint, destructiveHint, idempotentHint}` so clients can gate the dangerous ones.

Conventions used below:
`R` = read‑only · `W` = mutates emulation state · `S` = state‑machine (may change run/stop) ·
`⚡` = needs new C++ binding (not reachable from today's Lua).

### 5.1 Session & machine

| Tool | Kind | Description |
|---|---|---|
| `session.list_drivers` | R | Search the driver list (`driver_list::find`, `-listxml`) by name/description/manufacturer/year. Paginated. |
| `session.start` | S | Launch a MAME process for a driver. Args: `driver`, `bios`, `slots`, `software`, `no_throttle`, `seconds_to_run`, `autoboot_script`, `extra_args[]`. Returns `session_id`, ROM audit result, screen list, CPU list. |
| `session.stop` / `session.restart` | S | Terminate / relaunch, optionally restoring a save state. |
| `session.status` | R | Phase, `machine.time`, frame number, speed %, paused, execution state, current PC per CPU. |
| `session.reset` | W | `machine:soft_reset()` / `schedule_hard_reset()`. |
| `session.audit_roms` | R | Run `-verifyroms` for the driver; report missing/bad files. Saves the agent from mystery boot failures. |
| `machine.describe` | R | The single most valuable "orientation" tool: device tree (`machine.devices`), CPU types + endianness + address widths, address spaces and their `map` entries (`space.map` → `addrmap`/`mapentry`: `addrstart/addrend/read/write/share/region/region_offset`), memory regions with sizes/CRCs, screens, palettes, gfx sets, tilemaps, `ioport` ports & fields. This is the ROM‑hacker's memory map, generated from the driver itself. |
| `machine.options` | R/W | Read/modify a safe allow‑list of `emu_options` at runtime. |

### 5.2 Execution control

| Tool | Kind | Description |
|---|---|---|
| `exec.state` | R | `"running" | "stopped" | "paused"` + which device is the "visible CPU". |
| `exec.pause` / `exec.resume` | S | `machine:pause()` / `debugger.execution_state = "run"`. |
| `exec.step` | S | `device_debug::single_step(n)` (`debugcpu.h:69`). |
| `exec.step_over` | S | `single_step_over(n)`. |
| `exec.step_out` | S | `single_step_out()`. |
| `exec.run_to` | S | `go(addr)`. |
| `exec.run_until_vblank` | S | `go_vblank()`. |
| `exec.run_until_interrupt` | S | `go_interrupt(irqline)`. |
| `exec.run_until_exception` | S ⚡ | `go_exception(exc, cond)`. |
| `exec.run_for` | S | `go_milliseconds(ms)` — emulated‑time bounded run; the safest "advance a bit" primitive for agents. |
| `exec.run_frames` | S | N frames via `add_machine_frame_notifier` / `screen:frame_number()`. |
| `exec.next_device` | S | `go_next_device()` — invaluable on multi‑CPU boards. |
| `exec.wait_for_stop` | R | Supervisor‑side long poll; returns the stop event (reason, bp/wp index, PC, disasm at PC, register snapshot). |
| `exec.set_focus` | W | `focus`/`ignore`/`observe` a CPU so only one core traps. |

### 5.3 Breakpoints & friends

| Tool | Kind | Description |
|---|---|---|
| `bp.set` | W | `breakpoint_set(addr, condition, action)`. Conditions are full debugger expressions (`{A0}==0x1234 && b@0x8000!=0`). |
| `bp.list` / `bp.clear` / `bp.enable` / `bp.disable` | W | Per index or all; across all CPUs. |
| `wp.set` | W | `watchpoint_set(space, "r"|"w"|"rw", addr, len, cond, action)`. The workhorse for "who writes this VRAM byte?". |
| `wp.list` / `wp.clear` / `wp.enable` / `wp.disable` | W | |
| `rp.set` / `rp.list` / `rp.clear` | W ⚡ | Registerpoints — break when an expression becomes true (`registerpoint_set`, `debugcpu.h:112`). No Lua binding today. |
| `ep.set` / `ep.list` / `ep.clear` | W ⚡ | Exceptionpoints — break on CPU exception/trap number (`exceptionpoint_set`). Great for finding interrupt/illegal‑op handlers. |
| `bp.set_temporary` | W | One‑shot bp whose `action` is `bpclear <n>` — sugar over `bpset`. |

### 5.4 Memory

| Tool | Kind | Description |
|---|---|---|
| `mem.read` | R | `{device, space:"program|data|io|opcodes", address, length, element_size, mode:"logical|physical|direct"}`. Returns base64 + a hex+ASCII rendering. Chunked, with `nextCursor`. Backed by `read_range` / `mem_read` / `log_mem_read` / `direct_mem_read`. |
| `mem.write` | W | Same addressing, base64 payload. `destructiveHint: true`. |
| `mem.fill` | W | `fill`/`filld`/`filli`/`fillo`. |
| `mem.search` | R | `find` command semantics: byte/word/dword patterns, wildcards, strings. Returns addresses + context. The core of "where is the score stored?". |
| `mem.compare_snapshots` | R | Take two labelled RAM snapshots and diff them (the `cheatfind` workflow, `plugins/cheatfind/init.lua`) — changed/unchanged/increased/decreased. Enormous for locating game variables without any prior knowledge. |
| `mem.region_read` | R | Read a ROM region directly (`mem.regions[":maincpu"]:read(off,len)`) — the *file* bytes, unaffected by banking. Essential for static disassembly. |
| `mem.list_regions` | R | Regions with name/size/width/endianness. |
| `mem.list_shares` / `mem.list_banks` | R | RAM shares (often the actual VRAM/spriteram) and bank entries. |
| `mem.dump_to_file` | W | `save`/`saver` — dump a range or a whole region to a host file, returned as an MCP resource link (avoids blowing the context window). |
| `mem.load_from_file` | W | `load`/`loadr`. |
| `mem.watch_tap` | W | Install a read/write tap (`install_read_tap`) that logs `(pc, addr, data)` to a ring buffer; `mem.tap_read` drains it. Cheaper than a watchpoint when you want *many* hits rather than a stop. |
| `mem.pc_at` | R | `pcatmem` — which PC last touched this address (requires `trackmem`). Direct answer to "what code wrote here?". |

### 5.5 CPU state, disassembly, symbols

| Tool | Kind | Description |
|---|---|---|
| `cpu.list` | R | Every `device_execute_interface`: tag, family, clock, spaces, PC symbol. |
| `cpu.registers` | R | All `device_state_entry`s with symbol, value, and formatted string. |
| `cpu.set_register` | W | |
| `cpu.disassemble` | R ⚡ | `{device, address, count | length, show_bytes, show_comments}` → structured `[{pc, bytes, text, size, flags:{step_over,step_out}}]`. Should be backed by `debug_disasm_buffer` (`debugbuf.h`) rather than the file‑writing `dasm` command. **This is the #1 tool for the stated goal and needs a new binding.** |
| `cpu.disassemble_function` | R ⚡ | Follow from an entry point until RET/unconditional branch, recording call/jump targets — a recursive‑descent helper built on the `STEP_OVER`/`STEP_OUT` disasm flags. |
| `cpu.call_history` | R ⚡ | `device_debug::history_pc(i)` — the last N PCs. Gold for "how did we get here?". |
| `cpu.stack_guess` | R | Heuristic backtrace: read SP, disassemble around plausible return addresses. Best‑effort, clearly labelled. |
| `sym.eval` | R | Evaluate a debugger expression in a device context (`parsed_expression`). |
| `sym.list` | R | `symlist` — built‑in and user symbols. |
| `sym.define` | W | Add a named symbol (`symbol_table:add`). |
| `annot.add` / `annot.list` / `annot.remove` / `annot.save` | W | `comment_add/comment_remove/comment_text/comment_export` (`debugcpu.h:127`). **Persistent, address‑keyed comments — the agent's disassembly notebook**, and MAME already saves them per‑ROM. |

### 5.6 Tracing & coverage (the disassembly accelerators)

| Tool | Kind | Description |
|---|---|---|
| `trace.start` / `trace.stop` | W | `device_debug::trace(file, trace_over, detect_loops, logerror, action)`. Returns the trace as a resource link, plus a tail preview. |
| `trace.log` | W | `tracelog`/`tracesym` — inject formatted values into the trace at chosen points. |
| `cov.track_pc_start` / `cov.track_pc_stop` | W ⚡ | `set_track_pc(true)` + `track_pc_visited()` — **executed‑address coverage**. Diffing coverage between "attract mode" and "in game" instantly partitions the ROM into subsystems. Highest‑value RE tool in the list after `cpu.disassemble`. |
| `cov.visited_map` | R ⚡ | Export the visited set as ranges / a bitmap, and as a resource link. |
| `cov.track_mem_start/stop` | W ⚡ | `set_track_mem(true)`; feeds `mem.pc_at`. |
| `trace.log_tail` | R | `debugger.consolelog` / `errorlog` tail — also carries `logerror()` output from the driver, which often names hardware registers. |

### 5.7 Video, VRAM and graphics

| Tool | Kind | Description |
|---|---|---|
| `video.screenshot` | R | Composited frame via `video_manager::save_snapshot()`. Returns MCP `image` content (PNG, base64) **and** a resource link. Args: `screen`, `scale`, `format`, `return_inline`. Works fully headless (§1.6). |
| `video.pixels` | R | Raw `screen:pixels()` ARGB buffer for programmatic diffing (hashes, region compare) without decoding PNG. |
| `video.record_start` / `video.record_stop` | W | AVI/MNG via `video:begin_recording()`. |
| `video.screens` | R | Screens with visible area, refresh, orientation, palette info. |
| `video.wait_frames` | S | Advance N frames then screenshot — the "did my patch change the display?" loop. |
| `vram.read` | R | Convenience wrapper over `mem.read` bound to the tagged VRAM share/region (e.g. `:videoram`, `:spriteram`, `:colorram`) discovered by `machine.describe`. |
| `gfx.list_sets` | R ⚡ | Every `device_gfx_interface` and its `gfx_element`s: index, tile w/h, element count, bit depth, colour granularity, total colours (`drawgfx.h:157-175`). |
| `gfx.render_tiles` | R ⚡ | Render a range of decoded tiles from a gfx set into a PNG sheet at a chosen palette offset — the headless equivalent of MAME's F4 tile viewer (`ui/viewgfx.cpp`). **The single best tool for "what graphics does this ROM contain?"** |
| `gfx.render_tilemap` | R ⚡ | `tilemap_t::pixmap()` → PNG, plus `flagsmap()` as a priority/attribute overlay (`tilemap.h:462`). |
| `gfx.palette` | R | `device_palette_interface`: entries, adjusted RGB list, indirect entries, shadow/highlight config (already bound, `luaengine.cpp:1758`). Return as JSON and as a swatch PNG. |
| `gfx.decode_from_bytes` | R ⚡ | Apply an arbitrary `gfx_layout` (planes/offsets/strides) to a byte range from a region and render it. Lets the agent *hypothesise* a tile format for undecoded ROM data and see the result immediately — a headless "Tile Molester". |
| `gfx.find_tilemap_source` | R | Combine `wp.set` on a tilemap's RAM with `mem.pc_at` to identify the code that draws it. Composite/recipe tool. |

### 5.8 Audio

| Tool | Kind | Description |
|---|---|---|
| `audio.record_start` | W | `sound_manager::start_recording(path)` → `.wav`. |
| `audio.record_stop` | W | Returns the WAV as an MCP resource link (+ duration, sample rate, channel count). Optionally inline base64 for short clips. |
| `audio.record_window` | W | Sugar: start, run N frames / until a breakpoint, stop, return the file. The natural way to answer "what does this sound command play?". |
| `audio.devices` | R | Sound devices via `machine.sounds` / `device_sound_interface` (inputs, outputs, routes) — the sound chip inventory. |
| `audio.mute` / `audio.set_volume` | W | `sound.muted`, `system_mute`, per‑device gains. |
| `audio.trigger_command` | W | Recipe: write a value to the sound‑latch address, run N frames, capture WAV. Systematically enumerates a game's sound table. |
| `audio.samples_hook` | R ⚡ | Tap `emulator_info::sound_hook()` / `emu.register_sound_update` to grab raw per‑device sample buffers without the WAV round‑trip. |

### 5.9 Input

| Tool | Kind | Description |
|---|---|---|
| `input.list_ports` | R | Ports and fields with types, masks, player, names (`luaengine_input.cpp:237+`). |
| `input.press` | W | `field:set_value()` for N frames then release — coin, start, buttons, directions. |
| `input.set_dip` | W | Set DIP/config switches; combine with `session.restart` for service‑mode exploration. |
| `input.type_text` | W | `emu.keypost()` for keyboard systems. |
| `input.playback` / `input.record` | W | `-playback` / `-record` `.inp` files for reproducible repro cases. |

### 5.10 State management

| Tool | Kind | Description |
|---|---|---|
| `state.save` / `state.load` | W | Slot or named file (`machine:save/load`). |
| `state.checkpoint` / `state.restore` | W | In‑memory via `buffer_save`/`buffer_load` — fast experiment scaffolding: checkpoint, patch memory, observe, restore. |
| `state.rewind` | W | `rewind` step‑back if `-rewind` is enabled. |

### 5.11 Escape hatch & housekeeping

| Tool | Kind | Description |
|---|---|---|
| `debug.command` | W | Raw `debugger_console::execute_command()` + captured console output. Annotate `destructiveHint: true`. Guarantees the agent is never blocked by a missing wrapper, and tells us which wrappers to add next (log usage). |
| `debug.help` | R | `help <topic>` — MAME's own command reference (`debughlp.cpp`), so the agent can self‑serve syntax for `debug.command`. |
| `artifacts.list` / `artifacts.get` | R | Enumerate/fetch files this session produced (png/wav/avi/trace/dump), as MCP resources. |

### 5.12 MCP resources & prompts

Beyond tools, expose:

* **Resources:** `mame://session/{id}/machine.json` (the memory map), `mame://session/{id}/artifacts/*`,
  `mame://driver/{name}/listxml`, and the annotation file — so large artefacts are referenced,
  not pasted.
* **Prompts:** ready‑made workflows, e.g. *"Find the code that draws the score"*,
  *"Map the sound command table"*, *"Identify the tile format of an undecoded region"*,
  *"Bisect a crash with save states"*. These encode the recipe tools above into a repeatable plan.

---

## 6. Suggested MCP tool schema conventions

* **Addresses** accept `"0x1a2c"`, `"1a2c"`, decimal, *or* a debugger expression (`"pc+4"`,
  `"maincpu.pc"`). Always echo the resolved numeric value in the result.
* **Device selection** defaults to the "visible CPU"; every tool takes an optional `device` tag.
* **Bulk data** is never returned as raw JSON arrays. Use `{encoding:"base64", data, address,
  length, element_size, endianness}` plus an optional pre‑rendered `hexdump` string capped at a
  few KB, and a `resource_link` for anything bigger. Honour `nextCursor` pagination.
* **Images** use MCP `image` content blocks (`image/png`) with a size guard (downscale or link
  above ~1 MB).
* **Errors** are tool execution errors with actionable text (per SEP‑1303, so the model can
  self‑correct), e.g. `"no address space 'io' on ':audiocpu'; available: program, data"`.
* **Structured output** (`outputSchema`) on everything — agents reason far better over
  `{pc, bytes, text}` than over a formatted blob.

---

## 7. Risks, unknowns and validation tasks

| # | Risk / unknown | Validation |
|---|---|---|
| 1 | **WAV capture with `-sound none`.** `m_nosound_mode = machine.osd().no_sound()` (`sound.cpp:70`) disables the effects thread and `mapping_update()`. `m_record_buffer` is filled in `output_push()` and consumed at `sound.cpp:2058`. Need to confirm the mixer still runs. | Boot a driver with `-sound none -wavwrite out.wav` and inspect the file. If it fails, add a `sound_wav` OSD module (a `sound_none` that keeps the pipeline alive) — small, self‑contained. |
| 2 | **Snapshot without any OSD window.** `m_snap_target` is a hidden render target, but `render_manager::set_ui_target()` is only set for non‑hidden targets (`render.cpp:1014`), and `ui_target()` asserts non‑null. A truly window‑less OSD may trip that assert via `emulator_info::draw_user_interface()`. | Test early. Mitigation: the headless OSD allocates one hidden 640×480 target, or the headless `machine_manager` returns a no‑op `ui_manager` (the `zexall` pattern) so `draw_user_interface` never touches `ui_target()`. |
| 3 | **Lua socket semantics.** `posix_osd_socket::read()` is non‑blocking single‑shot and a listening socket "accepts" on first read (`posixsocket.cpp:88`), one client only. | Fine for one supervisor. Frame message boundaries explicitly (length‑prefixed or NDJSON) and reassemble across polls, as `plugins/gdbstub` does. |
| 4 | **Stop‑event detection in Lua** requires scraping `debugger.consolelog` for `"Stopped at breakpoint N"` (`plugins/gdbstub/init.lua:99`). Locale/format fragile. | Acceptable for Phase 1; fix properly in the C++ module using `triggered_breakpoint()`/`triggered_watchpoint()`. |
| 5 | **Latency.** Lua `register_periodic` runs once per `frame_update`/stop iteration; ~16 ms granularity while running. | Fine for agent interaction. For chatty workloads move the pump to C++ and/or batch tool calls. |
| 6 | **Build time / disk.** A full MAME build is hours and tens of GB. | `SOURCEFILTER` + `SUBTARGET` per project; cache `build/` in CI; ship a prebuilt container. |
| 7 | **Upstream rebase friction.** Every line touched in `src/emu` or `src/osd` is a future conflict. | Keep changes **additive**: new files under `src/osd/headless/`, `src/osd/modules/debugger/debugmcp.cpp`, `src/frontend/mame/luaengine_gfx.cpp`, `plugins/mcp/`, `tools/mcp-server/`. Only three shared files need edits: `osdobj_common.cpp` (2 `REGISTER_MODULE` lines), `scripts/src/osd/modules.lua` (file lists), `scripts/src/frontend.lua` (new luaengine files). |
| 8 | **Safety.** Tools can write memory, write host files, and spawn processes. | Sandbox all paths under a per‑session directory; allow‑list emu options; require `destructiveHint` on writes; rate‑limit; never let `session.start` take a raw command line without filtering. |
| 9 | **Licensing.** MAME is BSD‑3‑Clause/GPL‑mixed; every new file needs the `// license:BSD-3-Clause` header (enforced by `.github/workflows/includeguards.yml` conventions and `srcclean`). | Run `srcclean` and keep headers/include guards in the MAME style. |
| 10 | **Multi‑CPU confusion.** Agents will forget which CPU they're on. | Always return the device tag in every result; make `machine.describe` the mandatory first call in the server's instructions. |

---

## 8. Phased delivery

### Phase 0 — spike — ✅ **DONE, all green**
Executed on 2026‑08‑26 against `SUBTARGET=tiny`, MAME 0.289, GCC 12.2, in a container with
**no X, no Wayland, no framebuffer, no `/dev/dri`, no Xvfb**. Results in §11.
Risks 1 and 2 are **retired** — both features work fully headless.

### Phase 1 — working MCP over Lua (1–2 weeks)
* `plugins/mcp/{init.lua,plugin.json}` — JSON‑RPC over a UNIX socket, pumped from
  `emu.register_periodic`, reusing `plugins/json`.
* `tools/mcp-server/` — Node MCP server (stdio): session supervisor, schemas, chunking,
  artifacts, `wait_for_stop` long polling.
* Tools shipped: everything in §5 **not** marked ⚡ — i.e. full execution control, breakpoints,
  watchpoints, memory read/write/search/dump, regions/shares/banks, registers, symbols,
  screenshots, WAV, inputs, save states, `debug.command`, `machine.describe`.
* Docs: `docs/mcp/README.md`, `docs/mcp/tools.md`, plus `docs/source/plugins/mcp.rst` in the
  MAME docs style.

### Phase 2 — `osd=headless` (1–2 weeks)
* New OSD target + `monitor_none`; drop SDL/X/Qt/BGFX/GL/fontconfig from the link.
* CI workflow + smoke test.
* Container image with no graphics packages.

### Phase 3 — C++ where it counts (2–4 weeks)
* `src/osd/modules/debugger/debugmcp.cpp` — proper stop events, blocking pump, no log scraping.
* `src/frontend/mame/luaengine_gfx.cpp` — `gfx_element`, `device_gfx_interface`, `tilemap_t`
  bindings → unlocks `gfx.*` and `vram` tooling.
* `src/frontend/mame/luaengine_dasm.cpp` — `debug_disasm_buffer` binding → real
  `cpu.disassemble`, `cpu.disassemble_function`, `cpu.call_history`.
* Registerpoints, exceptionpoints, `trace`, `track_pc`, `track_mem` bindings → `rp.*`, `ep.*`,
  `cov.*`.
* Bulk memory over a binary path (base64 of a memcpy, not per‑byte Lua calls).

### Phase 4 — optional slimming
* `SUBTARGET=mcp` with its own `machine_manager` (the `src/zexall/main.cpp` pattern) that never
  instantiates `mame_ui_manager`, allowing `src/frontend/mame/ui/` to be excluded from the build
  entirely. Purely a size/build‑time optimisation — evaluate the maintenance cost against the
  benefit before doing it.

---

## 9. Concrete file inventory (all additive unless noted)

```
docs/mcp/PLAN.md                                   (this file)
docs/mcp/README.md                                 usage, quickstart, container
docs/mcp/tools.md                                  generated tool reference
docs/source/plugins/mcp.rst                        MAME-style plugin docs

plugins/mcp/init.lua                               Phase 1 server core
plugins/mcp/plugin.json
plugins/mcp/rpc.lua                                framing + dispatch
plugins/mcp/handlers/{exec,mem,bp,video,audio,…}.lua

tools/mcp-server/package.json                      Node MCP (stdio) supervisor
tools/mcp-server/src/{index,session,schemas,artifacts,transport}.ts

src/mame/mcp.flt                                   driver filter for fast builds

src/osd/headless/headlessmain.cpp                  Phase 2
src/osd/headless/osdheadless.{h,cpp}
src/osd/headless/headlessopts.{h,cpp}
scripts/src/osd/headless.lua
scripts/src/osd/headless_cfg.lua
src/osd/modules/monitor/monitor_none.cpp

src/osd/modules/debugger/debugmcp.cpp              Phase 3
src/frontend/mame/luaengine_gfx.cpp
src/frontend/mame/luaengine_dasm.cpp

.github/workflows/ci-mcp.yml

# modified (small, additive edits only):
src/osd/modules/lib/osdobj_common.cpp              +2 REGISTER_MODULE lines
scripts/src/osd/modules.lua                        + new module source files
scripts/src/frontend.lua                           + new luaengine_*.cpp
.gitignore                                         allow tools/, ignore artifacts
makefile / docs                                    document OSD=headless
```

---

## 10. Why this tool set specifically helps ROM disassembly

The tools above are ordered by leverage for the stated goal. Ranked:

1. **`cov.track_pc_*` + coverage diffing** — partitions an unknown ROM into functional regions by
   observing which addresses execute during which game phase. Nothing else compresses the search
   space so fast.
2. **`cpu.disassemble` / `cpu.disassemble_function`** with structured output and `STEP_OVER`
   flags — lets the agent build a call graph by recursive descent instead of reading a text blob.
3. **`wp.set` + `mem.pc_at`** — the canonical "who touches this address?" answer, turning data
   discoveries into code discoveries.
4. **`mem.compare_snapshots`** — finds game variables (lives, score, state machine) with no prior
   knowledge, exactly like a cheat search.
5. **`gfx.render_tiles` / `gfx.render_tilemap` / `gfx.decode_from_bytes`** — makes graphics data
   *visible* to a multimodal agent, so it can label ROM regions ("this is the font", "this is the
   sprite sheet") from pixels rather than guesswork.
6. **`annot.add` / `annot.save`** — persistent, address‑keyed notes stored by MAME itself, so
   knowledge accumulates across sessions and survives context resets.
7. **`machine.describe`** — the driver already encodes the hardware memory map; surfacing it means
   the agent never has to reverse‑engineer what MAME already knows.
8. **`state.checkpoint` / `state.restore`** — cheap, safe experimentation loops.
9. **`audio.trigger_command`** — systematically enumerates sound tables.
10. **`debug.command`** — the safety valve that keeps the agent unblocked while the wrapper set
    matures, and a usage log that tells us what to wrap next.

---

## 11. Phase 0 spike results (executed 2026‑08‑26)

Everything below was **measured**, not inferred. Environment: container with `DISPLAY` unset, no
`/tmp/.X11-unix`, no `/dev/fb*`, no `/dev/dri`, no Xvfb, 2 cores, 3.9 GB RAM, no swap.
Build: `SUBTARGET=tiny`, `OSD=sdl`, MAME 0.289, GCC 12.2.0. Binary: 92 MB, 374 `-listfull` entries (59 drivers plus devices).

### 11.1 Headline result

**Vanilla MAME runs with no X server and no framebuffer.** MAME's own verbose output:

```
Available videodrivers: x11 wayland KMSDRM offscreen dummy evdev
Current Videodriver: offscreen
```

SDL2 autodetects past x11/wayland/KMSDRM and lands on **`offscreen`** with no env vars set.
`SDL_VIDEODRIVER=dummy` is therefore **not required** — it is a hardening/latency measure only.
This **corrects §1.5/§3.1 of this plan**, which claimed it was mandatory. Explicitly setting
`dummy` is still recommended (avoids probing three unavailable drivers at every start, and
guards against a distro that omits the `offscreen` backend).

Verified directly against `libSDL2` (the exact calls at `osdsdl.cpp:298` / `window.cpp:911`):

| Env | `SDL_InitSubSystem(SDL_INIT_VIDEO)` | `SDL_CreateWindow` |
|---|---|---|
| vanilla (nothing set) | OK — driver `offscreen`, 1 display | OK |
| `SDL_VIDEODRIVER=dummy` | OK — driver `dummy` | OK |
| `SDL_VIDEODRIVER=x11` | **FAILS** "x11 not available" | — |

### 11.2 Risk 1 — WAV capture with `-sound none` → **WORKS**

`-wavwrite out.wav` with `-sound none` produced a valid **48 kHz mono, 3.00 s, 288 046‑byte** WAV
(parsed with Python `wave`). The `sound_wav` fallback module contemplated in §7 is **not needed**.

### 11.3 Risk 2 — snapshot with no window → **WORKS**

`-snapname test.png` produced a valid **256×240 PNG** (magic + IHDR verified). The feared
`ui_target()` assert never fires. `machine.video:snapshot()` from Lua also works. No window,
no renderer, no problem — confirming §1.6.

### 11.4 Full agent loop, headless, one run

`-debug -debugger none -autoboot_script <lua>` exercised the whole Phase 1 tool surface:

| Capability | Result |
|---|---|
| device/region enumeration | 10 devices; `:maincpu` m6809, program 8‑bit mask 0xffff; regions `:maincpu` 64 K, `:gfx1` 16 K, `:proms` 6 K |
| `bpset` | index 1 |
| `wpset` + **actually trapped** | `Stopped at watchpoint 1 writing AB to 9000` |
| memory write/read | round‑tripped |
| registers | `PC=0x5BA9` |
| screenshot | PNG written |
| WAV | 194 KB written |
| disassembly (`dasm` cmd) | `1000: 00 00 NEG <$00` … |
| expression eval (`print pc`) | `5BA9` |
| exit code | **0** |

Speed: **1025 %** of real time with `-nothrottle` (10005 % on an empty driver) — ample headroom
for agent-driven work.

### 11.5 New findings that change the plan

1. **BGFX needs `X11/Xlib.h` even with `NO_X11=1`.** `bgfx` is linked unconditionally
   (`scripts/src/main.lua:206`) and there is **no `NO_BGFX` option**; its
   `3rdparty/bgfx/3rdparty/khronos/EGL/eglplatform.h:116` includes `<X11/Xlib.h>` under
   `#elif defined(__unix__)`. Workaround used: `-DUSE_OZONE=1` (an earlier branch in the same
   `#if` chain, needs `-Wno-error=pointer-arith`). **This is a strong, concrete argument for the
   Phase 2 headless OSD**, which drops BGFX from the link entirely.
2. **`NO_X11=1` forces `-lEGL` on Linux** (`scripts/src/osd/sdl.lua:33`). With `-video none` EGL is
   never called, so a stub `.so` satisfies the linker. The headless OSD removes this too.
3. **`ARCHOPTS` must not be used to pass defines** — it overrides the arch flag and silently
   produced a `-m32` build. Use `ARCHOPTS_C` / `ARCHOPTS_CXX`.
4. **Upstream Lua binding bug:** `cpu.debug:bpset(addr)` **segfaults**;
   `cpu.debug:bpset(addr, cond, action)` works. `luaengine_debug.cpp:415` binds
   `char const *cond, char const *act` with no defaults, so the 1‑arg form passes null pointers.
   *Action:* always pass all three args from the MCP layer; consider an upstream patch adding
   `sol::optional` defaults. Same pattern likely affects `wpset`.
5. **`debugger:command()` is rock solid** and was unaffected by the above — it validates the
   §5.11 "escape hatch" as a genuine safety net, not just a convenience.
6. **Build resources:** GCC needs **>2 GB per TU** on `emumem_aspace.cpp` and the sol2/luaengine
   files. At `-j2` on 3.9 GB with no swap the build **OOM‑thrashed and stalled**. Fixed with 4 GB
   swap + `-j1`. Budget ≥3 GB RAM per parallel job, or add swap. Full `tiny` build ≈ 1.5 h at `-j1`.
7. **`___empty` hangs headless** — it drops into the interactive UI game chooser. Always launch a
   real driver, and prefer `-seconds_to_run` as a watchdog.
8. **GCC 12 `-Werror=restrict` false positives** in `fsmeta.cpp` and `device.cpp`. Use `NOWERROR=1`
   (a *generate*-time genie option — it will not take effect on an already-generated tree).

### 11.6 Reproducing the build

```bash
make SUBTARGET=tiny OSD=sdl \
  NO_X11=1 NO_USE_XINPUT=1 NO_OPENGL=1 USE_QTDEBUG=0 \
  NO_USE_MIDI=1 NO_USE_PORTAUDIO=1 NO_USE_PULSEAUDIO=1 NO_USE_PIPEWIRE=1 \
  NOWERROR=1 ARCHOPTS_CXX="-DUSE_OZONE=1" ARCHOPTS_C="-DUSE_OZONE=1" \
  PYTHON_EXECUTABLE=python3 -j1          # -j1 unless ≥3 GB RAM per job

./mametiny <driver> -video none -sound none -nothrottle \
           -debug -debugger none -seconds_to_run N \
           -snapname shot.png -wavwrite out.wav -autoboot_script tools.lua
```

Needs `libSDL2` + `libSDL2_ttf` + `libfontconfig` (+ headers) and a `libEGL` (stub is fine).
In this sandbox `apt` was blocked, so headers came from GitHub and the SDL2 runtime from the
`pysdl2-dll` PyPI wheel, with `pkg-config`/`sdl2-config` shims. A normal CI box just installs
`libsdl2-dev libsdl2-ttf-dev libfontconfig-dev libegl1-mesa-dev`.

### 11.7 Verdict

Phase 1 (Lua plugin + external MCP supervisor) is **validated end‑to‑end and unblocked** — every
capability it depends on works headless today. Phase 2 (`osd=headless`) is **more justified than
originally argued**: not merely a size optimisation, but the way to delete the BGFX/X11/EGL/SDL
build-and-runtime dependency chain that caused every single failure in this spike.
