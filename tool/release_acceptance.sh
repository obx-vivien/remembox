#!/usr/bin/env bash
# Acceptance test for a built release ZIP: unpacks it and uses the shipped
# launcher the way a user's MCP client does – not just the `initialize`
# handshake (that is tool/smoke.sh), but real tool calls against a real
# store with real embeddings.
#
# tool/release.sh runs this on the freshly built zip before it is written
# to release/ (also under --dry-run); a failure aborts the release. It can
# be run by hand against any zip as well.
#
# What is checked (one PASS / FAIL / NOT RUN / SKIP line per check – the
# driver, tool/release_acceptance.dart, holds the details):
#
#   0. Layout + spawn environment – the zip unpacks to remembox/dist/ with
#      executable launcher and binary, skill/SKILL.md and README.md, and
#      tool/smoke.sh passes on the UNPACKED launcher (foreign cwd,
#      unlimited fd limit).
#   A. Fresh install – empty store directory: `tools/list` equals the tools
#      registered in lib/src/server.dart, `stats`, `remember` (tag
#      normalisation, tag equal to the project dropped with a warning,
#      missing project rejected), `recall`, `area_set` / `project_set`
#      (unknown area rejected), `recall` by area, `fact_set` history,
#      `fact_get` current vs `at`, `fact_query` (area, includeHistory, no
#      filter rejected), `tags_list`, and consistent `stats` after a
#      restart.
#   B. Upgrade – only with <previous-release.zip>: the PREVIOUS release
#      creates a store and writes entries with legacy tag spellings; the
#      new release opens the same directory (entry count and vector index
#      intact, `recall` finds the old entries, `reindex` registers the
#      projects, `tags_normalize` dry run and real run, a new tag and a
#      fact can be written, consistent `stats`). Then the previous release
#      is started on the upgraded store again and must refuse it with the
#      documented ObjectBox message ("DB's last entity ID … is higher than
#      … from model"), and the new release must still open it afterwards.
#      Without <previous-release.zip> B is SKIPPED, loudly – the exit code
#      stays 0, the summary says so.
#
# Usage:
#   tool/release_acceptance.sh <new-release.zip> [<previous-release.zip>]
#   tool/release_acceptance.sh --preflight    # only: is Ollama usable?
#
# Requirements:
#   - A local Ollama at http://localhost:11434 with the `embeddinggemma`
#     model (the defaults of a fresh install). Missing -> the run FAILS
#     with a message saying so; it is never skipped.
#   - This checkout matches the zip under test: the expected tool list is
#     derived from lib/src/server.dart and the expected version from
#     pubspec.yaml (tool/release.sh guarantees both – it builds from HEAD
#     of a clean tree).
#
# Optional env:
#   REMEMBOX_DOWNGRADE=refused|opens
#                                 # what the previous release must do with
#                                 # the upgraded store. Default `refused`
#                                 # (the new release changed the database
#                                 # schema, as 0.3.0 did). Set `opens` for
#                                 # a release WITHOUT a schema change
#                                 # relative to the previous one – then the
#                                 # previous release must still open the
#                                 # store and read every entry. Explicit on
#                                 # purpose: either outcome is asserted,
#                                 # never just tolerated.
#   DART=<path to dart>           # defaults to `dart` on PATH
#
# The stores live in a temp dir under /tmp and hold synthetic data only;
# it is removed on success and kept (path printed) on failure.
set -euo pipefail

PREFLIGHT=false
NEW_ZIP=""
PREVIOUS_ZIP=""
if [ "${1:-}" = "--preflight" ] && [ "$#" -eq 1 ]; then
  PREFLIGHT=true
