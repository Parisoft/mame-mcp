#!/usr/bin/env node
// license:BSD-3-Clause
// copyright-holders:mame-mcp
//
// MCP server exposing a headless MAME as debugging / reverse-engineering
// tools. Transport is stdio, so nothing may be written to stdout except MCP
// protocol traffic -- MAME's own output is captured by the session and
// surfaced through tools instead.
//
// See docs/mcp/PLAN.md section 5 for the tool taxonomy.

import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { z } from 'zod';
import fs from 'node:fs';
import path from 'node:path';
import { MameSession } from './session.mjs';

// Default MAME_DIR to the repository root (three levels up from src/), not
// the server's cwd -- otherwise -pluginspath and the binary path miss.
const repoRoot = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..', '..');
const session = new MameSession({
  mameDir: process.env.MAME_DIR || repoRoot,
});

// ---------------------------------------------------------------- helpers

const MAX_INLINE_IMAGE = 1_000_000; // ~1MB before we return a link instead

function textResult(obj, { text } = {}) {
  const body = text ?? (typeof obj === 'string' ? obj : JSON.stringify(obj, null, 2));
  return { content: [{ type: 'text', text: body }], structuredContent: typeof obj === 'object' && obj !== null && !Array.isArray(obj) ? obj : undefined };
}

function errResult(err) {
  // MCP SEP-1303: input/validation problems are tool execution errors so the
  // model can read them and self-correct, not protocol errors.
  return { content: [{ type: 'text', text: `Error: ${err.message || String(err)}` }], isError: true };
}

// Wrap a handler so every failure becomes a readable tool error.
const guard = (fn) => async (args = {}) => {
  try { return await fn(args); } catch (e) { return errResult(e); }
};

// Attach a generated PNG to a tool result as inline MCP image content,
// falling back to a path reference when it is too large.
function withImage(res, file) {
  const content = [{ type: 'text', text: JSON.stringify(res, null, 2) }];
  try {
    const buf = fs.readFileSync(file);
    if (buf.length <= MAX_INLINE_IMAGE) {
      content.push({ type: 'image', data: buf.toString('base64'), mimeType: 'image/png' });
    } else {
      content.push({ type: 'text', text: `Image is ${buf.length} bytes; too large to inline. Read it from ${file}.` });
    }
  } catch (e) {
    content.push({ type: 'text', text: `Could not read ${file}: ${e.message}` });
  }
  return { content, structuredContent: res };
}

function requireSession() {
  if (!session.proc || !session.ready) {
    throw new Error('no MAME session running. Call session.start first (e.g. {"driver":"gridlee"}).');
  }
}

// Thin passthrough to a plugin RPC method.
const passthrough = (method, timeout) => guard(async (args) => {
  requireSession();
  const res = await session.call(method, args, timeout);
  return textResult(res);
});

const server = new McpServer(
  { name: 'mame-mcp', version: '0.1.0' },
  {
    capabilities: { tools: {}, logging: {} },
    instructions: [
      'Drive a headless MAME to debug and reverse-engineer arcade ROMs.',
      '',
      'ALWAYS start with session.start, then machine.describe -- describe returns the',
      'hardware memory map (CPUs, address spaces, ROM regions, RAM shares, screens)',
      'that the driver already encodes, so you never have to guess at it.',
      '',
      'Execution model: the CPU is either running, paused, or stopped at a',
      'breakpoint. Memory and registers are only coherent when stopped. Typical',
      'loop: bp.set -> exec.resume -> exec.wait_for_stop -> cpu.registers / mem.read.',
      '',
      'Addresses accept 0x1234, $1234, bare hex, decimal, or debugger expressions',
      'like "pc+4". Every result echoes the resolved value.',
      '',
      'If a wrapper is missing, debug.command runs any raw MAME debugger command.',
    ].join('\n'),
  },
);

// Shared argument fragments.
const deviceArg = { device: z.string().optional().describe('Device tag, e.g. ":maincpu". Defaults to the debugger\'s visible CPU.') };
const spaceArg = { space: z.enum(['program', 'data', 'io', 'opcodes']).optional().describe('Address space (default "program").') };
const addrArg = (desc) => ({ address: z.union([z.string(), z.number()]).describe(desc) });

