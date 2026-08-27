-- license:BSD-3-Clause
-- copyright-holders:mame-mcp
--
-- Offline unit tests for the pure-logic parts of the MCP plugin (base64,
-- hexdump, address parsing, JSON-RPC framing). These do NOT need MAME: run
-- them with any Lua 5.4:
--
--   lua54 plugins/mcp/test/test_util.lua
--
-- MAME-dependent behaviour is covered by mcp-server/test/smoke.mjs.

package.path = table.concat({
	'plugins/?.lua', 'plugins/?/init.lua',
	'./?.lua', './?/init.lua',
}, ';') .. ';' .. package.path

local pass, fail = 0, 0
local function ok(cond, what)
	if cond then pass = pass + 1
	else fail = fail + 1; io.write('  FAIL: ', what, '\n') end
end
local function eq(a, b, what)
	if a == b then pass = pass + 1
	else fail = fail + 1
		io.write(string.format('  FAIL: %s\n    expected: %s\n    actual:   %s\n',
			what, tostring(b), tostring(a)))
	end
end

------------------------------------------------------------------ harness
-- util.lua touches `manager` only inside functions we do not call here, so a
-- couple of stubs are enough to load it.
_G.manager = { machine = { devices = {}, debugger = nil } }
_G.emu = {}

local util = require('mcp/util')

------------------------------------------------------------------ base64
io.write('base64\n')
local vectors = {
	{ '',        '' },
	{ 'f',       'Zg==' },
	{ 'fo',      'Zm8=' },
	{ 'foo',     'Zm9v' },
	{ 'foob',    'Zm9vYg==' },
	{ 'fooba',   'Zm9vYmE=' },
	{ 'foobar',  'Zm9vYmFy' },
}
for _, v in ipairs(vectors) do
	eq(util.b64encode(v[1]), v[2], 'encode ' .. string.format('%q', v[1]))
	eq(util.b64decode(v[2]), v[1], 'decode ' .. v[2])
end

