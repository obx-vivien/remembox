#!/usr/bin/env bash
# Reproducible, from-scratch release build.
#
# Builds a self-contained macOS release ZIP from a clean `git archive` of
# HEAD — never from the working directory — so leftovers (uncommitted
# edits, stray docs, a locally-downloaded ObjectBox dylib, personal store
# data under ~/.remembox) can never leak into a published artifact.
#
# Steps (each logged `==>`, each fails loudly under `set -euo pipefail`):
#   1. Refuse a dirty tree; print the commit being released.
#   2. `git archive HEAD` into a fresh staging dir — this is what honors
#      `.gitattributes export-ignore` (internal dev-log/spike docs, see
#      that file's header comment).
#   3. Validate tool/release-denylist.txt (present, non-empty, every
#      pattern compiles as an ERE), then run the personal-trace gate
#      (content AND file/dir names) against it, plus a generic secrets
#      check, over the freshly archived source tree. A missing or
#      unusable denylist ABORTS the release — the gate is never silently
#      skipped. The gate runs twice total: here, early (cheap failure
#      before the slow build), and again in step 5b over the final
#      assembled tree.
#   4. Obtain the ObjectBox C library and compile, inside staging, by
#      calling tool/setup.sh (dylib download + codegen) and tool/build.sh
#      (exe + launcher) — never by copying the worktree's dylib.
#   5. Assemble the release ZIP layout: top-level remembox/ containing
#      dist/, skill/SKILL.md, LICENSE, README.md.
#   5b. Personal-trace gate, final pass: re-scan the fully assembled tree,
#      now including dist/'s compiled binaries, skill/SKILL.md, LICENSE
#      and README.md — none of which existed yet for step 3's pass. Scans
#      binary content via raw byte grep, not `strings` (see the comment on
#      run_trace_gate below for why), so this subsumes what used to be a
#      separate binary-strings gate.
#   6. Smoke-test the built launcher from a foreign cwd, gated mode.
#   7. Write remembox-<version>-macos-arm64.zip into release/, print path,
#      size, sha256.
#
# Usage:
#   tool/release.sh              # build the real zip
#   tool/release.sh --dry-run    # everything except writing the zip
#
# Required env:
#   REMEMBOX_SKILL_MD=<path>     # path to the SKILL.md you want to ship
#                                 # (the repo cannot know where it lives
#                                 # on this machine), e.g.
#                                 # REMEMBOX_SKILL_MD=/path/to/SKILL.md
# Optional env:
#   DART=<path to dart>          # defaults to `dart` on PATH, same as
#                                 # tool/setup.sh / tool/build.sh
set -euo pipefail

# --- Personal-trace gate: shared library --------------------------------
# These two functions are defined unconditionally, before the
# RELEASE_GATE_LIB_ONLY guard below, so a test harness can `source` this
# script with RELEASE_GATE_LIB_ONLY=1 to get `validate_denylist` and
# `run_trace_gate` without running a real release (no git archive, no
# build, no zip). Both read the global $DENYLIST set later in the main
# body (or by the sourcing test harness) and operate on the current
# working directory ("."), so the caller must `cd` into the tree first.

# Fails closed: aborts (exit 1) if $DENYLIST is missing, empty (after
# stripping comment/blank lines), or contains a pattern that does not
# compile as an ERE. A malformed pattern must never be read as "0 hits" —
# see run_trace_gate for the matching rule on the scan side.
validate_denylist() {
  echo "==> Validating denylist: $DENYLIST"
  if [ ! -f "$DENYLIST" ]; then
    echo "ERROR: no denylist at $DENYLIST." >&2
    echo "       This release must be built by the maintainer, with either" >&2
    echo "       tool/release-denylist.txt present (it is export-ignored —" >&2
    echo "       it never ships; pull it from a maintainer checkout) or" >&2
    echo "       RELEASE_DENYLIST=<path> pointing at an equivalent file." >&2
    echo "       The personal-trace gate cannot run without it, and a" >&2
    echo "       release cannot be built without the gate." >&2
    exit 1
  fi
  local active_patterns
  active_patterns="$(grep -v -E '^[[:space:]]*(#|$)' "$DENYLIST" | grep -c . || true)"
  if [ "$active_patterns" -eq 0 ]; then
    echo "ERROR: denylist at $DENYLIST has no active patterns (only comments/blank lines) — unusable." >&2
    exit 1
  fi
  local pattern pattern_rc
  while IFS= read -r pattern || [ -n "$pattern" ]; do
    case "$pattern" in
      ''|'#'*) continue ;;
    esac
    pattern_rc=0
    grep -E -e "$pattern" /dev/null >/dev/null 2>&1 || pattern_rc=$?
    if [ "$pattern_rc" -ge 2 ]; then
      echo "ERROR: denylist unusable — invalid pattern in $DENYLIST: $pattern" >&2
      exit 1
    fi
  done < "$DENYLIST"
  echo "==> Denylist OK: $active_patterns active pattern(s)"
}