const RO = { readOnlyHint: true };
const RW = { readOnlyHint: false, destructiveHint: true };
const SAFE_W = { readOnlyHint: false, destructiveHint: false };

// ================================================================= session

server.registerTool('session.start', {
  title: 'Start a MAME session',
  description: 'Launch MAME headless for a driver with the debugger active. Must be called before any other tool.',
  inputSchema: {
    driver: z.string().describe('Driver short name, e.g. "gridlee". Use session.list_drivers to find one.'),
    sound: z.boolean().optional().describe('Enable the sound backend. Leave false for headless; WAV capture works either way.'),
    seconds_to_run: z.number().optional().describe('Auto-exit after N emulated seconds (a useful watchdog).'),
    extra_args: z.array(z.string()).optional().describe('Additional raw MAME command-line arguments.'),
  },
  annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false },
}, guard(async ({ driver, sound, seconds_to_run, extra_args }) => {
  if (session.proc) await session.stop();
  await session.start(driver, { sound, secondsToRun: seconds_to_run, extraArgs: extra_args });
  const describe = await session.call('machine.describe', {});
  return textResult({
    started: true,
    driver,
    info: session.info,
    cpus: describe.cpus,
    regions: describe.regions,
    screens: describe.screens,
    hint: 'Call machine.describe for the full memory map.',
  });
}));

server.registerTool('session.stop', {
  title: 'Stop the MAME session',
  description: 'Terminate the running MAME process.',
  inputSchema: {},
  annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: true },
}, guard(async () => {
  await session.stop();
  return textResult({ stopped: true });
}));

server.registerTool('session.status', {
  title: 'Session status',
  description: 'Whether MAME is running, the execution state, and the tail of its output log.',
  inputSchema: { log_lines: z.number().optional() },
  annotations: RO,
}, guard(async ({ log_lines }) => {
  if (!session.proc) return textResult({ running: false });
  let machineStatus = null;
  try { machineStatus = await session.call('machine.status', {}, 5000); } catch { /* may be mid-stop */ }
  return textResult({
    running: true,
    ready: session.ready,
    driver: session.driver,
    execution_state: session.execState,
    last_stop: session.lastStop,
    machine: machineStatus,
    log: session.logTail(log_lines ?? 20),
  });
}));

server.registerTool('session.list_drivers', {
  title: 'List available drivers',
  description: 'Search the drivers compiled into this MAME binary by name or description.',
  inputSchema: {
    filter: z.string().optional().describe('Case-insensitive substring match.'),
    limit: z.number().optional(),
  },
  annotations: RO,
}, guard(async ({ filter, limit }) => {
  const { execFileSync } = await import('node:child_process');
  const out = execFileSync(session.mameBin, ['-listfull'], {
    cwd: session.mameDir, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024,
  });
  const lines = out.split('\n').slice(1).filter(Boolean);
  const needle = (filter || '').toLowerCase();
  const rows = [];
  for (const line of lines) {
    const m = line.match(/^(\S+)\s+"(.*)"\s*$/);
    if (!m) continue;
    if (needle && !m[1].toLowerCase().includes(needle) && !m[2].toLowerCase().includes(needle)) continue;
    rows.push({ name: m[1], description: m[2] });
    if (rows.length >= (limit ?? 100)) break;
  }
  return textResult({ drivers: rows, count: rows.length, total_available: lines.length });
}));

// ================================================================= machine

server.registerTool('machine.describe', {
  title: 'Describe the emulated hardware',
  description:
    'The memory map the driver already knows: CPUs and their address spaces, ROM regions, ' +
    'RAM shares, screens. Call this first -- it saves reverse-engineering what MAME can just tell you.',
  inputSchema: {},
  annotations: RO,
}, passthrough('machine.describe'));

server.registerTool('machine.reset', {
  title: 'Reset the machine',
  description: 'Reset the emulated machine. Soft reset by default; pass hard=true for a full power cycle.',
  inputSchema: { hard: z.boolean().optional() },
  annotations: RW,
}, passthrough('machine.reset'));

// =============================================================== execution

