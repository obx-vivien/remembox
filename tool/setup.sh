#!/usr/bin/env bash
# One-time developer setup for remembox.
#
# 1. Fetches Dart dependencies.
# 2. Downloads the ObjectBox C library (libobjectbox.dylib / .so) into ./lib
#    using the OFFICIAL objectbox-dart install script. Pure-Dart (non-Flutter)
#    ObjectBox apps need this native library at runtime; the Dart bindings
#    look for it in <cwd>/lib first (see objectbox-dart README, "Deploying
#    Dart Native projects"). install.sh is downloaded, checksum-verified,
#    and only THEN executed (M-7 below) — never piped straight into bash.
# 3. Runs build_runner to (re)generate lib/objectbox.g.dart and
#    lib/objectbox-model.json (both are committed to git — contract
#    docs/contract/objectbox-capabilities.md §1: committed generated model
#    JSON; never delete/regenerate the model file to "fix" schema issues).
#
# Usage: tool/setup.sh
set -euo pipefail

cd "$(dirname "$0")/.."

DART="${DART:-dart}"
if ! command -v "$DART" >/dev/null 2>&1; then
  DART="dart" # fall back to PATH for other machines
fi

echo "==> dart pub get"
"$DART" pub get

if [ -f lib/libobjectbox.dylib ] || [ -f lib/libobjectbox.so ]; then
  echo "==> ObjectBox C library already present in lib/ (skipping download)"
