/// Advisory, OS-level, cross-process instance detection/guard for the
/// ObjectBox store directory.
///
/// Background: two genuine OS processes opening the SAME ObjectBox store
/// directory do not collide at open time, but concurrent writers can
/// silently interleave writes with PARTIAL DATA LOSS (verified: 85+85 puts,
/// only 103 survived — see `lib/src/store.dart`'s `openMemoryStore` doc and
/// the 2026-07-07 concurrent-open experiment (internal)). This class is
/// the 2026-07-07 instance-guard follow-up in the 2026-07-06 engineering
/// log (internal): default mode tolerates a
/// second process and surfaces a warning on every write tool call; opt-in
/// `OBX_MEMORY_EXCLUSIVE=true` refuses to start at all if another instance
/// already holds a lock.
///
/// Mechanism: a single `RandomAccessFile` handle per process on
/// `<storeDirectory>/instances.lock`, held for the lifetime of the process,
/// using `dart:io`'s POSIX advisory file locks (`lockSync`/`unlockSync`).
/// These locks are (process, inode)-scoped — closing any OTHER file handle
/// to the same path drops ALL of this process's locks on that path — so
/// exactly one [RandomAccessFile] per process may ever open this file, owned
/// solely by this guard. The kernel drops all fcntl locks automatically on
/// process death, so there is no stale-lock/PID-file cleanup problem.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'store.dart' show LogSink, StoreMode, tightenPermissions;

/// Number of `lockSync()` attempts before giving up, and the fixed delay
/// between them. A short bounded startup retry, not a per-request retry —
/// blocking the isolate here is fine.
const int _maxAttempts = 5;
const Duration _retryDelay = Duration(milliseconds: 20);

/// Holds (or detects) an advisory lock on a store directory's
/// `instances.lock` file so the process can tell whether another RememBox
/// process is already attached to the same [Store] directory.
///
/// Only [acquire] may construct instances.
class StoreInstanceGuard {
  final RandomAccessFile _raf;
  final bool _exclusive;
  bool _released = false;

  StoreInstanceGuard._(this._raf, this._exclusive);

  /// Acquires a lock on `<storeDirectory>/instances.lock`, creating the
  /// directory first if needed (this guard runs BEFORE [openMemoryStore],
  /// whose own directory creation would otherwise happen too late for this
  /// purpose).
  ///
  /// Default (`exclusive: false`): acquires a SHARED lock — tolerates any
  /// number of other shared holders. After acquiring, checks once whether a
  /// peer is already attached and logs a WARN if so.
  ///
  /// `exclusive: true`: acquires an EXCLUSIVE lock — fails if anyone else
  /// (shared or exclusive) already holds the file, refusing this instance
  /// from starting at all.
  ///
  /// Both modes retry up to 5 times, 20ms apart, on a conflicting lock
  /// (`FileSystemException`); every attempt is logged, and after 5 failures
  /// throws a [StateError] with an actionable message. Any OTHER exception
  /// type is not caught-and-retried — it propagates immediately.
  /// [mode] is the store mode this process is starting in — additive
  /// (2026-09-06, the 2026-09-06 project-required engineering log
  /// (internal), Fix 2), default `null` preserving the pre-existing WARN
  /// text for any
  /// caller that does not (yet) pass it. When `mode == StoreMode.gated`,
  /// several attached processes are the DESIGN (Store-Gate serializes every
  /// tool call on `store.lock`), so the startup message is logged at INFO
  /// with "expected" wording instead of WARN. Any other value (including
  /// `null`) keeps the WARN, but with corrected advice — see the message
  /// below for why `OBX_MEMORY_EXCLUSIVE=true` is no longer recommended as
  /// the fix.
  static StoreInstanceGuard acquire(
    String storeDirectory, {
    required LogSink log,
    required bool exclusive,
    StoreMode? mode,
  }) {
    final dir = Directory(storeDirectory);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
      log('[instance-guard] created store directory $storeDirectory');
      // M-2 (2026-09-07 security review): only right after WE created it —
      // see [tightenPermissions]'s doc for why this races harmlessly
      // against store.dart's/store_gate.dart's own identical calls at their
      // own creation sites.
      tightenPermissions(storeDirectory, '700', log: log);
    }
    final lockPath = p.join(storeDirectory, 'instances.lock');
    // M-2: detect "first ever open" BEFORE creating the file below — chmod
    // once, not on every acquire() (every RememBox process calls this at
    // startup).
    final lockFileIsNew = !File(lockPath).existsSync();
    // FileMode.write truncates the file on every open, which is harmless
    // TODAY because this file carries no content (only an OS advisory
    // lock) — but this is a load-bearing invariant: never write
    // payload/metadata into instances.lock without revisiting this open
    // mode, or it will be silently discarded on the next process's
    // acquire().
    final raf = File(lockPath).openSync(mode: FileMode.write);
    if (lockFileIsNew) {
      tightenPermissions(lockPath, '600', log: log);
    }

