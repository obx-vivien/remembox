/// WP6 headline acceptance harness (2026-09-01, Store-Gate feature, the
/// 2026-09-01 store-gate engineering log (internal), plan §6/§14 MAJOR-7):
/// "the actual deliverable" per the task spec.
///
/// Spawns N real OS processes (test/helpers/gated_writer_worker.dart), each
/// writing M globally-unique entries through GATED mode against the SAME
/// store directory, then verifies (via a THIRD fresh process,
/// test/helpers/count_entries_worker.dart — proving cross-process
/// correctness, not just in-isolate bookkeeping) that exactly N*M rows
/// survive.
///
/// Includes the mandatory NEGATIVE CONTROL (§14 MAJOR-7): the identical
/// N*M shape run WITHOUT any StoreGate coordination
/// (test/helpers/ungated_writer_worker.dart), which is expected to LOSE
/// rows — this is what proves the harness is capable of reproducing the
/// documented R2-6 failure (85+85 puts -> 103 survivors) at all. Without
/// this control, 170/170 passing for the wrong reason (e.g. workers
/// accidentally serializing on something else, or a silently-failed
/// startup probe) would be indistinguishable from a genuine fix.
///
/// Real subprocess spawning is inherently slower than in-process tests —
/// explicit [Timeout] below rather than relying on the framework default
/// (§14 MINOR).
@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

// Platform.resolvedExecutable: the VM running this test — no PATH
// dependency, same SDK as the test.
// Must be `final`, not `const`: Platform.resolvedExecutable is a runtime
// value, not a compile-time constant.
final _dartExe = Platform.resolvedExecutable;

/// Native ObjectBox/libwebsockets log chatter from the reserved-port local-
/// activation sync client (see lib/src/store.dart's `startLocalActivation
/// SyncClient` doc) — observed DIRECTLY while building this harness to land
/// on the worker's STDOUT under gated mode's high per-call sync-client
/// churn (one real client per `withStore` call, vs. persistent mode's one
/// at startup), contradicting that doc comment's "does not affect stdout"
/// claim for this specific high-churn case. Filtered here the same way
/// this project's own test-running convention already filters it from
/// `dart test` output (see this task's own instructions / repo CLAUDE.md).
/// Flagged in the 2026-09-01 store-gate engineering log (internal) as a
/// discovered, unresolved discrepancy — not something this harness papers
/// over
/// silently.
final _nativeNoise = RegExp(r'Cl-Lws|LWS:|Connection mismatch');

class _WorkerRun {
  final String workerId;
  final int exitCode;
  final List<String> stdoutLines;
  final List<String> stderrLines;
  final List<Map<String, Object?>> ledger;

  _WorkerRun({
    required this.workerId,
    required this.exitCode,
    required this.stdoutLines,
    required this.stderrLines,
    required this.ledger,
  });
}

/// Spawns one worker script, waits for it to exit, and reads back its
/// ledger file. Fails loudly (not silently) on a non-zero exit or a
/// missing `DONE` — a worker that dies quietly would defeat the harness.
Future<_WorkerRun> _runWorker({
  required String script,
  required String storeDir,
  required int count,
  required String ledgerPath,
  required String workerId,
}) async {
  final proc = await Process.start(_dartExe, [
    'run',
    script,
    storeDir,
    '$count',
    ledgerPath,
    workerId,
  ]);
  final stdoutLines = <String>[];
  final stderrLines = <String>[];
  final stdoutDone = proc.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .forEach(stdoutLines.add);
  final stderrDone = proc.stderr
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .forEach(stderrLines.add);
  final exitCode = await proc.exitCode;
  await stdoutDone;
  await stderrDone;
  if (exitCode != 0) {
    fail(
      'worker $workerId ($script) exited $exitCode (expected 0).\n'
      'stdout: $stdoutLines\nstderr: $stderrLines',
    );
  }
  // 2026-09-01 finding (out of scope for this feature to fix at the root —
  // see the 2026-09-01 store-gate engineering log (internal), "Findings
  // outside this feature's scope"): the ObjectBox native library's own
  // sync-retry
  // chatter (matched by [_nativeNoise]) was observed landing on the SAME
  // fd 1 (stdout) our own `DONE` line uses, WITHOUT a guaranteed newline
  // boundary between them — under gated mode's heavy per-call
  // open/close/sync-client churn (this worker does that up to 85 times),
  // dart:io's LineSplitter can glue our `DONE` onto an adjacent native log
  // fragment into one merged line. A per-LINE filter-then-exact-match
  // (tried first) discards that merged line entirely, since it also
  // matches [_nativeNoise] — throwing the real signal away with the noise
  // it happened to stick to. A substring search over the RAW, unsplit
  // stdout text is immune to exactly where the line boundaries ended up.
  if (!stdoutLines.join('\n').contains('DONE')) {
    final meaningfulStdout = stdoutLines
        .where((l) => !_nativeNoise.hasMatch(l))
        .toList();
    fail(
      'worker $workerId ($script) never reported DONE on stdout — a '
      'worker that exits 0 without reporting done is itself a harness '
      'failure mode.\nstdout (raw): $stdoutLines\nstdout (filtered): '
      '$meaningfulStdout\nstderr: $stderrLines',
    );
  }
  final ledgerFile = File(ledgerPath);
  final lines =
      ledgerFile.existsSync() ? await ledgerFile.readAsLines() : <String>[];
  final ledger = [
    for (final line in lines)
      if (line.trim().isNotEmpty) jsonDecode(line) as Map<String, Object?>,
  ];
  return _WorkerRun(
    workerId: workerId,
    exitCode: exitCode,
    stdoutLines: stdoutLines,
    stderrLines: stderrLines,
    ledger: ledger,
  );
}

