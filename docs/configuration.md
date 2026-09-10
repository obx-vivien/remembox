# Configuration reference

All configuration is environment variables, read once at process start (or,
in the default per-call store mode, effectively per tool call – see
[One store, any number of windows](../README.md#one-store-any-number-of-windows)
in the README). Nothing is read from a config file.

The three most people touch – `OBX_MEMORY_DIR`, `OBX_MEMORY_EMBED_MODEL`,
`OBX_MEMORY_SYNC_URL` – are introduced in the README's
[Quick start](../README.md#quick-start-macos-apple-silicon) and
[One store, any number of windows](../README.md#one-store-any-number-of-windows)
sections. This page is the exhaustive list.

| Variable | Default | Meaning |
|---|---|---|
| `OBX_MEMORY_DIR` | `~/.remembox` | ObjectBox store directory. By default several RememBox processes can safely share one directory: the store is opened only for the duration of each tool call, behind a process-wide exclusive lock, so several stdio processes (Claude Code, Claude Desktop, Cowork) can share one store directory. A second process is tolerated only through the legacy shared-lock path when `OBX_MEMORY_STORE_MODE=persistent` is forced explicitly, and it risks silent write loss there; see `OBX_MEMORY_EXCLUSIVE`. To share memory across *devices*, use Sync (below), not a shared directory on one machine. |
| `OBX_MEMORY_EXCLUSIVE` | `false` | stdio mode only. Refuse to start if another RememBox process already holds a lock on `OBX_MEMORY_DIR` (via `StoreInstanceGuard`, an OS advisory file lock). Default `false`: a second process is tolerated and write tools return a warning when a peer is detected. Only relevant when `OBX_MEMORY_STORE_MODE=persistent` is forced explicitly and this process should be the sole writer – the default per-call store mode serializes access itself and doesn't need this. Do **not** set this to `true` together with an explicit `OBX_MEMORY_STORE_MODE=gated` (self-defeating; rejected with an actionable error). Accepts `true`/`1` (case-insensitive); anything else is `false`. |
| `OBX_MEMORY_STORE_MODE` | *(derived)* | Advanced – normally derived automatically: `gated` (per-call, several processes may share the store) by default, `persistent` (opened once, held for the process lifetime) automatically when `OBX_MEMORY_SYNC_URL` is set or when running with `--serve` (a live Sync connection needs a standing store handle). Set this explicitly only to force one of the two. An explicit `gated` is refused when combined with a non-empty `OBX_MEMORY_SYNC_URL` or with `--serve`. Accepts `persistent`/`gated` (case-insensitive, whitespace-trimmed); anything else throws at startup. Verify which mode is active from the startup log line (`[startup] store mode: …`) or by checking for a `store.lock` file in the store directory. |
| `OBX_LOG_LEVEL` | *(unset; `error` under the launcher)* | Undocumented upstream ObjectBox native flag, but real and load-bearing here: in the default per-call store mode, the native ObjectBox sync client writes its own log lines straight to stdout during the per-call open/close churn – the same channel that carries MCP JSON-RPC responses – and can corrupt or drop a reply. The `dist/remembox` launcher sets this to `error` itself, so it only matters if you start `bin/remembox` directly. Set to `error` (also accepts `none`; numeric values are ignored) to suppress the native log lines and keep the stdio channel clean; you may override it. Not needed when the store is held open for the process lifetime. |
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

For the store-sharing behavior itself (what the default per-call mode,
`persistent`, and the HTTP daemon actually do, and when Sync changes things),
see the README's
[One store, any number of windows](../README.md#one-store-any-number-of-windows)
section.