server.registerTool('exec.state', {
  title: 'Execution state',
  description: 'Whether the CPU is running, paused, or stopped at a breakpoint.',
  inputSchema: {},
  annotations: RO,
}, passthrough('exec.state'));

server.registerTool('exec.pause', {
  title: 'Pause emulation', description: 'Pause the scheduler. Screenshots and memory reads still work while paused.',
  inputSchema: {}, annotations: SAFE_W,
}, passthrough('exec.pause'));

server.registerTool('exec.resume', {
  title: 'Resume emulation',
  description: 'Resume from a breakpoint or pause. Pair with exec.wait_for_stop to catch the next trap.',
  inputSchema: {}, annotations: SAFE_W,
}, passthrough('exec.resume'));

server.registerTool('exec.step', {
  title: 'Step instructions',
  description: 'Execute N instructions (steps into calls).',
  inputSchema: { ...deviceArg, count: z.number().optional() },
  annotations: SAFE_W,
}, passthrough('exec.step'));

server.registerTool('exec.step_over', {
  title: 'Step over',
  description: 'Execute N instructions, stepping over subroutine calls.',
  inputSchema: { count: z.number().optional() }, annotations: SAFE_W,
}, passthrough('exec.step_over'));

server.registerTool('exec.step_out', {
  title: 'Step out',
  description: 'Run until the current subroutine returns.',
  inputSchema: {}, annotations: SAFE_W,
}, passthrough('exec.step_out'));

server.registerTool('exec.run_to', {
  title: 'Run to address',
  description: 'Resume until the PC reaches an address.',
  inputSchema: { ...deviceArg, ...addrArg('Target address.') },
  annotations: SAFE_W,
}, passthrough('exec.run_to'));

server.registerTool('exec.run_for', {
  title: 'Run for emulated milliseconds',
  description: 'Advance a bounded amount of emulated time. The safest way to "let it run a bit".',
  inputSchema: { milliseconds: z.number().optional() }, annotations: SAFE_W,
}, passthrough('exec.run_for'));

server.registerTool('exec.run_until_vblank', {
  title: 'Run until VBLANK', description: 'Resume until the next vertical blank.',
  inputSchema: {}, annotations: SAFE_W,
}, passthrough('exec.run_until_vblank'));

server.registerTool('exec.run_until_interrupt', {
  title: 'Run until interrupt',
  description: 'Resume until an interrupt fires (optionally a specific IRQ line).',
  inputSchema: { irq: z.number().optional() }, annotations: SAFE_W,
}, passthrough('exec.run_until_interrupt'));

server.registerTool('exec.wait_for_stop', {
  title: 'Wait for the CPU to stop',
  description:
    'Block until the CPU hits a breakpoint/watchpoint or the timeout expires. Returns the stop ' +
    'reason, the trapped index, the PC and the device. Implemented in the supervisor, so it never ' +
    'blocks the emulator.',
  inputSchema: { timeout_ms: z.number().optional().describe('Default 10000.') },
  annotations: RO,
}, guard(async ({ timeout_ms }) => {
  requireSession();
  const info = await session.waitForStop(timeout_ms ?? 10000);
  return textResult(info);
}));

// ============================================================= breakpoints

server.registerTool('bp.set', {
  title: 'Set a breakpoint',
  description: 'Break when the PC reaches an address. Conditions are full debugger expressions, e.g. "{A}==5".',
  inputSchema: {
    ...deviceArg, ...addrArg('Address to break on.'),
    condition: z.string().optional().describe('Debugger expression; the breakpoint only fires when true.'),
    action: z.string().optional().describe('Debugger command to run automatically on hit.'),
  },
  annotations: SAFE_W,
}, passthrough('bp.set'));

server.registerTool('bp.list', {
  title: 'List breakpoints', description: 'All breakpoints, across every CPU unless a device is given.',
  inputSchema: { ...deviceArg }, annotations: RO,
}, passthrough('bp.list'));

server.registerTool('bp.clear', {
  title: 'Clear breakpoints', description: 'Clear one breakpoint by index, or all of them.',
  inputSchema: { ...deviceArg, index: z.number().optional() }, annotations: SAFE_W,
}, passthrough('bp.clear'));

