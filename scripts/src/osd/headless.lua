-- license:BSD-3-Clause
-- copyright-holders:mame-mcp

---------------------------------------------------------------------------
--
--   headless.lua
--
--   Build rules for the headless OSD: no display server, no windowing
--   toolkit, no input devices, no fonts, no BGFX/OpenGL.
--
--   Deliberately does NOT reuse osdmodulesbuild() from modules.lua,
--   because that pulls in the entire SDL/BGFX/Qt module set. Instead we
--   list the small subset of modules that are meaningful without a
--   display, which is what removes the dependency chain that forces
--   X11 into the build (see docs/mcp/PLAN.md section 11.5).
--
--   Build with:  make OSD=headless
--
---------------------------------------------------------------------------

dofile("modules.lua")


-- Selects the POSIX vs Win32 file/dir/socket implementations in ocore, and
-- the osdlib_<os>.cpp variant. Each OSD script is expected to define these.
BASE_TARGETOS  = "unix"
SDLOS_TARGETOS = "unix"
if _OPTIONS["targetos"] == "windows" then
	BASE_TARGETOS  = "win32"
	SDLOS_TARGETOS = "win32"
elseif _OPTIONS["targetos"] == "macosx" then
	SDLOS_TARGETOS = "macosx"
end


function maintargetosdoptions(_target, _subtarget)
	-- Nothing to link beyond libc/libstdc++, pthreads and dl. That is
	-- the entire point: no SDL2, no SDL2_ttf, no fontconfig, no X11,
	-- no Xinerama, no GL, no EGL, no Qt.
	if BASE_TARGETOS == "unix" then
		links {
			"pthread",
			"dl",
		}
	end
end


newoption {
	trigger = "NO_USE_PORTAUDIO",
	description = "Disable PortAudio interface.",
	allowed = {
		{ "0",  "Enable PortAudio"  },
		{ "1",  "Disable PortAudio" },
	},
}

if not _OPTIONS["NO_USE_PORTAUDIO"] then
	_OPTIONS["NO_USE_PORTAUDIO"] = "1"
end

if not _OPTIONS["NO_USE_MIDI"] then
	_OPTIONS["NO_USE_MIDI"] = "1"
end


---------------------------------------------------------------------------
-- osd_headless: the OSD implementation plus the module subset it needs
---------------------------------------------------------------------------

