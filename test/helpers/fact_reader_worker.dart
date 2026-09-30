/// Standalone worker (NOT a test-framework file, same convention as
/// count_entries_worker.dart): opens a GATED [StoreGate] against `args[0]`
/// (storeDir) fresh, runs a `fact_query` for `args[1]` (project) with
/// `includeHistory: true`, prints the full result as ONE JSON line on
/// stdout, and exits 0.
///
/// Used by test/acceptance/multi_process_gated_test.dart (WP6): a THIRD,
/// fresh process (not one of the writers) is what actually proves
/// cross-process correctness – verifying in the same isolate as the test
/// would not exercise `store.lock`/the on-disk store at all, same
/// rationale as `count_entries_worker.dart`.
///
/// Goes through `MemoryService.factQuery` rather than a raw box query so
/// the reader sees the exact same `current`/history shape every fact tool
/// returns (WP3's `_factSummary`) instead of re-deriving it here and
/// risking the two definitions drifting apart.
library;

import 'dart:convert';
import 'dart:io';

import 'package:remembox/src/memory_service.dart';
import 'package:remembox/src/store_gate.dart';

import '../support/fake_embedder.dart';

Future<void> main(List<String> args) async {
  final storeDir = args[0];
  final project = args[1];
  final gate = await StoreGate.gated(
    storeDirectory: storeDir,
    log: (m) => stderr.writeln(m),
  );
  final service = MemoryService(
    gate: gate,
    embedder: FakeEmbedder(),
    log: (m) => stderr.writeln(m),
  );
  // limit high enough that a well-behaved run never truncates – the
  // acceptance test asserts truncated == false to catch it if it ever did.
  final result = await service.factQuery(
    project: project,
    includeHistory: true,
    limit: 2000,
  );
  await gate.close();
  stdout.writeln(jsonEncode(result));
  await stdout.flush();
  // Deliberately no exit(0) – see gated_writer_worker.dart's doc comment:
  // exit() can race the OS pipe delivery of this just-flushed line.
}