# Scans the current directory's content and file/dir names against
# $DENYLIST. Exits 1 (fail closed) the moment grep itself errors on a bad
# pattern (exit >=2) — that is never conflated with "0 hits" (exit 1,
# clean). Exits 1 with the hits printed when the scan finds a real match.
#
# `strings` is NOT used for binary content: a Dart AOT snapshot's string
# literals are not stored as conventional NUL-terminated printable-ASCII
# runs, so `strings` (even `-a`) finds zero of them on macOS — proven by
# hand: `strings dist/bin/remembox | grep -i -E -f denylist` reports 0
# hits on a binary that a raw byte grep over the same file finds real
# hits in. `LC_ALL=C grep -a` (treat the file as text regardless of
# embedded NUL bytes, byte-wise rather than locale-collated) is the
# reliable way to search compiled output.
#
# $1 = label for log lines. $2 = mode, "text" or "full":
#   text: content scanned with plain `grep -rn` (whole matching lines) —
#         for the archived source tree, which has no binaries yet.
#   full: content scanned with `LC_ALL=C grep -rno -a` (matched fragments
#         only, deduped, capped at 20 printed) so it is safe to point at
#         a tree that includes dist/bin/remembox, dist/remembox and
#         dist/lib/libobjectbox.* — a "line" inside a binary can be the
#         entire file, and printing it whole would flood the terminal.
# Both modes re-scan file/dir names.
run_trace_gate() {
  local label="$1"
  local mode="$2"
  echo "==> Personal-trace gate: $label"
  local abort_release=false
  local rc=0
  local content_hits name_hits n_content n_names

  if [ "$mode" = "full" ]; then
    content_hits="$(LC_ALL=C grep -rno -a -i -E -f "$DENYLIST" .)" || rc=$?
  else
    content_hits="$(grep -rn -i -E -f "$DENYLIST" .)" || rc=$?
  fi
  if [ "$rc" -ge 2 ]; then
    echo "ERROR: denylist unusable — grep failed scanning content ($label, exit $rc):" >&2
    printf '%s\n' "$content_hits" >&2
    exit 1
  fi
  n_content="$(printf '%s\n' "$content_hits" | grep -c . || true)"; [ -z "$content_hits" ] && n_content=0
  echo "  [content] $n_content hit(s)"
  if [ "$n_content" -gt 0 ]; then
    abort_release=true
    if [ "$mode" = "full" ]; then
      printf '%s\n' "$content_hits" | sort -u | head -20 | sed 's/^/      /'
      [ "$n_content" -gt 20 ] && echo "      ... ($n_content total match(es), showing first 20 unique fragments)"
    else
      printf '%s\n' "$content_hits" | sed 's/^/      /'
    fi
  fi

  rc=0
  name_hits="$(find . -print | LC_ALL=C grep -i -E -f "$DENYLIST")" || rc=$?
  if [ "$rc" -ge 2 ]; then
    echo "ERROR: denylist unusable — grep failed scanning file/dir names ($label, exit $rc):" >&2
    printf '%s\n' "$name_hits" >&2
    exit 1
  fi
  n_names="$(printf '%s\n' "$name_hits" | grep -c . || true)"; [ -z "$name_hits" ] && n_names=0
  echo "  [file/dir names] $n_names hit(s)"
  if [ "$n_names" -gt 0 ]; then
    printf '%s\n' "$name_hits" | sed 's/^/      /'
    abort_release=true
  fi

  if [ "$abort_release" = true ]; then
    echo "ERROR: personal traces found ($label) — see hits above." >&2
    echo "       Fix the source in the worktree, commit, re-run." >&2
    exit 1
  fi
  echo "==> Personal-trace gate ($label): clean"
}

if [ "${RELEASE_GATE_LIB_ONLY:-}" = "1" ]; then
  # Test harnesses source this script with RELEASE_GATE_LIB_ONLY=1 to get
  # the two functions above without running a real release.
  return 0 2>/dev/null || exit 0
fi

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

DRY_RUN=false
if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=true
fi