server.registerTool('bp.enable', {
  title: 'Enable breakpoints', description: 'Enable one breakpoint by index, or all.',
  inputSchema: { ...deviceArg, index: z.number().optional() }, annotations: SAFE_W,
}, passthrough('bp.enable'));

server.registerTool('bp.disable', {
  title: 'Disable breakpoints', description: 'Disable one breakpoint by index, or all.',
  inputSchema: { ...deviceArg, index: z.number().optional() }, annotations: SAFE_W,
}, passthrough('bp.disable'));

server.registerTool('wp.set', {
  title: 'Set a watchpoint',
  description:
    'Break when a memory range is read and/or written. The primary tool for "what code touches ' +
    'this address?" -- combine with cpu.registers on the stop to identify the writer.',
  inputSchema: {
    ...deviceArg, ...spaceArg, ...addrArg('Start address of the watched range.'),
    length: z.number().optional().describe('Bytes to watch (default 1).'),
    type: z.enum(['r', 'w', 'rw']).optional().describe('Trap on read, write, or both (default "w").'),
    condition: z.string().optional(),
    action: z.string().optional(),
  },
  annotations: SAFE_W,
}, passthrough('wp.set'));

server.registerTool('wp.list', {
  title: 'List watchpoints', description: 'Watchpoints for a device and address space.',
  inputSchema: { ...deviceArg, ...spaceArg }, annotations: RO,
}, passthrough('wp.list'));

server.registerTool('wp.clear', {
  title: 'Clear watchpoints', description: 'Clear one watchpoint by index, or all.',
  inputSchema: { ...deviceArg, index: z.number().optional() }, annotations: SAFE_W,
}, passthrough('wp.clear'));

server.registerTool('rp.set', {
  title: 'Set a registerpoint',
  description: 'Break when an expression becomes true, e.g. "A==0x10". Evaluated every instruction, so it is slow but powerful.',
  inputSchema: { condition: z.string(), action: z.string().optional() },
  annotations: SAFE_W,
}, passthrough('rp.set'));

server.registerTool('rp.clear', {
  title: 'Clear registerpoints', description: 'Clear one registerpoint by index, or all.',
  inputSchema: { index: z.number().optional() }, annotations: SAFE_W,
}, passthrough('rp.clear'));

// ================================================================== memory

server.registerTool('mem.read', {
  title: 'Read memory',
  description:
    'Read an address range. Returns base64 plus a hex+ASCII dump. Only coherent while the CPU is stopped.',
  inputSchema: {
    ...deviceArg, ...spaceArg, ...addrArg('Start address.'),
    length: z.number().optional().describe('Bytes to read (default 256, max 1MB).'),
    element_size: z.union([z.literal(1), z.literal(2), z.literal(4), z.literal(8)]).optional(),
    mode: z.enum(['logical', 'physical', 'direct']).optional(),
  },
  annotations: RO,
}, passthrough('mem.read'));

server.registerTool('mem.write', {
  title: 'Write memory',
  description: 'Write bytes to an address. Modifies emulation state.',
  inputSchema: {
    ...deviceArg, ...spaceArg, ...addrArg('Start address.'),
    data: z.string().optional().describe('base64 payload.'),
    bytes: z.array(z.number()).optional().describe('Byte values, as an alternative to base64.'),
  },
  annotations: RW,
}, passthrough('mem.write'));

server.registerTool('mem.search', {
  title: 'Search memory',
  description:
    'Find a byte pattern or ASCII string in an address range. Use this to locate strings, ' +
    'tables and known values, then watchpoint the hits.',
  inputSchema: {
    ...deviceArg, ...spaceArg,
    text: z.string().optional().describe('ASCII string to find.'),
    data: z.string().optional().describe('base64 byte pattern.'),
    bytes: z.array(z.number()).optional(),
    start: z.union([z.string(), z.number()]).optional(),
    end: z.union([z.string(), z.number()]).optional(),
    limit: z.number().optional(),
  },
  annotations: RO,
}, passthrough('mem.search', 60000));

server.registerTool('mem.list_regions', {
  title: 'List ROM/RAM regions',
  description: 'Memory regions with sizes and widths. Regions are the raw ROM contents, unaffected by banking.',
  inputSchema: {}, annotations: RO,
}, passthrough('mem.list_regions'));

