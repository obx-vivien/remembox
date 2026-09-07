/// Standalone worker (NOT a test-framework file): opens a GATED
/// [StoreGate] against `args[0]` (storeDir), counts `MemoryEntry` rows in
/// ONE `withStore` lending, prints `{"count": N}` as a single JSON line on
/// stdout, and exits 0.
///
/// Used by test/acceptance/multi_process_gated_test.dart (WP6, plan §6.3):
/// "a fresh THIRD process (not a worker) opens the store read-only-ish...
/// and counts entries" — a genuinely separate OS process, not an in-isolate
/// call, is what actually proves cross-process correctness (same rationale
/// test/instance_guard_test.dart's own doc comment gives for spawning real
/// processes at all).
///
/// Deliberately does NOT construct a [MemoryService] (no embedder needed
/// just to count) — goes straight through [StoreGate.withStore] to keep
/// this worker minimal and avoid coupling the count to unrelated
/// MemoryService setup.
library;

import 'dart:convert';
import 'dart:io';

import 'package:remembox/src/store_gate.dart';

Future<void> main(List<String> args) async {
  final storeDir = args[0];
  final gate = await StoreGate.gated(
    storeDirectory: storeDir,
    log: (m) => stderr.writeln(m),
  );
  final count = await gate.withStore(
    'count-entries',
    (session) => session.entries.count(),
  );
  await gate.close();
  stdout.writeln(jsonEncode({'count': count}));
  await stdout.flush();
  // Deliberately no exit(0) here — see gated_writer_worker.dart's doc
  // comment: exit() can race the OS pipe delivery of this just-flushed
  // line to the parent process. Nothing else keeps the event loop open,
  // so letting main() return exits promptly anyway.
}