DART="${DART:-dart}"
if ! command -v "$DART" >/dev/null 2>&1; then
  DART="dart"
fi

# --- 1. Clean tree, known commit ------------------------------------------
echo "==> Checking for a clean working tree"
if [ -n "$(git status --porcelain)" ]; then
  echo "ERROR: working tree is dirty — commit or stash before releasing:" >&2
  git status --porcelain >&2
  exit 1
fi
RELEASE_COMMIT="$(git rev-parse HEAD)"
echo "==> Releasing commit $RELEASE_COMMIT"

if [ -z "${REMEMBOX_SKILL_MD:-}" ]; then
  echo "ERROR: REMEMBOX_SKILL_MD is not set. Point it at the SKILL.md you" >&2
  echo "       want to ship, e.g.:" >&2
  echo "       REMEMBOX_SKILL_MD=/path/to/SKILL.md tool/release.sh" >&2
  exit 1
fi
if [ ! -f "$REMEMBOX_SKILL_MD" ]; then
  echo "ERROR: REMEMBOX_SKILL_MD does not point to a file: $REMEMBOX_SKILL_MD" >&2
  exit 1
fi
echo "==> Skill file: $REMEMBOX_SKILL_MD"

# --- 2. git archive into a fresh staging dir -------------------------------
# Staging lives under a fixed /tmp prefix, not the default mktemp base
# (macOS: a per-user the per-user macOS temp folder token). `dart compile` embeds the
# compile-time script path (Platform.script) into the AOT binary, so a
# default-base staging dir would bake that per-user/per-machine token into
# every shipped binary. /tmp/remembox-release.XXXXXX keeps the embedded
# path generic.
STAGE_PARENT="$(mktemp -d /tmp/remembox-release.XXXXXX)"
STAGE="$STAGE_PARENT/remembox"
mkdir -p "$STAGE"
echo "==> git archive $RELEASE_COMMIT -> $STAGE"
git archive "$RELEASE_COMMIT" | tar -x -C "$STAGE"
cleanup() { rm -rf "$STAGE_PARENT"; }
trap cleanup EXIT

# --- 3. Personal-trace gate on the staged (published) tree ---------------
# Patterns live OUTSIDE this script in tool/release-denylist.txt, which is
# export-ignored and never ships — a public copy of this script must not
# carry the maintainer's own name as a search pattern. A missing or
# unusable denylist now ABORTS the release (validate_denylist, above) —
# it is never silently skipped. The secrets check below is generic,
# needs no denylist file, and always runs.
DENYLIST="${RELEASE_DENYLIST:-$REPO_ROOT/tool/release-denylist.txt}"
validate_denylist
cd "$STAGE"
abort_release=false
run_trace_gate "staged source tree, early pass" text
# Secrets (generic, always): the two documented placeholder lines are allowed.
# --exclude=release.sh: this script's own secrets pattern is a literal, not a
# secret. The personal-trace gate above deliberately does NOT exclude it —
# release.sh must itself be free of personal patterns (they live in the
# denylist file).
raw_secret_hits="$(grep -rn -i -E --exclude=release.sh 'OBX_MEMORY_SYNC_CREDENTIALS=[^[:space:]$]|SYNC_SECRET=[A-Za-z0-9+/=]{8,}' . 2>/dev/null || true)"
real_secret_hits="$(printf '%s\n' "$raw_secret_hits" | grep -v -E 'OBX_MEMORY_SYNC_CREDENTIALS=(\.\.\.|<)' || true)"
n5="$(printf '%s\n' "$real_secret_hits" | grep -c . || true)"; [ -z "$real_secret_hits" ] && n5=0
echo "  [secrets] $n5 hit(s) (placeholder lines excluded)"
[ "$n5" -gt 0 ] && printf '%s\n' "$real_secret_hits" | sed 's/^/      /' && abort_release=true
if [ "$abort_release" = true ]; then
  echo "ERROR: secrets found in the staged (published) tree —" >&2
  echo "       see the hits above. Fix the source in the worktree, commit, re-run." >&2
  exit 1
fi
echo "==> Secrets check: clean"

cd "$REPO_ROOT"

# --- 4. ObjectBox C library + compile, inside staging ----------------------
# Never copy lib/libobjectbox.* from the worktree — that would bypass
# "from scratch". tool/setup.sh's download logic (pinned objectbox-dart
# install.sh, --sync variant) is the source of truth for how to obtain it;
# call it inside staging so it downloads fresh, cwd-relative, exactly as it
# would for a brand-new clone. It also runs build_runner, regenerating
# lib/objectbox.g.dart from the committed lib/objectbox-model.json.
echo "==> tool/setup.sh (staged): deps + ObjectBox C lib + codegen"
(cd "$STAGE" && DART="$DART" tool/setup.sh)

