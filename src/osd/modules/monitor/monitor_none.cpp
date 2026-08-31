// license:BSD-3-Clause
// copyright-holders:mame-mcp
/*
 * monitor_none.cpp
 *
 * Null monitor provider: reports a single synthetic display.
 *
 * Needed because the core asks the monitor module to pick a monitor
 * during video init even when no windows will ever be created (the
 * headless OSD, or any OSD running with -video none). Without a
 * provider, module selection throws "All monitorprovider modules failed
 * to initialize".
 *
 * The reported geometry only influences default window sizing and
 * aspect calculations, neither of which matter when nothing is drawn to
 * a display. It is deliberately a common 4:3-ish desktop size so that
 * any code doing arithmetic on it gets sane numbers.
 */

#include "modules/osdmodule.h"
#include "monitor_module.h"

#include "monitor_common.h"

#include "modules/lib/osdobj_common.h"
#include "modules/osdwindow.h"

#include <memory>


namespace {

char const *const NONE_MONITOR_NAME = "none";

class none_monitor_info : public osd_monitor_info
{
public:
	none_monitor_info(monitor_module &module, std::uint64_t handle, float aspect)
		: osd_monitor_info(module, handle, std::string(NONE_MONITOR_NAME), aspect)
	{
		none_monitor_info::refresh();
	}

private:
	virtual void refresh() override
	{
		m_pos_size = osd_rect(0, 0, 1920, 1080);
		m_usuable_pos_size = m_pos_size;
		m_is_primary = true;
	}
};


class none_monitor_module : public monitor_module_base
{
public:
	none_monitor_module()
		: monitor_module_base(OSD_MONITOR_PROVIDER, "none")
	{
	}

	// There are no real monitors, so every lookup resolves to the one
	// synthetic entry rather than failing.
	virtual std::shared_ptr<osd_monitor_info> monitor_from_rect(const osd_rect &proposed) override
	{
		if (!m_initialized)
			return nullptr;
		return pick_monitor(dynamic_cast<osd_options &>(*m_options), 0);
	}

	virtual std::shared_ptr<osd_monitor_info> monitor_from_window(const osd_window &window) override
	{
		if (!m_initialized)
			return nullptr;
		return pick_monitor(dynamic_cast<osd_options &>(*m_options), 0);
	}

protected:
	virtual int init_internal(const osd_options &options) override
	{
		m_options = const_cast<osd_options *>(&options);
		add_monitor(std::make_shared<none_monitor_info>(*this, 1, 1.0f));
		return 0;
	}

private:
	osd_options *m_options = nullptr;
};

} // anonymous namespace


MODULE_DEFINITION(MONITOR_NONE, none_monitor_module)
