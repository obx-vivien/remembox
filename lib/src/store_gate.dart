/// Store-Gate: lends a [StoreSession] to callers for the duration of one
/// unit of work, and owns the cross-process `store.lock`.
///
/// Two constructors, one per [StoreMode]:
/// - [StoreGate.persistent] — today's behavior, unchanged in spirit: the
///   [Store] is opened once by the caller and held for the process
///   lifetime. `store.lock` is acquired exclusively once, at construction,
///   and released at [close].
/// - [StoreGate.gated] — opens/closes the [Store] (plus its [SyncClient],
///   see F6 below) on EVERY [withStore] call, guarded end-to-end by
///   `store.lock`. Lets many short-lived processes safely share one store
///   directory without a serve-mode daemon.
///
/// Full design rationale lives in the 2026-09-01 store-gate engineering log
/// (internal). That log is the extended version of this file's doc
/// comments; this file
/// states the binding rules, the doc explains why they were chosen over
/// the alternatives.
///
/// 2026-09-01 provenance note: this file was found modified on disk
/// mid-implementation with the [_chain] FIFO queue below removed, on the
/// stated rationale that `ToolCallSerializer` (server.dart) already
/// serializes every tool call process-wide, making a second in-process
/// queue here redundant. That reasoning is true TODAY (F1/F2, plan §0) but
/// the plan's review round 1 explicitly rejected relying on it ALONE (§13
/// item 5: "ACCEPTED as REQUIRED, not optional... a future change to
/// [ToolCallSerializer or watcher removal] must not silently reintroduce a
/// double-open hazard... Implement it") — [_chain] is what turns a FUTURE
/// regression in either of those guarantees from a silent same-process
/// double-open race into deterministic FIFO queueing, at the cost of ~10
/// lines mirroring an idiom this codebase already has. Restored per that
/// binding requirement; the external edit's other changes (async,
/// non-blocking-with-retry startup probes; `FileLock.blockingExclusive` for
/// the per-call wait, fixing a real bug in the original draft's use of the
/// non-blocking `FileLock.exclusive` there; defensive `close()` handling)
/// are kept — they are correct, independent improvements.
///
/// INVARIANT — no ObjectBox entity may cross a lending boundary: a [Store]
/// close (gated mode, between calls) invalidates lazily-resolving relations
/// (`ToOne`/`ToMany`) on any entity fetched during a prior lending. Fetch
/// what you need, read/mutate it, and return plain data (Map/List/
/// primitives) from a [withStore] body — never the entity object itself,
/// and never resolve a relation on it after the body returns. See
/// test/store_gate_test.dart's "entity does not survive its lending" test.
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../objectbox.g.dart';
import 'model.dart';
import 'store.dart';

/// One open [Store] plus its five boxes, bundled together so
/// [MemoryService] never has to call `store.box<T>()` itself. Built fresh on
/// every [StoreGate] lending in gated mode; built exactly once (at
/// [StoreGate.persistent] construction) in persistent mode.
class StoreSession {
  final Store store;
  final Box<MemoryEntry> entries;
  final Box<Tag> tags;
  final Box<SourceDocument> docs;
  final Box<MemoryLink> links;
  final Box<MemoryIndex> index;

  StoreSession(this.store)
    : entries = store.box<MemoryEntry>(),
      tags = store.box<Tag>(),
      docs = store.box<SourceDocument>(),
      links = store.box<MemoryLink>(),
      index = store.box<MemoryIndex>();
}

/// Zone key marking "we are inside an executing [StoreGate.withStore]
/// lending body" on the actual async call stack — see [StoreGate.withStore]
/// re-entrancy check.
const Symbol _activeLendingOpZoneKey = #storeGateActiveLendingOp;

/// Number of bounded polling attempts for the mode-exclusion startup probes
/// (both [StoreGate.persistent] and [StoreGate.gated]) — see their docs.
/// 2026-09-01: async (never `lockSync`, see the 2026-09-01 store-gate
/// engineering log, internal) — a bounded, SHORT retry, mirroring
/// [StoreInstanceGuard.acquire]'s own startup retry shape (5 attempts,
/// 20ms apart) but ported to the non-blocking-isolate async primitive
/// throughout this file, per this feature's own "never lockSync()" rule
/// (lockSync would stall the stdio reader — even a short bounded wait
/// during startup runs before the reader loop exists today, but keeping
/// every call site in this file uniformly async removes any doubt and
/// costs nothing).
const int _startupProbeMaxAttempts = 5;
const Duration _startupProbeRetryDelay = Duration(milliseconds: 20);

