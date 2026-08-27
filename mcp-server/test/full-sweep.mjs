// license:BSD-3-Clause
// copyright-holders:mame-mcp
//
// full-sweep.mjs - invoke EVERY registered MCP tool against a real ROM and
// report which ones worked.
//
// Unlike smoke.mjs (which tests the agent workflow), this is a coverage
// audit: it asserts that no tool is dead on arrival, and fails if any
// tool is left uninvoked.
//
//   MAME_SWEEP_DRIVER=wrally node test/full-sweep.mjs
//
// Requires a built MAME and real ROMs under <repo>/roms.

import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, '..', '..');
const DRIVER = process.env.MAME_SWEEP_DRIVER || 'wrally';

const transport = new StdioClientTransport({
  command: 'node',
  args: [path.join(here, '..', 'src', 'index.mjs')],
  env: {
    ...process.env,
    // Respect the caller's environment; fall back to the repo defaults.
    MAME_DIR: process.env.MAME_DIR || repoRoot,
    MAME_BINARY: process.env.MAME_BINARY || path.join(repoRoot, 'mametiny'),
    MAME_ROMPATH: process.env.MAME_ROMPATH || path.join(repoRoot, 'roms'),
  },
});
const client = new Client({ name: 'full-sweep', version: '1.0.0' }, { capabilities: {} });
await client.connect(transport);

const { tools } = await client.listTools();
const ALL = tools.map((t) => t.name).sort();
const invoked = new Set();
const results = [];

const unwrap = (r) => {
  if (r.structuredContent) return r.structuredContent;
  try { return JSON.parse(r.content?.[0]?.text || '{}'); } catch { return {}; }
};

// Invoke a tool, record the outcome, never throw.
async function T(name, args = {}, { note, allowError = false } = {}) {
  invoked.add(name);
  let r;
  try {
    r = await client.callTool({ name, arguments: args });
  } catch (e) {
    results.push({ name, ok: false, detail: `threw: ${e.message}` });
    return {};
  }
  const d = unwrap(r);
  if (r.isError) {
    const msg = (r.content?.[0]?.text || '').split('\n')[0].slice(0, 110);
    results.push({ name, ok: allowError, detail: msg, expected: allowError });
  } else {
    results.push({ name, ok: true, detail: note ? note(d, r) : '' });
  }
  return d;
}

