#!/usr/bin/env bash
# license:BSD-3-Clause
# Runs all three mame-mcp test suites. Suites 1 and 2 need no MAME binary.
set -uo pipefail
cd "$(dirname "$0")/../.."
rc=0

echo "== 1/3 Lua unit tests (no MAME needed) =="
if command -v lua54 >/dev/null; then lua54 plugins/mcp/test/test_util.lua || rc=1
else echo "   SKIP: no lua54 on PATH"; fi

echo; echo "== 2/3 MCP protocol tests (no MAME binary needed) =="
( cd tools/mcp-server && node test/protocol.mjs ) || rc=1

echo; echo "== 3/3 End-to-end against a real emulator =="
if [ -x ./mametiny ]; then
  [ -f "$HOME/.mcpdeps/env.sh" ] && source "$HOME/.mcpdeps/env.sh"
  ( cd tools/mcp-server && MAME_ROMPATH="${MAME_ROMPATH:-$PWD/../../roms}" node test/smoke.mjs ) || rc=1
else
  echo "   SKIP: ./mametiny not built (see tools/dev/bootstrap-headless-build.sh)"
fi

echo; [ $rc -eq 0 ] && echo "ALL SUITES PASSED" || echo "FAILURES"
exit $rc