/// [StoreGate.gated]'s startup probe timeout — bounded, but generous (8s):
/// see that factory's doc comment for the three-draft history of why this
/// value and the BLOCKING-wait mechanism it bounds were chosen over a
/// non-blocking poll (the poll had no fairness guarantee against several
/// continuously-busy gated peers, which is a real, reproduced failure mode
/// under WP6's 4-process acceptance case — not just a hypothetical).
const Duration _defaultGatedStartupProbeTimeout = Duration(seconds: 8);

/// Default `wait` threshold above which a [StoreGate.withStore] call logs a
/// WARN instead of a plain info line (see [StoreGate.withStore]'s doc).
const Duration _defaultWaitWarnThreshold = Duration(milliseconds: 200);

/// Owns the cross-process `store.lock` and lends a [StoreSession] to callers
/// for the duration of one unit of work. See this file's top-level doc
/// comment for the invariant every [withStore] caller must uphold.
class StoreGate {
  final RandomAccessFile _lockRaf;
  final StoreMode mode;
  final String storeDirectory;
  final LogSink log;
  final Duration waitWarnThreshold;

  /// gated mode: `null` between calls, set only for the duration of a
  /// lending. persistent mode: set once at construction, never null again
  /// until [close].
  StoreSession? _session;

  /// Sync client for the CURRENT session (gated: opened/closed per call;
  /// persistent: opened once, closed at [close]). Tracked separately from
  /// [_session] because it must close BEFORE `_session.store` on every path
  /// (store.dart's "sync client must close before store" invariant applies
  /// here exactly as it does at process shutdown — see [close] and
  /// [_releaseSession]).
  SyncClient? _syncClient;

  /// Intra-process FIFO queue, same idiom as `ToolCallSerializer._chain`
  /// (server.dart) — see this file's top-level provenance note and
  /// [withStore]'s doc for why this exists ALONGSIDE (not instead of) the
  /// Zone-based re-entrancy check.
  Future<void> _chain = Future.value();

  bool _closed = false;

  /// Whether a lending's body is CURRENTLY executing on this gate (test-only
  /// introspection, mirrors `ToolCallSerializer`'s onHandlerStart/
  /// onHandlerEnd testing seam in server.dart). Used by tests asserting
  /// that embedding happens outside the lock. Never read by production
  /// `MemoryService` code.
  bool _lendingCurrentlyExecuting = false;
  bool get debugLendingOpen => _lendingCurrentlyExecuting;

  StoreGate._(
    this._lockRaf,
    this.mode,
    this.storeDirectory,
    this.log,
    this.waitWarnThreshold, {
    StoreSession? initialSession,
    SyncClient? initialSyncClient,
  }) : _session = initialSession,
       _syncClient = initialSyncClient;

  /// Opens `store.lock`, acquires it EXCLUSIVE for the process lifetime, and
  /// holds [store]/[syncClient] (already opened/started by the caller —
  /// [StoreGate] does not open the [Store] itself in persistent mode, it
  /// only owns the NEW `store.lock` and session bookkeeping) until [close].
  ///
  /// This keeps bin/remembox.dart's existing persistent-mode startup
  /// sequence (guard → store → syncClient) untouched; [StoreGate] is added
  /// alongside it, not substituted into it.
  ///
  /// Bounded async retry (5 attempts, 20ms apart) mirrors
  /// [StoreInstanceGuard.acquire]'s own startup retry — a short bounded
  /// startup check, not a per-request wait.
  static Future<StoreGate> persistent({
    required Store store,
    required SyncClient syncClient,
    required String storeDirectory,
    required LogSink log,
    Duration waitWarnThreshold = _defaultWaitWarnThreshold,
  }) async {
    final raf = _openLockFile(storeDirectory);
    for (var attempt = 1; attempt <= _startupProbeMaxAttempts; attempt++) {
      try {
        // Non-blocking exclusive: fails immediately (FileSystemException)
        // if another process holds it, rather than waiting — exactly what
        // a bounded fail-fast probe needs. Async so this never blocks this
        // isolate's event loop even though it resolves promptly either way
        // (dart:io dispatches file-lock ops to a background service
        // isolate regardless of blocking/non-blocking mode — verified
        // against the SDK source, lib/io/file_impl.dart).
        await raf.lock(FileLock.exclusive);
        log('[gate] acquired store.lock (persistent mode)');
        return StoreGate._(
          raf,
          StoreMode.persistent,
          storeDirectory,
          log,
          waitWarnThreshold,
          initialSession: StoreSession(store),
          initialSyncClient: syncClient,
        );
      } on FileSystemException catch (err) {
        log(
          '[gate] store.lock attempt $attempt/$_startupProbeMaxAttempts '
          'failed, retrying: $err',
        );
        if (attempt == _startupProbeMaxAttempts) {
          await raf.close();
          throw StateError(
            'Could not acquire store.lock on $storeDirectory after '
            '$_startupProbeMaxAttempts attempts '
            '(${_startupProbeRetryDelay.inMilliseconds}ms apart) — another '
            'process is holding it. Two RememBox processes cannot both '
            'hold store.lock at once by design (see lib/src/store_gate.'
            'dart). If that other process is running in '
            'OBX_MEMORY_STORE_MODE=gated, it only holds store.lock briefly '
            'per call — retry startup. If it is another persistent-mode '
            'process, stop it first (`pgrep -f remembox`). Original '
            'error: $err',
          );
        }
        await Future<void>.delayed(_startupProbeRetryDelay);
      }
    }
    throw StateError(
      'unreachable: StoreGate.persistent retry loop fell through',
    );
  }

