/// RememBox entrypoint: MCP server with ObjectBox-backed semantic memory.
///
/// Two transports, selected at startup:
/// - **stdio** (default): stdout is the MCP JSON-RPC channel; every log line
///   goes to stderr. One process per client session — the historical mode.
/// - **serve / HTTP daemon** (`--serve` or `OBX_MEMORY_HTTP_PORT`, added
///   2026-07-18 — see the 2026-07-18 HTTP-daemon engineering log,
///   internal): ONE process owns the ObjectBox store as the sole writer
///   (exclusive instance-guard lock) and serves MANY Claude Code sessions
///   concurrently over MCP streamable HTTP (`lib/src/http_transport.dart`).
///   This is the fix for the documented multi-writer silent-data-loss risk
///   (R2-6, see the 2026-07-06 engineering log, internal) that stdio mode
///   has whenever more than one client session is open at once. Requires
///   `OBX_MEMORY_HTTP_TOKEN` to be set (2026-09-07 — see the 2026-09-07
///   daemon-auth engineering log, internal) — `--serve` refuses to start
///   without one; `tool/install-daemon.sh` generates and wires one up
///   automatically.
///
/// Both modes share the same startup wiring (config, guard, store, sync
/// client, embedder, `MemoryService`) and the same shutdown/cleanup
/// sequence (`_cleanupResources`, carrying forward the R2-5 invariants
/// below) — only the transport layer differs.
library;

import 'dart:async';
import 'dart:io' as io;

import 'package:dart_mcp/stdio.dart';
import 'package:remembox/src/embedder.dart';
import 'package:remembox/src/http_transport.dart';
import 'package:remembox/src/instance_guard.dart';
import 'package:remembox/src/memory_service.dart';
import 'package:remembox/src/server.dart';
import 'package:remembox/src/store.dart';
import 'package:remembox/src/store_gate.dart';

