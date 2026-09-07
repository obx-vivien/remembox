/// Pins [StoreInstanceGuard] (lib/src/instance_guard.dart): the R2-6
/// follow-up (the 2026-07-06 engineering log (internal)'s 2026-07-07 "R2-6
/// Follow-up" section) advisory cross-process instance detection/guard.
///
/// Tests 2-4 spawn a REAL second OS process (via the scripts in
/// test/helpers/) to exercise genuine cross-process POSIX advisory file
/// locking — an in-process-only test cannot prove anything about peer
/// detection, since fcntl locks are (process, inode)-scoped.
///
/// No new dart_test.yaml tag needed: this file stays in the default `dart
/// test` suite (dart_test.yaml only tags `ollama`, skipped by default).
library;

import 'dart:convert';
import 'dart:io';

import 'package:remembox/objectbox.g.dart';
import 'package:remembox/src/instance_guard.dart';
import 'package:remembox/src/memory_service.dart';
import 'package:remembox/src/store.dart'
    show StoreMode, localActivationSyncUrl;
import 'package:remembox/src/store_gate.dart';
import 'package:test/test.dart';

import 'support/fake_embedder.dart';

class _Peer {
  final Process process;
  _Peer(this.process);

  static Future<_Peer> spawn(String storeDir, String helperScript) async {
    // Platform.resolvedExecutable: the VM running this test — no PATH
    // dependency, same SDK as the test.
    final proc = await Process.start(Platform.resolvedExecutable, [
      'run',
      helperScript,
      storeDir,
    ]);
    final firstLine =
        await proc.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first;
    if (firstLine != 'LOCK_HELD') {
      proc.kill();
      fail('peer did not report LOCK_HELD, got: $firstLine');
    }
    return _Peer(proc);
  }

  Future<void> stop() async {
    await process.stdin.close();
    final exited = await process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
    if (exited == -1) {
      stderr.writeln('WARNING: peer process did not exit cleanly, SIGKILLed');
    }
  }
}