server.registerTool('mem.region_read', {
  title: 'Read a memory region',
  description:
    'Read directly from a ROM region by tag. Unlike mem.read this bypasses banking and the CPU ' +
    'address map, so it is the right tool for static disassembly and graphics extraction.',
  inputSchema: {
    tag: z.string().describe('Region tag, e.g. ":maincpu" or ":gfx1".'),
    offset: z.union([z.string(), z.number()]).optional(),
    length: z.number().optional(),
  },
  annotations: RO,
}, passthrough('mem.region_read'));

server.registerTool('mem.list_shares', {
  title: 'List RAM shares',
  description: 'Shared RAM blocks. These are usually the actual videoram/spriteram/colorram.',
  inputSchema: {}, annotations: RO,
}, passthrough('mem.list_shares'));

// ===================================================================== cpu

server.registerTool('cpu.list', {
  title: 'List CPUs', description: 'Every executable device with an address space.',
  inputSchema: {}, annotations: RO,
}, passthrough('cpu.list'));

server.registerTool('cpu.registers', {
  title: 'Read CPU registers',
  description: 'All register values for a device. Most useful while stopped at a breakpoint.',
  inputSchema: { ...deviceArg }, annotations: RO,
}, passthrough('cpu.registers'));

server.registerTool('cpu.set_register', {
  title: 'Set a CPU register', description: 'Write a register value.',
  inputSchema: { ...deviceArg, name: z.string(), value: z.union([z.string(), z.number()]) },
  annotations: RW,
}, passthrough('cpu.set_register'));

server.registerTool('cpu.disassemble', {
  title: 'Disassemble code',
  description:
    'Disassemble N instructions from an address (defaults to the current PC). Returns structured ' +
    '{address, bytes, text} entries rather than a text blob, so you can build a call graph from it.',
  inputSchema: {
    ...deviceArg,
    address: z.union([z.string(), z.number()]).optional().describe('Defaults to the current PC.'),
    count: z.number().optional().describe('Instruction count (default 16).'),
  },
  annotations: RO,
}, passthrough('cpu.disassemble', 30000));

server.registerTool('sym.eval', {
  title: 'Evaluate an expression',
  description: 'Evaluate a MAME debugger expression, e.g. "pc+4", "b@0x1000", "{A}".',
  inputSchema: { ...deviceArg, expression: z.string() }, annotations: RO,
}, passthrough('sym.eval'));

server.registerTool('annot.add', {
  title: 'Annotate an address',
  description:
    'Attach a comment to an address. MAME persists these per-ROM, so they are your disassembly ' +
    'notebook and survive across sessions.',
  inputSchema: { ...deviceArg, ...addrArg('Address to annotate.'), text: z.string() },
  annotations: SAFE_W,
}, passthrough('annot.add'));

server.registerTool('annot.save', {
  title: 'Save annotations', description: 'Persist comments to the ROM comment file.',
  inputSchema: {}, annotations: SAFE_W,
}, passthrough('annot.save'));

// ================================================================== video

