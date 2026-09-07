#!/usr/bin/env bash
# Installs (or re-installs) the RememBox HTTP daemon as a macOS launchd
# LaunchAgent, so it starts at login, keeps running as the SOLE ObjectBox
# writer process, and is restarted automatically if it ever crashes.
#
# Background: RememBox's store does not tolerate multiple writer PROCESSES
# on one store directory without risking silent data loss (R2-6,
# the 2026-07-06 engineering log (internal)). Daemon mode fixes this by
# having ONE process own the store while every Claude Code session
# connects over MCP
# streamable HTTP instead of spawning its own stdio process — see
# the 2026-07-18 HTTP-daemon engineering log (internal).
#
# What this script does (idempotent — safe to re-run, e.g. after
# tool/build.sh produces a new binary, or after exporting a new OBX_MEMORY_*
# value you want the daemon to pick up):
#   1. Verifies dist/remembox exists (run tool/build.sh first).
#   2. Captures every OBX_MEMORY_* variable currently set (exported) in THIS
#      shell and renders it into the plist's EnvironmentVariables dict — a
#      LaunchAgent does NOT inherit the caller's shell environment, so
#      without this step the daemon would silently start with sync OFF and
#      code-level defaults for embed model/dims/etc even if your normal
#      setup overrides them (2026-08-14 review finding 1, see the
#      2026-07-18 HTTP-daemon engineering log (internal), "Review round 1
#      fixes"). DAEMON CONFIG IS THEREFORE FROZEN AT INSTALL TIME: re-run this
#      script after changing any OBX_MEMORY_* export to pick it up.
#   3. Renders tool/launchd/io.remembox.daemon.plist with this repo's
#      absolute dist binary path, the log directory, the port, and the
#      captured env dict, into ~/Library/LaunchAgents/io.remembox.daemon.plist.
#   4. Creates ~/.remembox/logs (stdout/stderr destinations).
#   5. If the agent is already loaded, unloads it first (`launchctl
#      bootout`) so a rebuilt binary / changed plist actually takes effect.
#   6. Loads it (`launchctl bootstrap gui/$UID`).
#   7. Prints the `claude mcp` commands to point Claude Code at the daemon.
#
# This script does NOT touch ~/.remembox/<store files> — only the launchd
# job definition and the log directory.
#
# Usage: tool/install-daemon.sh
set -euo pipefail

cd "$(dirname "$0")/.."
REPO_DIR="$(pwd)"
DIST_BIN="$REPO_DIR/dist/remembox"
PLIST_SRC="$REPO_DIR/tool/launchd/io.remembox.daemon.plist"
PLIST_DST="$HOME/Library/LaunchAgents/io.remembox.daemon.plist"
LOG_DIR="$HOME/.remembox/logs"
LABEL="io.remembox.daemon"
PORT="${OBX_MEMORY_HTTP_PORT:-3927}"
# Mirrors lib/src/store.dart MemoryConfig.fromEnvironment's storeDir
# resolution (OBX_MEMORY_DIR, else ~/.remembox) — this is where
# daemon.token (below) is persisted, so it must resolve to the SAME
# directory the daemon itself will use.
STORE_DIR="${OBX_MEMORY_DIR:-$HOME/.remembox}"
TOKEN_FILE="$STORE_DIR/daemon.token"

if [ ! -x "$DIST_BIN" ]; then
  echo "ERROR: $DIST_BIN missing or not executable — run tool/build.sh first." >&2
  exit 1
fi
if [ ! -f "$PLIST_SRC" ]; then
  echo "ERROR: $PLIST_SRC missing." >&2
  exit 1
fi

echo "==> Creating log directory $LOG_DIR"
mkdir -p "$LOG_DIR"
# 2026-09-07 (Fix 1, the 2026-09-07 daemon-auth engineering log
# (internal)): the security review found this directory 0755 —
# daemon.err.log there can carry
# diagnostic detail an unrelated local user should not get to read.
chmod 700 "$LOG_DIR"