echo "==> tool/build.sh (staged): compile dist/"
# TMPDIR: `dart compile exe` writes its intermediate snapshot.aot under
# $TMPDIR and the linker records that path in the binary's symbol table.
# The default macOS TMPDIR carries a per-user token, so point it at the
# generic staging dir for the build (the final gate checks the result).
(cd "$STAGE" && DART="$DART" TMPDIR="$STAGE_PARENT" tool/build.sh)

if [ ! -x "$STAGE/dist/remembox" ] || [ ! -x "$STAGE/dist/bin/remembox" ]; then
  echo "ERROR: tool/build.sh did not produce dist/remembox + dist/bin/remembox" >&2
  exit 1
fi
LIB_BUILT=""
for candidate in "$STAGE/dist/lib/libobjectbox.dylib" "$STAGE/dist/lib/libobjectbox.so"; do
  [ -f "$candidate" ] && LIB_BUILT="$candidate"
done
if [ -z "$LIB_BUILT" ]; then
  echo "ERROR: tool/build.sh did not bundle an ObjectBox C library into dist/lib" >&2
  exit 1
fi
echo "==> Built: $STAGE/dist (lib: $(basename "$LIB_BUILT"))"

# --- 5. Assemble the release layout ----------------------------------------
# remembox/
#   dist/          <- launcher + bin/remembox + lib/libobjectbox.dylib
#   skill/SKILL.md
#   LICENSE
#   README.md
echo "==> Assembling release layout"
mkdir -p "$STAGE/skill"
cp "$REMEMBOX_SKILL_MD" "$STAGE/skill/SKILL.md"
# Normalise the mode: REMEMBOX_SKILL_MD may point at a file with a
# restrictive mode in its source location (e.g. 0600) — that mode would
# otherwise leak into the ZIP as a small fingerprint of a private folder.
chmod 644 "$STAGE/skill/SKILL.md"

LICENSE_FILE=""
for candidate in LICENSE LICENSE.txt LICENSE-2.0.txt; do
  [ -f "$STAGE/$candidate" ] && LICENSE_FILE="$candidate" && break
done
if [ -z "$LICENSE_FILE" ]; then
  echo "ERROR: no LICENSE file found at the top of the archived tree" >&2
  exit 1
fi
echo "==> Licence file: $LICENSE_FILE"
if [ ! -f "$STAGE/README.md" ]; then
  echo "ERROR: README.md missing from the archived tree" >&2
  exit 1
fi
# Same mode normalisation as skill/SKILL.md above, for good measure.
chmod 644 "$STAGE/README.md" "$STAGE/$LICENSE_FILE"