project ("osd_" .. _OPTIONS["osd"])
	uuid (os.uuid("osd_" .. _OPTIONS["osd"]))
	kind (LIBTYPE)

	dofile("headless_cfg.lua")

	removeflags {
		"SingleOutputDir",
	}

	includedirs {
		MAME_DIR .. "src/emu",
		MAME_DIR .. "src/devices", -- imagedev, reachable from the debugger
		MAME_DIR .. "src/osd",
		MAME_DIR .. "src/lib",
		MAME_DIR .. "src/lib/util",
		MAME_DIR .. "src/osd/modules/file",
		MAME_DIR .. "src/osd/modules/render",
		MAME_DIR .. "src/osd/headless",
		MAME_DIR .. "3rdparty",
		ext_includedir("asio"),
	}

	files {
		-- the OSD itself
		MAME_DIR .. "src/osd/headless/headlessmain.cpp",
		MAME_DIR .. "src/osd/headless/osdheadless.cpp",
		MAME_DIR .. "src/osd/headless/osdheadless.h",

		-- shared OSD plumbing
		MAME_DIR .. "src/osd/osdepend.h",
		MAME_DIR .. "src/osd/watchdog.cpp",
		MAME_DIR .. "src/osd/watchdog.h",
		MAME_DIR .. "src/osd/interface/audio.cpp",
		MAME_DIR .. "src/osd/interface/audio.h",
		MAME_DIR .. "src/osd/interface/inputcode.h",
		MAME_DIR .. "src/osd/interface/inputdev.h",
		MAME_DIR .. "src/osd/interface/inputfwd.h",
		MAME_DIR .. "src/osd/interface/inputman.h",
		MAME_DIR .. "src/osd/interface/inputseq.cpp",
		MAME_DIR .. "src/osd/interface/inputseq.h",
		MAME_DIR .. "src/osd/interface/midiport.h",
		MAME_DIR .. "src/osd/interface/nethandler.cpp",
		MAME_DIR .. "src/osd/interface/nethandler.h",
		MAME_DIR .. "src/osd/interface/output.h",
		MAME_DIR .. "src/osd/interface/uievents.h",
		MAME_DIR .. "src/osd/modules/osdwindow.cpp",
		MAME_DIR .. "src/osd/modules/osdwindow.h",
		MAME_DIR .. "src/osd/modules/lib/osdobj_common.cpp",
		MAME_DIR .. "src/osd/modules/lib/osdobj_common.h",

		-- debugger: the whole reason this OSD exists
		MAME_DIR .. "src/osd/modules/debugger/debug_module.h",
		MAME_DIR .. "src/osd/modules/debugger/none.cpp",
		MAME_DIR .. "src/osd/modules/debugger/debuggdbstub.cpp",
		MAME_DIR .. "src/osd/modules/debugger/xmlconfig.cpp",
		MAME_DIR .. "src/osd/modules/debugger/xmlconfig.h",

		-- stub providers for everything that needs hardware we do not have
		MAME_DIR .. "src/osd/modules/render/render_module.h",
		MAME_DIR .. "src/osd/modules/render/drawnone.cpp",
		MAME_DIR .. "src/osd/modules/render/aviwrite.cpp",
		MAME_DIR .. "src/osd/modules/render/aviwrite.h",
		MAME_DIR .. "src/osd/modules/font/font_module.h",
		MAME_DIR .. "src/osd/modules/font/font_none.cpp",
		MAME_DIR .. "src/osd/modules/input/input_module.h",
		MAME_DIR .. "src/osd/modules/input/input_common.cpp",
		MAME_DIR .. "src/osd/modules/input/input_common.h",
		MAME_DIR .. "src/osd/modules/input/input_none.cpp",
		MAME_DIR .. "src/osd/modules/monitor/monitor_module.h",
		MAME_DIR .. "src/osd/modules/monitor/monitor_common.cpp",
		MAME_DIR .. "src/osd/modules/monitor/monitor_common.h",
		MAME_DIR .. "src/osd/modules/monitor/monitor_none.cpp",
		MAME_DIR .. "src/osd/modules/sound/sound_module.cpp",
		MAME_DIR .. "src/osd/modules/sound/sound_module.h",
		MAME_DIR .. "src/osd/modules/sound/none.cpp",
		MAME_DIR .. "src/osd/modules/midi/midi_module.h",
		MAME_DIR .. "src/osd/modules/midi/none.cpp",
		MAME_DIR .. "src/osd/modules/netdev/netdev_module.h",
		MAME_DIR .. "src/osd/modules/netdev/none.cpp",
		MAME_DIR .. "src/osd/modules/netdev/netdev_common.cpp",
		MAME_DIR .. "src/osd/modules/netdev/netdev_common.h",
		-- Always compiled: both are registered unconditionally by
		-- osdobj_common.cpp and self-stub when USE_NETWORK is absent.
		MAME_DIR .. "src/osd/modules/netdev/pcap.cpp",
		MAME_DIR .. "src/osd/modules/netdev/taptun.cpp",
		MAME_DIR .. "src/osd/modules/output/output_module.h",
		MAME_DIR .. "src/osd/modules/output/none.cpp",
		MAME_DIR .. "src/osd/modules/output/console.cpp",
		MAME_DIR .. "src/osd/modules/output/network.cpp",
		MAME_DIR .. "src/osd/modules/diagnostics/diagnostics_module.h",
		MAME_DIR .. "src/osd/modules/diagnostics/none.cpp",
	}



---------------------------------------------------------------------------
-- ocore_headless: core OS services (files, sockets, timing, threads)
---------------------------------------------------------------------------

project ("ocore_" .. _OPTIONS["osd"])
	uuid (os.uuid("ocore_" .. _OPTIONS["osd"]))
	kind (LIBTYPE)

	removeflags {
		"SingleOutputDir",
	}

	dofile("headless_cfg.lua")

	includedirs {
		MAME_DIR .. "src/emu",
		MAME_DIR .. "src/osd",
		MAME_DIR .. "src/lib",
		MAME_DIR .. "src/lib/util",
		MAME_DIR .. "src/osd/headless",
		ext_includedir("asio"),
	}

	files {
		MAME_DIR .. "src/osd/asio.cpp",
		MAME_DIR .. "src/osd/asio.h",
		MAME_DIR .. "src/osd/osdcore.cpp",
		MAME_DIR .. "src/osd/osdcore.h",
		MAME_DIR .. "src/osd/osdfile.h",
		MAME_DIR .. "src/osd/strconv.cpp",
		MAME_DIR .. "src/osd/strconv.h",
		MAME_DIR .. "src/osd/osdsync.cpp",
		MAME_DIR .. "src/osd/osdsync.h",
		MAME_DIR .. "src/osd/modules/osdmodule.cpp",
		MAME_DIR .. "src/osd/modules/osdmodule.h",
		MAME_DIR .. "src/osd/modules/lib/osdlib.h",
	}

	if BASE_TARGETOS == "unix" then
		files {
			MAME_DIR .. "src/osd/modules/lib/osdlib_" .. SDLOS_TARGETOS .. ".cpp",
			MAME_DIR .. "src/osd/modules/file/posixdir.cpp",
			MAME_DIR .. "src/osd/modules/file/posixfile.cpp",
			MAME_DIR .. "src/osd/modules/file/posixfile.h",
			MAME_DIR .. "src/osd/modules/file/posixptty.cpp",
			MAME_DIR .. "src/osd/modules/file/posixsocket.cpp",
		}
	else
		files {
			MAME_DIR .. "src/osd/modules/file/stdfile.cpp",
		}
	end