-- round-trip every byte value, which is what memory reads actually produce
local all = {}
for i = 0, 255 do all[#all + 1] = string.char(i) end
all = table.concat(all)
eq(util.b64decode(util.b64encode(all)), all, 'round-trip 0..255')
eq(#util.b64encode(all), 344, 'encoded length of 256 bytes')

------------------------------------------------------------------ hexdump
io.write('hexdump\n')
local hd = util.hexdump('\x00\x01\x41\x42', 0x1000)
eq(hd, '00001000  00 01 41 42                                      |..AB|',
	'hexdump formatting')
local hd2 = util.hexdump(string.rep('A', 20), 0)
eq(select(2, hd2:gsub('\n', '')), 1, 'hexdump wraps at 16 bytes')

------------------------------------------------------------------ addresses
io.write('address parsing\n')
eq(util.address(0x1234),    0x1234, 'number passthrough')
eq(util.address('0x1a2c'),  0x1a2c, '0x prefix')
eq(util.address('0X1A2C'),  0x1a2c, '0X prefix uppercase')
eq(util.address('$1a2c'),   0x1a2c, '$ prefix')
eq(util.address('1a2c'),    0x1a2c, 'bare hex (MAME convention)')
eq(util.address('4096'),    4096,   'decimal digits parse as decimal')
eq(util.address(' 0x10 '),  0x10,   'whitespace tolerated')

local okp = pcall(util.address, 'not an address!!')
ok(not okp, 'garbage address raises')
local okp2 = pcall(util.address, nil)
ok(not okp2, 'nil address raises')

------------------------------------------------------------------ clamp
io.write('clamp\n')
eq(util.clamp(5, 1, 10),   5,  'in range')
eq(util.clamp(-1, 1, 10),  1,  'below range')
eq(util.clamp(999, 1, 10), 10, 'above range')
eq(util.clamp(nil, 3, 10), 3,  'nil -> low bound')

------------------------------------------------------------------ sorted_keys
io.write('sorted_keys\n')
local ks = util.sorted_keys({ b = 1, a = 2, c = 3 })
eq(table.concat(ks, ','), 'a,b,c', 'keys sorted')

------------------------------------------------------------------ rpc framing
io.write('rpc framing\n')
-- Drive rpc.lua against a fake emu.file so we can test the wire protocol.
local sent = {}
local inbox = ''
_G.emu.file = function()
	return {
		open  = function() return nil end,
		read  = function(_, n)
			if #inbox == 0 then error('would block') end
			local c = inbox:sub(1, n); inbox = inbox:sub(#c + 1); return c
		end,
		write = function(_, s) sent[#sent + 1] = s; return #s end,
	}
end

local rpclib = require('mcp/rpc')
local r = rpclib.new('socket.test:1')
ok(r:ok(), 'rpc opens')

r:on('echo', function(p) return { got = p.v } end)
r:on('boom', function() error('kaboom') end)

local json = require('json')

-- happy path
inbox = '{"jsonrpc":"2.0","id":1,"method":"echo","params":{"v":42}}\n'
sent = {}; r:pump()
local resp = json.decode(sent[1])
eq(resp.id, 1, 'response id matches')
eq(resp.result.got, 42, 'handler result returned')

-- unknown method
inbox = '{"jsonrpc":"2.0","id":2,"method":"nope"}\n'
sent = {}; r:pump()
resp = json.decode(sent[1])
eq(resp.error.code, -32601, 'unknown method -> -32601')

-- handler error is trapped, not fatal
inbox = '{"jsonrpc":"2.0","id":3,"method":"boom"}\n'
sent = {}; r:pump()
resp = json.decode(sent[1])
eq(resp.error.code, -32000, 'handler error -> -32000')
ok(resp.error.message:find('kaboom'), 'error message propagated')

-- malformed JSON
inbox = 'this is not json\n'
sent = {}; r:pump()
resp = json.decode(sent[1])
eq(resp.error.code, -32700, 'parse error -> -32700')

-- notification (no id) produces no response
inbox = '{"jsonrpc":"2.0","method":"echo","params":{"v":1}}\n'
sent = {}; r:pump()
eq(#sent, 0, 'notification produces no reply')

-- split across reads: the critical property, since osd sockets return partial data
inbox = '{"jsonrpc":"2.0","id":4,"me'
sent = {}; r:pump()
eq(#sent, 0, 'partial message buffered, no reply yet')
inbox = 'thod":"echo","params":{"v":7}}\n'
r:pump()
resp = json.decode(sent[1])
eq(resp.result.got, 7, 'message reassembled across reads')

-- two messages in one read
inbox = '{"jsonrpc":"2.0","id":5,"method":"echo","params":{"v":1}}\n'
     .. '{"jsonrpc":"2.0","id":6,"method":"echo","params":{"v":2}}\n'
sent = {}; r:pump()
eq(#sent, 2, 'two messages in one chunk -> two replies')
eq(json.decode(sent[1]).id, 5, 'first id')
eq(json.decode(sent[2]).id, 6, 'second id')

-- notify() emits a well-formed notification with no id
sent = {}
r:notify('mcp/stopped', { reason = 'breakpoint', index = 3 })
local nt = json.decode(sent[1])
eq(nt.method, 'mcp/stopped', 'notify method')
eq(nt.params.index, 3, 'notify params')
eq(nt.id, nil, 'notify has no id')

-- responses must be single-line (NDJSON framing)
sent = {}
r:on('multi', function() return { text = 'a\nb\nc' } end)
inbox = '{"jsonrpc":"2.0","id":7,"method":"multi"}\n'
r:pump()
eq(select(2, sent[1]:gsub('\n', '')), 1, 'exactly one newline per response')

------------------------------------------------------------------ summary
io.write(string.format('\n%d passed, %d failed\n', pass, fail))
os.exit(fail == 0 and 0 or 1)