else
  # M-7 (2026-09-07 security review, supersedes SEC-7 2026-07-07): SEC-7
  # pinned to the git TAG v5.3.2 instead of a floating `main` ref, which
  # closed the "main can change without review" gap — but a tag itself can
  # still be force-moved or deleted by anyone with push access to
  # objectbox-dart, and the script was still `bash <(curl ...)`: piped
  # straight into a shell with zero integrity check on the bytes actually
  # executed. Three independent hardenings, all in this block:
  #
  #   1. Pinned to the tag's COMMIT SHA, not the tag name. Resolved
  #      2026-09-07 via `git ls-remote https://github.com/objectbox/
  #      objectbox-dart v5.3.2` -> a single line with no `^{}` peeled
  #      entry, i.e. v5.3.2 is a LIGHTWEIGHT tag, so that hash IS the
  #      commit (not a separate tag object needing a second resolve). A
  #      commit SHA cannot be moved the way a tag can.
  #   2. install.sh is downloaded to a TEMP FILE first and its sha256 is
  #      verified against a constant recorded here — computed 2026-09-07
  #      from exactly this pinned download — BEFORE it is ever executed.
  #      A mismatch aborts with expected-vs-actual, never runs the script.
  #   3. The resulting native library's sha256 is verified too, below —
  #      install.sh forwards to objectbox-c's own (separately unpinned)
  #      download.sh, so a verified install.sh alone does not guarantee
  #      the .dylib/.so it fetches is the expected binary.
  #
  # When bumping the `objectbox` dependency version in pubspec.yaml: bump
  # INSTALL_SH_COMMIT (re-resolve via git ls-remote against the NEW tag),
  # recompute INSTALL_SH_SHA256 from that fresh download, and recompute
  # EXPECTED_LIB_SHA256 below by actually running this script once and
  # inspecting the result — never hand-guess either constant.
  INSTALL_SH_COMMIT="9e9da125c5786448e0b9c9232bebb7840452bb9c" # tag v5.3.2
  INSTALL_SH_URL="https://raw.githubusercontent.com/objectbox/objectbox-dart/$INSTALL_SH_COMMIT/install.sh"
  INSTALL_SH_SHA256="2dde2c7a83ee7f08ea149fb0ed65e4e63fcb780345ee9bea0a4f2d432dde03c7"

  echo "==> Downloading ObjectBox install.sh (Sync variant) — pinned commit"
  echo "    commit: $INSTALL_SH_COMMIT (tag v5.3.2)"
  echo "    url:    $INSTALL_SH_URL"

  INSTALL_SH_TMP="$(mktemp)"
  # Runs on every exit path (success, checksum-abort, install.sh failure) —
  # never leaves a downloaded-but-unverified script lying around.
  trap 'rm -f "$INSTALL_SH_TMP"' EXIT
  # -fsS: fail loudly (non-zero + stderr) on a 404/removed ref instead of
  # writing an HTML/empty body to the temp file (carried forward from
  # SEC-7, 2026-07-07 security review, LOW).
  curl -fsS "$INSTALL_SH_URL" -o "$INSTALL_SH_TMP"

  ACTUAL_SHA256="$(shasum -a 256 "$INSTALL_SH_TMP" | awk '{print $1}')"
  if [ "$ACTUAL_SHA256" != "$INSTALL_SH_SHA256" ]; then
    echo "==> ABORT: install.sh checksum mismatch — refusing to execute an" >&2
    echo "    unverified script. A commit-SHA-pinned URL should never" >&2
    echo "    change content; either GitHub served something unexpected" >&2
    echo "    for this exact commit, or this project's recorded checksum" >&2
    echo "    (INSTALL_SH_SHA256 in tool/setup.sh) is stale — re-verify" >&2
    echo "    by hand before updating it." >&2
    echo "    expected: $INSTALL_SH_SHA256" >&2
    echo "    actual:   $ACTUAL_SHA256" >&2
    exit 1
  fi
  echo "==> install.sh checksum verified ($ACTUAL_SHA256)"

  # --sync: this project supports optional ObjectBox Sync replication
  # (OBX_MEMORY_SYNC_URL). The sync-enabled library is a superset of the
  # plain one, so local-only usage works identically.
  bash "$INSTALL_SH_TMP" --sync

  # M-7 part 3: verify the DOWNLOADED NATIVE LIBRARY too (see the block
  # comment above for why a verified install.sh does not already cover
  # this). Only the platform this hardening could actually run and verify
  # a checksum on gets a real recorded constant — every other platform
  # prints a loud UNVERIFIED line rather than a fabricated one (contract
  # §8: no silent gaps dressed up as coverage).
  UNAME_S="$(uname -s)"
  UNAME_M="$(uname -m)"
  if [ -f lib/libobjectbox.dylib ]; then
    LIB_PATH="lib/libobjectbox.dylib"
  elif [ -f lib/libobjectbox.so ]; then
    LIB_PATH="lib/libobjectbox.so"
  else
    echo "==> ABORT: install.sh completed but no libobjectbox.{dylib,so}" >&2
    echo "    was found in lib/ afterward." >&2
    exit 1
  fi
  LIB_SHA256="$(shasum -a 256 "$LIB_PATH" | awk '{print $1}')"
  if [ "$UNAME_S" = "Darwin" ]; then
    # Recorded 2026-09-07: objectbox-c 5.3.2, sync variant. install.sh's
    # download.sh maps every Darwin `uname -m` (arm64 included — verified
    # on this machine) to ONE universal (x86_64+arm64) build, so a single
    # constant covers all of macOS. Cross-checked: byte-identical to (same
    # sha256 as) this repo's already-committed lib/libobjectbox.dylib.
    EXPECTED_LIB_SHA256="56d906b679f4125dd0fc831158f56b8b6e470a9b5b571ee68bd4d4487952f430"
    if [ "$LIB_SHA256" != "$EXPECTED_LIB_SHA256" ]; then
      echo "==> ABORT: $LIB_PATH checksum mismatch." >&2
      echo "    expected: $EXPECTED_LIB_SHA256" >&2
      echo "    actual:   $LIB_SHA256" >&2
      exit 1
    fi
    echo "==> $LIB_PATH checksum verified ($LIB_SHA256)"
  else
    echo "==> UNVERIFIED: $LIB_PATH checksum ($LIB_SHA256) has no recorded" >&2
    echo "    constant for $UNAME_S/$UNAME_M — this hardening (2026-09-07)" >&2
    echo "    could only actually run and verify a checksum on macOS." >&2
    echo "    Not aborting (the download itself is over HTTPS from" >&2
    echo "    GitHub's release CDN), but this platform's binary integrity" >&2
    echo "    is NOT independently confirmed. Verify by hand and add a" >&2
    echo "    real constant for $UNAME_S/$UNAME_M above when you can." >&2
  fi
fi

echo "==> Running build_runner (generates lib/objectbox.g.dart + lib/objectbox-model.json)"
"$DART" run build_runner build --delete-conflicting-outputs

echo "==> Setup complete."