Future<void> main(List<String> args) async {
  void log(String message) => io.stderr.writeln(message);

  final config = MemoryConfig.fromEnvironment();
  final serveMode = serveModeRequested(args);

  // 2026-09-01 (Store-Gate, the 2026-09-01 store-gate engineering log
  // (internal), F5, plan §1.2): serve mode already gives one process
  // exclusive, persistent ownership of the store and serializes every tool
  // call through it (ToolCallSerializer) — gated mode's per-request
  // open/close would add real overhead (a full Store + SyncClient
  // open/close per tool call) for no additional safety. Checked here, not
  // in MemoryConfig.fromEnvironment, because serveMode is derived from CLI
  // args, not the environment.
  if (serveMode && config.storeMode == StoreMode.gated) {
    throw StateError(
      'OBX_MEMORY_STORE_MODE=gated is not supported with --serve. Serve '
      'mode already gives one process exclusive, persistent ownership of '
      'the store (see the 2026-07-18 HTTP-daemon engineering log, '
      'internal) and serializes every tool call through it '
      '(ToolCallSerializer) — gated mode\'s '
      'per-request open/close would add real overhead (a full Store + '
      'SyncClient open/close per tool call) for no additional safety. Use '
      'the default OBX_MEMORY_STORE_MODE=persistent with --serve, or drop '
      '--serve and use gated mode for multiple stdio processes instead.',
    );
  }

  // Fix 1 (2026-09-07, the 2026-09-07 daemon-auth engineering log
  // (internal)): resolved BEFORE the guard/store are touched, same
  // reasoning as the gated-mode check above — a config-time rejection must
  // never leave a
  // store.lock/instances.lock file behind (pinned by
  // test/remembox_main_test.dart '--serve without OBX_MEMORY_HTTP_TOKEN
  // refuses to start').
  final String? httpToken = serveMode ? resolveHttpToken() : null;

  // Serve mode is ALWAYS exclusive (see acquireServeModeGuard doc); stdio
  // mode keeps its historical config.exclusive default (false — tolerate a
  // second process, warn on writes).
  final guard =
      serveMode
          ? acquireServeModeGuard(config.storeDir, log: log)
          : StoreInstanceGuard.acquire(
            config.storeDir,
            log: log,
            exclusive: config.exclusive,
            // 2026-09-06 (Fix 2, the 2026-09-06 project-required
            // engineering log (internal)): known at this point (config is
            // parsed before the guard is acquired) — lets the startup peer
            // message log INFO ("expected") in gated mode instead of WARN.
            mode: config.storeMode,
          );

  // 2026-09-01 (Store-Gate, plan §10 sequencing): persistent mode keeps the
  // EXACT existing startup sequence (guard → store → syncClient), with
  // StoreGate.persistent added alongside it, not substituted into it. Gated
  // mode does NOT open the store here at all — that is gated mode's whole
  // point; StoreGate.gated only probes store.lock (bounded) so a stuck
  // persistent peer fails this process's startup fast, not with a hang.
  final StoreGate gate;
  if (config.storeMode == StoreMode.gated) {
    gate = await StoreGate.gated(storeDirectory: config.storeDir, log: log);
  } else {
    final store = openMemoryStore(config.storeDir, log: log);
    final syncClient = startSyncClient(store, config, log: log);
    gate = await StoreGate.persistent(
      store: store,
      syncClient: syncClient,
      storeDirectory: config.storeDir,
      log: log,
    );
  }

  final embedder = OllamaEmbedder(
    baseUrl: config.ollamaUrl,
    modelId: config.embedModel,
    dims: config.dims,
    log: log,
  );
  // S3 (2026-09-08 pre-publication audit): same startup-time observability
  // guard as warnIfSyncInsecure above, for the URL every memory text and
  // recall query is actually POSTed to.
  warnIfOllamaRemote(config.ollamaUrl, log);

  // Startup probe: fail loudly and early on missing Ollama/model, but keep
  // serving — tools surface the same actionable error per call, and
  // fixing Ollama requires no server restart.
  try {
    await embedder.ensureModelAvailable(autoPull: config.autoPull);
  } on EmbedderException catch (err) {
    log(
      '[startup] WARNING: embedding is currently unavailable — '
      '${err.message} Tools that need embeddings (remember/recall/'
      'supersede/reindex) will return this error until it is fixed.',
    );
  }

  final service = MemoryService(
    gate: gate,
    embedder: embedder,
    rankWeightRecency: config.rankWeightRecency,
    rankWeightFrequency: config.rankWeightFrequency,
    log: log,
    maxTextChars: config.maxTextChars,
    guard: guard,
  );
  // 2026-09-01 (Store-Gate, plan §5/WP5): the index watcher needs a live
  // Store reference for its entityChanges subscription across the whole
  // process lifetime (StoreGate.persistentStoreOrNull) — gated mode has no
  // such reference by design (§14 BLOCKER-1). Self-writes are already
  // indexed inline by remember() (WP4); foreign sync-arrived entries cannot
  // occur in gated mode (WP1 forbids OBX_MEMORY_SYNC_URL there); the
  // remaining case — a failed embedding leaving a stale index row — is
  // repaired by the reindex tool.
  if (config.storeMode == StoreMode.persistent) {
    service.startIndexWatcher();
  } else {
    log(
      '[startup] gated mode: index watcher NOT started. Self-writes are '
      'already indexed inline by remember() (WP4); foreign sync-arrived '
      'entries cannot occur in gated mode (WP1 forbids '
      'OBX_MEMORY_SYNC_URL here); the remaining case — a failed embedding '
      'leaving a stale index row — is repaired by the reindex tool. Run '
      'reindex manually or on a schedule if you need periodic self-repair '
      'in gated mode.',
    );
  }

  final stats = await service.stats();
  final storeStats = stats['store'] as Map<String, Object?>;
  final indexStats = stats['index'] as Map<String, Object?>;
  log(
    '[startup] $serverName $serverVersion — store: ${config.storeDir} '
    '(${storeStats['entries']} entries, ${indexStats['rows']} index rows), '
    'model: ${config.embedModel} (${config.dims} dims), '
    'sync: ${config.syncUrl.isEmpty ? 'off' : config.syncUrl}, '
    'maxTextChars: ${config.maxTextChars}, transport: '
    '${serveMode ? 'http (serve)' : 'stdio'}, '
    'storeMode: ${config.storeMode.name}',
  );
  log('[startup] ranking: ${config.describeRanking()}');

  if (serveMode) {
    await _runServeMode(
      args: args,
      service: service,
      guard: guard,
      gate: gate,
      embedder: embedder,
      log: log,
      // Non-null here: httpToken is only null when !serveMode (see its
      // declaration above), and we are inside `if (serveMode)`.
      httpToken: httpToken!,
    );
  } else {
    await _runStdioMode(
      service: service,
      guard: guard,
      gate: gate,
      embedder: embedder,
      log: log,
    );
  }
}