# ---------------------------------------------------------------------------
# Resolve OBX_MEMORY_HTTP_TOKEN (2026-09-07, Fix 1, the 2026-09-07
# daemon-auth engineering log, internal): the daemon now REQUIRES a bearer
# token and refuses to
# start without one (lib/src/http_transport.dart resolveHttpToken) —
# loopback binding alone is not a sufficient security boundary (see the
# 2026-09-07 daemon-auth engineering log (internal) for the review
# finding). Resolution order, most to least deliberate:
#   1. OBX_MEMORY_HTTP_TOKEN already exported in this shell — the operator's
#      explicit choice; used as-is and (re-)persisted to $TOKEN_FILE so a
#      later run without the export still finds it.
#   2. An existing $TOKEN_FILE from a previous run — reused, NOT
#      regenerated. Regenerating on every re-run would silently invalidate
#      every `claude mcp add ... --header "Authorization: Bearer <old>"`
#      registration this script already told the operator to make, the
#      moment they re-run this script for an unrelated reason (e.g. a
#      rebuilt binary) — a silent-failure mode this project's CLAUDE.md
#      forbids introducing.
#   3. Neither present — generate a fresh one with openssl.
# Token generation/persistence is deliberately done HERE, not inside the
# Dart process (lib/src/http_transport.dart resolveHttpToken's doc): a
# shell script already owns umask/chmod/mkdir for this whole install flow,
# so keeping that machinery out of the daemon process keeps it a pure
# request-handling loop with no Process.run or file-permission
# special-casing of its own.
echo "==> Resolving OBX_MEMORY_HTTP_TOKEN"
if [ -n "${OBX_MEMORY_HTTP_TOKEN:-}" ]; then
  echo "    using OBX_MEMORY_HTTP_TOKEN from this shell's environment (${#OBX_MEMORY_HTTP_TOKEN} chars)"
  # Re-export unconditionally: the variable may be set-but-not-exported
  # (e.g. sourced from a non-exported shell var), and the OBX_MEMORY_*
  # capture below reads from `env`, which only sees exported variables.
  export OBX_MEMORY_HTTP_TOKEN
  mkdir -p "$STORE_DIR"
  (umask 077 && printf '%s' "$OBX_MEMORY_HTTP_TOKEN" > "$TOKEN_FILE")
  chmod 600 "$TOKEN_FILE"
  echo "    persisted a copy to $TOKEN_FILE (mode 0600)"
elif [ -s "$TOKEN_FILE" ]; then
  echo "    reusing the existing token at $TOKEN_FILE"
  echo "    (unset OBX_MEMORY_HTTP_TOKEN and delete that file to force a fresh one)"
  OBX_MEMORY_HTTP_TOKEN="$(cat "$TOKEN_FILE")"
  export OBX_MEMORY_HTTP_TOKEN
  chmod 600 "$TOKEN_FILE"
else
  if ! command -v openssl >/dev/null 2>&1; then
    echo "ERROR: openssl not found — cannot generate OBX_MEMORY_HTTP_TOKEN." >&2
    echo "  Install openssl, or export OBX_MEMORY_HTTP_TOKEN yourself and re-run." >&2
    exit 1
  fi
  echo "    no OBX_MEMORY_HTTP_TOKEN set and no existing $TOKEN_FILE — generating a new one"
  mkdir -p "$STORE_DIR"
  GENERATED_TOKEN="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=')"
  (umask 077 && printf '%s' "$GENERATED_TOKEN" > "$TOKEN_FILE")
  chmod 600 "$TOKEN_FILE"
  OBX_MEMORY_HTTP_TOKEN="$GENERATED_TOKEN"
  export OBX_MEMORY_HTTP_TOKEN
  echo "    generated and persisted a new token to $TOKEN_FILE (mode 0600)"
