/// Standalone worker (NOT a test-framework file, same convention as
/// hold_shared_lock.dart / hold_exclusive_lock.dart): opens a [StoreGate]
/// in GATED mode against `args[0]` (storeDir), performs `args[1]` (count)
/// `remember()` calls with deterministic, worker-tagged text, appends each
/// `{workerId, seq, entryId, duplicate}` record as one JSON line to
/// `args[2]` (its own ground-truth ledger file), then reports `DONE` on
/// stdout and exits 0.
///
/// Used by test/acceptance/multi_process_gated_test.dart (WP6, plan §6.2):
/// N of these processes run concurrently against the SAME store directory,
/// each writing M distinct entries; the acceptance test compares the sum
/// of every worker's ledger against a fresh third process's count of what
/// actually survived in the store.
///
/// Any `remember()` failure is FATAL (non-zero exit, error on stderr) — a
/// worker that silently drops a write would defeat the entire point of the
/// harness (repo rule: no silent failure paths).
///
/// Deliberately does NOT call `dart:io`'s `exit()` anywhere: `exit()`
/// terminates the isolate WITHOUT waiting for the event loop to drain,
/// which can race the OS pipe delivery of a just-flushed stdout line to
/// the parent process (observed directly: the final `DONE` line was
/// intermittently lost by the parent test's stdout listener when this
/// worker called `exit(0)` immediately after `stdout.flush()`). Instead,
/// fatal paths set `io.exitCode` (the non-forceful idiom — takes effect
/// once `main()` naturally returns) and return early; the success path
/// just falls off the end of `main()`. Nothing else in this script keeps
/// the event loop alive, so this exits promptly either way.
library;

import 'dart:convert';
import 'dart:io';

import 'package:remembox/src/memory_service.dart';
import 'package:remembox/src/store_gate.dart';

import '../support/fake_embedder.dart';

Future<void> main(List<String> args) async {
  final storeDir = args[0];
  final count = int.parse(args[1]);
  final logPath = args[2];
  final workerId = args[3];
  void log(String m) => stderr.writeln('[worker $workerId] $m');

  final gate = await StoreGate.gated(storeDirectory: storeDir, log: log);
  // Deterministic, no real Ollama round trip — the harness measures
  // store.lock correctness, not embedding.
  final embedder = FakeEmbedder();
  final service = MemoryService(gate: gate, embedder: embedder, log: log);
  final ledger = File(logPath).openWrite();
  var fatal = false;
  try {
    for (var i = 0; i < count; i++) {
      // workerId is embedded in the text itself, not just the ledger, so
      // every one of N*M entries is globally content-unique across ALL
      // workers — a content-hash collision between two DIFFERENT workers'
      // writes would silently look like "dedup" instead of the row-loss
      // bug this harness exists to catch.
      final text =
          'gated-harness worker=$workerId seq=$i '
          '${DateTime.now().toIso8601String()} ${_rand()}';
      final Map<String, Object?> result;
      try {
        result = await service.remember(text: text, project: 'test');
      } catch (err, stack) {
        log('FATAL: remember() #$i threw: $err\n$stack');
        fatal = true;
        break;
      }
      if (result['duplicate'] == true) {
        // Should never happen given the uniqueness above — fatal, not
        // silently counted as success, because a silent dedup would make
        // the harness under-report the true N*M expectation.
        log('FATAL: remember() #$i unexpectedly reported duplicate=true '
            '(text was supposed to be globally unique): $result');
        fatal = true;
        break;
      }
      ledger.writeln(
        jsonEncode({
          'workerId': workerId,
          'seq': i,
          'entryId': result['id'],
          'duplicate': result['duplicate'],
        }),
      );
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

int _counter = 0;
String _rand() => (_counter++).toString();
