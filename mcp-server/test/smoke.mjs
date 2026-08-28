// license:BSD-3-Clause
// copyright-holders:mame-mcp
//
// End-to-end smoke test: drives a real headless MAME through the MCP server
// and exercises the full agent loop.
//
//   MAME_SMOKE_DRIVER=gridlee node test/smoke.mjs
//
// Requires a built MAME (see README.md, Building) and ROMs
// for the chosen driver under <repo>/roms. If the driver's ROMs are missing
// MAME still boots with a checksum warning, which is enough for this test.

import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import fs from 'node:fs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, '..', '..');
const serverPath = path.join(here, '..', 'src', 'index.mjs');
const DRIVER = process.env.MAME_SMOKE_DRIVER || 'gridlee';

let pass = 0, fail = 0;
const ok = (c, what, extra) => {
  if (c) { pass++; console.log(`  ok   ${what}`); }
  else { fail++; console.log(`  FAIL ${what}${extra ? '\n       ' + extra : ''}`); }
};

// Unwrap a tool result into its parsed JSON payload.
const data = (r) => {
  if (r.isError) throw new Error(r.content?.[0]?.text || 'tool error');
  if (r.structuredContent) return r.structuredContent;
  try { return JSON.parse(r.content?.[0]?.text || '{}'); } catch { return {}; }
};

const transport = new StdioClientTransport({
  command: 'node',
  args: [serverPath],
  env: { ...process.env, MAME_DIR: repoRoot, MAME_BINARY: path.join(repoRoot, 'mametiny') },
});
const client = new Client({ name: 'smoke', version: '1.0.0' }, { capabilities: {} });
await client.connect(transport);

const call = (name, args = {}) => client.callTool({ name, arguments: args });

