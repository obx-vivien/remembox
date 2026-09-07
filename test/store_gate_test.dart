/// Pins [StoreGate] (lib/src/store_gate.dart, 2026-09-01 Store-Gate feature,
/// the 2026-09-01 store-gate engineering log (internal)) — the core WP2
/// machinery, tested independently of [MemoryService]'s handler
/// restructuring (that lives in
/// memory_service_test.dart, unchanged in spirit).
///
/// Tests that need a genuine second OS process (mode-coexistence, kill -9
/// recovery) spawn real processes via test/helpers/hold_store_lock.dart —
/// same rationale test/instance_guard_test.dart's own doc comment gives:
/// fcntl locks are (process, inode)-scoped, so an in-process-only test
/// cannot prove anything about cross-process behavior.
library;

import 'dart:convert';
import 'dart:io';

import 'package:remembox/src/memory_service.dart';
import 'package:remembox/src/model.dart';
import 'package:remembox/src/store_gate.dart';
import 'package:test/test.dart';

import 'helpers/test_store_gate.dart';
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

  /// Kills this peer with NO cooperation — used by the kill-9 recovery
  /// test, which is specifically about proving the kernel drops the fcntl
  /// lock even though the dying process never runs its own cleanup.
  void kill9() => process.kill(ProcessSignal.sigkill);
}

