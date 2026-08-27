// license:BSD-3-Clause
// copyright-holders:mame-mcp
//============================================================
//
//  osdheadless.h - headless OSD interface
//
//  A minimal OSD with no display server, no windowing toolkit and no
//  input devices. Intended for automated/agent-driven use: the machine
//  runs, the debugger works, and screenshots/WAV capture still function
//  because those are produced by the emulation core (video_manager's
//  hidden software-rendered snapshot target and sound_manager's WAV
//  writer), not by the OSD.
//
//  See docs/mcp/PLAN.md phase 2.
//
//============================================================
#ifndef MAME_OSD_HEADLESS_OSDHEADLESS_H
#define MAME_OSD_HEADLESS_OSDHEADLESS_H

#pragma once

#include "modules/lib/osdobj_common.h"

#include "osdepend.h"

class render_target;


//============================================================
//  GLOBALS
//============================================================

// defined in src/osd/osdsync.cpp; honours -numprocessors
extern int osd_num_processors;


//============================================================
//  TYPE DEFINITIONS
//============================================================

class headless_options : public osd_options
{
public:
	headless_options();
};


class headless_osd_interface : public osd_common_t
{
public:
	headless_osd_interface(headless_options &options);
	virtual ~headless_osd_interface();

	// general overridables
	virtual void init(running_machine &machine) override;
	virtual void update(bool skip_redraw) override;
	virtual void input_update(bool relative_reset) override;
	virtual void check_osd_inputs() override;

	// video: deliberately create no windows at all
	virtual bool video_init() override;
	virtual bool window_init() override;
	virtual void video_exit() override;
	virtual void window_exit() override;

	virtual headless_options &options() override { return m_options; }

	// osd_common_t pure virtuals: there is no event loop and no focus
	virtual void process_events() override { }
	virtual bool has_focus() const override { return true; }

private:
	virtual void osd_exit() override;

	void output_oslog(const char *buffer);

	headless_options &m_options;

	// Sole render target. Never presented; exists so that
	// render_manager has a UI target (see video_init()).
	render_target *m_target = nullptr;
};

#endif // MAME_OSD_HEADLESS_OSDHEADLESS_H