try {
  console.log(`\n== 1. session.start (${DRIVER}) ==`);
  const start = data(await call('session.start', { driver: DRIVER }));
  ok(start.started === true, 'session started');
  ok(Array.isArray(start.cpus) && start.cpus.length > 0, 'CPUs reported',
     JSON.stringify(start.cpus));
  const cpuTag = start.cpus[0].tag;
  console.log(`     main CPU: ${cpuTag}`);

  console.log('\n== 2. machine.describe ==');
  const desc = data(await call('machine.describe'));
  ok(desc.driver?.name === DRIVER, 'driver name matches');
  ok(desc.regions?.length > 0, `${desc.regions?.length} memory regions`);
  ok(desc.cpus?.length > 0, `${desc.cpus?.length} CPUs with address spaces`);
  console.log('     regions: ' + desc.regions.map((r) => `${r.tag}(${r.size})`).join(' '));

  console.log('\n== 3. execution control ==');
  ok(data(await call('exec.pause')).state !== undefined, 'exec.pause');
  const st = data(await call('exec.state'));
  ok(typeof st.state === 'string', `exec.state = ${st.state}`);

  console.log('\n== 4. registers ==');
  const regs = data(await call('cpu.registers'));
  ok(regs.registers?.length > 0, `${regs.registers?.length} registers`);
  const pc = regs.registers.find((r) => r.name === 'PC' || r.name === 'CURPC');
  ok(pc !== undefined, `PC present (${pc?.hex})`);

  console.log('\n== 5. memory read ==');
  const mem = data(await call('mem.read', { address: '0x0000', length: 32 }));
  ok(mem.length === 32, 'read 32 bytes');
  ok(typeof mem.data === 'string' && mem.data.length > 0, 'base64 payload present');
  ok(mem.hexdump?.includes('00000000'), 'hexdump rendered');

  console.log('\n== 6. region read (raw ROM, bypasses banking) ==');
  const regionTag = desc.regions.find((r) => r.tag.includes('maincpu'))?.tag || desc.regions[0].tag;
  const rr = data(await call('mem.region_read', { tag: regionTag, offset: 0, length: 16 }));
  ok(rr.length === 16, `read 16 bytes from ${regionTag}`);

  console.log('\n== 7. breakpoint (3-arg form; 1-arg segfaults upstream) ==');
  const bp = data(await call('bp.set', { address: '0x1000' }));
  ok(typeof bp.index === 'number', `bp.set -> index ${bp.index}`);
  const bps = data(await call('bp.list'));
  ok(bps.breakpoints?.some((b) => b.index === bp.index), 'breakpoint appears in bp.list');
  ok(data(await call('bp.clear', { index: bp.index })).ok !== undefined, 'bp.clear');

  console.log('\n== 8. watchpoint round trip ==');
  const wp = data(await call('wp.set', { address: '0x9000', length: 4, type: 'w' }));
  ok(typeof wp.index === 'number', `wp.set -> index ${wp.index}`);
  ok(data(await call('wp.list')).watchpoints?.length > 0, 'wp.list non-empty');
  await call('wp.clear');

  console.log('\n== 9. disassembly ==');
  const dis = data(await call('cpu.disassemble', { address: '0x1000', count: 8 }));
  ok(dis.instructions?.length > 0, `${dis.instructions?.length} instructions`);
  ok(dis.instructions?.[0]?.text?.length > 0, `first: ${dis.instructions?.[0]?.address} ${dis.instructions?.[0]?.text}`);

  console.log('\n== 10. expression evaluation ==');
  const ev = data(await call('sym.eval', { expression: 'pc' }));
  ok(typeof ev.value === 'number', `sym.eval pc = ${ev.hex}`);

  console.log('\n== 11. memory search ==');
  const found = data(await call('mem.search', { text: 'A', start: '0x0000', end: '0x0400', limit: 4 }));
  ok(Array.isArray(found.matches), `search returned ${found.count} matches`);

  console.log('\n== 12. screenshot (headless!) ==');
  const shotRes = await call('video.screenshot');
  ok(!shotRes.isError, 'screenshot tool succeeded');
  const img = shotRes.content?.find((c) => c.type === 'image');
  ok(img !== undefined, 'PNG returned as inline MCP image content');
  if (img) {
    const buf = Buffer.from(img.data, 'base64');
    ok(buf.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])),
       `valid PNG magic (${buf.length} bytes)`);
  }

  console.log('\n== 13. WAV capture with -sound none ==');
  ok(data(await call('audio.record_start', { filename: 'smoke.wav' })).ok, 'recording started');
  await call('exec.resume');
  await new Promise((r) => setTimeout(r, 1200));
  const rec = data(await call('audio.record_stop'));
  ok(rec.ok === true, 'recording stopped');
  const wav = path.join(repoRoot, 'smoke.wav');
  if (fs.existsSync(wav)) {
    const b = fs.readFileSync(wav);
    ok(b.subarray(0, 4).toString() === 'RIFF' && b.subarray(8, 12).toString() === 'WAVE',
       `valid WAV (${b.length} bytes)`);
    fs.unlinkSync(wav);
  } else {
    ok(false, 'WAV file written', `expected ${wav}`);
  }

  console.log('\n== 14. breakpoint trap + wait_for_stop (the core agent loop) ==');
  await call('bp.clear');
  const pcNow = data(await call('cpu.registers')).registers.find((r) => r.name === 'PC');
  // Watchpoint a broad RAM range. Which addresses a driver actually
  // touches is driver-specific, so fall back to a PC breakpoint (which
  // is guaranteed to hit) before declaring failure.
  await call('wp.set', { address: '0x0000', length: 0x100, type: 'rw' });
  await call('exec.resume');
  let stop = data(await call('exec.wait_for_stop', { timeout_ms: 5000 }));
  if (stop.timed_out) {
    await call('wp.clear');
    await call('exec.pause');
    const pcNow2 = data(await call('cpu.registers')).registers.find((r) => r.name === 'PC');
    await call('bp.set', { address: pcNow2.hex });
    await call('exec.resume');
    stop = data(await call('exec.wait_for_stop', { timeout_ms: 8000 }));
  }
  ok(stop.timed_out !== true, `trapped: reason=${stop.reason} pc=${stop.pc}`);
  ok(['watchpoint', 'breakpoint', 'step', 'unknown'].includes(stop.reason),
     `stop reason recognised (${stop.reason})`);
  await call('wp.clear');
  await call('bp.clear');

  console.log('\n== 15. escape hatch ==');
  const raw = data(await call('debug.command', { command: 'help' }));
  ok(Array.isArray(raw.output), `debug.command returned ${raw.output?.length} console lines`);


  console.log('\n== 17. gfx: decoded graphics (phase 3) ==');
  const sets = data(await call('gfx.list_sets'));
  ok(Array.isArray(sets.sets), `gfx.list_sets returned ${sets.count} set(s)`);
  if (sets.count > 0) {
    const s0 = sets.sets[0];
    console.log(`     set0: ${s0.device}[${s0.index}] ${s0.width}x${s0.height} ` +
                `x${s0.elements} ${s0.depth}bpp`);
    const shotRes = await call('gfx.render_tiles', {
      device: s0.device, index: s0.index, count: 64, columns: 8,
    });
    ok(!shotRes.isError, 'gfx.render_tiles succeeded');
    const gimg = shotRes.content?.find((c) => c.type === 'image');
    ok(gimg !== undefined, 'tile sheet returned as inline MCP image');
    if (gimg) {
      const buf = Buffer.from(gimg.data, 'base64');
      ok(buf.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])),
         `valid PNG (${buf.length} bytes)`);
      const meta = data(shotRes);
      ok(meta.width === 8 * s0.width, `sheet width matches 8 columns (${meta.width})`);
    }
  } else {
    console.log('     (driver has no decoded gfx sets; skipping render)');
  }

  const tms = data(await call('gfx.list_tilemaps'));
  ok(typeof tms.count === 'number', `gfx.list_tilemaps -> ${tms.count} tilemap(s)`);
  if (tms.count > 0) {
    const tmRes = await call('gfx.render_tilemap', { index: 0 });
    ok(!tmRes.isError, 'gfx.render_tilemap succeeded');
    ok(tmRes.content?.some((c) => c.type === 'image'), 'tilemap returned as inline image');
  }

  console.log('\n== 18. dasm: structured disassembly (phase 3) ==');
  const dr = data(await call('dasm.range', { address: '0x1000', count: 8 }));
  ok(dr.instructions?.length > 0, `dasm.range -> ${dr.instructions?.length} instructions`);
  const i0 = dr.instructions?.[0];
  ok(i0 && typeof i0.text === 'string', `first: ${i0?.address} ${i0?.bytes} ${i0?.text}`);
  ok(i0 && typeof i0.step_over === 'boolean' && typeof i0.step_out === 'boolean',
     'step_over/step_out flags present (the reason this binding exists)');

  const one = data(await call('dasm.at', { address: '0x1000' }));
  ok(one.size > 0, `dasm.at size=${one.size} next=${one.next_pc}`);

  const fn = data(await call('dasm.function', { address: '0x1000', limit: 32 }));
  ok(Array.isArray(fn.instructions), `dasm.function swept ${fn.count} instructions`);
  ok(typeof fn.terminated === 'boolean', `terminated=${fn.terminated} (${fn.note})`);


  console.log('\n== 19. cov: execution coverage (phase 3b) ==');
  // trackpc is a write-only switch from the console; the readback below
  // only exists because of the luaengine_cov.cpp bindings.
  await call('exec.pause');
  ok(data(await call('cov.track_pc_start', { clear: true })).ok, 'cov.track_pc_start');

  // Let the game actually execute so there is something to measure.
  await call('exec.resume');
  await new Promise((r) => setTimeout(r, 1500));
  await call('exec.pause');
  ok(data(await call('cov.track_pc_stop')).ok, 'cov.track_pc_stop');

  // NB: limit caps how many ADDRESSES are examined, so it must cover the
  // whole requested range -- a short limit silently truncates the sweep
  // before reaching high addresses.
  const cov = data(await call('cov.visited_map', { start: '0x0000', end: '0xFFFF', limit: 200000 }));
  ok(typeof cov.visited_instructions === 'number',
     `visited ${cov.visited_instructions} of ${cov.examined_instructions} examined`);
  ok(cov.truncated === false, `sweep covered the whole range (examined ${cov.examined_instructions})`);
  ok(cov.visited_instructions > 0,
     `coverage actually recorded (${cov.range_count} range(s))`);
  if (cov.ranges?.length) {
    const r0 = cov.ranges[0];
    console.log(`     first range: ${r0.first}-${r0.last} (${r0.size} bytes)`);
  }

  // A single address inside a covered range must report as visited.
  if (cov.ranges?.length) {
    const probe = data(await call('cov.visited', { address: cov.ranges[0].first }));
    ok(probe.visited === true, `cov.visited agrees for ${probe.address}`);
  }

  console.log('\n== 20. cov: write attribution and history ==');
  ok(data(await call('cov.track_mem_start', { clear: true })).ok, 'cov.track_mem_start');
  await call('exec.resume');
  await new Promise((r) => setTimeout(r, 800));
  await call('exec.pause');
  await call('cov.track_mem_stop');
  // pc_at legitimately returns found=false if nothing wrote that exact
  // address, so assert the shape rather than a specific hit.
  const at = data(await call('cov.pc_at', { address: '0x0000' }));
  ok(typeof at.found === 'boolean', `cov.pc_at found=${at.found}${at.pc ? ' pc=' + at.pc : ''}`);

  const hist = data(await call('cov.history', { count: 8 }));
  ok(Array.isArray(hist.history), `cov.history returned ${hist.count} entries`);
  ok(hist.count > 0, `history non-empty (newest ${hist.history?.[0]})`);

  console.log('\n== 21. session.stop ==');
  ok(data(await call('session.stop')).stopped === true, 'session stopped');

} catch (e) {
  fail++;
  console.log(`\nFATAL: ${e.message}`);
  try { await call('session.stop'); } catch { /* best effort */ }
}

console.log(`\n${pass} passed, ${fail} failed`);
await client.close();
process.exit(fail === 0 ? 0 : 1);
