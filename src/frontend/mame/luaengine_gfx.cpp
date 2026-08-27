// license:BSD-3-Clause
// copyright-holders:mame-mcp
/***************************************************************************

    luaengine_gfx.cpp

    Lua bindings for decoded graphics: gfx_element, device_gfx_interface
    and tilemap_t.

    Motivation: MAME already knows how to decode a driver's graphics (the
    gfx_decode_entry layouts in the driver), but the only consumer of that
    knowledge is the interactive tile viewer in src/frontend/mame/ui/
    viewgfx.cpp, which needs a UI. There is no debugger command for it
    either, so on a headless build the decoded graphics were previously
    unreachable.

    These bindings expose the decoded pixels directly, which lets an
    automated consumer render tile sheets and tilemaps to images. The
    rendering follows gfx_viewer::gfxset_draw_item() in viewgfx.cpp.

***************************************************************************/

#include "emu.h"
#include "luaengine.ipp"

#include "drawgfx.h"
#include "digfx.h"
#include "emupal.h"
#include "fileio.h"
#include "machine.h"
#include "screen.h"
#include "tilemap.h"

#include "png.h"

#include <algorithm>
#include <cstring>


namespace {

//-------------------------------------------------
//  gfx_element wrapper
//
//  gfx_element is owned by its device_gfx_interface, so the wrapper
//  holds a bare pointer plus the owning device to keep tag information
//  available for diagnostics.
//-------------------------------------------------

struct gfx_element_wrapper
{
	gfx_element_wrapper(gfx_element &g, device_t &dev, unsigned idx)
		: gfx(&g), device(&dev), index(idx)
	{ }

	gfx_element *gfx;
	device_t *device;
	unsigned index;
};


//-------------------------------------------------
//  render one decoded tile into an ARGB32 bitmap
//
//  Mirrors gfx_viewer::gfxset_draw_item(). The palette pointer walks
//  colorbase + colour * granularity, which is how MAME maps a gfx
//  element's pen indices onto the device palette.
//-------------------------------------------------

void draw_gfx_element(
		bitmap_argb32 &dest,
		gfx_element &gfx,
		u32 code,
		u32 color,
		int dstx,
		int dsty)
{
	int const width = gfx.width();
	int const height = gfx.height();

	rgb_t const *palette = nullptr;
	if (gfx.has_palette())
	{
		palette = gfx.palette().palette()->entry_list_raw()
				+ gfx.colorbase() + (color * gfx.granularity());
	}

	u8 const *const src = gfx.get_data(code);

	for (int y = 0; y < height; y++)
	{
		if ((dsty + y) < 0 || (dsty + y) >= dest.height())
			continue;
		u32 *d = &dest.pix(dsty + y, dstx);
		u8 const *const s = src + (y * gfx.rowbytes());
		for (int x = 0; x < width; x++)
		{
			if ((dstx + x) < 0 || (dstx + x) >= dest.width())
				continue;
			u8 const pen = s[x];
			// Without a palette, fall back to a greyscale ramp scaled to
			// the element's bit depth so the data is still legible.
			*d++ = palette
					? (0xff000000 | palette[pen])
					: (0xff000000 | (pen * 0x010101 * 255 / std::max<u32>(1, (1U << gfx.depth()) - 1)));
		}
	}
}

//-------------------------------------------------
//  write an ARGB32 bitmap out as a PNG
//
//  Returning the bitmap to Lua is not practical: the bitmap usertypes
//  are bound to a bitmap_helper class private to luaengine_render.cpp.
//  Writing the file here keeps this module self-contained and gives the
//  caller something it can hand straight to an image consumer.
//-------------------------------------------------

bool write_png(bitmap_argb32 const &bitmap, char const *filename, std::string &err)
{
	emu_file file(OPEN_FLAG_WRITE | OPEN_FLAG_CREATE | OPEN_FLAG_CREATE_PATHS);
	std::error_condition const filerr = file.open(filename);
	if (filerr)
	{
		err = filerr.message();
		return false;
	}
	util::png_info pnginfo;
	std::error_condition const pngerr = util::png_write_bitmap(file, &pnginfo, bitmap, 0, nullptr);
	if (pngerr)
	{
		err = pngerr.message();
		return false;
	}
	return true;
}

} // anonymous namespace


//-------------------------------------------------
//  initialize_gfx - register graphics classes
//-------------------------------------------------

