# Sync across devices (optional)

RememBox's domain entities are `@Sync()`-annotated; add an ObjectBox Sync
Server and identical memories appear on all your machines. This is entirely
optional – local-only is the default and the common case.

```bash
# 1. Start the dedicated RememBox sync server (own dataset, port 9997).
#    An explicit auth decision is REQUIRED – the script refuses to start
#    otherwise:
REMEMBOX_SYNC_INSECURE=1 tool/sync-server/run.sh                          # unauthenticated, loopback-only, dev
OBX_MEMORY_SYNC_SECRET=$(openssl rand -base64 32) tool/sync-server/run.sh  # with auth, loopback-only

# 2. Point RememBox at it (every device):
export OBX_MEMORY_SYNC_URL=ws://127.0.0.1:9997
export OBX_MEMORY_SYNC_CREDENTIALS=...        # same secret, if set
```

Setting `OBX_MEMORY_SYNC_URL` automatically keeps the store open for the
process lifetime, because a live Sync connection needs a standing store
handle. Only one process may then use that store directory – for several
windows at once, run the HTTP daemon instead, which every client talks to
over HTTP (see
[One store, multiple Claude windows](../README.md#one-store-multiple-claude-windows)
in the README).

By default the sync server's published port is **loopback-only**
(`127.0.0.1`), regardless of auth mode – nothing outside this machine can
reach it. Real cross-device sync needs the sync port reachable from other
machines; opt in explicitly and only with authentication:

```bash
OBX_MEMORY_SYNC_SECRET=$(openssl rand -base64 32) \
  REMEMBOX_SYNC_BIND=0.0.0.0 tool/sync-server/run.sh
```

Setting `REMEMBOX_SYNC_BIND` to anything other than `127.0.0.1` **requires**
`OBX_MEMORY_SYNC_SECRET` – the script refuses to bind non-loopback without
auth – and prints a warning: plaintext `ws://` traffic is sniffable on the
network; prefer `wss://` or tunnel the port (SSH/WireGuard) instead of
exposing it directly to an untrusted network.

The ObjectBox Sync admin web UI (`http://127.0.0.1:9987` by default) has
**no authentication**, so it is **off by default**. Set
`REMEMBOX_SYNC_ADMIN=1` to start it for local debugging – it always stays
published on `127.0.0.1` only, even with `REMEMBOX_SYNC_BIND=0.0.0.0`.

Entries arriving from other devices are picked up by a change observer and
embedded/indexed locally (the vector index itself never syncs – embeddings
are large, device-local, and recomputable). Re-run `tool/sync-server/run.sh`
after schema changes – it refreshes the server's copy of
`lib/objectbox-model.json`. Never point RememBox at another project's sync
server dataset.

## Platform notes

**With the Sync-enabled ObjectBox library, writes to `@Sync` entity types
require an active sync client** (`OBX_ERROR 10001` otherwise; pinned by
`test/sync_annotation_test.dart`). In local-only mode RememBox therefore
starts a client against the reserved port `ws://127.0.0.1:0` – it can never
connect and replicates nothing; its only effect is enabling local writes.
This is logged at startup.

**Native log noise in local-only mode is expected.** The reserved-port
client above retries a connection that can never succeed by design, and the
underlying C library prints its own `LWS: Connect failed errno=49` /
`Connection mismatch on destroy` lines straight to stderr. This noise is
harmless (stdout, the MCP channel, is unaffected) and only occurs in
local-only mode – a real, connected `OBX_MEMORY_SYNC_URL` doesn't hit this
path, and there the connection logs matter anyway.

## Known limitation: cross-device replace can dangle links

`MemoryEntry.contentHash` (and `SourceDocument.contentHash`, `Tag.name`) use
sync-mandated `ConflictStrategy.replace`: if two devices independently store
the same content hash, replicating that write **replaces** the losing row
and mints a **new local object id** for the surviving one. Any
`MemoryLink.from`/`.to` (or, transiently, a `MemoryIndex` row) that pointed
at the old id is now dangling – it does not get fixed up automatically,
because the replace only rewrites the one conflicting row, not the
relation graph around it. `reindex` detects this (bulk id-diff, not a
per-link query) and reports it as `danglingLinks`/`danglingLinkDetails`,
and `stats` reports the same count. **Neither auto-removes dangling links
by default**: with sync, a link can legitimately arrive *before* its target
entry (eventual consistency), so blind auto-purge on every sweep would
delete valid in-flight data along with genuine orphans. Pass
`purgeDanglingLinks: true` to `reindex` to actually remove the links found
dangling in that call, once you've confirmed (e.g. by re-running after
sync has caught up) that they're genuinely orphaned and not just early.
Orphaned `SourceDocument`s (no entry refers to them any more) are reported
by `stats` too, but are **never** auto-deleted – documents can be shared
across many entries and are therefore always a manual decision.
