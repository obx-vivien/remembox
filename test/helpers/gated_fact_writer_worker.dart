/// Standalone worker (NOT a test-framework file, same convention as
/// gated_writer_worker.dart): opens a [StoreGate] in GATED mode against
/// `args[0]` (storeDir), performs `args[1]` (ownCount) `fact_set()` calls
/// on globally-unique keys (one per call) followed by `args[2]`
/// (sharedCount) `fact_set()` calls on ONE key shared with every other
/// worker run against the same store directory, appends one JSON line per
/// call to `args[3]` (its own ground-truth ledger file), then reports
/// `DONE` on stdout and exits 0.
///
/// Used by test/acceptance/multi_process_gated_test.dart (WP6, plan §5 /
/// addendum): N of these processes run concurrently against the SAME
/// store directory. `fact_set`'s own-key writes exercise the same
/// per-call `store.lock` serialization the entry-writer acceptance test
/// already covers, applied to the facts write path instead of `remember`.
/// The shared-key writes are the actual point: `MemoryService.factSet`
/// reads "the current row for this key" and writes a replacement inside
/// ONE `store.lock`-guarded lending (`StoreGate.withStore` is held for the
/// FULL call, not just the transaction – see store_gate.dart), so two
/// `fact_set` calls on the same key from different processes can never
/// interleave: whichever call the OS schedules second always sees the
/// first call's write as "the current row" and closes it. That is what
/// makes "exactly one current row survives, with a consistent
/// closed -> current chain" a deterministic property of gated mode rather
/// than something that merely happens to pass under a lucky schedule (repo
/// rule: acceptance tests must not depend on a race).
///
/// Same fatal-on-any-failure and no-`exit()` discipline as
/// gated_writer_worker.dart – see that file's doc comment for the
/// reasoning (a worker that silently drops a write defeats the harness; a
/// forceful `exit()` can race the OS pipe delivery of the final `DONE`
/// line).
library;

import 'dart:convert';
import 'dart:io';

import 'package:remembox/src/memory_service.dart';
import 'package:remembox/src/store_gate.dart';

import '../support/fake_embedder.dart';

/// Fixed across every worker instance and every acceptance-test run – the
/// shared key all workers contend on. Deliberately not derived from
/// arguments: it must be IDENTICAL across processes for the shared-key
/// contention to actually happen.
const _sharedProject = 'wp6-facts-acceptance';
const _sharedSubject = 'shared-counter';
const _sharedAttribute = 'value';

Future<void> main(List<String> args) async {
  final storeDir = args[0];
  final ownCount = int.parse(args[1]);
  final sharedCount = int.parse(args[2]);
  final logPath = args[3];
  final workerId = args[4];
  void log(String m) => stderr.writeln('[fact-worker $workerId] $m');

  final gate = await StoreGate.gated(storeDirectory: storeDir, log: log);
  // No real Ollama round trip needed: fact_set never embeds (facts have no
  // vector – see docs/architecture.md, "Areas and facts (0.3.0)").
  final embedder = FakeEmbedder();
  final service = MemoryService(gate: gate, embedder: embedder, log: log);
  final ledger = File(logPath).openWrite();
  var fatal = false;
  try {
    for (var i = 0; i < ownCount; i++) {
      final Map<String, Object?> result;
      try {
        result = await service.factSet(
          subject: 'worker-$workerId-item-$i',
          attribute: 'value',
          project: _sharedProject,
          valueText: 'own value from worker=$workerId seq=$i',
        );
      } catch (err, stack) {
        log('FATAL: own-key fact_set #$i threw: $err\n$stack');
        fatal = true;
        break;
      }
      ledger.writeln(
        jsonEncode({
          'type': 'own',
          'workerId': workerId,
          'seq': i,
          'id': result['id'],
          'action': result['action'],
        }),
      );
    }
    if (!fatal) {
      for (var i = 0; i < sharedCount; i++) {
        final Map<String, Object?> result;
        try {
          result = await service.factSet(
            subject: _sharedSubject,
            attribute: _sharedAttribute,
            project: _sharedProject,
            // Encodes workerId+seq into the value so the reader can trace
            // which call produced which row without a second lookup –
            // uniqueness here also guarantees fact_set never takes the
            // "identical value, no-op" branch by accident.
            valueText: 'worker=$workerId seq=$i',
          );
        } catch (err, stack) {
          log('FATAL: shared-key fact_set #$i threw: $err\n$stack');
          fatal = true;
          break;
        }
        ledger.writeln(
          jsonEncode({
            'type': 'shared',
            'workerId': workerId,
            'seq': i,
            'id': result['id'],
            'action': result['action'],
            'closedId': result['closedId'],
            'closedIds': result['closedIds'],
          }),
        );
      }
    }
  } finally {
    await ledger.close();
    await gate.close();
  }
  if (fatal) {
    exitCode = 1;
    return;
  }
  stdout.writeln('DONE');
  await stdout.flush();
}
