# Configuration reference

All configuration is environment variables, read once at process start (or,
for `gated` mode, effectively per tool call – see [Modes](../README.md#modes)
in the README). Nothing is read from a config file.

The five most people touch – `OBX_MEMORY_STORE_MODE`, `OBX_LOG_LEVEL`,
`OBX_MEMORY_DIR`, `OBX_MEMORY_EMBED_MODEL`, `OBX_MEMORY_SYNC_URL` – are
introduced in the README's [Quick start](../README.md#quick-start-macos) and
[Modes](../README.md#modes) sections. This page is the exhaustive list.

| Variable | Default | Meaning |
|---|---|---|
| `OBX_MEMORY_DIR` | `~/.remembox` | ObjectBox store directory. **Single writer per directory:** prefer exactly one RememBox process per store dir – a second is tolerated in `persistent` mode's legacy shared-lock path but risks silent write loss; see `OBX_MEMORY_EXCLUSIVE`. The real fix is `gated` mode (below): the store is opened only for the duration of each tool call, behind a process-wide exclusive lock, so several stdio processes can safely share one directory. To share memory across *devices*, use Sync (below), not a shared directory on one machine. |
| `OBX_MEMORY_EXCLUSIVE` | `false` | stdio mode only. Refuse to start if another RememBox process already holds a lock on `OBX_MEMORY_DIR` (via `StoreInstanceGuard`, an OS advisory file lock). Default `false`: a second process is tolerated and write tools return a warning when a peer is detected. Set `true` on the process that should be the sole writer in `persistent` mode – or, better, switch to `gated` mode, which serializes access itself and doesn't need this. Do **not** set this to `true` in `gated` mode (self-defeating; rejected with an actionable error). Accepts `true`/`1` (case-insensitive); anything else is `false`. |
| `OBX_MEMORY_STORE_MODE` | `persistent` | `persistent` opens the Store once and holds it for the process lifetime; a second `persistent` process against the same directory refuses to start outright. `gated` opens the Store per tool call, serialized by an exclusive `store.lock`, so multiple processes (several Claude Code windows, Cowork, etc.) can share one store directory safely. `gated` refuses to start when combined with a non-empty `OBX_MEMORY_SYNC_URL` (a live Sync connection needs a persistent store handle – use `persistent` or the HTTP daemon for Sync) or with `--serve`. For `gated` stdio use, also set `OBX_LOG_LEVEL=error` (see below) – required, not optional. Accepts `persistent`/`gated` (case-insensitive, whitespace-trimmed); anything else throws at startup. Verify it's active by checking for a `store.lock` file in the store directory. |
| `OBX_LOG_LEVEL` | *(unset)* | Undocumented upstream ObjectBox native flag, but real and load-bearing here: in `gated` mode, the native ObjectBox sync client writes its own log lines straight to stdout during the per-call open/close churn – the same channel that carries MCP JSON-RPC responses – and can corrupt or drop a reply. Set to `error` (also accepts `none`; numeric values are ignored) to suppress it; verified to eliminate the corruption. `persistent` mode is not affected and does not need this variable. |
| `OBX_MEMORY_HTTP_PORT` | `3927` | Daemon (`--serve`) mode only: the HTTP daemon's loopback port. An explicit `--serve=<port>` CLI flag overrides this. |
| `OBX_MEMORY_HTTP_TOKEN` | *(unset)* | Daemon (`--serve`) mode only, **required**: the daemon refuses to start without it. Every request must carry `Authorization: Bearer <token>`. `tool/install-daemon.sh` generates one, stores it at `<store dir>/daemon.token` with mode `0600`, and prints the client registration line (with the token) once to the terminal. To generate one by hand: `openssl rand -base64 32 | tr '+/' '-_' | tr -d '='`. |
| `OBX_MEMORY_HTTP_SESSION_TTL_SECONDS` | `1800` | Daemon mode only: how long an HTTP session may sit idle before the daemon's periodic sweep disposes it (logged). Claude Code sessions often vanish without a clean `DELETE`, so this is the only thing that reclaims them. |
| `OBX_MEMORY_HTTP_MAX_SESSIONS` | `64` | Daemon mode only: max concurrent HTTP sessions. A new `initialize` beyond the cap first tries to evict the oldest session that has never served a request since its `initialize` (logged) – so a flood of idle, unauthenticated-looking sessions can't lock out a real client. Only if every current session has already served traffic does the daemon answer `503` + a logged line naming the cap. DoS hygiene on top of loopback binding and the daemon's bearer-token check (the actual security boundaries – see the README's Security & privacy section), not a substitute for either. |
| `OBX_MEMORY_HTTP_MAX_BODY_BYTES` | `4194304` (4 MiB) | Daemon mode only: max size of a single JSON-RPC POST body. An oversized body gets `413` + a logged line; bytes past the cap are never buffered (streamed and counted, abort on overflow). Same hygiene-not-boundary framing as the session cap above. |
| `OBX_MEMORY_EMBED_MODEL` | `embeddinggemma` | Ollama embedding model. |
| `OBX_MEMORY_OLLAMA_URL` | `http://localhost:11434` | Ollama base URL. |
| `OBX_MEMORY_DIMS` | `768` | Expected embedding dimensions – must equal the schema's `@HnswIndex(dimensions: 768)`; changing models with other dims requires a schema change plus `reindex`. |
| `OBX_MEMORY_AUTO_PULL` | `true` | Pull a missing embed model at startup (progress logged). |
| `OBX_MEMORY_RANK_W_RECENCY` | `0.1` | Recency boost weight – see [Ranking](architecture.md#ranking). |
| `OBX_MEMORY_RANK_W_FREQUENCY` | `0.05` | Access-frequency boost weight. |
| `OBX_MEMORY_SYNC_URL` | *(unset)* | ObjectBox Sync server URL (e.g. `ws://127.0.0.1:9997`); unset = local-only. See [Sync across devices](sync.md). |
| `OBX_MEMORY_SYNC_CREDENTIALS` | *(unset)* | Shared secret for sync auth; empty = unauthenticated (localhost dev only). |
| `OBX_MEMORY_MAX_TEXT_CHARS` | `32000` | Cap on `remember()`'s input text length (normalized). Text over the limit is **rejected** with a clear error naming the limit and the actual size – never silently truncated. Other string arguments (title, tags, source references, etc.) are validated and length-capped the same way – see the tool schemas in `lib/src/server.dart`. |

**One embedding model per store.** Index rows record the model that embedded
them; `recall` refuses to compare vectors across models (those candidates are
excluded, with a warning telling you to run `reindex`, which re-embeds
everything with the current model).

For the store modes themselves (what "persistent", "gated", and the HTTP
daemon actually do, and when to pick each), see the README's
[Modes](../README.md#modes) section.
