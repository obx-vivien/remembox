#!/usr/bin/env bash
# Builds a self-contained dist/ folder:
#
#   dist/
#     remembox            <- launcher script (what MCP clients invoke)
#     bin/remembox        <- compiled native executable
#     lib/libobjectbox.dylib (or .so)
#
# Why the launcher: the objectbox-dart bindings resolve lib/libobjectbox.*
# relative to the CURRENT WORKING DIRECTORY (not the executable), and MCP
# clients launch servers from arbitrary cwds. The compiled binary also
# pre-loads the library exe-relative (lib/src/store.dart,
# ensureNativeLibraryLoaded) as a second line of defense; the launcher makes
# the dist folder work even if that ever regresses, and gives `claude mcp
# add` a single stable path.
set -euo pipefail

cd "$(dirname "$0")/.."

DART="${DART:-dart}"
if ! command -v "$DART" >/dev/null 2>&1; then
  DART="dart"
fi

LIB_FILE=""
for candidate in lib/libobjectbox.dylib lib/libobjectbox.so; do
  [ -f "$candidate" ] && LIB_FILE="$candidate"
done
if [ -z "$LIB_FILE" ]; then
  echo "ERROR: ObjectBox C library not found in lib/ — run tool/setup.sh first." >&2
  exit 1
fi

echo "==> dart compile exe"
rm -rf dist
mkdir -p dist/bin dist/lib
"$DART" compile exe bin/remembox.dart -o dist/bin/remembox

echo "==> bundling $LIB_FILE"
cp "$LIB_FILE" dist/lib/

cat > dist/remembox <<'EOF'
#!/usr/bin/env bash
# RememBox launcher. MCP clients run servers from arbitrary working
# directories, but the ObjectBox native library is resolved cwd-relative —
# so run the real binary from the dist folder. stdio passes through
# untouched (stdout stays a clean MCP JSON-RPC channel).
#
# fd-limit cap: Node-based MCP clients (Claude Code) spawn children with
# RLIMIT_NOFILE = unlimited; libwebsockets cannot create its context under
# that, and the ObjectBox Sync client then dies at startup with
# OBX_ERROR 10098 ("Could not create lws context") — reproduced 2026-07-07
# via `ulimit -n unlimited` (10M fds works, unlimited does not; see the
# 2026-07-06 engineering log (internal), section on OBX 10098). Cap to a
# sane value before exec.
ulimit -n 1048576 2>/dev/null || ulimit -n 10240 2>/dev/null || true
cd "$(dirname "$0")" && exec ./bin/remembox "$@"
EOF
chmod +x dist/remembox

echo "==> dist/ ready:"
ls -laR dist | sed 's/^/    /'
echo "Add to Claude with:"
echo "  claude mcp add --scope user remembox -- $(pwd)/dist/remembox"
echo
echo "NOTE (2026-09-06): any RememBox server that was ALREADY RUNNING now has a"
echo "deleted cwd (dist/ was rebuilt). In gated mode its next call fails —"
echo "stop them and restart your Claude sessions:  pkill -f bin/remembox"
