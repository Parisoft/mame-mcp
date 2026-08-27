// license:BSD-3-Clause
// copyright-holders:mame-mcp
//
// Protocol-level test: drives the MCP server over stdio with a real MCP
// client and checks tool registration, schemas and error handling.
// Does NOT require a MAME binary -- tools that need a session must fail
// cleanly, which is itself part of the contract.
//
//   node test/protocol.mjs

import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const here = path.dirname(fileURLToPath(import.meta.url));
const serverPath = path.join(here, '..', 'src', 'index.mjs');

let pass = 0, fail = 0;
const ok = (c, what) => { if (c) { pass++; } else { fail++; console.log(`  FAIL: ${what}`); } };
const eq = (a, b, what) => {
  if (a === b) pass++;
  else { fail++; console.log(`  FAIL: ${what}\n    expected: ${b}\n    actual:   ${a}`); }
};

const transport = new StdioClientTransport({
  command: 'node',
  args: [serverPath],
  env: { ...process.env, MAME_BINARY: '/nonexistent/mame' },
});

const client = new Client({ name: 'protocol-test', version: '1.0.0' }, { capabilities: {} });
await client.connect(transport);
console.log('connected to server');

// ------------------------------------------------------------ tools/list
const { tools } = await client.listTools();
console.log(`\ntools/list -> ${tools.length} tools`);
ok(tools.length >= 35, `expected >=35 tools, got ${tools.length}`);

const byName = Object.fromEntries(tools.map((t) => [t.name, t]));
const required = [
  'session.start', 'session.stop', 'session.status', 'session.list_drivers',
  'machine.describe', 'machine.reset',
  'exec.state', 'exec.pause', 'exec.resume', 'exec.step', 'exec.step_over',
  'exec.step_out', 'exec.run_to', 'exec.run_for', 'exec.wait_for_stop',
  'bp.set', 'bp.list', 'bp.clear', 'bp.enable', 'bp.disable',
  'wp.set', 'wp.list', 'wp.clear', 'rp.set',
  'mem.read', 'mem.write', 'mem.search', 'mem.list_regions', 'mem.region_read', 'mem.list_shares',
  'cpu.list', 'cpu.registers', 'cpu.set_register', 'cpu.disassemble',
  'sym.eval', 'annot.add',
  'video.screenshot', 'video.screens',
  'audio.record_start', 'audio.record_stop',
  'input.list_ports', 'input.press',
  'state.save', 'state.load',
  'debug.command', 'debug.console_log', 'debug.error_log',
];
for (const n of required) ok(byName[n], `tool "${n}" is registered`);

// ------------------------------------------------------- schema sanity
console.log('\nschemas');
for (const t of tools) {
  ok(t.description && t.description.length > 20, `${t.name} has a real description`);
  ok(t.inputSchema && t.inputSchema.type === 'object', `${t.name} has an object inputSchema`);
}

// Annotations should mark the dangerous ones so clients can gate them.
eq(byName['mem.read'].annotations?.readOnlyHint, true, 'mem.read is read-only');
eq(byName['mem.write'].annotations?.destructiveHint, true, 'mem.write is destructive');
eq(byName['debug.command'].annotations?.destructiveHint, true, 'debug.command is destructive');
eq(byName['bp.set'].annotations?.destructiveHint, false, 'bp.set is non-destructive');

// Required args must actually be required.
ok(byName['bp.set'].inputSchema.required?.includes('address'), 'bp.set requires address');
ok(byName['session.start'].inputSchema.required?.includes('driver'), 'session.start requires driver');
ok(!byName['mem.read'].inputSchema.required?.includes('device'), 'mem.read device is optional');

// ----------------------------------------------- errors before a session
console.log('\nerror handling with no session');
for (const name of ['machine.describe', 'mem.read', 'cpu.registers', 'bp.list']) {
  const r = await client.callTool({
    name,
    arguments: name === 'mem.read' ? { address: '0x0' } : {},
  });
  ok(r.isError === true, `${name} reports isError without a session`);
  const text = r.content?.[0]?.text || '';
  ok(/session\.start/.test(text), `${name} error tells the agent to call session.start`);
}

// A bad driver must fail cleanly, not hang or crash the server.
console.log('\nsession.start with a missing binary');
const bad = await client.callTool({ name: 'session.start', arguments: { driver: 'nosuchdriver' } });
ok(bad.isError === true, 'session.start fails cleanly when the binary is missing');

// The server must still be alive and responsive afterwards.
const after = await client.listTools();
ok(after.tools.length === tools.length, 'server survives a failed session.start');

// Schema validation is enforced by the SDK.
console.log('\nargument validation');
const badArgs = await client.callTool({ name: 'bp.set', arguments: { address: {} } });
ok(badArgs.isError === true, 'invalid argument type is rejected');

console.log(`\n${pass} passed, ${fail} failed`);
await client.close();
process.exit(fail === 0 ? 0 : 1);