# Everything not part of the shipped layout stays out of the zip: remove
# the rest of the archived tree (source, tests, tool/, docs/, pubspec*,
# .gitattributes/.gitignore, and .dart_tool/ left behind by `dart pub get`
# / build_runner in step 4) now that dist/ has been produced from it. Keep
# only what step 6 lists. dotglob is required — bare `*` does not match
# dotfiles/dotdirs in bash, which would otherwise ship .dart_tool etc.
KEEP_ITEMS="dist skill $LICENSE_FILE README.md"
shopt -s dotglob
for entry in "$STAGE"/*; do
  name="$(basename "$entry")"
  keep=false
  for k in $KEEP_ITEMS; do
    [ "$name" = "$k" ] && keep=true && break
  done
  [ "$keep" = false ] && rm -rf "$entry"
done
shopt -u dotglob
echo "==> Release contents:"
ls -la "$STAGE" | sed 's/^/    /'

# --- 5b. Personal-trace gate, final pass ------------------------------------
# Re-scan now that skill/SKILL.md, LICENSE, README.md and dist/ (including
# the compiled binaries) are all in place — step 3's pass ran before any
# of those existed, so none of them were ever scanned before this fix.
# "full" mode covers binary content too, so this subsumes what used to be
# a separate binary-strings gate (see run_trace_gate's comment for why
# `strings` cannot be used for that).
cd "$STAGE"
run_trace_gate "final assembled tree, incl. binaries" full
cd "$REPO_ROOT"

# Belt-and-suspenders check on top of the denylist above: `dart compile`
# bakes the compile-time script path (Platform.script) into the AOT
# binary. The denylist's /Users/ and /home/ patterns catch a leaked
# operator home dir, but a build-machine temp path (e.g. macOS
# the per-user macOS temp folder, its /private alias, or a bare /tmp/... outside our own
# STAGE_PARENT prefix) would not match either pattern. Fail loudly if any
# absolute file:// URI referencing a real filesystem root shows up in the
# compiled binary.
BIN_PATH="$STAGE/dist/bin/remembox"
if [ -f "$BIN_PATH" ]; then
  echo "==> Scanning $BIN_PATH for embedded absolute file:// paths"
  # The compile-time script path is always embedded; on macOS /tmp resolves
  # to /private/tmp, so the only ACCEPTABLE form is the generic staging
  # prefix. Anything else (a home directory, the per-user temp folder, a
  # foreign build path) fails the release.
  FOREIGN_PATHS="$(LC_ALL=C grep -a -o -E 'file:///[A-Za-z0-9_./-]+' "$BIN_PATH" \
    | grep -v -E '^file:///(private/)?tmp/remembox-release\.' | sort -u || true)"
  HIT_COUNT="$(printf '%s\n' "$FOREIGN_PATHS" | grep -c . || true)"; [ -z "$FOREIGN_PATHS" ] && HIT_COUNT=0
  if [ "$HIT_COUNT" != "0" ]; then
    printf '%s\n' "$FOREIGN_PATHS" | sed 's/^/      /' >&2
    echo "ERROR: $BIN_PATH embeds $HIT_COUNT build-machine file:// path(s)" >&2
    echo "       (dart compile bakes Platform.script's compile-time path" >&2
    echo "       into the AOT binary — rebuild with a staging dir under a" >&2
    echo "       generic /tmp prefix, see STAGE_PARENT above)." >&2
    exit 1
  fi
fi

# --- 6. Smoke test (foreign cwd, gated mode) --------------------------------
echo "==> Smoke test: dist/remembox, foreign cwd, gated mode"
SMOKE_STORE_DIR="$(mktemp -d)"
SMOKE_INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"release-smoke","version":"0"}}}'
SMOKE_OUT="$(cd /tmp && printf '%s\n' "$SMOKE_INIT" \
  | OBX_MEMORY_DIR="$SMOKE_STORE_DIR" \
    OBX_MEMORY_AUTO_PULL=false \
    OBX_MEMORY_STORE_MODE=gated \
    OBX_LOG_LEVEL=error \
    "$STAGE/dist/remembox" 2>"$SMOKE_STORE_DIR/stderr.log" | head -1)"

if printf '%s' "$SMOKE_OUT" | grep -q '"serverInfo"'; then
  echo "==> Smoke test: PASS"
  echo "    $SMOKE_OUT"
  rm -rf "$SMOKE_STORE_DIR"
else
  echo "ERROR: smoke test FAILED — no valid initialize result on stdout." >&2
  echo "stdout was: $SMOKE_OUT" >&2
  echo "stderr (last 10 lines):" >&2
  tail -10 "$SMOKE_STORE_DIR/stderr.log" >&2 || true
  rm -rf "$SMOKE_STORE_DIR"
  exit 1
fi

# --- 7. Write the zip --------------------------------------------------------
VERSION="$(grep -m1 '^version:' "$REPO_ROOT/pubspec.yaml" | sed -E 's/^version:[[:space:]]*//')"
if [ -z "$VERSION" ]; then
  echo "ERROR: could not read version: from pubspec.yaml" >&2
  exit 1
fi
ZIP_NAME="remembox-${VERSION}-macos-arm64.zip"
RELEASE_DIR="$REPO_ROOT/release"
mkdir -p "$RELEASE_DIR"
ZIP_PATH="$RELEASE_DIR/$ZIP_NAME"

if [ "$DRY_RUN" = true ]; then
  echo "==> --dry-run: skipping zip write ($ZIP_PATH not created)"
  echo "==> Dry run complete."
  exit 0
fi

echo "==> Writing $ZIP_PATH"
rm -f "$ZIP_PATH"
(cd "$STAGE_PARENT" && zip -r -q -X "$ZIP_PATH" "remembox")

ZIP_SIZE="$(du -h "$ZIP_PATH" | cut -f1)"
ZIP_SHA="$(shasum -a 256 "$ZIP_PATH" | cut -d' ' -f1)"

echo "==> Release built:"
echo "    path:   $ZIP_PATH"
echo "    size:   $ZIP_SIZE"
echo "    sha256: $ZIP_SHA"
