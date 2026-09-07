#!/usr/bin/env bash
# Runs a dedicated ObjectBox Sync Server for RememBox in Docker.
#
# IMPORTANT: this server gets its OWN dataset directory and its OWN port.
# Never point RememBox at another project's sync server / dataset — two
# stores replicating against the same server dataset are replicas of the
# same logical DB (contract docs/contract/how-to-use-objectbox.md §9:
# "never reuse another project's sync-server dataset").
#
# The server needs OUR schema: this script copies lib/objectbox-model.json
# into the dataset dir on every start, so re-run it after schema changes
# ("after schema changes ... refresh the sync-server model file", §9).
#
# Auth: set OBX_MEMORY_SYNC_SECRET for shared-secret auth. Running WITHOUT
# a secret requires an EXPLICIT opt-in: REMEMBOX_SYNC_INSECURE=1. Neither
# set → the script refuses to start (SEC-3, 2026-07-07 security review: an
# unauthenticated sync endpoint must never be the default-by-omission).
#
# Network exposure: REMEMBOX_SYNC_BIND controls which interface the published
# Docker ports bind to. Default is 127.0.0.1 (loopback-only — the container
# port is always ws://0.0.0.0:9999 internally, but the HOST publish is
# loopback-only by default, so nothing outside this machine can reach it).
# Set REMEMBOX_SYNC_BIND=0.0.0.0 to actually expose the sync port to the LAN
# for real cross-device sync — this REQUIRES OBX_MEMORY_SYNC_SECRET to be
# set (the script refuses non-loopback bind combined with unauthenticated
# sync) and prints a plaintext-over-LAN warning (ws:// is sniffable; prefer
# wss:// or an SSH/WireGuard tunnel for anything beyond a trusted LAN).
# (SEC-1, 2026-07-07 security review: this script used to publish the
# authenticated branch's sync port on 0.0.0.0 unconditionally — inverted
# from the unauthenticated branch, which correctly used 127.0.0.1. Both
# branches now default to loopback and share the same REMEMBOX_SYNC_BIND
# gate.)
#
# Admin UI: the ObjectBox Sync admin web UI is UNAUTHENTICATED (no login),
# so it is opt-in. Set REMEMBOX_SYNC_ADMIN=1 to start it (still published on
# 127.0.0.1 only — debugging use on this machine, never exposed to the LAN
# even with REMEMBOX_SYNC_BIND=0.0.0.0). Default: no admin UI at all
# (SEC-2, 2026-07-07 security review).
#
# Usage:
#   tool/sync-server/run.sh          # start (or restart) the server
#   docker logs -f remembox-sync     # watch it
#   docker rm -f remembox-sync      # stop it
#
# Then on every device:
#   export OBX_MEMORY_SYNC_URL=ws://<host>:9997
#   export OBX_MEMORY_SYNC_CREDENTIALS=<the same secret, if set>
set -euo pipefail

cd "$(dirname "$0")"

IMAGE="${REMEMBOX_SYNC_IMAGE:-objectboxio/sync:sync-server-2026-06-24}"
PORT="${REMEMBOX_SYNC_PORT:-9997}"
ADMIN_PORT="${REMEMBOX_SYNC_ADMIN_PORT:-9987}"
SYNC_BIND="${REMEMBOX_SYNC_BIND:-127.0.0.1}"
DATA_DIR="$(pwd)/data"

if [ -z "${OBX_MEMORY_SYNC_SECRET:-}" ] && [ "${REMEMBOX_SYNC_INSECURE:-}" != "1" ]; then
  echo "==> ERROR: refusing to start without an explicit auth decision." >&2
  echo "    Either set OBX_MEMORY_SYNC_SECRET=<shared secret> for authenticated sync," >&2
  echo "    or set REMEMBOX_SYNC_INSECURE=1 to explicitly run unauthenticated" >&2
  echo "    (localhost-only; never combine with REMEMBOX_SYNC_BIND=0.0.0.0)." >&2
  exit 1
fi

if [ "$SYNC_BIND" != "127.0.0.1" ]; then
  if [ -z "${OBX_MEMORY_SYNC_SECRET:-}" ]; then
    echo "==> ERROR: refusing to bind sync to '$SYNC_BIND' (non-loopback) without OBX_MEMORY_SYNC_SECRET." >&2
    echo "    Binding beyond 127.0.0.1 exposes the sync port to the LAN; that requires" >&2
    echo "    authentication. Set OBX_MEMORY_SYNC_SECRET, or leave REMEMBOX_SYNC_BIND unset" >&2
    echo "    (defaults to 127.0.0.1) for a loopback-only unauthenticated server." >&2
    exit 1
  fi
  echo "==> WARNING: binding sync port to '$SYNC_BIND' — reachable from the LAN." >&2
  echo "    Plaintext ws:// traffic is sniffable on the network. Prefer wss:// or" >&2
  echo "    tunnel this port (SSH/WireGuard) instead of exposing it directly." >&2
fi

mkdir -p "$DATA_DIR"
cp ../../lib/objectbox-model.json "$DATA_DIR/objectbox-model.json"
echo "==> model file refreshed in $DATA_DIR"

