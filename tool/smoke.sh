#!/usr/bin/env bash
# Environment smoke test for the dist/ launcher. Pins the two spawn-
# environment hazards that unit tests cannot cover (they need a compiled
# binary + a hostile process environment):
#
#   1. Foreign working directory — the ObjectBox native lib is resolved
#      cwd-relative; the launcher must cd into dist/ first.
#   2. RLIMIT_NOFILE = unlimited — how Node-based MCP clients (Claude Code)
#      spawn children; libwebsockets fails with OBX 10098 unless the
#      launcher caps `ulimit -n` (reproduced 2026-07-07; see the
#      2026-07-06 engineering log (internal), section on OBX 10098).
#
# Usage: tool/smoke.sh   (after tool/build.sh; needs no Ollama — initialize
# only, tools are not called)
set -uo pipefail

cd "$(dirname "$0")/.."
LAUNCHER="$(pwd)/dist/remembox"
[ -x "$LAUNCHER" ] || { echo "FAIL: dist/remembox missing — run tool/build.sh"; exit 1; }

INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}'
STORE_DIR="$(mktemp -d /tmp/remembox-smoke.XXXXXX)"
fail=0

check() { # name, precmd
  local name="$1" precmd="$2" out
  out=$(cd /tmp && eval "$precmd"; printf '%s\n' "$INIT" \
    | OBX_MEMORY_DIR="$STORE_DIR" "$LAUNCHER" 2>"$STORE_DIR/err-$name.log" | head -1)
  if printf '%s' "$out" | grep -q '"serverInfo"'; then
    echo "PASS: $name"
  else
    echo "FAIL: $name — no initialize response; stderr:"
    tail -5 "$STORE_DIR/err-$name.log" | sed 's/^/    /'
    fail=1
  fi
}

check "foreign-cwd" ":"
check "unlimited-fd-limit" "ulimit -n unlimited 2>/dev/null || true"

rm -rf "$STORE_DIR"
[ "$fail" = 0 ] && echo "smoke: all green" || exit 1
