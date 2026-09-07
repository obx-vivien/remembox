# RememBox – notes for coding-assistant sessions

## Before touching persistence code

Read **docs/contract/objectbox-capabilities.md** and
**docs/contract/how-to-use-objectbox.md** first and treat them as hard
constraints. The model/service code cites them inline (`contract §N`) –
keep those citations accurate when you change the code they annotate.

Non-negotiables from the contract, enforced throughout this repo:

- **At most one open Store at a time per store directory** – not necessarily
  one per process. `persistent` mode opens once in `lib/src/store.dart` and
  holds it; `gated` mode opens and closes per tool call behind `StoreGate`
  (`lib/src/store_gate.dart`). Never open a second Store concurrently: two
  writers on one directory lose writes silently (measured: 85+85 puts →
  103 rows survived). Background in `docs/architecture.md`.
- ONE canonical ANN index (`MemoryIndex`). Never add a second vector path or
  an `@HnswIndex` on a domain entity.
- No silent failure paths: every fallback/repair/exclusion logs to stderr
  and/or surfaces in the tool result `warnings`. A caught error is either
  rethrown or logged with context – never discarded.
- Query-first reads (`count()`, ordered+limited queries, id-only
  projections); no `getAll()`-and-filter.
- Never weaken a test to make it pass. Fix the code or the premise.
- `project` is required on every stored entry and validated server-side –
  `recall` filters by `project` only; tags are labels, not a filter.

## Dev-log citations in comments

Code comments, tests and scripts cite the maintainer's internal engineering
logs and status notes as neutral provenance phrases, e.g. "the 2026-09-01
store-gate engineering log (internal)". Those logs live in the maintainer's
repository history but are `export-ignore`d (see `.gitattributes`) and do
not ship in this public tree. Read such a citation as provenance (date +
topic of the change), not as a link to follow. The public references are
`docs/architecture.md`, `docs/configuration.md`, `docs/sync.md` and
`docs/contract/`.

## Ground rules

- Run `dart analyze` (clean) and `dart test` (green) before every commit.
  Dart binary: `dart` from PATH (Dart SDK ≥ 3.10; a Flutter install's
  `$FLUTTER_HOME/bin/dart` works too).
- `lib/objectbox-model.json` + `lib/objectbox.g.dart` are COMMITTED.
  **Never delete/regenerate the model JSON to "fix" schema problems** –
  that breaks store compatibility and sync. After entity edits:
  `dart run build_runner build`, review the model diff, commit both.
- stdout belongs to the MCP JSON-RPC protocol. ALL logging goes through
  stderr `LogSink`s. Never `print()`. Known exception outside our code: the
  native ObjectBox Sync client writes its own chatter to fd 1. In `gated`
  mode (one sync client per tool call) that chatter can corrupt the stdio
  channel – `OBX_LOG_LEVEL=error` suppresses it and is required there;
  `persistent` mode is not affected. When probing this, capture fd 1 and
  fd 2 separately – merged, the problem is invisible. Do not "fix" it by
  relaxing this rule.
- Commit messages describe the change and its reason. No generated
  trailers, no tool attributions.
- Keep the project name in its two places only: `pubspec.yaml` `name:` and
  `serverName` in `lib/src/server.dart`.

## Platform gotchas (pinned by tests – don't rediscover them)

1. **CWD-relative dylib lookup.** objectbox-dart resolves
   `lib/libobjectbox.dylib` from the *current working directory*, not the
   executable. That's why `dist/remembox` is a launcher script that `cd`s
   into the dist folder, and why `ensureNativeLibraryLoaded()` pre-loads
   the dylib exe-relative. Any deployment change must keep the smoke test
   passing **from a foreign cwd** (see below).
2. **@Sync entities need an ACTIVE sync client** (with the Sync-enabled C
   library): `put()` fails with OBX_ERROR 10001 otherwise. Local-only mode
   starts a client on reserved port `ws://127.0.0.1:0` (never connects,
   never replicates) purely for write activation. Pinned by
   `test/sync_annotation_test.dart` – if that test changes behavior, check
   the ObjectBox changelog, do not paper over it.
3. **Rebuilding `dist/` deletes the cwd of every running gated server.**
   `tool/build.sh` does `rm -rf dist`; the launcher `cd`s into `dist/`. The
   cwd-relative dylib candidate now tolerates a missing cwd (skipped with a
   log line; the exe-relative candidates still load the library), so a call
   no longer crashes – but running servers keep executing the OLD binary
   until restarted. Rule: after `tool/build.sh`, stop all servers
   (`pkill -f "bin/remembox"`) and restart the client sessions.

## Store modes (`OBX_MEMORY_STORE_MODE`)

| Mode | Store open | Several processes | Sync |
|---|---|---|---|
| `persistent` (default) | process lifetime | no – a second process refuses to start | yes |
| `gated` | per tool call | yes – lock per call | no; refuses to start with `OBX_MEMORY_SYNC_URL` set |

The lock is `<storeDir>/store.lock` and it is **advisory**: a process from an
older binary does not know it and writes past it. After every update stop
all old processes (`pkill -f "bin/remembox"`), or the fleet is mixed and
therefore unprotected.

**The peer warning is mode-aware.** The `StoreInstanceGuard` peer detection
(`instances.lock`, independent of `store.lock`) deliberately does NOT add a
tool-result warning in `gated` mode – several processes are the design there
(every tool call is serialized on `store.lock`). Instead it logs ONE INFO
line per process so the situation stays observable. In `persistent` mode the
warning stays (a peer from an older binary is a real data-loss risk), and
the honest options are: stop the other process, or switch to `gated`.
`OBX_MEMORY_EXCLUSIVE=true` only makes the SECOND process refuse to start –
it does not resolve concurrency, it prevents it.

## HTTP daemon (`--serve`)

Requires `OBX_MEMORY_HTTP_TOKEN`; every request needs
`Authorization: Bearer <token>`, a non-loopback `Host` or a present
non-loopback `Origin` is rejected, POST bodies must be `application/json`.
`tool/install-daemon.sh` generates and stores the token (mode 0600) and
prints the client registration line. Session ids appear in logs only as an
8-character hash.

## Common tasks

```bash
tool/setup.sh                 # deps + ObjectBox C lib (Sync variant) + codegen
dart test                     # default suite (no Ollama)
dart test -P ollama           # integration vs real Ollama
tool/build.sh                 # rebuild dist/ (exe + dylib + launcher)
tool/sync-server/run.sh       # dedicated sync server (docker, port 9997)
tool/release.sh               # from-scratch release ZIP: git archive HEAD (never
                              # the worktree) + personal-trace gate (source tree,
                              # then again over the final assembled tree incl.
                              # compiled binaries; fails closed on a missing or
                              # unusable denylist) + fresh dylib download + build
                              # + smoke test; REMEMBOX_SKILL_MD=<path> required;
                              # --dry-run skips writing the zip (output: release/)
```

Smoke test after any deployment-related change (must print an initialize
result JSON on stdout):

```bash
cd /tmp && printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}' \
  | OBX_MEMORY_DIR=$(mktemp -d) OBX_MEMORY_AUTO_PULL=false <repo>/dist/remembox
```
