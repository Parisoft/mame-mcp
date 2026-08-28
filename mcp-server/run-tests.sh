#!/usr/bin/env bash
# license:BSD-3-Clause
# Runs all mame-mcp test suites. Suites 1 and 2 need no MAME binary.
set -uo pipefail
cd "$(dirname "$0")/.."
rc=0

echo "== 1/4 Lua unit tests (no MAME needed) =="
if command -v lua54 >/dev/null; then lua54 plugins/mcp/test/test_util.lua || rc=1
else echo "   SKIP: no lua54 on PATH"; fi

echo; echo "== 2/4 MCP protocol tests (no MAME binary needed) =="
( cd mcp-server && node test/protocol.mjs ) || rc=1

echo; echo "== 3/4 End-to-end agent workflow (needs a build + ROMs) =="
if [ -x ./mametiny ]; then
  [ -f "$HOME/.mcpdeps/env.sh" ] && source "$HOME/.mcpdeps/env.sh"
  ( cd mcp-server && MAME_ROMPATH="${MAME_ROMPATH:-$PWD/../roms}" node test/smoke.mjs ) || rc=1
else
  echo "   SKIP: ./mametiny not built (see README.md, Building)"
fi

echo; echo "== 4/4 Full tool sweep: invoke every registered tool =="
if [ -x ./mametiny ]; then
  ( cd mcp-server && node test/full-sweep.mjs ) || rc=1
else
  echo "   SKIP: ./mametiny not built"
fi

echo; [ $rc -eq 0 ] && echo "ALL SUITES PASSED" || echo "FAILURES"
exit $rc