/// Shared shutdown sequence for BOTH transports (extracted 2026-07-18, see
/// the 2026-07-18 HTTP-daemon engineering log (internal), to avoid
/// duplicating the R2-5 ordering invariants below in two places — "No
/// duplicated logic" rule, CLAUDE.md Change-Safety Rules).
///
/// Ordering, unchanged in SPIRIT from the original R2-5 stdio-only sequence
/// (the 2026-07-06 engineering log (internal), fix round 2), updated
/// 2026-09-01 (Store-Gate,
/// plan §7) to route step 2-4 through [StoreGate.close] instead of calling
/// `syncClient.close()`/`store.close()` directly — [gate] IS now the thing
/// that owns and closes them (persistent mode: closes the sync client then
/// the store, same ordering as before; gated mode: nothing is standing open
/// between calls, but this still releases the `store.lock` handle):
/// 1. `service.dispose()` — stops the index watcher first.
/// 2. `embedder.close()`.
/// 3. `gate.close()` — internally: sync-client-close (MUST close before the
///    store — objectbox-dart docs: closing the store with a live sync
///    client is undefined behavior) → store-close → store.lock-release.
/// 4. `guard.release()` — AFTER `gate.close()`, not before: releasing first
///    would open a window where a second process's `acquire()` could
///    succeed and start writing to the directory while this process's own
///    `Store` handle is still live/mid-close, recreating the exact
///    two-writer hazard the guard exists to prevent, even if only during
///    shutdown.
Future<void> _cleanupResources({
  required MemoryService service,
  required OllamaEmbedder embedder,
  required StoreGate gate,
  required StoreInstanceGuard guard,
  required LogSink log,
}) async {
  await service.dispose();
  embedder.close();
  await gate.close();
  guard.release(log: log);
}

/// stdio transport main loop — unchanged behavior from RememBox v0.1.
Future<void> _runStdioMode({
  required MemoryService service,
  required StoreInstanceGuard guard,
  required StoreGate gate,
  required OllamaEmbedder embedder,
  required LogSink log,
}) async {
  final server = RememboxServer(
    stdioChannel(input: io.stdin, output: io.stdout),
    service: service,
    log: log,
  );

  // R2-5 (the 2026-07-06 engineering log (internal), fix round 2):
  // SIGINT/SIGTERM must run
  // the SAME cleanup as a normal stdin-EOF channel close, not skip it —
  // previously only the channel-close path (below, `await server.done`) ever
  // ran cleanup, so a `kill`/Ctrl-C on the server process left the store,
  // sync client, and embedder resources dangling until process exit
  // (contract §8: no silent skip of cleanup).
  //
  // Mechanism: each signal handler calls `server.shutdown()`, the SAME
  // public method dart_mcp's own channel-close path calls internally (it
  // completes `server.done`) — so `await server.done` below unblocks
  // exactly as it would for a normal stdin close, and the one cleanup block
  // after it runs unchanged, regardless of which trigger fired.
  // `shutdownTriggered` guards against double-dispose if a signal races the
  // channel closing on its own, or if both signals arrive back-to-back, and
  // makes the log name exactly the trigger that won that race.
  var shutdownTriggered = false;
  void handleShutdownTrigger(String triggerName) {
    if (shutdownTriggered) return;
    shutdownTriggered = true;
    log('[shutdown] $triggerName — cleaning up');
    unawaited(server.shutdown());
  }

  final sigintSub = io.ProcessSignal.sigint.watch().listen(
    (_) => handleShutdownTrigger('SIGINT received'),
  );
  final sigtermSub = io.ProcessSignal.sigterm.watch().listen(
    (_) => handleShutdownTrigger('SIGTERM received'),
  );

  await server.done;
  handleShutdownTrigger('MCP channel closed');
  await sigintSub.cancel();
  await sigtermSub.cancel();
  await _cleanupResources(
    service: service,
    embedder: embedder,
    gate: gate,
    guard: guard,
    log: log,
  );
  log('[shutdown] cleanup complete — exiting');
  // R2-5 (the 2026-07-06 engineering log (internal), fix round 2), verified
  // by hand with a real pipe (not a FIFO — a FIFO opened for read+write
  // never delivers a true EOF while any opener holds it, which masked this
  // during initial manual testing): `main()` returning is NOT enough to end
  // the process
  // here. `stdioChannel`'s underlying `io.stdin` listener keeps the VM's
  // event loop alive for as long as stdin itself has not reached EOF —
  // which, on a SIGTERM/SIGINT shutdown, it usually has NOT (the parent
  // process/MCP client may still hold its write end open even though IT
  // asked us to terminate). Without this explicit exit, a `kill`/Ctrl-C'd
  // server would run this entire cleanup block correctly and then hang
  // forever instead of actually terminating — silently defeating the whole
  // point of handling the signal. Safe to call unconditionally (also on the
  // normal stdin-EOF path): cleanup above has already run to completion.
  io.exit(0);
}

