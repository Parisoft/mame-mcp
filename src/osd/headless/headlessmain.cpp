// license:BSD-3-Clause
// copyright-holders:mame-mcp
//============================================================
//
//  headlessmain.cpp - entry point for the headless OSD
//
//  Deliberately tiny: no SDL, no fontconfig, no crash-diagnostics
//  module, no platform windowing. Just hand control to the MAME
//  frontend with a headless OSD instance.
//
//============================================================

#include "osdheadless.h"

#include "emu.h"
#include "main.h"

#include "osdepend.h"

#include <cstdio>


int main(int argc, char *argv[])
{
	std::vector<std::string> args = osd_get_command_line(argc, argv);

	// Unbuffered, so a supervising process sees output immediately even
	// when stdout is a pipe rather than a terminal.
	setvbuf(stdout, (char *)nullptr, _IONBF, 0);
	setvbuf(stderr, (char *)nullptr, _IONBF, 0);

	int res = 0;
	{
		headless_options options;
		headless_osd_interface osd(options);
		osd.register_options();
		res = emulator_info::start_frontend(options, osd, args);
	}

	return res;
}