    final targetLock = exclusive ? FileLock.exclusive : FileLock.shared;
    for (var attempt = 1; attempt <= _maxAttempts; attempt++) {
      try {
        raf.lockSync(targetLock);
        final guard = StoreInstanceGuard._(raf, exclusive);
        log(
          '[instance-guard] acquired ${exclusive ? "EXCLUSIVE" : "shared"} '
          'lock on $lockPath',
        );
        if (!exclusive && guard.peersPresent()) {
          if (mode == StoreMode.gated) {
            log(
              '[instance-guard] INFO: another RememBox process is also '
              'attached to this store directory ($storeDirectory) in '
              'shared mode — expected in gated mode: writes are '
              'serialized per tool call via store.lock, so concurrent '
              'processes are safe by design.',
            );
          } else {
            log(
              '[instance-guard] WARN: another RememBox process is also '
              'attached to this store directory ($storeDirectory) in '
              'shared mode — concurrent writers on the same store '
              'directory can silently lose writes (verified: 85+85 rows '
              'written, 103 survived — see openMemoryStore doc in '
              'lib/src/store.dart). Stop the other process, or switch '
              'this store directory to gated mode '
              '(OBX_MEMORY_STORE_MODE=gated), which serializes '
              'concurrent writers safely by design. Setting '
              'OBX_MEMORY_EXCLUSIVE=true on ONE instance only makes the '
              'SECOND process refuse to start — it does not resolve '
              'concurrency, it prevents it.',
            );
          }
        }
        return guard;
      } on FileSystemException catch (err) {
        final label = exclusive ? 'exclusive-lock' : 'shared-lock';
        log(
          '[instance-guard] $label attempt $attempt/$_maxAttempts failed, '
          'retrying: $err',
        );
        if (attempt == _maxAttempts) {
          if (exclusive) {
            throw StateError(
              'Could not acquire an EXCLUSIVE instance lock on '
              '$storeDirectory after 5 attempts (20ms apart). Another '
              'RememBox process already holds a lock on this store '
              'directory. Two concurrent writers on the same ObjectBox '
              'store directory do not error at open time — they silently '
              'interleave writes with PARTIAL DATA LOSS (verified: 85+85 '
              'puts, only 103 survived; see the openMemoryStore doc in '
              'lib/src/store.dart). '
              'Stop the other instance (`pgrep -f remembox`) before '
              'running with OBX_MEMORY_EXCLUSIVE=true, or unset '
              'OBX_MEMORY_EXCLUSIVE to share the store in default '
              '(shared-lock, warned) mode instead. Original error: $err',
            );
          }
          throw StateError(
            'Could not acquire a shared instance lock on $storeDirectory '
            'after 5 attempts (20ms apart). Another RememBox process is '
            'holding an EXCLUSIVE lock (OBX_MEMORY_EXCLUSIVE=true), which '
            'refuses all other instances. Find it with `pgrep -f remembox` '
            'and stop it — unsetting OBX_MEMORY_EXCLUSIVE on THIS instance '
            'is not the fix, the other one must stop. Original error: $err',
          );
        }
        sleep(_retryDelay);
      }
    }
    // Unreachable: the loop above either returns or throws on the final
    // attempt.
    throw StateError('unreachable: instance guard retry loop fell through');
  }

  /// Whether another process currently holds a lock on this same
  /// `instances.lock` file.
  ///
  /// Always `false` for an exclusive-mode guard (holding an exclusive lock
  /// already means no one else can hold anything).
  ///
  /// For a shared-mode guard: attempts to upgrade this handle's own lock to
  /// exclusive. If that fails with a lock conflict, a peer is present. If it
  /// succeeds, no peer was present at that instant — the upgrade is reverted
  /// back to shared in a `finally` block so the revert ALWAYS runs, whether
  /// returning normally or if the revert itself throws (that exception
  /// propagates uncaught, not swallowed).
  ///
  /// An error other than a lock conflict during this probe must not be
  /// silently mislabeled as "peer present"/"peer absent" — it propagates to
  /// the caller, which for write-tool call sites means the tool call
  /// surfaces as `internal_error` via server.dart's existing generic catch
  /// (the correct, already-tested "something unexpected happened" path).
  bool peersPresent() {
    if (_exclusive) return false;
    try {
      _raf.lockSync(FileLock.exclusive);
    } on FileSystemException {
      return true;
    }
    try {
      return false;
    } finally {
      _raf.lockSync(FileLock.shared);
    }
  }

  /// Releases the lock and closes the handle. Safe to call more than once —
  /// the second call is logged and ignored, never throws.
  void release({required LogSink log}) {
    if (_released) {
      log('[instance-guard] release() called twice — ignoring the second call');
      return;
    }
    _released = true;
    try {
      _raf.unlockSync();
    } finally {
      _raf.closeSync();
    }
    log(
      '[instance-guard] released ${_exclusive ? "EXCLUSIVE" : "shared"} lock',
    );
  }
}