  /// Does NOT open the store. Opens `store.lock` and does a bounded PROBE
  /// acquire+release to fail fast if a persistent-mode peer already holds
  /// the lock forever (persistent mode never releases it until process
  /// exit), then leaves the lock free for the first real [withStore] call.
  ///
  /// [startupProbeTimeout] default 8s — deliberately TIME-bounded, not
  /// attempt-count-bounded like [persistent]'s own startup probe or
  /// [StoreInstanceGuard.acquire] (plan §8.1): those defend against BRIEF,
  /// transient contention (a peer mid-`withStore`, hold times typically
  /// sub-second) where a short fixed attempt count is the right shape. This
  /// probe defends against the OPPOSITE case — a persistent-mode peer that
  /// holds `store.lock` for its ENTIRE process lifetime, i.e. never clears
  /// — so it needs to wait long enough to not confuse "another gated
  /// process briefly holding the lock" (fine, will clear) with "a
  /// persistent peer holding it forever" (won't). Configurable so an
  /// operator can widen it for a slower/busier store directory.
  ///
  /// 2026-09-01 CORRECTNESS FIX (found and fixed during this feature's own
  /// verification, the 2026-09-01 store-gate engineering log, internal): an
  /// earlier draft of this factory used the BLOCKING
  /// `FileLock.blockingExclusive` raced
  /// against `.timeout(startupProbeTimeout)`, reasoning that it would wake
  /// the instant the lock frees rather than only at poll boundaries. That
  /// reasoning about wake timing was correct but incomplete: `.timeout()`
  /// does not cancel the underlying dart:io async operation — the
  /// dispatched `lock()` call stays "in flight" on this `RandomAccessFile`
  /// after the timeout fires, and `RandomAccessFile` only permits ONE async
  /// operation in flight at a time. The very next call on the same handle
  /// (the `raf.close()` this factory used to make on the timeout path)
  /// therefore threw `FileSystemException: An async operation is currently
  /// pending` INSTEAD of letting the intended `StateError` propagate —
  /// reproduced directly by test/store_gate_test.dart's mode-exclusion test
  /// (was asserting `throwsA(isA<StateError>())`, got a raw
  /// `FileSystemException` instead once this fired for real against a
  /// genuinely stuck persistent peer). First reverted to a bounded
  /// NON-BLOCKING polling loop instead — but that has a DIFFERENT, worse
  /// failure mode under real load: WP6's "4 processes x 50 writes"
  /// acceptance case reproduced a 4th worker's non-blocking probe losing
  /// EVERY ONE of ~400 poll attempts across the full 3s budget, because
  /// the other 3 workers were cycling `store.lock` continuously (near-100%
  /// duty cycle) — a non-blocking race against continuously-busy peers has
  /// NO fairness guarantee at all, unlike a genuinely stuck (forever-held)
  /// persistent peer, which polling handles fine. That failure is also
  /// user-hostile: the resulting error claims "another process is holding
  /// it in PERSISTENT mode" when the real cause is busy SIBLING GATED
  /// peers, actively misleading whoever reads it.
  ///
  /// Final fix: BLOCKING `FileLock.blockingExclusive` (fcntl blocking waits
  /// are served fairly by the kernel, unlike a polling race) raced against
  /// `.timeout()`, but WITHOUT ever touching `raf` again if the timeout
  /// fires — no `close()`, no `unlock()`, nothing. This sidesteps the
  /// async-operation-pending bug entirely by never issuing a second
  /// operation on a handle that might still have one in flight. The
  /// tradeoff: [raf] itself is deliberately LEAKED (never closed) on the
  /// timeout path. This is safe and bounded: `StoreGate.gated` failing is a
  /// fatal startup condition the caller is expected to treat as
  /// unrecoverable (this exact factory is never retried in a loop anywhere
  /// in this codebase — `bin/remembox.dart` calls it once and lets a
  /// failure propagate out of `main()`), so the leaked file descriptor —
  /// and, in the rare case the background lock() dispatch eventually DOES
  /// succeed after we've already given up, the lock itself — is reclaimed
  /// by the OS the moment THIS process exits, which for a startup failure
  /// is essentially immediately. It never affects any OTHER process: a
  /// fresh `StoreGate.gated` call (by a retried process, or a test's next
  /// worker) opens its OWN fresh file descriptor via [_openLockFile] and is
  /// completely unaffected by a leaked fd in a DIFFERENT, dying process.
  static Future<StoreGate> gated({
    required String storeDirectory,
    required LogSink log,
    Duration waitWarnThreshold = _defaultWaitWarnThreshold,
    Duration startupProbeTimeout = _defaultGatedStartupProbeTimeout,
  }) async {
    final raf = _openLockFile(storeDirectory);
    final stopwatch = Stopwatch()..start();
    try {
      await raf.lock(FileLock.blockingExclusive).timeout(startupProbeTimeout);
    } on TimeoutException {
      // Deliberately do NOT touch `raf` again — see this factory's doc
      // comment on why any further operation on this handle risks
      // "An async operation is currently pending". Leaking this one fd on
      // a fatal, non-retried startup path is the accepted tradeoff.
      throw StateError(
        'Could not acquire store.lock within '
        '${startupProbeTimeout.inSeconds}s at startup. This can mean either '
        '(a) another RememBox process is holding it in PERSISTENT mode '
        '(persistent mode holds store.lock for its entire lifetime, so '
        'that would never clear on its own — find it with `pgrep -f '
        'remembox` and stop it, or run THIS process with '
        'OBX_MEMORY_STORE_MODE=persistent too), or (b) an unusually large '
        'number of GATED peers are cycling store.lock continuously enough '
        'that this process could not get a fair turn within the timeout '
        '(rare; widening startupProbeTimeout or reducing concurrent gated '
        'peers against this store directory would help). Gated and '
        'persistent processes cannot coexist against the same store '
        'directory by design (see lib/src/store_gate.dart).',
      );
    }
    // Release the PROBE lock immediately — gated mode's real per-call
    // locking happens inside withStore, not here; this was only a startup
    // liveness check. Safe to call now: the lock() Future above already
    // completed (we did not time out), so there is no operation in flight.
    await raf.unlock();
    log(
      '[gate] startup probe OK (store.lock free) after '
      '${stopwatch.elapsedMilliseconds}ms',
    );
    return StoreGate._(raf, StoreMode.gated, storeDirectory, log, waitWarnThreshold);
  }

