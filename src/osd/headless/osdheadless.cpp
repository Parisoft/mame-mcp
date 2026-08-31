// license:BSD-3-Clause
// copyright-holders:mame-mcp
//============================================================
//
//  osdheadless.cpp - headless OSD implementation
//
//  No display server, no window system, no input devices, no fonts.
//
//  The point of this OSD is that the emulation core does not actually
//  need any of those to be useful to an automated consumer:
//
//    * screenshots come from video_manager, which owns a hidden render
//      target and a pure software rasteriser (src/emu/video.cpp);
//    * WAV capture comes from sound_manager's own writer, fed by the
//      mixer rather than by an OSD sound backend;
//    * the debugger engine in src/emu/debug is entirely GUI-free.
//
//  So this file mostly consists of *not* doing things: no SDL init, no
//  window creation, no event pump.
//
//============================================================

#include "osdheadless.h"

#include "modules/lib/osdlib.h"
#include "modules/font/font_module.h"
#include "modules/input/input_module.h"
#include "modules/monitor/monitor_module.h"

#include "emu.h"
#include "emuopts.h"
#include "main.h"
#include "render.h"
#include "video.h"

#include "modules/osdwindow.h"

#include <algorithm>
#include <cstdlib>
#include <functional>


//============================================================
//  OPTIONS
//============================================================

headless_options::headless_options()
	: osd_options()
{
	// Override the inherited defaults for anything that cannot work
	// without a display, so a headless run needs no extra command line.
	// The provider option names come from the module headers rather than
	// from OSDOPTION_*.
	set_default_value(OSDOPTION_VIDEO,             "none");
	set_default_value(OSDOPTION_SOUND,             "none");
	set_default_value(OSD_FONT_PROVIDER,           "none");
	set_default_value(OSD_MONITOR_PROVIDER,        "none");
	set_default_value(OSD_KEYBOARDINPUT_PROVIDER,  "none");
	set_default_value(OSD_MOUSEINPUT_PROVIDER,     "none");
	set_default_value(OSD_LIGHTGUNINPUT_PROVIDER,  "none");
	set_default_value(OSD_JOYSTICKINPUT_PROVIDER,  "none");
	set_default_value(OSDOPTION_DEBUGGER,          "none");

	// Nothing to synchronise to without a display, and agent-driven
	// sessions want maximum speed.
	set_default_value(OPTION_THROTTLE,             "0");
}


//============================================================
//  headless_osd_interface
//============================================================

headless_osd_interface::headless_osd_interface(headless_options &options)
	: osd_common_t(options)
	, m_options(options)
{
}

headless_osd_interface::~headless_osd_interface()
{
}


//============================================================
//  init
//============================================================

void headless_osd_interface::init(running_machine &machine)
{
	// Let the common code register the machine, watchdog and verbosity.
	osd_common_t::init(machine);

	// Honour -numprocessors just like the other OSDs do.
	char const *const stemp = options().numprocessors();
	osd_num_processors = 0;
	if (strcmp(stemp, "auto") != 0)
	{
		osd_num_processors = atoi(stemp);
		if (osd_num_processors < 1)
		{
			osd_printf_warning("numprocessors < 1 doesn't make much sense. Assuming auto ...\n");
			osd_num_processors = 0;
		}
	}

	// Selects and initialises every module (render/sound/input/font/
	// monitor/debugger/...). Our video_init() override below is called
	// from in here and creates no windows.
	osd_common_t::init_subsystems();

	if (options().oslog())
	{
		using namespace std::placeholders;
		machine.add_logerror_callback(std::bind(&headless_osd_interface::output_oslog, this, _1));
	}

	osd_printf_verbose("headless OSD initialised (no display, no input)\n");
}


void headless_osd_interface::output_oslog(const char *buffer)
{
	fputs(buffer, stderr);
}


//============================================================
//  video
//============================================================

bool headless_osd_interface::video_init()
{
	// No windows: the SDL OSD creates one osd_window per screen here,
	// which is what forces an SDL video subsystem and, on a normal
	// build, a real window even with -video none.
	//
	// We do still have to allocate ONE render target. render_manager
	// only adopts a non-hidden target as the UI target
	// (render.cpp: "make us the UI target if there is none"), and
	// render_manager::ui_target() asserts that it is non-null. The
	// frontend calls it every frame via
	// emulator_info::draw_user_interface(), so with zero targets the
	// emulator dereferences a null pointer as soon as it starts running.
	//
	// This target is never presented anywhere -- nothing reads its
	// primitives -- but it gives the UI layer somewhere to render and
	// keeps the core's assumptions intact. Screenshots are unaffected:
	// video_manager owns its own separate hidden snapshot target.
	m_target = machine().render().target_alloc();
	if (!m_target)
	{
		osd_printf_error("headless: could not allocate a render target\n");
		return false;
	}
	m_target->set_bounds(640, 480, 1.0f);

	return true;
}

bool headless_osd_interface::window_init()
{
	return true;
}

void headless_osd_interface::video_exit()
{
	if (m_target)
	{
		machine().render().target_free(m_target);
		m_target = nullptr;
	}
}

void headless_osd_interface::window_exit()
{
}


//============================================================
//  update / input
//============================================================

void headless_osd_interface::update(bool skip_redraw)
{
	osd_common_t::update(skip_redraw);

	// No windows to blit to. We still have to tick the debugger so that
	// OSD debug modules (including the MCP bridge) get their periodic
	// callback while the machine is running.
	if ((machine().debug_flags & DEBUG_FLAG_OSD_ENABLED) != 0)
		debugger_update();
}

void headless_osd_interface::input_update(bool relative_reset)
{
	// The "none" input modules have no devices to poll, but keep the
	// call so any future virtual input provider still works.
	poll_input_modules(relative_reset);
}

void headless_osd_interface::check_osd_inputs()
{
	// No UI hotkeys without a keyboard.
}


//============================================================
//  osd_exit
//============================================================

void headless_osd_interface::osd_exit()
{
	osd_common_t::osd_exit();
}


//============================================================
//  OSD-provided globals
//
//  Each OSD is expected to define these; the emulator core and the
//  frontend reference them unconditionally.
//============================================================

// Referenced by osdwindow.cpp. No windows are ever created here, but the
// translation unit is still linked, so the symbol has to exist.
osd_video_config video_config;


void osd_setup_osd_specific_emu_options(emu_options &opts)
{
	opts.add_entries(osd_options::s_option_entries);
}


void osd_set_aggressive_input_focus(bool aggressive_focus)
{
	// No input and no window manager: nothing to do.
}