/// Spawns a THIRD, fresh process (not one of the writers) to count
/// surviving entries — a genuinely separate OS process is what actually
/// proves cross-process correctness (verifying in the SAME isolate as the
/// test would not).
Future<int> _countEntriesInFreshProcess(String storeDir) async {
  final proc = await Process.start(_dartExe, [
    'run',
    'test/helpers/count_entries_worker.dart',
    storeDir,
  ]);
  final stdout = await proc.stdout.transform(utf8.decoder).join();
  final stderrText = await proc.stderr.transform(utf8.decoder).join();
  final exitCode = await proc.exitCode;
  if (exitCode != 0) {
    fail(
      'count_entries_worker exited $exitCode.\nstdout: $stdout\n'
      'stderr: $stderrText',
    );
  }
  // 2026-09-01 finding (not a Store-Gate bug — pre-existing, orthogonal;
  // see the 2026-09-01 store-gate engineering log (internal), "Findings
  // outside this feature's scope"): the ObjectBox native library's own
  // sync-retry
  // chatter ("LWS: Connect failed", "Connection mismatch on destroy") was
  // observed landing on FILE DESCRIPTOR 1 (stdout), not stderr, for the
  // local-activation sync client every gated-mode open starts — CONTRARY
  // to store.dart's FIX-6 comment, which documents it as stderr-only and
  // therefore harmless to "stdout (the MCP channel)". That claim is
  // unverified for this exact reproduction and is flagged separately for
  // follow-up; it is out of scope to fix here. Concretely, this means
  // `count_entries_worker`'s stdout can contain a native log line AFTER
  // our own JSON line (arrives asynchronously, post-flush) — so instead of
  // trusting "the last non-empty line", find the line that actually
  // parses as our expected `{"count": N}` shape.
  Map<String, Object?>? parsed;
  for (final line in stdout.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || !trimmed.startsWith('{')) continue;
    try {
      final decoded = jsonDecode(trimmed) as Map<String, Object?>;
      if (decoded.containsKey('count')) {
        parsed = decoded;
        break;
      }
    } on FormatException {
      continue; // native log noise that happens to start with '{' — skip
    }
  }
  if (parsed == null) {
    fail(
      'count_entries_worker produced no line matching {"count": N} on '
      'stdout.\nstdout: $stdout\nstderr: $stderrText',
    );
  }
  return parsed['count'] as int;
}

Future<List<_WorkerRun>> _runGatedWorkers(
  String storeDir,
  int n,
  int m,
) async {
  return Future.wait([
    for (var i = 0; i < n; i++)
      _runWorker(
        script: 'test/helpers/gated_writer_worker.dart',
        storeDir: storeDir,
        count: m,
        ledgerPath: '$storeDir.ledger_$i.jsonl',
        workerId: 'w$i',
      ),
  ]);
}