fi

# ---------------------------------------------------------------------------
# Capture OBX_MEMORY_* env for the daemon (2026-08-14 review finding 1).
#
# A LaunchAgent's ProgramArguments run with launchd's own minimal
# environment, NOT the interactive shell environment this installer runs
# in — any OBX_MEMORY_* variable the operator relies on (sync URL/
# credentials, embed model, Ollama URL, dims, store dir, ...) must be
# captured HERE and baked into the plist's <key>EnvironmentVariables</key>
# dict, or the daemon silently starts with sync OFF and code defaults.
#
# `env | grep` (not `${!OBX_MEMORY_@}`) deliberately, so this works under
# macOS's stock /bin/bash 3.2 (no bash-4 indirect-expansion-by-prefix) and
# only picks up EXPORTED vars — exactly what a subprocess would see.
XML_ESCAPE() {
  local v="$1"
  v="${v//&/&amp;}"
  v="${v//</&lt;}"
  v="${v//>/&gt;}"
  v="${v//\"/&quot;}"
  v="${v//\'/&apos;}"
  printf '%s' "$v"
}

ENV_DICT_FILE="$(mktemp)"
# Same directory as $PLIST_DST (not the system tmp dir), so the final `mv`
# below is a same-filesystem rename — atomic and guaranteed not to fall back
# to a copy+delete (which would reopen the truncation window this fix
# exists to close) even if $TMPDIR lives on a different volume than $HOME.
PLIST_TMP="$(mktemp "${PLIST_DST}.XXXXXX")"
trap 'rm -f "$ENV_DICT_FILE" "$PLIST_TMP"' EXIT
FOUND_VARS=()
while IFS='=' read -r name value; do
  [ -z "$name" ] && continue
  # An oddly-named variable (e.g. containing `[`, `(`, or other shell
  # metacharacters) reaches bash's indirect expansion `${!name}` below
  # BEFORE `set -u` would catch it — bash evaluates any subscript/command
  # substitution embedded in the name as part of resolving the expansion.
  # An attacker who controls the operator's environment (a sourced
  # .env/direnv, a wrapper script, a CI job) could smuggle a command
  # substitution into a variable name and get it executed here. Reject
  # anything that is not a plain shell identifier before touching its
  # value at all. Do not echo the hostile name itself — it may itself be
  # attacker-controlled text an operator would paste back into a shell.
  case "$name" in
    *[!A-Za-z0-9_]*)
      echo "WARNING: skipping oddly named environment variable" >&2
      continue
      ;;
  esac
  # A value containing an embedded newline (2026-08-14 review round 2, N4,
  # the 2026-07-18 HTTP-daemon engineering log (internal)) would defeat the
  # line-based `env | grep` parsing above: `env`'s output puts the
  # continuation on its
  # own line, which does not start with `OBX_MEMORY_` and so is silently
  # dropped by `grep` — `value` above ends up holding a TRUNCATED value with
  # no indication anything went wrong, and that truncated/mangled value
  # would get baked into the plist. Re-read the variable's REAL value via
  # bash indirect expansion (a single named lookup, not the bash-4
  # prefix-listing syntax this script already avoids) and check THAT for a
  # newline before trusting it at all.
  full_value="${!name}"
  case "$full_value" in
    *$'\n'*)
      echo "WARNING: \$$name contains a newline — skipping it (cannot be" >&2
      echo "  represented in this installer's line-based env capture);" >&2
      echo "  the daemon will start as if $name were unset. Re-export it" >&2
      echo "  without an embedded newline and re-run this script." >&2
      continue
      ;;
  esac
  FOUND_VARS+=("$name")
  {
    printf '        <key>%s</key>\n' "$(XML_ESCAPE "$name")"
    printf '        <string>%s</string>\n' "$(XML_ESCAPE "$full_value")"
  } >> "$ENV_DICT_FILE"
