#!/bin/bash
# Claude Code hook (SessionStart and Stop) that runs `remembox cockpit-sync`:
# re-renders the generated thread section of the cockpit file and appends
# the comparison to the compare log (see docs/usage-guide.md, "Threads").
#
# Fail-open and quiet: always exits 0 and prints nothing, so a hook can
# never block or clutter a session. A failure – launcher missing, non-zero
# exit, or a run longer than the timeout (killed) – is appended as one JSON
# line to the compare log instead of being dropped.
#
# Installing it is an operator step (the hooks section of Claude Code's
# settings.json); nothing installs it automatically. The script ships in the
# release ZIP as remembox/hooks/cockpit-sync-hook.sh and in the repository
# as tool/hooks/cockpit-sync-hook.sh; it finds the launcher on its own (see
# REMEMBOX_BIN), so the hook command only needs the path of this script.
#
# Environment:
#   REMEMBOX_BIN                   launcher. Unset: <this script's directory>/
#                                  ../dist/remembox (release ZIP: remembox/
#                                  hooks/ next to remembox/dist/), then
#                                  <this script's directory>/../../dist/
#                                  remembox (repository: tool/hooks/). If
#                                  none is executable, that is logged.
#                                  A symlink to this script works; a COPY
#                                  elsewhere needs REMEMBOX_BIN.
#   REMEMBOX_COCKPIT_HOOK_TIMEOUT  seconds before the run is killed (default 20)
#   OBX_MEMORY_COCKPIT_LOG         compare log (default on macOS:
#                                  ~/Library/Logs/remembox/cockpit-compare.log,
#                                  elsewhere: ${XDG_STATE_HOME:-~/.local/state}/
#                                  remembox/cockpit-compare.log – the same rule
#                                  as `remembox cockpit-sync` itself)
#   OBX_MEMORY_COCKPIT_FILE        the cockpit file – REQUIRED: without it the
#                                  hook does nothing (not configured is not a
#                                  failure, so nothing is logged either)
#   OBX_MEMORY_DIR                 passed through to cockpit-sync
#
# Next to a persistent-mode process (`--serve` or OBX_MEMORY_SYNC_URL) the
# run fails after the store's 8-second startup probe (that process holds
# store.lock); that failure is logged.
set -u

timeout_s="${REMEMBOX_COCKPIT_HOOK_TIMEOUT:-20}"
if [ -n "${OBX_MEMORY_COCKPIT_LOG:-}" ]; then
  log="$OBX_MEMORY_COCKPIT_LOG"
elif [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
  log="$HOME/Library/Logs/remembox/cockpit-compare.log"
else
  log="${XDG_STATE_HOME:-$HOME/.local/state}/remembox/cockpit-compare.log"
fi

# Claude Code passes the hook input as JSON on stdin; read it so the writer
# never blocks (skipped when run by hand from a terminal).
if [ ! -t 0 ]; then cat >/dev/null 2>&1; fi

# Not configured: nothing to do, and nothing to report.
[ -n "${OBX_MEMORY_COCKPIT_FILE:-}" ] || exit 0

fail() {
  # The log carries cockpit titles: a directory or file created here is
  # private (700 / 600); an existing one is left as it is (cockpit-sync
  # tightens an existing log itself).
  mkdir -p -m 700 "$(dirname "$log")" 2>/dev/null || return 0
  local at msg
  at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  # JSON-safe: no control characters, quotes or backslashes, bounded.
  msg=$(printf '%s' "$1" | tr -d '\000-\037"\\' | cut -c1-500)
  ( umask 077
    printf '{"at":"%s","event":"hook-failure","error":"%s"}\n' "$at" "$msg" \
      >>"$log" ) 2>/dev/null
  return 0
}

# Launcher: REMEMBOX_BIN, else next to this script (release ZIP layout, then
# repository layout). Only an executable file counts.
bin=""
if [ -n "${REMEMBOX_BIN:-}" ]; then
  if [ -x "$REMEMBOX_BIN" ] && [ ! -d "$REMEMBOX_BIN" ]; then bin="$REMEMBOX_BIN"; fi
  tried="REMEMBOX_BIN=$REMEMBOX_BIN"
else
  # The script's real location: follow symlinks (readlink without -f, which
  # BSD and GNU do not share; a relative link target is relative to the
  # link's directory), at most 40 hops, so a symlinked hook still finds
  # ../dist/remembox. A COPY elsewhere does not – it needs REMEMBOX_BIN.
  src="$0"
  hops=0
  while [ -L "$src" ] && [ "$hops" -lt 40 ]; do
    target=$(readlink "$src") || break
    case "$target" in
      /*) src="$target" ;;
      *) src="$(dirname "$src")/$target" ;;
    esac
    hops=$((hops + 1))
  done
  here=$(cd "$(dirname "$src")" 2>/dev/null && pwd -P) || here=""
  tried="REMEMBOX_BIN unset"
  if [ -n "$here" ]; then
    for candidate in "$here/../dist/remembox" "$here/../../dist/remembox"; do
      tried="$tried; $candidate"
      if [ -x "$candidate" ] && [ ! -d "$candidate" ]; then
        bin="$candidate"
        break
      fi
    done
  else
    tried="$tried; cannot resolve the script directory of $0"
  fi
fi
if [ -z "$bin" ]; then
  fail "cockpit-sync hook: launcher is missing or not executable ($tried)"
  exit 0
fi

errfile=$(mktemp "${TMPDIR:-/tmp}/remembox-cockpit-hook.XXXXXX") || exit 0
"$bin" cockpit-sync >/dev/null 2>"$errfile" &
pid=$!
# The watcher's stdout and stderr both go to /dev/null: a sleeping watcher
# that still held the hook's stdout open would make whoever reads it wait
# for the full timeout.
(
  sleep "$timeout_s" &
  wait $!
  kill -TERM "$pid" 2>/dev/null
) >/dev/null 2>&1 &
watcher=$!
wait "$pid" 2>/dev/null
rc=$?
pkill -P "$watcher" 2>/dev/null
kill "$watcher" 2>/dev/null
wait "$watcher" 2>/dev/null

if [ "$rc" -ne 0 ]; then
  if [ "$rc" -ge 128 ]; then
    reason="was killed after ${timeout_s}s (exit $rc)"
  else
    reason="exited $rc"
  fi
  # The reason is cockpit-sync's own last [cockpit] line (not the usage
  # text or native chatter around it).
  fail "cockpit-sync $reason: $(grep '^\[cockpit\]' "$errfile" 2>/dev/null | tail -n 1)"
fi
rm -f "$errfile"
exit 0