void main() {
  group('multi-process gated-mode acceptance (WP6)', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync(
        'remembox_acceptance_gated_',
      );
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test(
      'DIRECT REPRO of the documented failure shape: 2 processes x 85 '
      'writes each through GATED mode -> exactly 170/170 rows survive '
      '(the original unguarded scenario lost 67: 85+85 puts, 103 '
      'survivors)',
      () async {
        const n = 2, m = 85;
        final runs = await _runGatedWorkers(tempDir.path, n, m);

        var totalLedgerRows = 0;
        for (final run in runs) {
          expect(
            run.ledger.length,
            m,
            reason:
                'worker ${run.workerId} must have logged exactly $m lines '
                'to its OWN ledger — a harness sanity check independent of '
                'the store itself',
          );
          expect(
            run.ledger.every((e) => e['duplicate'] == false),
            isTrue,
            reason:
                'every logged write must be duplicate=false (§14 MINOR) — '
                'a content-hash collision between workers would shrink the '
                'survivor count for a DIFFERENT reason than row loss, and '
                'the naive totalRows==n*m assertion below would not catch '
                'that distinction on its own: worker ${run.workerId} '
                'ledger=${run.ledger}',
          );
          totalLedgerRows += run.ledger.length;
        }
        expect(totalLedgerRows, n * m);

        final survivors = await _countEntriesInFreshProcess(tempDir.path);
        // ignore: avoid_print
        print(
          '[gated 2x85] ledger total=$totalLedgerRows, survivors=$survivors',
        );
        expect(
          survivors,
          n * m,
          reason:
              'gated mode must not lose any of the N*M writes each worker '
              'independently logged to its own ground-truth ledger',
        );
      },
    );

    test(
      'higher-concurrency case: 4 processes x 50 writes each through '
      'GATED mode -> exactly 200/200 rows survive',
      () async {
        const n = 4, m = 50;
        final runs = await _runGatedWorkers(tempDir.path, n, m);

        var totalLedgerRows = 0;
        for (final run in runs) {
          expect(run.ledger.length, m);
          expect(run.ledger.every((e) => e['duplicate'] == false), isTrue);
          totalLedgerRows += run.ledger.length;
        }
        expect(totalLedgerRows, n * m);

        final survivors = await _countEntriesInFreshProcess(tempDir.path);
        // ignore: avoid_print
        print(
          '[gated 4x50] ledger total=$totalLedgerRows, survivors=$survivors',
        );
        expect(survivors, n * m);
      },
    );
  });

  group('NEGATIVE CONTROL (§14 MAJOR-7) — proves the harness can actually '
      'reproduce the failure it claims to fix', () {
    late Directory controlDir;

    setUp(() {
      controlDir = Directory.systemTemp.createTempSync(
        'remembox_acceptance_control_',
      );
    });

    tearDown(() {
      controlDir.deleteSync(recursive: true);
    });

    test(
      'the SAME 2x85 shape with ZERO locking (raw openStore + raw box '
      'writes, no StoreGate/instances.lock/store.lock at all — exactly '
      "R2-6's original hand-probe methodology) loses rows",
      () async {
        const n = 2, m = 85;
        final runs = await Future.wait([
          for (var i = 0; i < n; i++)
            _runWorker(
              script: 'test/helpers/ungated_writer_worker.dart',
              storeDir: controlDir.path,
              count: m,
              ledgerPath: '${controlDir.path}.ledger_$i.jsonl',
              workerId: 'w$i',
            ),
        ]);

        var totalLedgerRows = 0;
        for (final run in runs) {
          totalLedgerRows += run.ledger.length;
        }
        final survivors = await _countEntriesInFreshProcess(controlDir.path);
        // Reported unconditionally — the control's row loss (or lack of
        // it) is itself evidence for the final report, not just an
        // internal sanity check to discard.
        // ignore: avoid_print
        print(
          '[CONTROL 2x85, no gate] ledger total=$totalLedgerRows, '
          'survivors=$survivors, lost=${totalLedgerRows - survivors}',
        );
        expect(
          survivors,
          lessThan(totalLedgerRows),
          reason:
              'the unguarded control MUST lose rows relative to what the '
              'workers logged, or this harness cannot be trusted to have '
              'detected the R2-6 hazard gated mode actually fixes — a '
              'harness bug (e.g. workers accidentally serializing on '
              'something else) could otherwise make the gated tests above '
              'pass for the wrong reason',
        );
      },
    );
  },
      // 2026-09-10: the negative control demonstrates a scheduling race, so
      // it is not deterministic by nature. On GitHub's hosted macOS runner
      // both unguarded writers happened to keep all 170 rows (the OS
      // serialized them), which would fail this assertion for the wrong
      // reason. It stays in every local run, where it has always reproduced
      // the loss; on CI only the positive guarantees above are checked.
      skip: Platform.environment.containsKey('CI')
          ? 'race demonstration, not deterministic on hosted CI runners – '
              'run locally'
          : false);
}
