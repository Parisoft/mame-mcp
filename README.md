# mame-mcp

**A headless [MAME](https://www.mamedev.org/) that AI agents can drive over the
[Model Context Protocol](https://modelcontextprotocol.io), to debug and reverse-engineer
arcade ROMs.**

Breakpoints, watchpoints, memory, registers, disassembly, execution coverage, decoded
graphics, screenshots and audio capture — **67 MCP tools**, with no X server, no
framebuffer and no graphics libraries of any kind.

```
$ ldd mametiny
        linux-vdso.so.1
        libstdc++.so.6
        libm.so.6
        libgcc_s.so.1
        libc.so.6
```

That is the complete dependency list. It runs under `env -i`.

> This is a fork of [mamedev/mame](https://github.com/mamedev/mame). The upstream README is
> preserved at the bottom. **71 lines** were added to 9 pre-existing MAME files; everything
> else is new files.

---

## Contents

- [Why](#why)
- [How it works](#how-it-works)
- [Quick start](#quick-start)
- [The tools](#the-tools)
- [A worked example](#a-worked-example)
- [What we changed in MAME](#what-we-changed-in-mame)
- [Testing](#testing)
- [Known limitations](#known-limitations)
- [Further reading](#further-reading)

---

## Why

MAME already contains an enormous amount of knowledge about arcade hardware: an accurate
per-driver memory map, a full-featured debugger, and correct graphics-decode layouts for
thousands of games. Almost all of that is reachable only through a GUI or an interactive
console — which makes it unavailable to an automated agent in a container.

This fork exposes that knowledge as structured, machine-readable MCP tools, and strips the
emulator down so it runs anywhere.

The two things that make it more than a remote-control wrapper:

* **`machine.describe`** returns the hardware memory map the driver already encodes — CPUs,
  address spaces, ROM regions, RAM shares, screens. An agent never has to reverse-engineer
  what MAME can simply tell it.
* **`cov.*`** records which addresses actually execute. Diffing coverage between two game
  phases partitions an unknown ROM into functional regions in a single step.

## How it works

```
 Agent  ──MCP (stdio, JSON-RPC 2.0)──▶  mcp-server/  (Node supervisor)
                                          │  spawns + supervises
                                          │  NDJSON JSON-RPC over a UNIX socket
                                          ▼
                                   mame -debug -debugger none -plugin mcp
                                          └── plugins/mcp/  (Lua)
                                                └── C++ bindings in src/frontend/mame/
```

Three layers, each there for a reason:

| Layer | Why it exists |
|---|---|
| **Node supervisor** | MAME writes freely to stdout/stderr, which would corrupt an MCP stdio stream. It also owns process lifecycle and implements `exec.wait_for_stop` by long-polling *outside* the emulator loop — blocking inside would deadlock the pump. |
| **Lua plugin** | `debugger_cpu::wait_for_debugger()` calls `lua_engine::on_periodic()` **inside its stop loop**, so the RPC pump keeps serving requests while the CPU is halted at a breakpoint. That is what makes interactive debugging possible at all. |
| **C++ bindings** | Graphics, disassembly and coverage had no Lua route. See [below](#3-new-lua-bindings-3-new-files). |

## Quick start

### 1. Build a headless binary

**Requirements:** a C++20 compiler (GCC 11+ or Clang 13+), GNU make, Python 3, and
~10 GB of free disk. **No SDL, X11, fontconfig, Qt, OpenGL or pkg-config** — not even to
compile. On a bare Debian/Ubuntu container that is:

```bash
apt-get install -y build-essential python3 git
```

Then:

```bash
make OSD=headless SUBTARGET=tiny NOWERROR=1 -j$(nproc)
```

This produces **`./mametiny`** (~86 MB) in the repository root. Verify it:

```bash
$ ldd mametiny          # should list only libc/libstdc++/libm/libgcc
$ ./mametiny -help      # works with no DISPLAY set
```

#### The two flags that matter

| Flag | Why it is needed |
|---|---|
| `OSD=headless` | selects the display-free OSD. Without it you get the SDL OSD and its whole dependency chain. |
| `NOWERROR=1` | GCC 12 emits `-Werror=restrict` false positives in `fsmeta.cpp` and `device.cpp`. This is a *generate*-time genie option, so it has no effect on an already-generated tree — if you first built without it, `rm -rf build/projects` before rebuilding. |

> **Generate-time vs build-time.** `OSD`, `SUBTARGET`, `SOURCES`, `SOURCEFILTER`,
> `NOWERROR` and every `NO_USE_*` flag are consumed by **genie** when it generates the
> makefiles — not by `make` when it compiles. Adding one to a tree that was generated
> without it silently does nothing. Whenever you change any of them:
>
> ```bash
> rm -rf build/projects
> ```
>
> Add `PYTHON_EXECUTABLE=python3` if bare `python` is not on your `PATH`. `SOURCES=` and
> `SOURCEFILTER=` invoke `scripts/build/makedep.py` at generate time, so they fail early
> without it.

#### Choosing what to build

`SUBTARGET` controls how many systems are compiled in. This dominates both build time and
binary size:

| Build | Machines | Binary | Time (2 cores) |
|---|---|---|---|
| `SUBTARGET=tiny` | 59 | 86 MB | ~1.5–2 h |
| `SOURCES=<file.cpp>` | a handful | smaller | much faster |
| `SOURCES=src/mame/konami` | 108 | — | ~2.5–3.5 h at `-j1` |
| full (no `SUBTARGET`) | ~43,000 | very large | many hours |

For a specific game, compile only its driver — MAME derives the required CPUs, sound chips
and video hardware automatically:

```bash
# one driver (World Rally)
make OSD=headless SOURCES=src/mame/gaelco/wrally.cpp NOWERROR=1 -j$(nproc)

# a whole manufacturer directory -- makedep.py walks it for *.cpp
make OSD=headless SOURCES=src/mame/konami NOWERROR=1 -j$(nproc)

# or a reusable list, one driver source per line
printf 'gaelco/wrally.cpp\nexidy/circus.cpp\n' > src/mame/mcp.flt
make OSD=headless SOURCEFILTER=src/mame/mcp.flt NOWERROR=1 -j$(nproc)
```

`SOURCES` accepts a comma-separated list of `.cpp` files **or directories** — a directory
is walked recursively (`scripts/build/makedep.py`, `collect_sources`). For example
`SOURCES=src/mame/konami` selects 157 source files and 108 machines.

`SOURCES` and `SOURCEFILTER` are mutually exclusive.

⚠️ **Check the binary name.** Without `SUBTARGET=tiny` the output is **`./mame`**, not
`./mametiny`. A build that looks like it "produced nothing" is usually this — point
`MAME_BINARY` at the right file.

⚠️ The `SUBTARGET=tiny` row is measured; the others are extrapolated. Savings are
**not** proportional to driver count — a large part of the binary is the emulation core,
file formats, Lua and the frontend, none of which shrink.

#### Memory

Budget **~3 GB of RAM per parallel job**. `emumem_aspace.cpp` and the sol2 translation
units need more than 2 GB each; at `-j2` on a 4 GB machine the build will OOM-thrash and
appear to hang. If you are tight on memory use `-j1`, or add swap:

```bash
sudo dd if=/dev/zero of=/swapfile bs=1M count=4096 status=none
sudo chmod 600 /swapfile && sudo mkswap -q /swapfile && sudo swapon /swapfile
```

There is no progress indication while thrashing — the build simply stops advancing. If a
`-j2` build appears stuck, check `free -m` before assuming it crashed.

#### Troubleshooting

**A build that "succeeds" without compiling anything.** An interrupted parallel build can
leave a truncated object file behind. `make` then keeps re-archiving it and reports
success — the tell is `Archiving libfrontend.a...` with zero files compiled, and a linker
that either fails on missing symbols or produces a binary with no Lua engine. A real
`luaengine.o` is ~10 MB; the broken one was **416 bytes with no symbols**:

```bash
ls -la build/linux_gcc/obj/x64/Release/src/frontend/luaengine.o   # suspiciously small?
rm -rf build/linux_gcc/obj/x64/Release/src/frontend \
       build/linux_gcc/bin/x64/Release/libfrontend.a
```

The same applies to any object left behind by an interrupted run; deleting the containing
directory and its `.a` forces a clean rebuild of just that library.

**`alsa/asoundlib.h: No such file or directory`.** See *If `apt` is unavailable* below —
you need the `NO_USE_*` flags, and they only take effect after `rm -rf build/projects`.

**A flag seems to be ignored.** It is almost certainly generate-time; see the note under
*The two flags that matter*.

#### Reducing the binary

The build keeps debug symbols by default:

| | Size |
|---|---|
| as built | 86 MB |
| `strip mametiny` | 65 MB |
| stripped + `xz -9` | 9.7 MB |

Stripping is safe but costs you readable stack traces if MAME crashes — a real trade-off
for a debugging tool.

#### If `apt` is unavailable

The headless OSD needs no SDL, X11, EGL, fontconfig or Qt, so a locked-down sandbox needs
no staged dependencies — only a compiler and Python. If ALSA headers are missing, disable
the audio backends at *generate* time:

```bash
make OSD=headless SUBTARGET=tiny PYTHON_EXECUTABLE=python3 NOWERROR=1 \
     NO_USE_MIDI=1 NO_USE_PORTAUDIO=1 NO_USE_PULSEAUDIO=1 NO_USE_PIPEWIRE=1 -j1
```

`scripts/src/main.lua` links PortAudio/PortMidi based purely on these options, regardless
of which OSD is selected, and building those 3rdparty libraries is what pulls in
`alsa/asoundlib.h`. This is **not** a headless-specific problem — any build on a machine
without ALSA headers hits it. `NO_USE_PULSEAUDIO` / `NO_USE_PIPEWIRE` are only needed for
OSDs that compile those backends; the headless OSD compiles just
`src/osd/modules/sound/none.cpp`, so `NO_USE_MIDI=1 NO_USE_PORTAUDIO=1` is sufficient.

#### The SDL build

`OSD=sdl` still works and is unaffected by this fork, but needs SDL2, SDL2\_ttf,
fontconfig and an EGL stub, plus `-DUSE_OZONE=1` to work around bgfx pulling in
`X11/Xlib.h`. See [`docs/mcp/README.md`](docs/mcp/README.md). There is no reason to prefer
it for agent use.

### 2. Install the server

```bash
cd mcp-server && npm install
```

### 3. Register with an MCP client

```json
{
  "mcpServers": {
    "mame": {
      "command": "node",
      "args": ["/path/to/mame-mcp/mcp-server/src/index.mjs"],
      "env": {
        "MAME_DIR": "/path/to/mame-mcp",
        "MAME_BINARY": "/path/to/mame-mcp/mametiny",
        "MAME_ROMPATH": "/path/to/roms"
      }
    }
  }
}
```

| Variable | Default | Meaning |
|---|---|---|
| `MAME_BINARY` | `./mametiny` | MAME executable |
| `MAME_DIR` | repo root | working directory; also where `plugins/` is found |
| `MAME_ROMPATH` | `roms` | ROM search path |
| `MAME_MCP_ARTIFACTS` | `$TMPDIR/mame-mcp-artifacts` | screenshots, save states, scratch files |

**ROMs are not included** and are not distributed with this repository. Point
`MAME_ROMPATH` at your own dump set.

## The tools

67 tools. Full generated reference: [`docs/mcp/tools.md`](docs/mcp/tools.md).

| Group | # | What it does |
|---|---|---|
| `session.*` | 4 | start/stop MAME, list drivers, status |
| `machine.*` | 2 | **`describe`** — the driver's memory map; reset |
| `exec.*` | 11 | pause/resume, step/over/out, run-to, run-for, vblank, IRQ, `wait_for_stop` |
| `bp.*` `wp.*` `rp.*` | 10 | breakpoints, watchpoints, registerpoints |
| `mem.*` | 6 | read/write/search, ROM regions, RAM shares |
| `cpu.*` | 4 | registers, CPU list, legacy disassembly |
| `dasm.*` | 3 | structured disassembly with `step_over`/`step_out` flags |
| `cov.*` | 8 | **execution coverage**, write attribution, PC history |
| `gfx.*` | 5 | decoded tile sheets, tilemaps, palette — returned as **inline PNGs** |
| `video.*` `audio.*` | 4 | screenshots, WAV capture |
| `input.*` `state.*` | 4 | button presses, save states |
| `sym.*` `annot.*` | 3 | expression evaluation, persistent per-ROM comments |
| `debug.*` | 3 | **escape hatch** — any raw MAME debugger command, plus logs |

`debug.command` matters: it guarantees an agent is never blocked by a missing wrapper,
since it reaches all ~150 of MAME's native debugger commands.

## A worked example

The workflow the `cov.*` tools exist for — isolating the code that only runs during
gameplay. Measured on World Rally (Gaelco, 1993):

```
cov.track_pc_start          →  begin recording executed addresses
exec.resume ... 4s          →  let the attract mode run
cov.visited_map             →  536 addresses
input.press COIN / START    →  insert a credit and start
exec.resume ... 5s
cov.visited_map             →  1008 addresses
                               ────────────────────────
                               472 addresses new in phase B
dasm.range 0x2862           →  move.b $fec1fc.l, D0
                               andi.w  #$df, D0
                               beq     $2770
```

472 addresses of gameplay-only code, isolated in one step and immediately disassemblable.

The typical debugging loop:

```
session.start → machine.describe → wp.set → exec.resume → exec.wait_for_stop
              → cpu.registers → mem.read → dasm.range → annot.add
```

Memory and registers are only coherent while **stopped**; reading a free-running CPU gives
a torn snapshot.

## What we changed in MAME

Deliberately minimal and additive, so rebasing against upstream stays cheap.
**71 lines added across 9 pre-existing files**, all of it guarded or list-shaped:

| File | + | Why |
|---|---|---|
| `src/osd/modules/lib/osdobj_common.cpp` | 21 | `#ifndef OSD_HEADLESS` guards around modules with no headless build; register `MONITOR_NONE` |
| `scripts/src/main.lua` | 16 | don't link `qtdbg_*`/bgfx for `osd=headless` |
| `src/osd/modules/lib/osdlib_unix.cpp` | 12 | SDL was included solely for clipboard get/set; made conditional |
| `src/emu/debug/debugcpu.cpp` | 8 | **upstream bug fix** (see below) |
| `scripts/src/3rdparty.lua` | 4 | don't generate the bgfx projects for `osd=headless` |
| `src/frontend/mame/luaengine.{h,cpp}` | 3 + 3 | declare and call the three new `initialize_*()` hooks |
| `scripts/src/mame/frontend.lua` | 3 | add the three new source files |
| `scripts/src/osd/modules.lua` | 1 | add `monitor_none.cpp` |

Everything else is **new files**:

#### 1. The headless OSD (`OSD=headless`)

`src/osd/headless/`, `scripts/src/osd/headless*.lua`, `src/osd/modules/monitor/monitor_none.cpp`

Stock MAME *does* run without X — SDL falls back to an `offscreen` driver. The problem is
the *dependency chain*: bgfx is linked unconditionally and its EGL header includes
`X11/Xlib.h` regardless of `NO_X11`; `NO_X11` itself forces `-lEGL`; and `osdlib_unix.cpp`
pulls in SDL purely for clipboard support. This OSD removes all of it.

It also creates **no windows** — but it does allocate exactly one hidden render target,
because `render_manager` only adopts a non-hidden target as the UI target and
`ui_target()` asserts non-null while the frontend calls it every frame. *"Create no
windows" is not the same as "create no targets."*

#### 2. The MCP bridge

`plugins/mcp/` (Lua) and `mcp-server/` (Node).

#### 3. New Lua bindings (3 new files)

Each exposes something with **no prior route out of a headless MAME**:

| File | Binds | Why it was unreachable |
|---|---|---|
| `luaengine_gfx.cpp` | `gfx_element`, `device_gfx_interface`, `tilemap_t` | MAME decodes every driver's graphics, but the only consumer was the interactive F4 tile viewer — and there is no `gfx` debugger command |
| `luaengine_dasm.cpp` | `debug_disasm_buffer` | the `dasm` console command writes a *file* you must parse back, discarding the `STEP_OVER`/`STEP_OUT` flags that make control-flow following possible |
| `luaengine_cov.cpp` | `track_pc`, `track_mem`, `history_pc` | **`trackpc` is a write-only switch**: nothing in `debugcmd.cpp` ever reads the visited set back — only `dvdisasm.cpp` queries it, one address at a time, to shade the disassembly view |

#### An upstream bug we fixed

`device_debug::compute_debug_flags()` did not consider `m_track_pc` / `m_track_mem` when
deciding whether to request `DEBUG_FLAG_CALL_HOOK`. Since coverage is recorded inside
`instruction_hook()`, **enabling tracking silently recorded nothing** unless some other
feature (a breakpoint, a trace, single-stepping) had already requested the hook.
`set_track_pc()` and `set_track_mem()` now also recompute the flags so the change takes
effect immediately.

## Testing

```bash
./mcp-server/run-tests.sh          # all four suites
```

| Suite | Tests | Needs a build? |
|---|---|---|
| `plugins/mcp/test/test_util.lua` | 49 | no — pure logic (base64, addresses, JSON-RPC framing) |
| `mcp-server/test/protocol.mjs` | 200 | no — tool registration, schemas, annotations, error handling |
| `mcp-server/test/smoke.mjs` | 56 | yes — the agent workflow end to end |
| `mcp-server/test/full-sweep.mjs` | 67 tools | yes — invokes **every** tool, fails if any is uninvoked |

Last full run, on World Rally with the headless build:

```
tools registered : 67
tools invoked    : 67
  FAILED         : 0
ALL TOOLS EXERCISED SUCCESSFULLY
```

`docs/mcp/tools.md` is generated from the live server, so the reference cannot drift:

```bash
cd mcp-server && node test/gen-tools-doc.mjs > ../docs/mcp/tools.md
```

## Known limitations

Honest list — see [`docs/mcp/README.md`](docs/mcp/README.md) for detail.

* **Stop events are detected by scraping the debugger console log** for
  `"Stopped at breakpoint N"`, as `plugins/gdbstub` does. `triggered_breakpoint()` is not
  exposed to Lua. This is the most brittle part of the stack; a C++ `debug_module` would
  fix it properly.
* **`dasm.function` is a linear sweep**, not a control-flow walk — it stops at the first
  end-of-flow instruction and does not follow branches.
* **`cov.visited_map`'s `limit`** caps addresses *examined*, not hits found. Set it below
  your range and the sweep truncates early and under-reports; the result reports
  `truncated` so you can detect this.
* **Bulk memory reads are byte-at-a-time through Lua**, so very large reads are slow.
* **One session per server process.**
* Some ROM sets need care: MAME is strict, and drivers occasionally rename ROMs between
  revisions or require documentation-only PAL dumps that the emulation never reads.

## Further reading

| Document | Contents |
|---|---|
| [`docs/mcp/README.md`](docs/mcp/README.md) | usage guide, configuration, verified results |
| [`docs/mcp/tools.md`](docs/mcp/tools.md) | generated reference for all 67 tools |
| [`docs/mcp/HEADLESS-OSD.md`](docs/mcp/HEADLESS-OSD.md) | headless OSD design and measurements |
| [`docs/mcp/PLAN.md`](docs/mcp/PLAN.md) | the original design plan and phase-by-phase findings |

## Licence

Same as MAME: BSD-3-Clause / GPL-mixed, per-file. All new files carry
`// license:BSD-3-Clause`. See [COPYING](COPYING).

---

---

# MAME (upstream README)

## What is MAME?

MAME is a multi-purpose emulation framework.

MAME's purpose is to preserve decades of software history. As electronic technology continues to rush forward, MAME prevents this important "vintage" software from being lost and forgotten. This is achieved by documenting the hardware and how it functions. The source code to MAME serves as this documentation. The fact that the software is usable serves primarily to validate the accuracy of the documentation (how else can you prove that you have recreated the hardware faithfully?). Over time, MAME (originally stood for Multiple Arcade Machine Emulator) absorbed the sister-project MESS (Multi Emulator Super System), so MAME now documents a wide variety of (mostly vintage) computers, video game consoles and calculators, in addition to the arcade video games that were its initial focus.

## Where can I find out more?

* [Official MAME Development Team Site](https://www.mamedev.org/) (includes binary downloads, wiki, forums, and more)
* [MAME Testers](https://mametesters.org/) (official bug tracker for MAME)

### Community

* [r/MAME](https://www.reddit.com/r/MAME/) on Reddit
* [MAMEdev Forum](https://forum.mamedev.org/)
* [MAMEdev Discussions](https://github.com/orgs/mamedev/discussions) on GitHub

## Development

![Alt](https://repobeats.axiom.co/api/embed/8461d8ae4630322dafc736fc25782de214b49630.svg "Repobeats analytics image")

### CI status and code scanning

[![CI (Linux)](https://github.com/mamedev/mame/workflows/CI%20(Linux)/badge.svg)](https://github.com/mamedev/mame/actions/workflows/ci-linux.yml) [![CI (Windows](https://github.com/mamedev/mame/workflows/CI%20(Windows)/badge.svg)](https://github.com/mamedev/mame/actions/workflows/ci-windows.yml) [![CI (macOS)](https://github.com/mamedev/mame/workflows/CI%20(macOS)/badge.svg)](https://github.com/mamedev/mame/actions/workflows/ci-macos.yml) [![Compile UI translations](https://github.com/mamedev/mame/workflows/Compile%20UI%20translations/badge.svg)](https://github.com/mamedev/mame/actions/workflows/language.yml) [![Build documentation](https://github.com/mamedev/mame/workflows/Build%20documentation/badge.svg)](https://github.com/mamedev/mame/actions/workflows/docs.yml)  [![Coverity Scan Status](https://scan.coverity.com/projects/5727/badge.svg?flat=1)](https://scan.coverity.com/projects/mame-emulator)

### How to compile?

If you're on a UNIX-like system (including Linux and macOS), it could be as easy as typing

```
make
```

for a full build,

```
make SUBTARGET=tiny
```

for a build including a small subset of supported systems.

See the [Compiling MAME](http://docs.mamedev.org/initialsetup/compilingmame.html) page on our documentation site for more information, including prerequisites for macOS and popular Linux distributions.

For recent versions of macOS you need to install [Xcode](https://developer.apple.com/xcode/) including command-line tools and [SDL 2.0](https://github.com/libsdl-org/SDL/releases/latest).

For Windows users, we provide a ready-made [build environment](http://www.mamedev.org/tools/) based on MinGW-w64.

Visual Studio builds are also possible, but you still need [build environment](http://www.mamedev.org/tools/) based on MinGW-w64.
In order to generate solution and project files just run:

```
make vs2022
```
or use this command to build it directly using msbuild

```
make vs2022 MSBUILD=1
```

### Coding standard

MAME source code should be viewed and edited with your editor set to use four spaces per tab. Tabs are used for initial indentation of lines, with one tab used per indentation level. Spaces are used for other alignment within a line.

Some parts of the code follow [Allman style](https://en.wikipedia.org/wiki/Indent_style#Allman_style); some parts of the code follow [K&R style](https://en.wikipedia.org/wiki/Indent_style#K.26R_style) -- mostly depending on who wrote the original version. **Above all else, be consistent with what you modify, and keep whitespace changes to a minimum when modifying existing source.** For new code, the majority tends to prefer Allman style, so if you don't care much, use that.

All contributors need to either add a standard header for license info (on new files) or inform us of their wishes regarding which of the following licenses they would like their code to be made available under: the [BSD-3-Clause](http://opensource.org/licenses/BSD-3-Clause) license, the [LGPL-2.1](http://opensource.org/licenses/LGPL-2.1), or the [GPL-2.0](http://opensource.org/licenses/GPL-2.0).

See more specific [C++ Coding Guidelines](https://docs.mamedev.org/contributing/cxx.html) on our documentation web site.

## License

The MAME project as a whole is made available under the terms of the
[GNU General Public License, version 2](http://opensource.org/licenses/GPL-2.0)
or later (GPL-2.0+), since it contains code made available under multiple
GPL-compatible licenses.  A great majority of the source files (over 90%
including core files) are made available under the terms of the
[3-clause BSD License](http://opensource.org/licenses/BSD-3-Clause), and we
would encourage new contributors to make their contributions available under the
terms of this license.

Please note that MAME is a registered trademark of Gregory Ember, and permission
is required to use the "MAME" name, logo, or wordmark.

<a href="http://opensource.org/licenses/GPL-2.0" target="_blank">
<img align="right" width="100" src="https://opensource.org/wp-content/uploads/2009/06/OSIApproved.svg">
</a>

    Copyright (c) 1997-2026  MAMEdev and contributors

    This program is free software; you can redistribute it and/or modify it
    under the terms of the GNU General Public License version 2, as provided in
    docs/legal/GPL-2.0.

    This program is distributed in the hope that it will be useful, but WITHOUT
    ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
    FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
    more details.

Please see [COPYING](COPYING) for more details.