done < <(env | grep '^OBX_MEMORY_' || true)

echo "==> Captured environment for the daemon (frozen at install time):"
# Known vars this daemon reads at startup (lib/src/store.dart
# MemoryConfig.fromEnvironment), with their code-level defaults, so the
# report below is explicit about what's baked in vs. what falls back.
KNOWN_VAR_NAMES="OBX_MEMORY_DIR OBX_MEMORY_EMBED_MODEL OBX_MEMORY_OLLAMA_URL OBX_MEMORY_DIMS OBX_MEMORY_SYNC_URL OBX_MEMORY_SYNC_CREDENTIALS OBX_MEMORY_HTTP_TOKEN"
for name in $KNOWN_VAR_NAMES; do
  is_set=false
  for f in "${FOUND_VARS[@]:-}"; do
    [ "$f" = "$name" ] && is_set=true && break
  done
  if [ "$is_set" = true ]; then
    case "$name" in
      OBX_MEMORY_SYNC_CREDENTIALS|OBX_MEMORY_HTTP_TOKEN)
        # Never echo a secret to stdout/logs — report presence+length only.
        eval "len=\${#$name}"
        echo "    $name = *** (set, ${len} chars) — baked in"
        ;;
      *)
        eval "printf '    %s = %s' \"\$name\" \"\$$name\""
        echo " — baked in"
        ;;
    esac
  else
    case "$name" in
      OBX_MEMORY_DIR) def="~/.remembox" ;;
      OBX_MEMORY_EMBED_MODEL) def="embeddinggemma" ;;
      OBX_MEMORY_OLLAMA_URL) def="http://localhost:11434" ;;
      OBX_MEMORY_DIMS) def="768" ;;
      OBX_MEMORY_SYNC_URL) def="(unset = local-only)" ;;
      OBX_MEMORY_SYNC_CREDENTIALS) def="(unset = unauthenticated)" ;;
      OBX_MEMORY_HTTP_TOKEN) def="(REQUIRED — should never reach this branch; resolved above)" ;;
      *) def="(code default)" ;;
    esac
    echo "    $name not set — daemon default applies: $def"
  fi
done
OTHER_COUNT=0
for f in "${FOUND_VARS[@]:-}"; do
  case " $KNOWN_VAR_NAMES " in
    *" $f "*) ;;
    *)
      OTHER_COUNT=$((OTHER_COUNT + 1))
      echo "    $f = (other OBX_MEMORY_* var) — baked in"
      ;;
  esac
done
if [ "${#FOUND_VARS[@]:-0}" -eq 0 ]; then
  echo "    (no OBX_MEMORY_* variables were set in this shell — daemon uses"
  echo "     code defaults for everything above)"
fi
echo "==> Re-run this script any time you change an OBX_MEMORY_* export —"
echo "    daemon config is frozen at install time, it does NOT re-read"
echo "    your shell environment on its own."