void main() {
  late Directory tempDir;
  late List<String> logLines;

  void logCapture(String line) => logLines.add(line);

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('remembox_guard_test_');
    logLines = [];
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test('solo: default acquire sees no peer, peersPresent() is false, and '
      'release() works and logs', () {
    final guard = StoreInstanceGuard.acquire(
      tempDir.path,
      log: logCapture,
      exclusive: false,
    );
    expect(guard.peersPresent(), isFalse);
    guard.release(log: logCapture);
    expect(
      logLines.any((l) => l.contains('released') && l.contains('shared')),
      isTrue,
      reason: 'release() must log a release line: $logLines',
    );
  });

  test('a real peer holding a shared lock is detected by peersPresent(), and '
      'detection clears again once the peer actually stops', () async {
    final peer = await _Peer.spawn(
      tempDir.path,
      'test/helpers/hold_shared_lock.dart',
    );
    addTearDown(peer.stop);

    final guard = StoreInstanceGuard.acquire(
      tempDir.path,
      log: logCapture,
      exclusive: false,
    );
    expect(guard.peersPresent(), isTrue);

    await peer.stop();

    var cleared = false;
    for (var i = 0; i < 10; i++) {
      if (!guard.peersPresent()) {
        cleared = true;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(
      cleared,
      isTrue,
      reason:
          'peersPresent() must clear once the peer process has actually '
          'released its lock (kernel lock release on process exit is not '
          'necessarily instantaneous relative to the next check)',
    );

    guard.release(log: logCapture);
  });

  test('exclusive acquire fails with StateError mentioning EXCLUSIVE when a '
      'peer already holds a shared lock', () async {
    final peer = await _Peer.spawn(
      tempDir.path,
      'test/helpers/hold_shared_lock.dart',
    );
    addTearDown(peer.stop);

    expect(
      () => StoreInstanceGuard.acquire(
        tempDir.path,
        log: logCapture,
        exclusive: true,
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('EXCLUSIVE'),
        ),
      ),
    );
  });

  test('default (shared) acquire fails with StateError mentioning pgrep when a '
      'peer already holds an exclusive lock', () async {
    final peer = await _Peer.spawn(
      tempDir.path,
      'test/helpers/hold_exclusive_lock.dart',
    );
    addTearDown(peer.stop);

    expect(
      () => StoreInstanceGuard.acquire(
        tempDir.path,
        log: logCapture,
        exclusive: false,
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('pgrep'),
        ),
      ),
    );
  });

  // 2026-09-06 (Fix 2, the 2026-09-06 project-required engineering log
  // (internal)): [StoreInstanceGuard.acquire]'s startup peer-detection log
  // is now mode-aware — gated mode logs INFO ("expected"), everything else
  // keeps the WARN but with corrected advice.
  test(
    'acquire() with mode=gated logs the peer detection at INFO with '
    '"expected" wording, not WARN',
    () async {
      final peer = await _Peer.spawn(
        tempDir.path,
        'test/helpers/hold_shared_lock.dart',
      );
      addTearDown(peer.stop);

      final guard = StoreInstanceGuard.acquire(
        tempDir.path,
        log: logCapture,
        exclusive: false,
        mode: StoreMode.gated,
      );
      addTearDown(() => guard.release(log: logCapture));

      expect(
        logLines.any(
          (l) =>
              l.contains('[instance-guard] INFO') &&
              l.contains('expected in gated mode'),
        ),
        isTrue,
        reason:
            'gated mode: peer attachment is expected — INFO, not WARN: '
            '$logLines',
      );
      expect(
        logLines.any((l) => l.contains('[instance-guard] WARN')),
        isFalse,
        reason: 'gated mode must not also log the persistent-mode WARN: '
            '$logLines',
      );
    },
  );

  test(
    'acquire() with mode=persistent (or omitted) still logs the peer '
    'detection at WARN, with corrected advice (no more recommending '
    'OBX_MEMORY_EXCLUSIVE=true as THE fix)',
    () async {
      final peer = await _Peer.spawn(
        tempDir.path,
        'test/helpers/hold_shared_lock.dart',
      );
      addTearDown(peer.stop);

      final guard = StoreInstanceGuard.acquire(
        tempDir.path,
        log: logCapture,
        exclusive: false,
        mode: StoreMode.persistent,
      );
      addTearDown(() => guard.release(log: logCapture));

      final warnLine = logLines.firstWhere(
        (l) => l.contains('[instance-guard] WARN'),
        orElse: () => '',
      );
      expect(
        warnLine,
        isNotEmpty,
        reason: 'persistent mode must still WARN: $logLines',
      );
      expect(
        warnLine,
        isNot(
          contains('set OBX_MEMORY_EXCLUSIVE=true on one instance to prevent it'),
        ),
        reason:
            '2026-09-06 (Fix 2): the old wrong recommendation ("set this '
            'to prevent it") must be gone — it only makes the SECOND '
            'process refuse to start, it does not resolve concurrency',
      );
      expect(
        warnLine,
        contains('gated mode'),
        reason: 'the corrected advice must offer gated mode as the fix',
      );
    },
  );

  test('a write-tool result carries the guard-peer warning when a peer is '
      'attached', () async {
    final store = openStore(directory: tempDir.path);
    final syncClient = SyncClient(
      store,
      [localActivationSyncUrl],
      [SyncCredentials.none()],
    )..start();
    final embedder = FakeEmbedder();
    final guard = StoreInstanceGuard.acquire(
      tempDir.path,
      log: logCapture,
      exclusive: false,
    );
    final gate = await StoreGate.persistent(
      store: store,
      syncClient: syncClient,
      storeDirectory: tempDir.path,
      log: logCapture,
    );
    final service = MemoryService(
      gate: gate,
      embedder: embedder,
      log: logCapture,
      guard: guard,
    );
    addTearDown(() async {
      await service.dispose();
      await gate.close();
      guard.release(log: logCapture);
    });

    final peer = await _Peer.spawn(
      tempDir.path,
      'test/helpers/hold_shared_lock.dart',
    );
    addTearDown(peer.stop);

    final result = await service.remember(
      text: 'some test memory text',
      project: 'test',
    );
    expect(result['warning'], isNotNull);
    expect(result['warning'] as String, contains('Another RememBox process'));
  });

  test('remember() dedup early-return still carries the guard-peer warning '
      'when a peer is attached', () async {
    final store = openStore(directory: tempDir.path);
    final syncClient = SyncClient(
      store,
      [localActivationSyncUrl],
      [SyncCredentials.none()],
    )..start();
    final embedder = FakeEmbedder();
    final guard = StoreInstanceGuard.acquire(
      tempDir.path,
      log: logCapture,
      exclusive: false,
    );
    final gate = await StoreGate.persistent(
      store: store,
      syncClient: syncClient,
      storeDirectory: tempDir.path,
      log: logCapture,
    );
    final service = MemoryService(
      gate: gate,
      embedder: embedder,
      log: logCapture,
      guard: guard,
    );
    addTearDown(() async {
      await service.dispose();
      await gate.close();
      guard.release(log: logCapture);
    });

    final peer = await _Peer.spawn(
      tempDir.path,
      'test/helpers/hold_shared_lock.dart',
    );
    addTearDown(peer.stop);

    // First remember() creates the entry; second is the duplicate-content
    // early return (memory_service.dart's remember(), the `txResult is
    // MemoryEntry` branch) — that early return must also carry the
    // guard-peer warning, not just the main return site.
    await service.remember(
      text: 'duplicate-detection warning coverage text',
      project: 'test',
    );
    final result = await service.remember(
      text: 'duplicate-detection warning coverage text',
      project: 'test',
    );
    expect(result['duplicate'], isTrue);
    expect(result['warning'], isNotNull);
    expect(result['warning'] as String, contains('Another RememBox process'));
  });

  test('supersede() result carries the guard-peer warning exactly once when '
      'a peer is attached', () async {
    final store = openStore(directory: tempDir.path);
    final syncClient = SyncClient(
      store,
      [localActivationSyncUrl],
      [SyncCredentials.none()],
    )..start();
    final embedder = FakeEmbedder();
    final guard = StoreInstanceGuard.acquire(
      tempDir.path,
      log: logCapture,
      exclusive: false,
    );
    final gate = await StoreGate.persistent(
      store: store,
      syncClient: syncClient,
      storeDirectory: tempDir.path,
      log: logCapture,
    );
    final service = MemoryService(
      gate: gate,
      embedder: embedder,
      log: logCapture,
      guard: guard,
    );
    addTearDown(() async {
      await service.dispose();
      await gate.close();
      guard.release(log: logCapture);
    });

    final rememberResult = await service.remember(
      text: 'original entry text for supersede warning test',
      project: 'test',
    );
    final oldId = rememberResult['id'] as int;

    final peer = await _Peer.spawn(
      tempDir.path,
      'test/helpers/hold_shared_lock.dart',
    );
    addTearDown(peer.stop);

    final result = await service.supersede(
      oldId,
      text: 'replacement entry text for supersede warning test',
    );
    expect(result['warning'], isNotNull);
    final warning = result['warning'] as String;
    expect(warning, contains('Another RememBox process'));
    // supersede() must not double-append: it copies remember()'s warning and
    // must NOT also do its own peersPresent() check + append (that would put
    // the message in the string twice).
    final occurrences = RegExp(
      RegExp.escape('Another RememBox process'),
    ).allMatches(warning).length;
    expect(
      occurrences,
      1,
      reason: 'supersede() result must carry the guard warning exactly once, '
          'got: $warning',
    );
  });

  // 2026-09-06 (Fix 2): the gated-mode counterpart of the three tests
  // above — same peer-attached setup, but `gate.mode == StoreMode.gated`,
  // where several attached processes are the DESIGN (Store-Gate serializes
  // every call on store.lock). The write-tool result must carry NO
  // warning; the situation must still be observable via one INFO log line
  // (never a silent drop).
  test(
    'gated mode: a write-tool result carries NO warning when a peer is '
    'attached, and the situation is logged at INFO instead',
    () async {
      final peer = await _Peer.spawn(
        tempDir.path,
        'test/helpers/hold_shared_lock.dart',
      );
      addTearDown(peer.stop);

      final guard = StoreInstanceGuard.acquire(
        tempDir.path,
        log: logCapture,
        exclusive: false,
        mode: StoreMode.gated,
      );
      final gate = await StoreGate.gated(
        storeDirectory: tempDir.path,
        log: logCapture,
      );
      final embedder = FakeEmbedder();
      final service = MemoryService(
        gate: gate,
        embedder: embedder,
        log: logCapture,
        guard: guard,
      );
      addTearDown(() async {
        await service.dispose();
        await gate.close();
        guard.release(log: logCapture);
      });

      final result = await service.remember(
        text: 'gated mode peer warning suppression text',
        project: 'test',
      );
      expect(
        result.containsKey('warning'),
        isFalse,
        reason:
            'gated mode: a peer is expected (Store-Gate serializes every '
            'tool call on store.lock) — the result must carry no '
            'result-level warning: $result',
      );
      expect(
        logLines.any(
          (l) =>
              l.contains('[guard]') && l.contains('expected in gated mode'),
        ),
        isTrue,
        reason:
            'the peer must still be observable via one INFO log line, '
            'even though the result carries no warning (never a silent '
            'drop): $logLines',
      );
    },
  );
}