void lua_engine::initialize_gfx(sol::table &emu)
{

/*  gfx_element library
 *
 * manager.machine.devices[tag].gfx[index]
 *
 * gfx.width          - tile width in pixels
 * gfx.height         - tile height in pixels
 * gfx.elements       - number of tiles in the set
 * gfx.depth          - bits per pixel
 * gfx.colors         - number of colours (palette groups)
 * gfx.granularity    - palette entries per colour
 * gfx.colorbase      - first palette entry used
 * gfx.rowbytes       - stride of the decoded data
 * gfx.has_palette    - whether a palette is attached
 *
 * gfx:pixels(code)   - decoded pen indices for one tile, as a byte
 *                      string of width*height bytes
 * gfx:pen_usage(code)- bitmask of pens used by a tile (0 if unavailable)
 * gfx:sheet(filename, first, count, columns, color)
 *                    - render a range of tiles as a PNG grid; returns
 *                      width, height, tiles drawn and column count
 */

	auto gfx_type = sol().registry().new_usertype<gfx_element_wrapper>("gfx", sol::no_constructor);
	gfx_type["width"] = sol::property([] (gfx_element_wrapper const &g) { return g.gfx->width(); });
	gfx_type["height"] = sol::property([] (gfx_element_wrapper const &g) { return g.gfx->height(); });
	gfx_type["elements"] = sol::property([] (gfx_element_wrapper const &g) { return g.gfx->elements(); });
	gfx_type["depth"] = sol::property([] (gfx_element_wrapper const &g) { return g.gfx->depth(); });
	gfx_type["colors"] = sol::property([] (gfx_element_wrapper const &g) { return g.gfx->colors(); });
	gfx_type["granularity"] = sol::property([] (gfx_element_wrapper const &g) { return g.gfx->granularity(); });
	gfx_type["colorbase"] = sol::property([] (gfx_element_wrapper const &g) { return g.gfx->colorbase(); });
	gfx_type["rowbytes"] = sol::property([] (gfx_element_wrapper const &g) { return g.gfx->rowbytes(); });
	gfx_type["index"] = sol::property([] (gfx_element_wrapper const &g) { return g.index; });
	gfx_type["has_palette"] = sol::property([] (gfx_element_wrapper const &g) { return g.gfx->has_palette(); });
	gfx_type["device"] = sol::property([] (gfx_element_wrapper const &g) { return g.device; });

	gfx_type.set_function(
			"pixels",
			[] (gfx_element_wrapper &g, sol::this_state s, u32 code) -> sol::object
			{
				if (code >= g.gfx->elements())
					return sol::lua_nil;
				unsigned const w = g.gfx->width();
				unsigned const h = g.gfx->height();
				buffer_helper buf(s);
				auto space = buf.prepare(size_t(w) * h);
				u8 *out = reinterpret_cast<u8 *>(space.get());
				u8 const *const src = g.gfx->get_data(code);
				for (unsigned y = 0; y < h; y++)
					std::memcpy(out + (size_t(y) * w), src + (size_t(y) * g.gfx->rowbytes()), w);
				space.add(size_t(w) * h);
				buf.push();
				return sol::make_reference(s, sol::stack_reference(s, -1));
			});

	gfx_type.set_function(
			"pen_usage",
			[] (gfx_element_wrapper &g, u32 code) -> u32
			{
				if (!g.gfx->has_pen_usage() || (code >= g.gfx->elements()))
					return 0;
				return g.gfx->pen_usage(code);
			});

	// Render a contiguous range of tiles into a grid. This is the
	// headless equivalent of MAME's F4 tile viewer.
	gfx_type.set_function(
			"sheet",
			[] (gfx_element_wrapper &g, sol::this_state s, std::string const &filename, sol::object first_obj, sol::object count_obj, sol::object cols_obj, sol::object color_obj)
			{
				u32 const total = g.gfx->elements();
				u32 first = first_obj.is<u32>() ? first_obj.as<u32>() : 0;
				if (first >= total)
					first = total ? (total - 1) : 0;
				u32 count = count_obj.is<u32>() ? count_obj.as<u32>() : std::min<u32>(total - first, 256);
				count = std::min<u32>(count, total - first);
				u32 cols = cols_obj.is<u32>() ? cols_obj.as<u32>() : 16;
				cols = std::clamp<u32>(cols, 1, 256);
				u32 const color = color_obj.is<u32>()
						? std::min<u32>(color_obj.as<u32>(), g.gfx->colors() ? (g.gfx->colors() - 1) : 0)
						: 0;

				u32 const rows = count ? ((count + cols - 1) / cols) : 0;
				int const w = int(cols) * g.gfx->width();
				int const h = int(rows) * g.gfx->height();

				if ((w <= 0) || (h <= 0))
					luaL_error(s, "empty tile range");

				bitmap_argb32 bitmap(w, h);
				bitmap.fill(0xff000000);
				for (u32 i = 0; i < count; i++)
				{
					u32 const cx = i % cols;
					u32 const cy = i / cols;
					draw_gfx_element(
							bitmap, *g.gfx, first + i, color,
							int(cx) * g.gfx->width(),
							int(cy) * g.gfx->height());
				}

				std::string err;
				if (!write_png(bitmap, filename.c_str(), err))
					luaL_error(s, "could not write %s: %s", filename.c_str(), err.c_str());

				return std::make_tuple(w, h, count, cols);
			});


/*  tilemap library
 *
 * manager.machine.tilemaps[index]
 *
 * tmap.width / tmap.height - size in pixels
 * tmap:pixels()            - the composed tilemap as pen indices
 * tmap:render(filename)    - the composed tilemap written as a PNG
 * tmap:flags()             - per-pixel attribute/priority bytes
 */

	auto tmap_type = sol().registry().new_usertype<tilemap_t>("tilemap", sol::no_constructor);
	tmap_type["width"] = sol::property(&tilemap_t::width);
	tmap_type["height"] = sol::property(&tilemap_t::height);
	tmap_type["enabled"] = sol::property(&tilemap_t::enabled);
	tmap_type["palette"] = sol::property(
			[] (tilemap_t &t) -> device_palette_interface * { return &t.palette(); });

	tmap_type.set_function(
			"pixels",
			[] (tilemap_t &t, sol::this_state s)
			{
				bitmap_ind16 &pix = t.pixmap(); // forces a pixmap_update()
				int const w = pix.width();
				int const h = pix.height();
				buffer_helper buf(s);
				auto space = buf.prepare(size_t(w) * h * 2);
				u16 *out = reinterpret_cast<u16 *>(space.get());
				for (int y = 0; y < h; y++)
					std::memcpy(out + (size_t(y) * w), &pix.pix(y, 0), size_t(w) * 2);
				space.add(size_t(w) * h * 2);
				buf.push();
				return std::make_tuple(sol::make_reference(s, sol::stack_reference(s, -1)), w, h);
			});

	tmap_type.set_function(
			"flags",
			[] (tilemap_t &t, sol::this_state s)
			{
				bitmap_ind8 &fm = t.flagsmap();
				int const w = fm.width();
				int const h = fm.height();
				buffer_helper buf(s);
				auto space = buf.prepare(size_t(w) * h);
				u8 *out = reinterpret_cast<u8 *>(space.get());
				for (int y = 0; y < h; y++)
					std::memcpy(out + (size_t(y) * w), &fm.pix(y, 0), size_t(w));
				space.add(size_t(w) * h);
				buf.push();
				return std::make_tuple(sol::make_reference(s, sol::stack_reference(s, -1)), w, h);
			});

	// Compose the tilemap through its palette into a true-colour bitmap.
	tmap_type.set_function(
			"render",
			[] (tilemap_t &t, sol::this_state s, std::string const &filename)
			{
				bitmap_ind16 &pix = t.pixmap();
				int const w = pix.width();
				int const h = pix.height();
				bitmap_argb32 bitmap(w, h);
				rgb_t const *const palette = t.palette().palette()->entry_list_adjusted();
				u32 const entries = t.palette().entries();
				for (int y = 0; y < h; y++)
				{
					u16 const *src = &pix.pix(y, 0);
					u32 *dst = &bitmap.pix(y, 0);
					for (int x = 0; x < w; x++)
					{
						u16 const pen = *src++;
						*dst++ = 0xff000000 | ((pen < entries) ? palette[pen] : rgb_t(0, 0, 0));
					}
				}

				std::string err;
				if (!write_png(bitmap, filename.c_str(), err))
					luaL_error(s, "could not write %s: %s", filename.c_str(), err.c_str());

				return std::make_tuple(w, h);
			});


/*  accessors
 *
 * Registered here rather than in luaengine.cpp so that this module is
 * fully self-contained: adding it touches only the initialize_gfx()
 * declaration and call site.
 *
 * manager.machine.devices[tag].gfx        - table of gfx sets, keyed by index
 * manager.machine.tilemaps                - table of tilemaps, keyed by index
 * manager.machine.tilemaps.count
 */

	auto device_type = sol().registry()["device"];
	if (device_type.valid())
	{
		sol::usertype<device_t> dev = device_type;
		dev["gfx"] = sol::property(
				[this] (device_t &d)
				{
					sol::table table = sol().create_table();
					device_gfx_interface *intf = nullptr;
					if (d.interface(intf))
					{
						for (unsigned i = 0; i < MAX_GFX_ELEMENTS; i++)
						{
							gfx_element *const g = intf->gfx(i);
							if (g)
								table[i] = gfx_element_wrapper(*g, d, i);
						}
					}
					return table;
				});
	}

	auto machine_type = sol().registry()["machine"];
	if (machine_type.valid())
	{
		sol::usertype<running_machine> mach = machine_type;
		mach["tilemaps"] = sol::property(
				[this] (running_machine &m)
				{
					sol::table table = sol().create_table();
					tilemap_manager &tm = m.tilemap();
					int const n = tm.count();
					for (int i = 0; i < n; i++)
					{
						tilemap_t *const t = tm.find(i);
						if (t)
							table[i] = t;
					}
					table["count"] = n;
					return table;
				});
	}
}