void main() {
  late Directory tempDir;
  late List<String> logLines;

  void logCapture(String line) => logLines.add(line);

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('remembox_gate_test_');
    logLines = [];
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  group('StoreSession', () {
    test('bundles all five boxes against the same store', () async {
      final testGate = await openTestGate(tempDir.path, log: logCapture);
      final session = StoreSession(testGate.store);
      expect(session.store, same(testGate.store));
      expect(session.entries.count(), 0);
      expect(session.tags.count(), 0);
      expect(session.docs.count(), 0);
      expect(session.links.count(), 0);
      expect(session.index.count(), 0);
      await testGate.close();
    });
  });

  group('withStore lifecycle', () {
    test(
      'releases the lending after a throwing body (finally path) — a '
      'subsequent call still succeeds',
      () async {
        final gate = await StoreGate.gated(
          storeDirectory: tempDir.path,
          log: logCapture,
        );
        addTearDown(gate.close);
        await expectLater(
          gate.withStore('x', (_) => throw StateError('boom')),
          throwsA(isA<StateError>()),
        );
        final result = await gate.withStore(
          'y',
          (session) => session.entries.count(),
        );
        expect(
          result,
          0,
          reason:
              'a fresh withStore call after a throwing one must still '
              'succeed — proves the finally path released the lock/session',
        );
      },
    );

    test(
      'throws immediately (not a hang/deadlock) on same-call-stack '
      're-entrancy',
      () async {
        final gate = await StoreGate.gated(
          storeDirectory: tempDir.path,
          log: logCapture,
        );
        addTearDown(gate.close);
        final stopwatch = Stopwatch()..start();
        await expectLater(
          gate.withStore(
            'outer',
            (session) => gate.withStore('inner', (session2) => 1),
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('re-entrant'),
            ),
          ),
        );
        expect(
          stopwatch.elapsed,
          lessThan(const Duration(seconds: 2)),
          reason:
              'a bounded wall-clock check — not just throwsA — is required '
              'here: a regression that reintroduces the nested-lock '
              'deadlock (§14 BLOCKER-2) would otherwise hang the test '
              'instead of failing loudly',
        );
      },
    );

    test(
      'two SEQUENTIAL (not nested) top-level calls do NOT spuriously '
      'throw re-entrancy — only true nesting on the same call stack does',
      () async {
        final gate = await StoreGate.gated(
          storeDirectory: tempDir.path,
          log: logCapture,
        );
        addTearDown(gate.close);
        // Fire two independent withStore calls without awaiting the first
        // — they queue on the intra-process chain, which is normal,
        // expected operation (e.g. a tool call and, independently, a
        // sweep batch), not nesting.
        final first = gate.withStore(
          'first',
          (session) => session.entries.count(),
        );
        final second = gate.withStore(
          'second',
          (session) => session.entries.count(),
        );
        final results = await Future.wait([first, second]);
        expect(results, [0, 0]);
      },
    );

    test('withStore throws after close()', () async {
      final gate = await StoreGate.gated(
        storeDirectory: tempDir.path,
        log: logCapture,
      );
      await gate.close();
      await expectLater(
        gate.withStore('after-close', (session) => 1),
        throwsA(isA<StateError>()),
      );
    });

    test(
      'a failing gated store-open releases store.lock instead of leaking '
      'it (review fix 2026-09-01) — proven by a SECOND process acquiring '
      'the lock afterwards',
      () async {
        final gate = await StoreGate.gated(
          storeDirectory: tempDir.path,
          log: logCapture,
        );
        addTearDown(gate.close);
        // Sabotage: strip all permissions from the store directory so
        // openMemoryStore throws AFTER the OS lock was acquired inside
        // _acquireSession. The store.lock file handle itself was opened at
        // construction, before the sabotage, so only the store open fails.
        await Process.run('chmod', ['000', tempDir.path]);
        addTearDown(() => Process.run('chmod', ['755', tempDir.path]));
        await expectLater(
          gate.withStore('sabotaged', (session) => session.entries.count()),
          throwsA(anything),
        );
        expect(
          logLines.any(
            (l) => l.contains('failed to open the store/sync client'),
          ),
          isTrue,
          reason:
              'the failure must be logged with the release action, not '
              'swallowed (repo no-silent-failure contract): $logLines',
        );
        await Process.run('chmod', ['755', tempDir.path]);
        // Cross-process proof: fcntl locks are (process, inode)-scoped, so
        // a SAME-process re-acquire would succeed even if the lock had
        // leaked — only a genuinely different process can prove release.
        // _Peer.spawn fails the test if the peer cannot report LOCK_HELD.
        final peer = await _Peer.spawn(
          tempDir.path,
          'test/helpers/hold_store_lock.dart',
        );
        await peer.stop();
      },
    );

    test(
      'close() lets an in-flight lending finish instead of yanking the '
      'lock handle out from under it (review fix 2026-09-01)',
      () async {
        final gate = await StoreGate.gated(
          storeDirectory: tempDir.path,
          log: logCapture,
        );
        final inFlight = gate.withStore('slow-lending', (session) async {
          await Future<void>.delayed(const Duration(milliseconds: 150));
          return session.entries.count();
        });
        final closing = gate.close();
        expect(
          await inFlight,
          0,
          reason:
              'a lending already queued when close() was called must '
              'complete normally — close() drains the FIFO chain before '
              'releasing/closing the store.lock handle',
        );
        await closing;
        await expectLater(
          gate.withStore('after-close', (session) => 1),
          throwsA(isA<StateError>()),
        );
      },
    );

    test('close() is safe to call twice (logs, does not throw)', () async {
      final gate = await StoreGate.gated(
        storeDirectory: tempDir.path,
        log: logCapture,
      );
      await gate.close();
      await gate.close();
      expect(
        logLines.any((l) => l.contains('close() called twice')),
        isTrue,
        reason: 'the second close() must be logged, not silently ignored',
      );
    });
  });

  group('wait/hold logging', () {
    test(
      'logs "[gate] <op> wait=Nms hold=Nms" on a normal completion',
      () async {
        final gate = await StoreGate.gated(
          storeDirectory: tempDir.path,
          log: logCapture,
        );
        addTearDown(gate.close);
        await gate.withStore('probe-op', (session) async {
          await Future<void>.delayed(const Duration(milliseconds: 5));
          return session.entries.count();
        });
        final line = logLines.firstWhere(
          (l) => l.startsWith('[gate] probe-op wait='),
          orElse: () => fail('no wait/hold line found: $logLines'),
        );
        expect(line, matches(RegExp(r'^\[gate\] probe-op wait=\d+ms hold=\d+ms$')));
      },
    );

    test('upgrades to a WARN line once wait exceeds waitWarnThreshold', () async {
      final gate = await StoreGate.gated(
        storeDirectory: tempDir.path,
        log: logCapture,
        // Zero threshold: even the fastest real call's wait/hold time (>=
        // 0ms, effectively always measurable as >0 given real syscalls)
        // deterministically trips the WARN path without needing genuine
        // cross-process contention (which same-process fcntl semantics
        // cannot reproduce in-process anyway — see store_gate.dart's own
        // doc on why self-conflict never blocks).
        waitWarnThreshold: Duration.zero,
      );
      addTearDown(gate.close);
      await gate.withStore('warn-op', (session) => session.entries.count());
      expect(
        logLines.any(
          (l) =>
              l.contains('WARN') &&
              l.contains('warn-op') &&
              l.contains('exceeded'),
        ),
        isTrue,
        reason: 'expected a WARN line above the (zero) threshold: $logLines',
      );
    });
  });

  group('embed-outside-lock invariant (WP4)', () {
    test(
      'embedder.embed() observes debugLendingOpen == false while '
      "remember()'s index write is happening",
      () async {
        final testGate = await openTestGate(tempDir.path, log: logCapture);
        addTearDown(testGate.close);
        var embedCalls = 0;
        final embedder = FakeEmbedder(
          onEmbed: () {
            embedCalls++;
            expect(
              testGate.gate.debugLendingOpen,
              isFalse,
              reason:
                  'embed() must NEVER run while a StoreGate lending is '
                  'open — a regression here would silently reintroduce '
                  'per-request latency/serialization the plan explicitly '
                  'requires embedding to stay outside (WP4)',
            );
          },
        );
        final service = MemoryService(
          gate: testGate.gate,
          embedder: embedder,
          log: logCapture,
        );
        addTearDown(service.dispose);
        final result = await service.remember(
          text: 'embed outside lock probe',
          project: 'test',
        );
        expect(result['indexed'], isTrue);
        expect(embedCalls, 1);
      },
    );

    test(
      'reindex() embeds strictly outside the lending, across a batch '
      'boundary (>50 entries — the batched path the plan flags as risky)',
      () async {
        final testGate = await openTestGate(tempDir.path, log: logCapture);
        addTearDown(testGate.close);
        final embedder = FakeEmbedder();
        final service = MemoryService(
          gate: testGate.gate,
          embedder: embedder,
          log: logCapture,
        );
        addTearDown(service.dispose);
        // 55 > _reindexBatchSize (50): forces reindex through TWO
        // scan/embed/write batch cycles, not just one.
        const entryCount = 55;
        for (var i = 0; i < entryCount; i++) {
          await service.remember(
            text: 'reindex batch probe $i',
            project: 'test',
          );
        }
        // Wipe every index row so reindex must re-create all of them.
        testGate.store.box<MemoryIndex>().removeAll();
        embedder.calls.clear();
        // Violations are COLLECTED, not expect()ed inside the hook: a
        // TestFailure thrown mid-reindex would surface as a confusing
        // reindex error instead of a clear assertion at the end.
        final violations = <String>[];
        embedder.onEmbed = () {
          if (testGate.gate.debugLendingOpen) {
            violations.add('embed ran inside an open lending');
          }
        };
        final run = await service.reindex();
        expect(run['created'], entryCount);
        expect(embedder.calls.length, entryCount);
        expect(
          violations,
          isEmpty,
          reason:
              'no reindex embed may run while a StoreGate lending is open '
              '(WP4) — in gated mode that would hold store.lock across '
              'Ollama I/O and block every other process',
        );
      },
    );

    test(
      'the observer sweep embeds strictly outside the lending',
      () async {
        final testGate = await openTestGate(tempDir.path, log: logCapture);
        addTearDown(testGate.close);
        final violations = <String>[];
        final embedder = FakeEmbedder();
        final service = MemoryService(
          gate: testGate.gate,
          embedder: embedder,
          log: logCapture,
        );
        addTearDown(service.dispose);
        embedder.onEmbed = () {
          if (testGate.gate.debugLendingOpen) {
            violations.add('embed ran inside an open lending');
          }
        };
        service.startIndexWatcher(debounce: const Duration(milliseconds: 50));
        // Simulate a sync arrival: direct box put, bypassing remember(),
        // so ONLY the watcher sweep can index it (same pattern as
        // memory_service_test.dart's observer-driven indexing group).
        testGate.store.box<MemoryEntry>().put(
              MemoryEntry(
                title: 'sweep probe',
                text: 'sweep embed-outside-lock probe',
                kind: MemoryKind.fact,
                sourceType: MemorySource.chat,
                contentHash: MemoryService.contentHashOf(
                  'sweep embed-outside-lock probe',
                ),
              ),
            );
        // Poll (bounded) until the sweep has indexed it — a fixed sleep
        // would be flakier and slower.
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (testGate.store.box<MemoryIndex>().count() == 0) {
          if (DateTime.now().isAfter(deadline)) {
            fail(
              'observer sweep never indexed the raw-put entry within 5s: '
              '$logLines',
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(
          embedder.calls,
          contains('sweep embed-outside-lock probe'),
          reason: 'the sweep (not remember()) must have embedded the entry',
        );
        expect(
          violations,
          isEmpty,
          reason:
              'no sweep embed may run while a StoreGate lending is open '
              '(WP4/§14 MAJOR-2)',
        );
      },
    );
  });

  group('mode coexistence (§8)', () {
    test(
      "gated mode's startup probe fails fast (bounded, not a hang) beside "
      'a persistent peer, naming the conflict',
      () async {
        final peer = await _Peer.spawn(
          tempDir.path,
          'test/helpers/hold_store_lock.dart',
        );
        addTearDown(peer.stop);
        final stopwatch = Stopwatch()..start();
        await expectLater(
          StoreGate.gated(
            storeDirectory: tempDir.path,
            log: logCapture,
            startupProbeTimeout: const Duration(milliseconds: 300),
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('PERSISTENT'),
            ),
          ),
        );
        expect(
          stopwatch.elapsed,
          lessThan(const Duration(seconds: 2)),
          reason:
              'must fail within the bounded probe window, not merely '
              '"eventually" — a test that only checked throwsA without '
              'this wall-clock bound would not prove "fails fast"',
        );
      },
    );

    test(
      'a SECOND persistent-mode process against the same store directory '
      'fails at startup with an actionable error instead of silently '
      'coexisting (the pre-Store-Gate silent-write-loss configuration)',
      () async {
        final peer = await _Peer.spawn(
          tempDir.path,
          'test/helpers/hold_store_lock.dart',
        );
        addTearDown(peer.stop);
        // Platform.resolvedExecutable: the VM running this test — no PATH
        // dependency, same SDK as the test.
        final second = await Process.run(
          Platform.resolvedExecutable,
          ['run', 'test/helpers/hold_store_lock.dart', tempDir.path],
        );
        expect(
          second.exitCode,
          isNot(0),
          reason:
              'the second persistent process must refuse to start — '
              'tolerating it is exactly the two-writer configuration '
              'proven to silently lose rows (R2-6). stdout: '
              '${second.stdout}\nstderr: ${second.stderr}',
        );
        expect(
          second.stdout.toString(),
          isNot(contains('LOCK_HELD')),
          reason: 'it must never have acquired store.lock',
        );
        expect(
          second.stderr.toString(),
          contains('Could not acquire store.lock'),
          reason: 'the refusal must be loud and name the lock',
        );
      },
    );

    test(
      'kill -9 on a persistent lock holder releases store.lock with NO '
      'cooperation from the dying process — a gated startup probe then '
      'succeeds promptly',
      () async {
        final peer = await _Peer.spawn(
          tempDir.path,
          'test/helpers/hold_store_lock.dart',
        );
        // Deliberately no addTearDown(peer.stop) — SIGKILL below is the
        // point of this test, not a normal shutdown.
        peer.kill9();
        // SIGKILL is asynchronous from this process's perspective; give
        // the kernel a brief moment to actually reap the process and drop
        // its fcntl locks before probing.
        await Future<void>.delayed(const Duration(milliseconds: 300));
        final stopwatch = Stopwatch()..start();
        final gate = await StoreGate.gated(
          storeDirectory: tempDir.path,
          log: logCapture,
          startupProbeTimeout: const Duration(seconds: 3),
        );
        expect(
          stopwatch.elapsed,
          lessThan(const Duration(seconds: 3)),
          reason:
              'the lock must already be free (kernel-released on process '
              'death) — this should succeed on the FIRST probe attempt, '
              'well under the full timeout budget',
        );
        await gate.close();
      },
    );
  });

  group('F6 timing measurement (recorded in the internal engineering log)', () {
    test(
      'persistent-mode withStore stays near-zero cost across many calls; '
      'gated mode pays real per-call Store+SyncClient open/close overhead',
      () async {
        const iterations = 20;
        final testGate = await openTestGate(tempDir.path, log: (_) {});
        final persistentStopwatch = Stopwatch()..start();
        for (var i = 0; i < iterations; i++) {
          await testGate.gate.withStore(
            'p$i',
            (session) => session.entries.count(),
          );
        }
        persistentStopwatch.stop();
        await testGate.close();

        final gatedDir = Directory.systemTemp.createTempSync(
          'remembox_gate_timing_',
        );
        addTearDown(() => gatedDir.deleteSync(recursive: true));
        final gatedGate = await StoreGate.gated(
          storeDirectory: gatedDir.path,
          log: (_) {},
        );
        final gatedStopwatch = Stopwatch()..start();
        for (var i = 0; i < iterations; i++) {
          await gatedGate.withStore('g$i', (session) => session.entries.count());
        }
        gatedStopwatch.stop();
        await gatedGate.close();

        final persistentPerCallUs =
            persistentStopwatch.elapsedMicroseconds / iterations;
        final gatedPerCallUs = gatedStopwatch.elapsedMicroseconds / iterations;
        // Printed (not just asserted) so the actual numbers are captured
        // for the 2026-09-01 store-gate engineering log (internal)'s "What
        // was measured" section (plan §13 item 2).
        // ignore: avoid_print
        print(
          '[F6 timing] persistent: ${persistentStopwatch.elapsedMicroseconds}us '
          'total / $iterations calls (${persistentPerCallUs.toStringAsFixed(1)}'
          'us/call); gated: ${gatedStopwatch.elapsedMicroseconds}us total / '
          '$iterations calls (${gatedPerCallUs.toStringAsFixed(1)}us/call)',
        );
        expect(
          gatedStopwatch.elapsedMicroseconds,
          greaterThan(persistentStopwatch.elapsedMicroseconds),
          reason:
              "gated mode's real per-call Store+SyncClient open/close must "
              'cost measurably more than persistent mode reusing one '
              'already-open session',
        );
      },
    );
  });

  group('no entity survives its lending (§14 MINOR)', () {
    test(
      'a COLD (never-resolved) lazy relation on an entity fetched inside '
      'a lending throws a CLEAN Dart exception once the lending has '
      'closed — never an opaque native crash',
      () async {
        final gate = await StoreGate.gated(
          storeDirectory: tempDir.path,
          log: logCapture,
        );
        addTearDown(gate.close);
        final entryId = await gate.withStore('setup', (session) {
          final tag = Tag(name: 'probe-tag');
          final tagId = session.tags.put(tag);
          final entry = MemoryEntry(
            title: 't',
            text: 'probe',
            kind: MemoryKind.fact,
            sourceType: MemorySource.note,
            contentHash: 'probe-hash',
          );
          final id = session.entries.put(entry);
          final fresh = session.entries.get(id)!;
          fresh.tags.add(session.tags.get(tagId)!);
          fresh.tags.applyToDb();
          return id;
        });
        // Fetch the entry in its OWN lending, deliberately WITHOUT
        // touching .tags (keeps the relation cold/unresolved) — gated
        // mode's store genuinely closes once this call returns.
        final detachedEntry = await gate.withStore(
          'fetch',
          (session) => session.entries.get(entryId)!,
        );
        expect(
          () => detachedEntry.tags.length,
          throwsA(isA<Exception>()),
          reason:
              'touching a cold relation after the owning lending has '
              'closed must throw a catchable exception (verified: '
              'ObjectBoxException), never crash the process — this is the '
              'concrete backing for this file\'s own INVARIANT doc comment',
        );
      },
    );
  });
}