echo "==> Rendering plist ($PLIST_SRC -> $PLIST_DST)"
#
# NOTE: the read+delete pair below uses two SEPARATE -e address/command
# pairs, not a `{r ...; d}` block — BSD/macOS sed (unlike GNU sed) does not
# reliably combine `r` (queue a file for append) with `d` (delete the
# current line) inside one `{}` block; verified by hand on this machine's
# sed. Each `-e` here matches the SAME single line (the plist has exactly
# one literal occurrence of the placeholder — see the plist's own doc
# comment for why that must stay true).
#
# Escapes a string for safe use as the REPLACEMENT side of a `sed
# s#find#repl#` substitution (2026-08-14 review round 2, M1b,
# the 2026-07-18 HTTP-daemon engineering log (internal)): a literal `#` in
# the replacement would prematurely close this script's `#`-delimited
# command, `&` would
# re-insert sed's whole match, and a literal `\` starts a sed escape
# sequence — all three are legal in a real path/port value (DIST_BIN,
# LOG_DIR come from `$REPO_DIR`/`$HOME`, which a `#`-containing checkout
# path would hit) and previously went in unescaped. Backslash MUST be
# escaped first — escaping `#`/`&` first would double-escape the
# backslashes those substitutions themselves introduce.
ESCAPE_SED_REPL() {
  local v="$1"
  v="${v//\\/\\\\}"
  v="${v//#/\\#}"
  v="${v//&/\\&}"
  printf '%s' "$v"
}
DIST_BIN_SEDREPL="$(ESCAPE_SED_REPL "$DIST_BIN")"
LOG_DIR_SEDREPL="$(ESCAPE_SED_REPL "$LOG_DIR")"
PORT_SEDREPL="$(ESCAPE_SED_REPL "$PORT")"
# Render into a temp file first and `mv` over $PLIST_DST only once sed has
# fully succeeded (2026-08-14 review round 2, M1a,
# the 2026-07-18 HTTP-daemon engineering log (internal)): `> "$PLIST_DST"`
# truncates the destination BEFORE sed runs, so a failing sed (or a `set
# -e` exit mid-`-e`
# chain, which cannot happen with these particular substitutions but could
# with a future one) would previously leave a truncated/empty plist at
# $PLIST_DST instead of leaving the last-good one in place. `mv` on the same
# filesystem (both under `/tmp` -> `$HOME`, i.e. same volume on macOS) is
# atomic, so $PLIST_DST is either the old file or the fully-rendered new
# one, never a partial write.
sed \
  -e "s#__REMEMBOX_DIST_BIN__#$DIST_BIN_SEDREPL#g" \
  -e "s#__REMEMBOX_LOG_DIR__#$LOG_DIR_SEDREPL#g" \
  -e "s#__REMEMBOX_PORT__#$PORT_SEDREPL#g" \
  -e "/__REMEMBOX_ENV_DICT__/r $ENV_DICT_FILE" \
  -e "/__REMEMBOX_ENV_DICT__/d" \
  "$PLIST_SRC" > "$PLIST_TMP"
mv "$PLIST_TMP" "$PLIST_DST"

UID_NUM="$(id -u)"
if launchctl print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1; then
  echo "==> $LABEL is already loaded — unloading first (bootout) so the"
  echo "    (possibly rebuilt) binary and plist take effect"
  launchctl bootout "gui/$UID_NUM/$LABEL" || true
fi

echo "==> Loading $LABEL (launchctl bootstrap gui/$UID_NUM)"
launchctl bootstrap "gui/$UID_NUM" "$PLIST_DST"

echo "==> Installed."
echo "    Binary: $DIST_BIN --serve=$PORT"
echo "    Logs:   $LOG_DIR/daemon.out.log / daemon.err.log"
echo "    Token:  $TOKEN_FILE (mode 0600)"
echo ""
# 2026-09-07 (Fix 1, the 2026-09-07 daemon-auth engineering log
# (internal)): this is the ONE intentional place the real token value is
# printed — every other
# report line above shows length only, never the value. The daemon now
# rejects any request without this exact bearer token (constant-time
# compared), so the operator needs it verbatim to register the client.
echo "Re-register RememBox in Claude Code as an HTTP MCP server (copy this —"
echo "the token below is shown only here):"
echo "  claude mcp remove remembox --scope user"
echo "  claude mcp add --scope user --transport http remembox http://127.0.0.1:$PORT/mcp --header \"Authorization: Bearer $OBX_MEMORY_HTTP_TOKEN\""
echo ""
echo "Check daemon status / logs:"
echo "  launchctl print gui/$UID_NUM/$LABEL | head -20"
echo "  tail -f $LOG_DIR/daemon.err.log"
echo ""
echo "Stop the daemon deliberately (KeepAlive would otherwise restart it):"
echo "  launchctl bootout gui/$UID_NUM/$LABEL"