elif [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "Usage: $0 <new-release.zip> [<previous-release.zip>]" >&2
  echo "       $0 --preflight" >&2
  exit 64
else
  # Resolve against the caller's cwd before the cd below.
  abs_path() { printf '%s/%s\n' "$(cd "$(dirname "$1")" && pwd)" "$(basename "$1")"; }
  if [ ! -f "$1" ]; then
    echo "ERROR: no release zip at $1" >&2
    exit 1
  fi
  NEW_ZIP="$(abs_path "$1")"
  if [ "$#" -eq 2 ]; then
    # Given but wrong is an error, not a reason to skip scenario B.
    if [ ! -f "$2" ]; then
      echo "ERROR: no previous release zip at $2" >&2
      exit 1
    fi
    PREVIOUS_ZIP="$(abs_path "$2")"
  fi
fi

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

DART="${DART:-dart}"
if ! command -v "$DART" >/dev/null 2>&1; then
  echo "ERROR: dart not found (DART=$DART) – the acceptance driver is a Dart script." >&2
  exit 1
fi

if [ "$PREFLIGHT" = true ]; then
  exec "$DART" "$REPO_ROOT/tool/release_acceptance.dart" --preflight
fi

DOWNGRADE="${REMEMBOX_DOWNGRADE:-refused}"
if [ "$DOWNGRADE" != "refused" ] && [ "$DOWNGRADE" != "opens" ]; then
  echo "ERROR: REMEMBOX_DOWNGRADE must be 'refused' or 'opens', got '$DOWNGRADE'" >&2
  exit 1
fi

VERSION="$(grep -m1 '^version:' "$REPO_ROOT/pubspec.yaml" | sed -E 's/^version:[[:space:]]*//')"
if [ -z "$VERSION" ]; then
  echo "ERROR: could not read version: from pubspec.yaml" >&2
  exit 1
fi

WORK="$(mktemp -d /tmp/remembox-acceptance.XXXXXX)"
finish() {
  local rc=$?
  if [ "$rc" -eq 0 ]; then
    rm -rf "$WORK"
  else
    echo "ERROR: release acceptance FAILED (exit $rc) – work dir kept for inspection: $WORK" >&2
  fi
}
trap finish EXIT

# Unpacks $1 into $WORK/$2 and verifies the documented layout; prints the
# launcher path. Everything a user runs or reads after unzipping must be
# there, and the two executables must have survived the zip as executables.
unpack() {
  local zip="$1" name="$2" root
  root="$WORK/$name"
  # unpack runs inside $(...), where errexit does not apply (bash 3.2): every
  # failure needs an explicit exit, and the caller checks the status too.
  mkdir "$root" || { echo "ERROR: cannot create $root" >&2; exit 1; }
  unzip -q "$zip" -d "$root" || { echo "ERROR: unzip failed for $zip" >&2; exit 1; }
  local item
  for item in remembox/dist/remembox remembox/dist/bin/remembox; do
    if [ ! -x "$root/$item" ]; then
      echo "ERROR: $zip does not unpack to an executable $item" >&2
      exit 1
    fi
  done
  # The dylib must sit next to the binary: without it the server falls back
  # to /usr/local/lib and a broken zip would pass on a machine that has a
  # system-installed ObjectBox library.
  for item in remembox/dist/lib/libobjectbox.dylib remembox/skill/SKILL.md remembox/README.md remembox/LICENSE; do
    if [ ! -f "$root/$item" ]; then
      echo "ERROR: $zip does not contain $item" >&2
      exit 1
    fi
  done
  printf '%s\n' "$root/remembox/dist/remembox"
}

echo "==> Release acceptance: $NEW_ZIP (expecting remembox $VERSION)"
NEW_LAUNCHER="$(unpack "$NEW_ZIP" new)" || exit 1
echo "PASS: layout – $(basename "$NEW_ZIP") unpacks to remembox/{dist,skill,README.md,LICENSE} with executable launcher and binary and the bundled dylib"

DRIVER_ARGS=(
  --new-launcher "$NEW_LAUNCHER"
  --server-source "$REPO_ROOT/lib/src/server.dart"
  --expect-version "$VERSION"
  --work-dir "$WORK"
  --downgrade "$DOWNGRADE"
)
if [ -n "$PREVIOUS_ZIP" ]; then
  echo "==> Previous release for the upgrade scenario: $PREVIOUS_ZIP (expected afterwards: $DOWNGRADE)"
  PREVIOUS_LAUNCHER="$(unpack "$PREVIOUS_ZIP" previous)" || exit 1
  DRIVER_ARGS+=(--previous-launcher "$PREVIOUS_LAUNCHER")
fi

echo "==> Spawn-environment smoke test on the unpacked launcher"
# The server under test must not inherit the caller's OBX_* settings.
env $(env | sed -n 's/^\(OBX_[A-Za-z0-9_]*\)=.*/-u \1/p') "$REPO_ROOT/tool/smoke.sh" "$NEW_LAUNCHER"

# Foreign cwd, like every other check here – nothing may depend on being
# started from the repository.
(cd "$WORK" && "$DART" "$REPO_ROOT/tool/release_acceptance.dart" "${DRIVER_ARGS[@]}")

if [ -z "$PREVIOUS_ZIP" ]; then
  echo "WARNING: upgrade scenario SKIPPED – no previous release zip given." >&2
  echo "         Only the fresh install was accepted; pass the previously" >&2
  echo "         published zip as second argument to cover the upgrade." >&2
fi
echo "==> Release acceptance: PASS"
