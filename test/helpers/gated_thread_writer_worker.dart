/// Standalone worker (NOT a test-framework file, same convention as
/// gated_fact_writer_worker.dart): opens a GATED [StoreGate] against
/// `args[0]` (storeDir) and runs `thread_update` calls on ONE thread title
/// shared with every other worker against the same store directory,
/// appending one JSON line per call to its ledger (`args[2]`), then
/// reports `DONE` on stdout and exits 0.
///
/// Modes:
/// - `storeDir count ledger workerId`: `count` calls of `thread_update`
///   with title "shared thread", state inProgress for even i and waiting
///   for odd i, idempotency key `workerId-i`.
/// - `storeDir replay ledger workerId i`: repeats call `i` of worker
///   `workerId` with the same arguments (an idempotent replay).
///
/// Used by test/acceptance/multi_process_gated_test.dart (0.5.0 threads):
/// `thread_update` resolves the live thread by title and writes inside ONE
/// `store.lock`-guarded lending, so concurrent creates from several
/// processes must converge on exactly one thread – deterministic, not a
/// lucky schedule. Fatal on any failure, no `exit()` (see
/// gated_writer_worker.dart).
library;

import 'dart:convert';
import 'dart:io';

import 'package:remembox/src/memory_service.dart';
import 'package:remembox/src/model.dart';
import 'package:remembox/src/store_gate.dart';

import '../support/fake_embedder.dart';

const sharedThreadTitle = 'shared thread';
const sharedThreadProject = 'threads-acceptance';

String _stateFor(int i) =>
    i.isEven ? ThreadStates.inProgress : ThreadStates.waiting;

Future<void> main(List<String> args) async {
  final storeDir = args[0];
  final replay = args[1] == 'replay';
  final ledgerPath = args[2];
  final workerId = args[3];
  void log(String m) => stderr.writeln('[thread-worker $workerId] $m');
  final indices = replay
      ? [int.parse(args[4])]
      : [for (var i = 0; i < int.parse(args[1]); i++) i];

  final gate = await StoreGate.gated(storeDirectory: storeDir, log: log);
  final service = MemoryService(
    gate: gate,
    embedder: FakeEmbedder(),
    log: log,
  );
  final ledger = File(ledgerPath).openWrite();
  var fatal = false;
  try {
    for (final i in indices) {
      final Map<String, Object?> result;
      try {
        result = await service.threadUpdate(
          title: sharedThreadTitle,
          project: sharedThreadProject,
          state: _stateFor(i),
          idempotencyKey: '$workerId-$i',
        );
      } catch (err, stack) {
        log('FATAL: thread_update #$i threw: $err\n$stack');
        fatal = true;
        break;
      }
      ledger.writeln(
        jsonEncode({
          'workerId': workerId,
          'seq': i,
          'threadId': result['threadId'],
          'action': result['action'],
          'requested': _stateFor(i),
          'state': result['state'],
          'version': result['version'],
          'replayed': result['replayed'] == true,
        }),
      );
    }
  } finally {
    await ledger.close();
    await service.dispose();
    await gate.close();
  }
  if (fatal) {
    exitCode = 1;
    return;
  }
  stdout.writeln('DONE');
  await stdout.flush();
}