server.registerTool('video.screenshot', {
  title: 'Take a screenshot',
  description:
    'Capture the current frame as a PNG and return it inline. Works fully headless -- no X server ' +
    'or window is involved.',
  inputSchema: {
    screen: z.string().optional().describe('Screen tag; defaults to all active screens.'),
    filename: z.string().optional(),
  },
  annotations: RO,
}, guard(async (args) => {
  requireSession();

  // MAME writes snapshots to <snapshot_directory>/<driver>/NNNN.png, so the
  // scan has to recurse one level rather than just listing the top directory.
  const listPngs = (dir) => {
    const out = [];
    let entries = [];
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return out; }
    for (const e of entries) {
      const p = path.join(dir, e.name);
      if (e.isDirectory()) out.push(...listPngs(p));
      else if (e.name.toLowerCase().endsWith('.png')) out.push(p);
    }
    return out;
  };

  const before = new Set(listPngs(session.artifacts));
  const res = await session.call('video.screenshot', args);

  // MAME writes asynchronously relative to our RPC reply; give it a moment.
  let created = null;
  for (let i = 0; i < 40 && !created; i++) {
    await new Promise((r) => setTimeout(r, 50));
    const fresh = listPngs(session.artifacts).filter((f) => !before.has(f));
    if (fresh.length) {
      // Newest by mtime, so repeat shots in one session pick the right file.
      created = fresh.map((f) => ({ f, m: fs.statSync(f).mtimeMs }))
        .sort((a, b) => a.m - b.m).pop().f;
    }
  }
  if (!created) {
    return textResult({
      ...res,
      warning: `no new PNG appeared under ${session.artifacts}`,
    });
  }

  const full = created;
  const buf = fs.readFileSync(full);
  const content = [{ type: 'text', text: JSON.stringify({ file: full, bytes: buf.length }, null, 2) }];
  if (buf.length <= MAX_INLINE_IMAGE) {
    content.push({ type: 'image', data: buf.toString('base64'), mimeType: 'image/png' });
  } else {
    content.push({ type: 'text', text: `Image is ${buf.length} bytes; too large to inline. Read it from ${full}.` });
  }
  return { content, structuredContent: { file: full, bytes: buf.length } };
}));

server.registerTool('video.screens', {
  title: 'List screens', description: 'Screens with resolution, refresh rate and frame counter.',
  inputSchema: {}, annotations: RO,
}, passthrough('video.screens'));

// ================================================================== audio

server.registerTool('audio.record_start', {
  title: 'Start WAV capture',
  description: 'Begin recording emulated audio to a .wav file. Works even with the sound backend disabled.',
  inputSchema: { filename: z.string().optional() }, annotations: SAFE_W,
}, passthrough('audio.record_start'));

server.registerTool('audio.record_stop', {
  title: 'Stop WAV capture',
  description: 'Stop recording and report the resulting file.',
  inputSchema: {}, annotations: SAFE_W,
}, guard(async () => {
  requireSession();
  const res = await session.call('audio.record_stop', {});
  const wavs = fs.existsSync(session.mameDir)
    ? fs.readdirSync(session.mameDir).filter((f) => f.endsWith('.wav'))
    : [];
  return textResult({ ...res, wav_files: wavs.map((f) => path.join(session.mameDir, f)) });
}));

// ================================================================== input

server.registerTool('input.list_ports', {
  title: 'List input ports',
  description: 'Input ports and fields (coins, start, buttons, DIP switches).',
  inputSchema: {}, annotations: RO,
}, passthrough('input.list_ports'));

server.registerTool('input.press', {
  title: 'Press an input',
  description: 'Hold an input field for N frames, then release it automatically.',
  inputSchema: {
    port: z.string().describe('Port tag from input.list_ports.'),
    field: z.string().describe('Field name from input.list_ports.'),
    frames: z.number().optional().describe('Frames to hold (default 2).'),
    value: z.number().optional(),
  },
  annotations: SAFE_W,
}, passthrough('input.press'));

// ================================================================== state

server.registerTool('state.save', {
  title: 'Save a save state', description: 'Snapshot machine state to a slot for later restore.',
  inputSchema: { slot: z.string().optional() }, annotations: SAFE_W,
}, passthrough('state.save'));

server.registerTool('state.load', {
  title: 'Load a save state', description: 'Restore machine state from a slot.',
  inputSchema: { slot: z.string().optional() }, annotations: RW,
}, passthrough('state.load'));


// ================================================================ graphics

server.registerTool('gfx.list_sets', {
  title: 'List decoded graphics sets',
  description:
    'Every decoded tile/sprite set the driver defines, with tile size, element count, bit depth ' +
    'and palette layout. Start here before rendering.',
  inputSchema: { ...deviceArg }, annotations: RO,
}, passthrough('gfx.list_sets'));