docker rm -f remembox-sync >/dev/null 2>&1 || true

# S4 (2026-09-08 pre-publication audit): populated below only in the
# authenticated branch; the trap is a harmless no-op otherwise.
SYNC_SECRET_ENV_FILE=""
cleanup_sync_secret_env_file() {
  [ -n "$SYNC_SECRET_ENV_FILE" ] && rm -f "$SYNC_SECRET_ENV_FILE"
  return 0
}
trap cleanup_sync_secret_env_file EXIT

# Admin UI is opt-in (SEC-2): unauthenticated, so off by default. When
# enabled it is still published on 127.0.0.1 only, regardless of
# REMEMBOX_SYNC_BIND. ADMIN_BIND_VALUE (plain string, not an array) is
# passed through as an env var into the authenticated branch's inner shell
# script below; ADMIN_PUBLISH_ARGS/ADMIN_BIND_ARGS are docker/sync-server
# CLI arg arrays used directly by both docker run invocations. Empty
# arrays are expanded with the bash-3.2-safe ${arr[@]+"${arr[@]}"} idiom
# (macOS ships bash 3.2, where "${arr[@]}" alone on a truly empty array
# trips `set -u`'s unbound-variable check).
ADMIN_PUBLISH_ARGS=()
ADMIN_BIND_ARGS=()
ADMIN_BIND_VALUE=""
if [ "${REMEMBOX_SYNC_ADMIN:-}" = "1" ]; then
  ADMIN_PUBLISH_ARGS=(-p "127.0.0.1:$ADMIN_PORT:9980")
  ADMIN_BIND_ARGS=(--admin-bind "0.0.0.0:9980")
  ADMIN_BIND_VALUE="0.0.0.0:9980"
  echo "==> admin UI enabled (REMEMBOX_SYNC_ADMIN=1) — unauthenticated, localhost-only, debugging only" >&2
fi

if [ -n "${OBX_MEMORY_SYNC_SECRET:-}" ]; then
  echo "==> starting with shared-secret auth on port $PORT (bind: $SYNC_BIND, admin: ${REMEMBOX_SYNC_ADMIN:-0})"
  # S4 (2026-09-08 pre-publication audit): the secret goes into a 0600
  # temp file consumed via --env-file, not `-e SYNC_SECRET=...` — a
  # `docker run -e` value is readable via `docker inspect` by anyone in
  # the docker group and briefly visible in `ps` args. umask 077 before
  # creating the file (in the subshell that runs mktemp) so there is no
  # window where it is more permissive than 0600; the trap removes it on
  # exit regardless of how the script ends.
  SYNC_SECRET_ENV_FILE="$(umask 077 && mktemp)"
  printf 'SYNC_SECRET=%s\n' "$OBX_MEMORY_SYNC_SECRET" > "$SYNC_SECRET_ENV_FILE"
  docker run -d --name remembox-sync \
    ${ADMIN_PUBLISH_ARGS[@]+"${ADMIN_PUBLISH_ARGS[@]}"} -p "$SYNC_BIND:$PORT:9999" \
    -v "$DATA_DIR:/data" \
    --env-file "$SYNC_SECRET_ENV_FILE" \
    -e "ADMIN_BIND_ARG=${ADMIN_BIND_VALUE:-}" \
    --entrypoint /bin/sh \
    "$IMAGE" -c 'set -eu
umask 077
cat > /tmp/sync-conf.json <<EOF
{"auth":{"sharedSecret":"$SYNC_SECRET"}}
EOF
if [ -n "$ADMIN_BIND_ARG" ]; then
  exec /sync-server -c /tmp/sync-conf.json \
    -m /data/objectbox-model.json \
    --bind ws://0.0.0.0:9999 \
    --admin-bind "$ADMIN_BIND_ARG"
else
  exec /sync-server -c /tmp/sync-conf.json \
    -m /data/objectbox-model.json \
    --bind ws://0.0.0.0:9999
fi'
else
  echo "==> starting WITHOUT authentication (REMEMBOX_SYNC_INSECURE=1, localhost dev only!) on port $PORT (bind: $SYNC_BIND, admin: ${REMEMBOX_SYNC_ADMIN:-0})"
  docker run -d --name remembox-sync \
    ${ADMIN_PUBLISH_ARGS[@]+"${ADMIN_PUBLISH_ARGS[@]}"} -p "$SYNC_BIND:$PORT:9999" \
    -v "$DATA_DIR:/data" \
    "$IMAGE" \
    --model /data/objectbox-model.json \
    --bind ws://0.0.0.0:9999 \
    ${ADMIN_BIND_ARGS[@]+"${ADMIN_BIND_ARGS[@]}"} \
    --unsecured-no-authentication
fi

if [ "${REMEMBOX_SYNC_ADMIN:-}" = "1" ]; then
  echo "==> RememBox sync server up: ws://$SYNC_BIND:$PORT (admin UI: http://127.0.0.1:$ADMIN_PORT — unauthenticated, debugging only)"
else
  echo "==> RememBox sync server up: ws://$SYNC_BIND:$PORT (admin UI disabled; set REMEMBOX_SYNC_ADMIN=1 to enable)"
fi