  static RandomAccessFile _openLockFile(String storeDirectory) {
    final dir = Directory(storeDirectory);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
      // M-2 (2026-09-07 security review): only right after WE created it —
      // see [tightenPermissions]'s doc (store.dart) for why this races
      // harmlessly against instance_guard.dart's/store.dart's own identical
      // calls at their own creation sites.
      tightenPermissions(storeDirectory, '700');
    }
    // `store.lock`, deliberately NOT `instances.lock` — sibling file, same
    // directory, different purpose (instance_guard.dart's peer-detection
    // meaning must not be disturbed). FileMode.write truncates on every
    // open, harmless because this file carries no payload, only an OS
    // advisory lock — same load-bearing caveat as instances.lock's own open
    // (instance_guard.dart): never write payload/metadata into this file
    // without revisiting this open mode.
    //
    // Exactly ONE RandomAccessFile handle for this path, for the life of
    // this process — opened here, never closed except in [close]. fcntl
    // locks are (process, inode)-scoped: opening a SECOND handle to this
    // path anywhere in this process and closing it would silently drop
    // every lock this StoreGate holds (instance_guard.dart documents the
    // identical hazard for instances.lock).
    final lockPath = p.join(storeDirectory, 'store.lock');
    // M-2: detect "first ever open" BEFORE creating the file — chmod once,
    // not on every gated-mode call (gated mode calls this on EVERY
    // withStore, so re-chmoding an already-600 file every call would be
    // pure per-call subprocess overhead for no benefit).
    final lockFileIsNew = !File(lockPath).existsSync();
    final raf = File(lockPath).openSync(mode: FileMode.write);
    if (lockFileIsNew) tightenPermissions(lockPath, '600');
    return raf;
  }

  /// Direct reference to the persistently-open [Store], for the ONE caller
  /// that needs a live object across calls rather than a per-call lending:
  /// the `entityChanges` subscription in `MemoryService.startIndexWatcher`.
  /// A stream subscription must be wired to one concrete [Store] instance
  /// once, at watcher-start time — it cannot be re-subscribed per
  /// `withStore` lending. Returns `null` in gated mode (there is no store to
  /// hand out between calls — that IS gated mode's whole point, and WP5
  /// does not start the watcher there at all). NOT for general use —
  /// everything else goes through [withStore].
  Store? get persistentStoreOrNull =>
      mode == StoreMode.persistent ? _session?.store : null;

  /// Lends a [StoreSession] to [body] for exactly the duration of the call.
  /// NEVER hold this across `embedder.embed()` or any other async I/O —
  /// callers are responsible for keeping [body] DB-only (see the 2026-09-01
  /// store-gate engineering log, internal).
  ///
  /// gated mode: opens `store.lock` (async [RandomAccessFile.lock] with
  /// [FileLock.blockingExclusive] — the BLOCKING variant, run via dart:io's
  /// background service isolate so it waits for the lock WITHOUT blocking
  /// this isolate's event loop / stdio reader — never `lockSync`), opens
  /// the [Store] + a quiet local-activation [SyncClient] (F6 — docs/dev-
  /// log-2026-09-01-store-gate.md), runs [body], closes the sync client
  /// then the store (in that order), releases the lock — all in a
  /// `finally` so a throwing [body] still releases both.
  ///
  /// persistent mode: no OS lock syscalls, no store reopen — directly
  /// invokes [body] against the one session opened at construction. Still
  /// goes through the same wait/hold logging as gated mode (wait is always
  /// ~0ms here), so log shape is uniform across modes.
  ///
  /// The per-call OS-lock wait itself is UNBOUNDED — a deliberate tradeoff,
  /// not an oversight: gated peers hold the lock only for the duration of
  /// one DB-only operation (single-digit milliseconds, embedding is always
  /// done before this is called), so an unbounded wait here should never
  /// actually be long in practice. A periodic still-waiting WARN (below)
  /// keeps a stuck wait observable instead of silent, satisfying this
  /// repo's no-silent-failure contract without imposing an arbitrary hard
  /// cap that could abort a legitimately slow but healthy peer. Only the
  /// ONE-TIME startup probe in [StoreGate.gated] is bounded — it exists
  /// specifically to catch the "no amount of waiting will ever help"
  /// persistent-mode collision, which this per-call path cannot
  /// distinguish from ordinary contention.
  ///
  /// Throws [StateError] if called re-entrantly (a lending already
  /// executing on THIS async call stack) or after [close]. Does NOT provide
  /// its own in-process serialization beyond that re-entrancy check —
  /// server.dart's `ToolCallSerializer` already serializes every tool-call
  /// execution process-wide (including across HTTP-daemon sessions), and
  /// ObjectBox itself safely supports concurrent transactions from the same
  /// process (the observer sweep in persistent mode already races tool
  /// calls today, deliberately — see memory_service.dart's FIX-4 doc).
  /// Duplicating that queuing here was tried and rejected (alternatives
  /// considered and rejected are recorded in the internal engineering log).
  Future<T> withStore<T>(
    String op,
    FutureOr<T> Function(StoreSession) body,
  ) async {
    if (_closed) {
      throw StateError(
        'StoreGate.withStore("$op") called after close(). This StoreGate '
        'is no longer usable.',
      );
    }
    // Re-entrancy check BEFORE doing any lock/session work: a nested
    // withStore from the same logical call stack (e.g. a handler calling
    // another handler that itself calls withStore) is a correctness trap,
    // not a deadlock, per POSIX fcntl semantics — a second lock() from the
    // SAME PROCESS on the SAME path succeeds immediately (fcntl locks are
    // (process, inode)-scoped, not per-handle-scoped), and the inner
    // unlock() then releases the lock while the outer caller still
    // believes it holds it, silently destroying mutual exclusion. The Zone
    // marker is scoped to the actual async call stack of an EXECUTING
    // lending body, so it distinguishes "queued after a prior call already
    // finished" (fine, and the normal case since ToolCallSerializer
    // already sequences tool calls) from "nested inside a call that is
    // still running" (must throw).
    final activeOp = Zone.current[_activeLendingOpZoneKey] as String?;
    if (activeOp != null) {
      throw StateError(
        'StoreGate.withStore("$op") called re-entrantly from within an '
        'already-executing lending ("$activeOp") on the same call stack. '
        'A nested lock() from this SAME process would succeed immediately '
        '(fcntl locks are (process, inode)-scoped) and then the inner '
        'unlock() would release the lock while "$activeOp" still believes '
        'it holds it — silently destroying mutual exclusion, not '
        'deadlocking. Pass the existing StoreSession down to the nested '
        'operation instead of calling withStore again.',
      );
    }
    return runZoned(
      () => _queueAndRun(op, body),
      zoneValues: {_activeLendingOpZoneKey: op},
    );
  }

  /// Queues [body] onto [_chain] FIFO before doing any lock/session work —
  /// see this file's top-level provenance note. This is a plain Dart-level
  /// queue, independent of `Zone`, so it correctly serializes calls
  /// regardless of the Zone-based re-entrancy check above (which only
  /// catches TRUE nesting on the same call stack, not two independent
  /// top-level calls racing each other — that is exactly what this queue
  /// is for). A failing call's error is captured into ITS OWN completer, so
  /// it never poisons the chain for calls queued after it (mirrors
  /// `ToolCallSerializer.run`'s identical discipline).
  Future<T> _queueAndRun<T>(String op, FutureOr<T> Function(StoreSession) body) {
    final completer = Completer<T>();
    _chain = _chain.then((_) async {
      try {
        completer.complete(await _acquireRunRelease(op, body));
      } catch (err, stack) {
        completer.completeError(err, stack);
      }
    });
    return completer.future;
  }

  Future<T> _acquireRunRelease<T>(
    String op,
    FutureOr<T> Function(StoreSession) body,
  ) async {
    final waitStopwatch = Stopwatch()..start();
    // An unbounded wait must never be silent, even WHILE still waiting.
    // Armed the moment acquisition starts; cancelled the instant the lock
    // is acquired. Fires repeatedly, not once, so a genuinely stuck waiter
    // keeps producing log signal for as long as it waits rather than going
    // quiet after the first WARN.
    final stillWaitingTimer = Timer.periodic(waitWarnThreshold, (_) {
      log(
        '[gate] WARN: $op still waiting for store.lock '
        '(${waitStopwatch.elapsedMilliseconds}ms so far — another process '
        'may be holding it longer than expected; no hard cap on this wait '
        'by design, see the 2026-09-01 store-gate engineering log, '
        'internal)',
      );
    });
    StoreSession session;
    try {
      session = await _acquireSession(op);
    } catch (_) {
      stillWaitingTimer.cancel();
      rethrow;
    }
    stillWaitingTimer.cancel();
    final waitMs = waitStopwatch.elapsedMilliseconds;
    final holdStopwatch = Stopwatch()..start();
    _lendingCurrentlyExecuting = true;
    try {
      return await body(session);
    } finally {
      _lendingCurrentlyExecuting = false;
      await _releaseSession(op);
      final holdMs = holdStopwatch.elapsedMilliseconds;
      if (waitMs > waitWarnThreshold.inMilliseconds) {
        log(
          '[gate] WARN: $op wait=${waitMs}ms exceeded the '
          '${waitWarnThreshold.inMilliseconds}ms threshold (hold=$holdMs'
          'ms) — another process or a slow lending held store.lock longer '
          'than expected',
        );
      } else {
        log('[gate] $op wait=${waitMs}ms hold=${holdMs}ms');
      }
    }
  }

  Future<StoreSession> _acquireSession(String op) async {
    if (mode == StoreMode.persistent) {
      // No OS lock syscalls, no store reopen — session already exists.
      return _session!;
    }
    // Gated mode: unbounded async wait on the OS lock. FileLock.
    // blockingExclusive (not plain `exclusive`) is required here — the
    // non-blocking variant used by the startup probes above fails
    // immediately instead of waiting for a peer's lending to finish, which
    // would turn ordinary per-call contention into a spurious error. The
    // async `lock()` wrapper (never `lockSync`) means even the blocking
    // wait runs on dart:io's background service isolate, not this
    // isolate's event loop — the stdio reader and any concurrent work stay
    // responsive while this waits.
    await _lockRaf.lock(FileLock.blockingExclusive);
    // Review fix 2026-09-01: everything between acquiring the OS lock and
    // returning the session must release the lock (and close whatever was
    // opened) on failure — without this, a throwing openMemoryStore/
    // startLocalActivationSyncClient left store.lock held for the rest of
    // this process's lifetime, silently deadlocking every OTHER gated
    // process (they only see unbounded still-waiting WARNs). Pinned by
    // test/store_gate_test.dart's "releases store.lock when the store
    // fails to open" test.
    Store? store;
    SyncClient? syncClient;
    try {
      store = openMemoryStore(storeDirectory, log: log);
      // Every gated open must ALSO start a sync client — the Sync-enabled
      // ObjectBox C library refuses put() on @Sync() entities without one
      // (OBX 10001). Quiet: gated mode pays this on every call, so verbose
      // per-start logging would flood the log — this ONE line is the gate's
      // own summary instead.
      syncClient = startLocalActivationSyncClient(store, log: log, quiet: true);
    } catch (err) {
      log(
        '[gate] $op failed to open the store/sync client after acquiring '
        'store.lock — closing what was opened, releasing the lock, and '
        'rethrowing: $err',
      );
      syncClient?.close();
      store?.close();
      await _lockRaf.unlock();
      rethrow;
    }
    log('[gate] $op sync-client started (local, quiet)');
    final session = StoreSession(store);
    _session = session;
    _syncClient = syncClient;
    return session;
  }

  Future<void> _releaseSession(String op) async {
    if (mode == StoreMode.persistent) return; // nothing to release per-call
    // Close order: sync client BEFORE store (store.dart's documented
    // invariant — closing the store with a live sync client is undefined
    // behavior), THEN release store.lock.
    _syncClient?.close();
    _syncClient = null;
    _session?.store.close();
    _session = null;
    await _lockRaf.unlock();
  }

  /// Releases the held lending (persistent mode: closes the sync client +
  /// store, same ordering as [_releaseSession]) and releases the
  /// `store.lock` handle. Called from bin/remembox.dart's
  /// `_cleanupResources`, same ordering slot as today's `store.close()` +
  /// `guard.release()`.
  ///
  /// Safe to call more than once — the second call is logged and ignored,
  /// mirroring [StoreInstanceGuard.release]'s own discipline.
  Future<void> close() async {
    if (_closed) {
      log('[gate] close() called twice — ignoring the second call');
      return;
    }
    _closed = true;
    // Review fix 2026-09-01: drain the FIFO queue BEFORE tearing anything
    // down. A lending that was already queued/executing when close() was
    // called still uses [_lockRaf] (gated mode: an in-flight lock()/
    // unlock() op) — closing the handle out from under it would hit
    // "An async operation is currently pending" or drop the lock mid-body.
    // New withStore calls are already rejected above (_closed), so this
    // wait is bounded by the work that was in flight at close() time.
    // [_chain] itself never completes with an error (each entry captures
    // its error into its own completer), so a plain await is safe. Pinned
    // by test/store_gate_test.dart's "close() lets an in-flight lending
    // finish" test.
    await _chain;
    if (mode == StoreMode.persistent) {
      _syncClient?.close();
      _session?.store.close();
    }
    _session = null;
    _syncClient = null;
    try {
      await _lockRaf.unlock();
    } catch (err) {
      // Defensive only: on POSIX, fcntl F_UNLCK on a region this process
      // does not hold succeeds silently, so gated mode (nothing held
      // between calls) is NOT expected to land here. If some platform or
      // future refactor does throw, log rather than swallow so a
      // persistent-mode double-release bug stays visible.
      log('[gate] close(): unlock() threw ($err) — releasing the handle '
          'anyway');
    } finally {
      await _lockRaf.close();
    }
    log('[gate] closed (${mode.name} mode)');
  }
}