server.registerTool('gfx.render_tiles', {
  title: 'Render decoded tiles to a PNG',
  description:
    'Render a range of decoded tiles as a PNG contact sheet and return it inline. This is the ' +
    'headless equivalent of MAME\'s F4 tile viewer, and the fastest way to identify what graphics ' +
    'a ROM contains: fonts, sprite sheets, backgrounds. Use gfx.list_sets first to pick a set.',
  inputSchema: {
    ...deviceArg,
    index: z.number().optional().describe('Gfx set index (default 0).'),
    first: z.number().optional().describe('First tile (default 0).'),
    count: z.number().optional().describe('Tiles to render (default 256).'),
    columns: z.number().optional().describe('Tiles per row (default 16).'),
    color: z.number().optional().describe('Palette group to colour with (default 0).'),
    filename: z.string().optional(),
  },
  annotations: RO,
}, guard(async (args) => {
  requireSession();
  const res = await session.call('gfx.render_tiles', args, 30000);
  return withImage(res, res.file);
}));

server.registerTool('gfx.list_tilemaps', {
  title: 'List tilemaps',
  description: 'Tilemaps the driver has created, with their pixel dimensions.',
  inputSchema: {}, annotations: RO,
}, passthrough('gfx.list_tilemaps'));

server.registerTool('gfx.render_tilemap', {
  title: 'Render a tilemap to a PNG',
  description:
    'Compose a whole tilemap through its palette and return it as a PNG. Shows the full ' +
    'background/foreground plane including off-screen regions, which is often where scoreboards ' +
    'and status text live.',
  inputSchema: {
    index: z.number().optional().describe('Tilemap index (default 0).'),
    filename: z.string().optional(),
  },
  annotations: RO,
}, guard(async (args) => {
  requireSession();
  const res = await session.call('gfx.render_tilemap', args, 30000);
  return withImage(res, res.file);
}));

server.registerTool('gfx.palette', {
  title: 'Read the palette',
  description: 'Current palette entries as hex colours.',
  inputSchema: { ...deviceArg, limit: z.number().optional() }, annotations: RO,
}, passthrough('gfx.palette'));

// ============================================================ disassembly

server.registerTool('dasm.range', {
  title: 'Disassemble a range',
  description:
    'Disassemble N instructions with structured output: {address, bytes, text, size, step_over, ' +
    'step_out}. The step_over/step_out flags come from the disassembler itself, so you can follow ' +
    'calls and returns without parsing mnemonics. Prefer this over cpu.disassemble.',
  inputSchema: {
    ...deviceArg,
    address: z.union([z.string(), z.number()]).optional().describe('Defaults to the current PC.'),
    count: z.number().optional().describe('Instruction count (default 16).'),
  },
  annotations: RO,
}, passthrough('dasm.range', 30000));

server.registerTool('dasm.at', {
  title: 'Disassemble one instruction',
  description: 'Disassemble a single instruction, including its size and next PC.',
  inputSchema: { ...deviceArg, ...addrArg('Address to disassemble.') },
  annotations: RO,
}, passthrough('dasm.at'));

server.registerTool('dasm.function', {
  title: 'Disassemble a function',
  description:
    'Sweep from an entry point until an end-of-flow instruction (step_out), collecting call ' +
    'targets seen along the way. Note: this is a linear sweep, it does not follow branches, so ' +
    'treat the result as a first approximation of the function body.',
  inputSchema: {
    ...deviceArg, ...addrArg('Function entry point.'),
    limit: z.number().optional().describe('Max instructions to sweep (default 256).'),
  },
  annotations: RO,
}, passthrough('dasm.function', 30000));


// ================================================================ coverage

server.registerTool('cov.track_pc_start', {
  title: 'Start PC coverage tracking',
  description:
    'Record every address the CPU executes. The highest-leverage tool for reverse engineering: ' +
    'run one game phase (attract mode), snapshot the coverage, run another (in game), then diff ' +
    'the two to partition an unknown ROM into functional regions. Slows emulation somewhat.',
  inputSchema: {
    ...deviceArg,
    clear: z.boolean().optional().describe('Discard existing coverage first.'),
  },
  annotations: SAFE_W,
}, passthrough('cov.track_pc_start'));

server.registerTool('cov.track_pc_stop', {
  title: 'Stop PC coverage tracking',
  description: 'Stop recording executed addresses. Coverage collected so far is retained.',
  inputSchema: { ...deviceArg }, annotations: SAFE_W,
}, passthrough('cov.track_pc_stop'));