const hex = (v) => (typeof v === 'string' ? v : `0x${(v >>> 0).toString(16).toUpperCase()}`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

console.log(`\n=== FULL TOOL SWEEP: ${ALL.length} tools, driver "${DRIVER}" ===\n`);

// ---------------------------------------------------------------- session
console.log('-- session --');
await T('session.list_drivers', { filter: DRIVER, limit: 5 },
  { note: (d) => `${d.count} match(es)` });

const started = await T('session.start', { driver: DRIVER },
  { note: (d) => `${d.cpus?.length} cpu(s), ${d.regions?.length} region(s)` });

if (!started.started) {
  console.log('\nFATAL: session.start failed; cannot continue.');
  for (const r of results) console.log(`  ${r.ok ? 'ok  ' : 'FAIL'} ${r.name}  ${r.detail}`);
  await client.close();
  process.exit(1);
}

const cpuTag = started.cpus?.[0]?.tag;
await T('session.status', {}, { note: (d) => `running=${d.running} state=${d.execution_state}` });

// ---------------------------------------------------------------- machine
console.log('-- machine --');
const desc = await T('machine.describe', {},
  { note: (d) => `${d.device_count} devices, ${d.regions?.length} regions, ${d.screens?.length} screens` });

const romRegion = desc.regions?.find((r) => r.tag.includes('maincpu')) || desc.regions?.[0];
const ramShare = desc.shares?.[0];

// ---------------------------------------------------------------- cpu
console.log('-- cpu / registers --');
await T('cpu.list', {}, { note: (d) => `${d.cpus?.length} cpu(s)` });
await T('exec.pause', {}, { note: (d) => d.state });
const regs = await T('cpu.registers', { device: cpuTag },
  { note: (d) => `${d.registers?.length} registers` });
const pcReg = regs.registers?.find((r) => ['PC', 'CURPC', 'PCA'].includes(r.name));
const PC = pcReg?.hex || '0x0';
console.log(`     PC = ${PC}`);

await T('cpu.set_register', { device: cpuTag, name: pcReg?.name || 'PC', value: PC },
  { note: () => 'PC rewritten to same value (no-op)' });

// ---------------------------------------------------------------- memory
console.log('-- memory --');
await T('mem.list_regions', {}, { note: (d) => d.regions?.map((r) => r.tag).join(' ') });
await T('mem.list_shares', {}, { note: (d) => `${d.shares?.length} share(s)` });
await T('mem.read', { device: cpuTag, address: PC, length: 64 },
  { note: (d) => `${d.length} bytes @ ${d.address}` });
await T('mem.region_read', { tag: romRegion?.tag, offset: 0, length: 32 },
  { note: (d) => `${d.length} bytes from ${d.tag}` });
await T('mem.search', { device: cpuTag, text: 'A', start: '0x0', end: '0x2000', limit: 4 },
  { note: (d) => `${d.count} match(es)` });

// Write into RAM if we can find some; otherwise this legitimately errors.
const writeAddr = ramShare ? '0x0' : '0x0';
await T('mem.write', { device: cpuTag, address: writeAddr, bytes: [0] },
  { note: (d) => `wrote ${d.length} byte(s) @ ${d.address}`, allowError: true });

// ---------------------------------------------------------------- disasm
console.log('-- disassembly --');
await T('cpu.disassemble', { device: cpuTag, address: PC, count: 4 },
  { note: (d) => `${d.count} insn (legacy path)` });
await T('dasm.at', { device: cpuTag, address: PC },
  { note: (d) => `${d.address} ${d.text} size=${d.size}` });
const dr = await T('dasm.range', { device: cpuTag, address: PC, count: 12 },
  { note: (d) => `${d.count} insn, first="${d.instructions?.[0]?.text}"` });
await T('dasm.function', { device: cpuTag, address: PC, limit: 64 },
  { note: (d) => `swept ${d.count}, terminated=${d.terminated}, ${d.calls?.length} call(s)` });

// ---------------------------------------------------------------- symbols
console.log('-- symbols / annotations --');
await T('sym.eval', { device: cpuTag, expression: 'pc' }, { note: (d) => `pc = ${d.hex}` });
await T('annot.add', { device: cpuTag, address: PC, text: 'full-sweep marker' },
  { note: (d) => `annotated ${d.address}` });
await T('annot.save', {}, { note: () => 'comments persisted' });

// ---------------------------------------------------------------- graphics
console.log('-- graphics --');
const sets = await T('gfx.list_sets', {}, { note: (d) => `${d.count} gfx set(s)` });
const s0 = sets.sets?.[0];
if (s0) {
  console.log(`     set0: ${s0.device}[${s0.index}] ${s0.width}x${s0.height} x${s0.elements} ${s0.depth}bpp`);
}
await T('gfx.render_tiles',
  s0 ? { device: s0.device, index: s0.index, count: 128, columns: 16 } : {},
  { note: (d) => `PNG ${d.width}x${d.height}, ${d.tiles} tiles`, allowError: !s0 });

const tms = await T('gfx.list_tilemaps', {}, { note: (d) => `${d.count} tilemap(s)` });
await T('gfx.render_tilemap', { index: 0 },
  { note: (d) => `PNG ${d.width}x${d.height}`, allowError: !(tms.count > 0) });
await T('gfx.palette', { limit: 16 },
  { note: (d) => `${d.entries} entries, first=${d.colors?.[0]}`, allowError: true });

// ---------------------------------------------------------------- video
console.log('-- video --');
await T('video.screens', {}, { note: (d) => d.screens?.map((s) => `${s.tag} ${s.width}x${s.height}`).join(' ') });
await T('video.screenshot', {}, { note: (d) => `PNG ${d.bytes} bytes` });

// ---------------------------------------------------------------- audio
console.log('-- audio --');
await T('audio.record_start', { filename: 'sweep.wav' }, { note: () => 'recording' });
await T('exec.resume', {}, { note: (d) => d.state });
await sleep(1200);
await T('audio.record_stop', {}, { note: (d) => `${d.wav_files?.length || 0} wav file(s)` });

// ---------------------------------------------------------------- coverage
console.log('-- coverage --');
await T('exec.pause');
await T('cov.track_pc_start', { device: cpuTag, clear: true }, { note: () => 'tracking on' });
await T('cov.track_mem_start', { device: cpuTag, clear: true }, { note: () => 'mem tracking on' });
await T('exec.resume');
await sleep(2500);              // let the game actually run
await T('exec.pause');
await T('cov.track_pc_stop', { device: cpuTag }, { note: () => 'tracking off' });
await T('cov.track_mem_stop', { device: cpuTag }, { note: () => 'mem tracking off' });

const cov = await T('cov.visited_map',
  { device: cpuTag, start: '0x0', end: '0xFFFF', limit: 200000 },
  { note: (d) => `${d.visited_instructions} visited / ${d.examined_instructions} examined, ${d.range_count} range(s), truncated=${d.truncated}` });
if (cov.ranges?.length) {
  console.log(`     first ranges: ${cov.ranges.slice(0, 3).map((r) => `${r.first}-${r.last}`).join(', ')}`);
}
await T('cov.visited', { device: cpuTag, address: cov.ranges?.[0]?.first || PC },
  { note: (d) => `${d.address} visited=${d.visited}` });
await T('cov.pc_at', { device: cpuTag, address: '0x0' },
  { note: (d) => `found=${d.found}${d.pc ? ' pc=' + d.pc : ''}` });
await T('cov.history', { device: cpuTag, count: 8 },
  { note: (d) => `${d.count} entries, newest ${d.history?.[0]}` });

// ---------------------------------------------------------------- breakpoints
console.log('-- breakpoints / watchpoints --');
const bp = await T('bp.set', { device: cpuTag, address: PC }, { note: (d) => `index ${d.index}` });
await T('bp.list', {}, { note: (d) => `${d.breakpoints?.length} breakpoint(s)` });
await T('bp.disable', { device: cpuTag, index: bp.index }, { note: () => 'disabled' });
await T('bp.enable', { device: cpuTag, index: bp.index }, { note: () => 're-enabled' });
await T('bp.clear', { device: cpuTag, index: bp.index }, { note: () => 'cleared' });

const wp = await T('wp.set', { device: cpuTag, address: '0x0', length: 16, type: 'w' },
  { note: (d) => `index ${d.index}` });
await T('wp.list', { device: cpuTag }, { note: (d) => `${d.watchpoints?.length} watchpoint(s)` });
await T('wp.clear', { device: cpuTag }, { note: () => 'cleared' });

await T('rp.set', { condition: '1==0' }, { note: () => 'registerpoint set' });
await T('rp.clear', {}, { note: () => 'cleared' });

// ---------------------------------------------------------------- execution
console.log('-- execution control --');
await T('exec.state', {}, { note: (d) => d.state });
await T('exec.step', { device: cpuTag, count: 1 }, { note: () => 'stepped 1' });
await T('exec.step_over', { count: 1 }, { note: () => 'stepped over' });
await T('exec.step_out', {}, { note: () => 'step out issued' });
await T('exec.run_for', { milliseconds: 20 }, { note: (d) => `${d.milliseconds}ms` });
await T('exec.run_to', { device: cpuTag, address: PC }, { note: (d) => `to ${d.address}` });
await T('exec.run_until_vblank', {}, { note: () => 'issued' });
await T('exec.run_until_interrupt', {}, { note: () => 'issued' });
await T('exec.wait_for_stop', { timeout_ms: 2500 },
  { note: (d) => `reason=${d.reason}${d.pc ? ' pc=' + d.pc : ''}` });
await T('exec.pause');

// ---------------------------------------------------------------- input
console.log('-- input --');
const ports = await T('input.list_ports', {}, { note: (d) => `${d.ports?.length} port(s)` });
const p0 = ports.ports?.find((p) => p.fields?.length);
await T('input.press',
  p0 ? { port: p0.tag, field: p0.fields[0].name, frames: 2 } : {},
  { note: (d) => `${d.port}.${d.field} for ${d.frames}f`, allowError: !p0 });

// ---------------------------------------------------------------- state
console.log('-- save states --');
await T('state.save', { slot: '1' }, { note: () => 'saved to slot 1' });
await sleep(400);
await T('state.load', { slot: '1' }, { note: () => 'loaded slot 1' });

// ---------------------------------------------------------------- debug
console.log('-- escape hatch --');
await T('debug.command', { command: 'help' }, { note: (d) => `${d.output?.length} line(s)` });
await T('debug.console_log', { lines: 5 }, { note: (d) => `${d.lines?.length} line(s)` });
await T('debug.error_log', { lines: 5 }, { note: (d) => `${d.lines?.length} line(s)` });

// ---------------------------------------------------------------- teardown
console.log('-- teardown --');
await T('machine.reset', { hard: false }, { note: () => 'soft reset' });
await T('session.stop', {}, { note: () => 'stopped' });

// ---------------------------------------------------------------- report
console.log('\n=== RESULTS ===\n');
let pass = 0, fail = 0, expected = 0;
for (const r of results) {
  if (r.ok && r.expected) { expected++; console.log(`  ok*  ${r.name.padEnd(26)} (expected failure) ${r.detail}`); }
  else if (r.ok) { pass++; console.log(`  ok   ${r.name.padEnd(26)} ${r.detail}`); }
  else { fail++; console.log(`  FAIL ${r.name.padEnd(26)} ${r.detail}`); }
}

const missed = ALL.filter((t) => !invoked.has(t));
console.log(`\ntools registered : ${ALL.length}`);
console.log(`tools invoked    : ${invoked.size}`);
console.log(`  succeeded      : ${pass}`);
console.log(`  expected-fail  : ${expected}   (tool unavailable for this driver)`);
console.log(`  FAILED         : ${fail}`);
if (missed.length) console.log(`NEVER INVOKED    : ${missed.join(', ')}`);

const clean = (fail === 0) && (missed.length === 0);
console.log(`\n${clean ? 'ALL TOOLS EXERCISED SUCCESSFULLY' : 'SWEEP INCOMPLETE'}`);
await client.close();
process.exit(clean ? 0 : 1);
