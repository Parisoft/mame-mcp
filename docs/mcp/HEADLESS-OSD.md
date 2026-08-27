# The `headless` OSD

Phase 2 of [`PLAN.md`](PLAN.md): a MAME OSD with **no display server, no windowing
toolkit, no input devices, no fonts, no BGFX/OpenGL** — and therefore none of the
build-or-run dependencies that force X11 into a normal build.

```bash
make OSD=headless SUBTARGET=tiny NOWERROR=1 -j$(nproc)
./mametiny <driver> -debug -debugger none -plugin mcp
```

---

## Why it exists

Phase 0 established that stock MAME *does* run without X (SDL falls back to its
`offscreen` video driver). So why build a new OSD at all?

Because **the dependency chain, not the runtime, is the problem.** Every single
failure in the phase 0 spike came from graphics libraries that a headless agent
sandbox has no reason to carry:

| Failure | Cause |
|---|---|
| `X11/Xlib.h: No such file` | bgfx is linked unconditionally; its EGL header includes Xlib on unix *regardless of* `NO_X11=1` |
| `cannot find -lEGL` | `NO_X11=1` makes `sdl.lua` link EGL on Linux |
| `SDL2/SDL.h: No such file` | the SDL OSD, obviously — but also `osdlib_unix.cpp`, purely for clipboard support |

With `OSD=headless` the link line is:

```
-ldl -lrt
```

No SDL2, no SDL2_ttf, no fontconfig, no X11/Xinerama/Xext/Xi, no GL, no EGL,
no Qt, no BGFX/bimg/bx, no PortAudio/PortMidi.

## What still works

Everything the MCP server needs, because these are emulation-core features rather
than OSD features:

* **Screenshots** — `video_manager` owns a hidden render target and a pure
  software rasteriser (`src/emu/video.cpp`), independent of the OSD window list.
* **WAV capture** — `sound_manager` writes WAVs from the mixer, not from an OSD
  sound backend.
* **AVI recording** — same path, via `aviwrite`.
* **The whole debugger** — `src/emu/debug/` has never needed a GUI. The `none`
  and `gdbstub` debug modules are both built.
* **Lua plugins**, including `plugins/mcp`.

## What is gone

Deliberately: interactive video, audio playback, keyboard/mouse/joystick/lightgun
input, UI fonts and the built-in menu system. `-video`, `-sound` and every input
provider default to `none` and there is nothing else to select.

---

## Design

```
src/osd/headless/
  headlessmain.cpp     main(); hands off to emulator_info::start_frontend
  osdheadless.{h,cpp}  osd_common_t subclass
scripts/src/osd/
  headless.lua         project definitions (osd_headless, ocore_headless)
  headless_cfg.lua     compiler defines
src/osd/modules/monitor/
  monitor_none.cpp     NEW: null monitor provider
```

Two things make it small:

1. **It does not call `osdmodulesbuild()`.** That helper in `modules.lua` adds the
   entire SDL/BGFX/Qt module set. `headless.lua` instead lists the ~30 sources
   that are meaningful without a display.

2. **It defines neither `OSD_SDL` nor `SDLMAME_*`.** Most shared OSD modules are
   wrapped in `#if defined(OSD_SDL)` and fall back to `MODULE_NOT_SUPPORTED`
   stubs, so simply not defining those macros compiles them away.

`osd_common_t` leaves only two pure virtuals for a concrete OSD —
`process_events()` and `has_focus()` — both trivial here.

### `video_init()` creates nothing

This is the crux. The SDL OSD creates one `osd_window` per screen in
`video_init()`, which is what forces a real window **even with `-video none`**.
The headless override returns `true` without allocating anything. The core's
snapshot target is separate, so screenshots keep working.

### `monitor_none`

New, because `pick_monitor()` is called during video init even when no window will
ever exist. Without a provider, module selection throws *"All monitorprovider
modules failed to initialize"*. It reports one synthetic 1920×1080 primary display;
the geometry only feeds default window sizing and aspect maths, neither of which
matter here.

It is registered for **all** OSDs (and added to `modules.lua`), so it also serves
as a safe fallback for `-video none` on a normal build.

