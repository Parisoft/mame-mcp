-- license:BSD-3-Clause
-- copyright-holders:mame-mcp

--------------------------------------------------
-- headless_cfg.lua
--
-- Compiler configuration shared by every headless project.
--
-- The whole point of this OSD is what is NOT defined here: no OSD_SDL,
-- no SDLMAME_*, no USE_OPENGL, no SDLMAME_X11. Those defines are what
-- activate the SDL/X11/GL code paths inside the shared osd modules, so
-- leaving them out makes those modules compile down to their
-- MODULE_NOT_SUPPORTED stubs.
--------------------------------------------------

defines {
	"OSD_HEADLESS",
	"USE_OPENGL=0",
}

if _OPTIONS["targetos"] == "linux" or BASE_TARGETOS == "unix" then
	defines {
		"SDLMAME_UNIX",  -- selects POSIX file/dir/socket implementations in ocore
	}
end

if _OPTIONS["NO_USE_MIDI"] == "1" then
	defines {
		"NO_USE_MIDI",
	}
end

if _OPTIONS["NO_USE_PORTAUDIO"] == "1" then
	defines {
		"NO_USE_PORTAUDIO",
	}
end

-- The pulse/pipewire sound modules are never built here, but the shared
-- registration code in osdobj_common.cpp is guarded on these.
defines {
	"NO_USE_PULSEAUDIO",
	"NO_USE_PIPEWIRE",
}

if _OPTIONS["USE_TAPTUN"] == "1" or _OPTIONS["USE_PCAP"] == "1" then
	defines {
		"USE_NETWORK",
	}
	if _OPTIONS["USE_TAPTUN"] == "1" then
		defines { "OSD_NET_USE_TAPTUN" }
	end
	if _OPTIONS["USE_PCAP"] == "1" then
		defines { "OSD_NET_USE_PCAP" }
	end
end