server.registerTool('cov.visited_map', {
  title: 'Read executed-address coverage',
  description:
    'Sweep an address range and return the executed regions as ranges. Call cov.track_pc_start ' +
    'first and let the game run. Defaults to an exhaustive byte-wise probe, so a wide range ' +
    'over a large ROM can take a moment; pass mode="instruction" to trade accuracy for speed.',
  inputSchema: {
    ...deviceArg, ...spaceArg,
    start: z.union([z.string(), z.number()]).optional().describe('Default 0.'),
    end: z.union([z.string(), z.number()]).optional().describe('Default the full address mask.'),
    limit: z.number().optional().describe('Max addresses to examine (default 200000).'),
    mode: z.enum(['byte', 'instruction']).optional().describe(
      'byte (default) probes every address and cannot miss. instruction steps via the ' +
      'disassembler: faster over large ranges, but can walk past executed addresses when its ' +
      'alignment differs from what the CPU ran.'),
  },
  annotations: RO,
}, passthrough('cov.visited_map', 120000));

server.registerTool('cov.visited', {
  title: 'Was this address executed?',
  description: 'Check a single address against the recorded coverage.',
  inputSchema: { ...deviceArg, ...addrArg('Address to check.') },
  annotations: RO,
}, passthrough('cov.visited'));

server.registerTool('cov.track_mem_start', {
  title: 'Start memory-write attribution',
  description:
    'Record which PC last wrote each memory address, so cov.pc_at can answer "what code wrote ' +
    'here?" without setting a watchpoint and waiting for a hit.',
  inputSchema: { ...deviceArg, clear: z.boolean().optional() },
  annotations: SAFE_W,
}, passthrough('cov.track_mem_start'));

server.registerTool('cov.track_mem_stop', {
  title: 'Stop memory-write attribution',
  description: 'Stop recording write attribution.',
  inputSchema: { ...deviceArg }, annotations: SAFE_W,
}, passthrough('cov.track_mem_stop'));

server.registerTool('cov.pc_at', {
  title: 'Which PC wrote this address?',
  description:
    'The PC that last wrote a memory address. Requires cov.track_mem_start beforehand. Turns a ' +
    'data discovery straight into a code discovery.',
  inputSchema: {
    ...deviceArg, ...spaceArg, ...addrArg('Memory address to attribute.'),
    data: z.number().optional().describe('Value written, if known.'),
  },
  annotations: RO,
}, passthrough('cov.pc_at'));

server.registerTool('cov.history', {
  title: 'Recent PC history',
  description:
    'The most recently executed addresses, newest first. Answers "how did we get here?" at a ' +
    'breakpoint without setting up a trace.',
  inputSchema: { ...deviceArg, count: z.number().optional().describe('Default 16, max 256.') },
  annotations: RO,
}, passthrough('cov.history'));

// ============================================================ escape hatch

server.registerTool('debug.command', {
  title: 'Run a raw debugger command',
  description:
    'Execute any MAME debugger command and return its console output (bpset, wpset, dasm, find, ' +
    'trace, trackpc, cheatinit, ...). Use this when no dedicated tool exists. ' +
    'Run "help" for the command list.',
  inputSchema: { command: z.string().describe('e.g. "trackpc 1,,1" or "find 0,ffff,\\"HISCORE\\""') },
  annotations: RW,
}, passthrough('debug.command', 60000));

server.registerTool('debug.console_log', {
  title: 'Read the debugger console log',
  description: 'Recent debugger console output, including anything produced by breakpoint actions.',
  inputSchema: { lines: z.number().optional() }, annotations: RO,
}, passthrough('debug.console_log'));

server.registerTool('debug.error_log', {
  title: 'Read the error log',
  description: 'The emulated machine\'s logerror() output. Drivers often name hardware registers here.',
  inputSchema: { lines: z.number().optional() }, annotations: RO,
}, passthrough('debug.error_log'));

// ================================================================== startup

process.on('SIGINT', async () => { await session.stop(); process.exit(0); });
process.on('SIGTERM', async () => { await session.stop(); process.exit(0); });
process.on('exit', () => { if (session.proc) try { session.proc.kill('SIGKILL'); } catch { /* exiting */ } });

const transport = new StdioServerTransport();
await server.connect(transport);