---

## Changes to shared files

Kept minimal and additive, so upstream rebases stay cheap. Every emulator-source
edit is an `#ifndef OSD_HEADLESS` guard, which is inert for existing OSDs.

| File | Change |
|---|---|
| `src/osd/modules/lib/osdobj_common.cpp` | guard module registrations that have no headless implementation; register `MONITOR_NONE` |
| `src/osd/modules/lib/osdlib_unix.cpp` | SDL is included only for clipboard get/set; made conditional (headless returns empty / `not_supported`) |
| `scripts/src/main.lua` | do not link `qtdbg_*` or bgfx/bimg/bx for `osd=headless` |
| `scripts/src/3rdparty.lua` | do not *generate* the bgfx/bimg/bx projects for `osd=headless` |
| `scripts/src/osd/modules.lua` | add `monitor_none.cpp` to the shared module list |

**Verified non-regressive:** simulating the preprocessor over
`register_options()` yields 58 modules for an SDL build before the change and 59
after — the only delta is the newly added `MONITOR_NONE`. A headless build
resolves to 18, all `_NONE` stubs plus the two debugger modules.

---

## Build notes

`OSD=headless` needs none of the SDL-era workarounds. In particular
`-DUSE_OZONE=1` and the `libEGL` stub are no longer required, because bgfx is not
built at all.

Still needed on GCC 12:

* `NOWERROR=1` — `-Werror=restrict` false positives in `fsmeta.cpp` / `device.cpp`.
  It is a *generate*-time genie option, so it has no effect on an
  already-generated tree.
* `-j1` under about 3 GB of RAM per job — `emumem_aspace.cpp` and the sol2
  translation units need >2 GB each.

## Verified results

Built and run on 2026-08-27, `SUBTARGET=tiny`, GCC 12.2, in a container with no X,
no Wayland, no framebuffer, no `/dev/dri` and **no SDL installed at all**.

### Dynamic dependencies

```
$ ldd mametiny
        linux-vdso.so.1
        libstdc++.so.6
        libm.so.6
        libgcc_s.so.1
        libc.so.6
        /lib64/ld-linux-x86-64.so.2
```

That is the entire list. For comparison, the phase 0 SDL build needed
`libSDL2`, `libSDL2_ttf` and `libfontconfig` on top of these, plus an `libEGL`
stub to link at all.

It also runs under `env -i` — no `SDL_VIDEODRIVER=dummy`, no `DISPLAY`, nothing.

### Functional

| Check | Result |
|---|---|
| `-listfull` | 374 drivers |
| boot `gridlee`, 2 emulated seconds | exit 0, **10879 %** of real time |
| screenshot | valid 256×240 PNG |
| WAV capture with `-sound none` | valid 48 kHz 2.0 s WAV |
| MCP end-to-end suite (`test/smoke.mjs`) | **32/32 passing** |

The entire phase 1 MCP stack works against the headless binary **unchanged** —
no plugin or server edits were needed.

### Non-regression

* `osd=sdl` still generates all 32 projects (bgfx included) and
  `libosd_sdl.a` still builds.
* Simulating the preprocessor over `register_options()`: 58 modules for SDL
  before the change, 59 after — the sole delta is the newly added
  `MONITOR_NONE`.

## A bug this surfaced

Booting initially segfaulted immediately after OSD init. This is exactly
**risk 2** from [`PLAN.md`](PLAN.md) §7, and it is real:

`render_manager` only adopts a **non-hidden** target as the UI target, and
`ui_target()` asserts it is non-null. The frontend calls it every frame through
`emulator_info::draw_user_interface()`. With zero windows there are zero
non-hidden targets, so the emulator dereferences a null pointer as soon as it
starts running.

The fix is in `video_init()`: allocate exactly one render target that is never
presented. Nothing reads its primitives; it exists purely so the UI layer has
somewhere to draw. Screenshots are unaffected because `video_manager` owns its
own separate hidden snapshot target.

This is worth knowing for anyone else building a window-less OSD — "create no
windows" is not quite the same as "create no targets".
