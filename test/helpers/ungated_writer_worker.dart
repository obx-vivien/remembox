/// Standalone worker (NOT a test-framework file) — the NEGATIVE CONTROL
/// counterpart to gated_writer_worker.dart (2026-09-01, Store-Gate plan
/// §14 MAJOR-7): opens the store directly via `openMemoryStore`/
/// `startLocalActivationSyncClient` and writes rows straight through the
/// `MemoryEntry` box — bypassing `MemoryService`, and critically
/// bypassing `StoreGate` ENTIRELY, not just running it in "persistent
/// mode".
///
/// Why not just use `StoreGate.persistent` here (i.e. "gate: false"
/// wired through the normal API)? Tried first, and it does not reproduce
/// the hazard: `StoreGate.persistent` ALWAYS acquires `store.lock`
/// exclusively as part of this very feature, so two such processes
/// against the same directory don't silently interleave writes — the
/// SECOND process's `StoreGate.persistent()` call simply fails outright
/// (loud `StateError`, no data loss, wrong failure mode entirely). That
/// is store.lock correctly doing its job — but it means going through
/// `StoreGate` at all cannot serve as a control for "no coordination",
/// because `StoreGate` inherently coordinates. To reproduce the TRUE
/// historical R2-6 hazard (the 2026-07-06 engineering log, internal: two
/// independent `openStore()` calls against the same directory, no locking of
/// any
/// kind, concurrent raw writes silently interleaving with partial data
/// loss — the exact methodology `lib/src/store.dart`'s `openMemoryStore`
/// doc comment describes as "a hand probe"), this worker goes around
/// `StoreGate`/`MemoryService` completely.
///
/// Same worker contract as gated_writer_worker.dart otherwise: `args[1]`
/// (count) writes, ledger written to `args[2]`, `args[3]` is the worker
/// id, `DONE`/exit 0 on success.
///
/// This worker's PURPOSE is to lose rows under concurrency — that is the
/// point of a negative control, not a bug in the harness. Do not "fix" it
/// to go through StoreGate; that would defeat what it exists to prove.
library;

import 'dart:convert';
import 'dart:io';

import 'package:remembox/src/model.dart';
import 'package:remembox/src/store.dart';

Future<void> main(List<String> args) async {
  final storeDir = args[0];
  final count = int.parse(args[1]);
  final logPath = args[2];
  final workerId = args[3];
  void log(String m) => stderr.writeln('[ungated-worker $workerId] $m');

  // Raw open — NO store.lock, NO StoreGate, NO instance guard. Exactly two
  // (or more) of these running concurrently against the same directory is
  // precisely the scenario R2-6 documented as silently losing writes.
  final store = openMemoryStore(storeDir, log: log);
  final syncClient = startLocalActivationSyncClient(
    store,
    log: log,
    quiet: true,
  );
  final entries = store.box<MemoryEntry>();
  final ledger = File(logPath).openWrite();
  try {
    for (var i = 0; i < count; i++) {
      final contentHash = 'ungated-$workerId-$i';
      final entry = MemoryEntry(
        title: 'ungated $workerId #$i',
        text: 'ungated-harness worker=$workerId seq=$i '
            '${DateTime.now().toIso8601String()}',
        kind: MemoryKind.fact,
        sourceType: MemorySource.note,
        contentHash: contentHash,
      );
      int id;
      try {
        id = entries.put(entry);
      } catch (err, stack) {
        // Unlike the gated worker, a thrown error here is real signal
        // about the unguarded-concurrency hazard, not necessarily a
        // harness bug — log it and keep going so one hiccup doesn't
        // prevent observing the row-loss signal in the rest of the run;
        // the ledger's own count vs the fresh-process count is the source
        // of truth either way.
        log('put() #$i threw (may itself be evidence of the '
            'unguarded-concurrency hazard, not a harness bug): $err\n$stack');
        continue;
      }
      ledger.writeln(
        jsonEncode({
          'workerId': workerId,
          'seq': i,
          'entryId': id,
          'duplicate': false,
        }),
      );
    }
  } finally {
    await ledger.close();
    syncClient.close();
    store.close();
  }
  stdout.writeln('DONE');
  await stdout.flush();
  // Deliberately no exit(0) here — see gated_writer_worker.dart's doc
  // comment: exit() can race the OS pipe delivery of this just-flushed
  // line to the parent process. Nothing else keeps the event loop open,
  // so letting main() return exits promptly anyway.
}