/// HTTP daemon transport main loop (2026-07-18, see the 2026-07-18
/// HTTP-daemon engineering log, internal). No stdin/channel-close analog —
/// the daemon just runs until SIGINT/SIGTERM, at which point it stops
/// accepting new HTTP connections, disposes every live session, and runs
/// the SAME `_cleanupResources` sequence as stdio mode before exiting.
Future<void> _runServeMode({
  required List<String> args,
  required MemoryService service,
  required StoreInstanceGuard guard,
  required StoreGate gate,
  required OllamaEmbedder embedder,
  required LogSink log,
  required String httpToken,
}) async {
  final port = resolveHttpPort(args);
  final sessionTtl = resolveSessionTtl();
  final maxSessions = resolveMaxSessions();
  final maxBodyBytes = resolveMaxBodyBytes();
  final daemon = RememboxHttpDaemon(
    service: service,
    log: log,
    token: httpToken,
    sessionTtl: sessionTtl,
    maxSessions: maxSessions,
    maxBodyBytes: maxBodyBytes,
  );
  final boundPort = await daemon.start(address: '127.0.0.1', port: port);
  log(
    '[startup] HTTP daemon listening on http://127.0.0.1:$boundPort/mcp '
    '(session TTL ${sessionTtl.inSeconds}s, max sessions $maxSessions, '
    'max body bytes $maxBodyBytes)',
  );

  // Same single-trigger-wins pattern as _runStdioMode's shutdownTriggered,
  // adapted to serve mode's lack of a `server.done`-equivalent channel-close
  // signal: the daemon only ever stops on SIGINT/SIGTERM here.
  var shutdownTriggered = false;
  final shutdownCompleter = Completer<void>();
  void handleShutdownTrigger(String triggerName) {
    if (shutdownTriggered) return;
    shutdownTriggered = true;
    log('[shutdown] $triggerName — cleaning up');
    shutdownCompleter.complete();
  }

  final sigintSub = io.ProcessSignal.sigint.watch().listen(
    (_) => handleShutdownTrigger('SIGINT received'),
  );
  final sigtermSub = io.ProcessSignal.sigterm.watch().listen(
    (_) => handleShutdownTrigger('SIGTERM received'),
  );

  await shutdownCompleter.future;
  await sigintSub.cancel();
  await sigtermSub.cancel();
  // Shutdown-safety note (2026-08-14 review round 2, N3, the 2026-07-18
  // HTTP-daemon engineering log (internal), "Review round 2 polish"):
  // `daemon.stop()` disposes
  // every live HTTP session — each disposal fails any still-pending request
  // completer (see `_Session.dispose` / `_fromServerSub`'s `onDone`
  // handler) — BEFORE `_cleanupResources` below touches `store`.
  // Nothing here defends against a parked handler resuming mid-write after
  // `store.close()`; safety instead falls out of two properties of this
  // process:
  //   1. Dart is single-threaded (one isolate, one event loop) — there is
  //      no OS thread that could be inside a store write while this
  //      sequence executes `store.close()`; any interleaving happens only
  //      at explicit `await` points, never inside a synchronous block.
  //   2. The only `await` points reachable from a request handler are I/O
  //      against the embedder (Ollama HTTP) or the network (sync client) —
  //      never a bare suspension that could resume back into ObjectBox
  //      store code after close, and by the time this line runs
  //      `daemon.stop()` has already resolved every session's pending
  //      completers, so there is nothing left to resume into anyway.
  // The `io.exit(0)` at the end of this function is the actual backstop: it
  // terminates the process synchronously right after cleanup, so even a
  // handler continuation that somehow survived the above could not resume
  // against an already-closed store — there is no process left to resume
  // in.
  await daemon.stop();
  await _cleanupResources(
    service: service,
    embedder: embedder,
    gate: gate,
    guard: guard,
    log: log,
  );
  log('[shutdown] cleanup complete — exiting');
  // Same rationale as the stdio path's io.exit(0) (see the comment on the
  // matching call in _runStdioMode): an open HttpServer socket keeps the VM
  // event loop alive even after `daemon.stop()` has closed it, and a signal
  // handler's async work does not by itself end the process. Safe to call
  // unconditionally — cleanup above has already run to completion.
  io.exit(0);
}
