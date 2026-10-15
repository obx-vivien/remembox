/// Standalone worker (NOT a test-framework file, same convention as
/// fact_reader_worker.dart): opens a GATED [StoreGate] against `args[0]`
/// (storeDir) fresh and prints ONE JSON line on stdout: every [Thread] row
/// whose titleKey is `args[1]` (id, version, state) and the number of
/// [ThreadState] rows of each. A fresh process – not one of the writers –
/// is what proves cross-process correctness.
library;

import 'dart:convert';
import 'dart:io';

import 'package:remembox/objectbox.g.dart';
import 'package:remembox/src/store_gate.dart';

Future<void> main(List<String> args) async {
  final storeDir = args[0];
  final titleKey = args[1];
  final gate = await StoreGate.gated(
    storeDirectory: storeDir,
    log: (m) => stderr.writeln(m),
  );
  final result = await gate.withStore('thread-reader', (session) {
    final query = session.threads
        .query(Thread_.titleKey.equals(titleKey, caseSensitive: true))
        .build();
    try {
      return {
        'threads': [
          for (final t in query.find())
            {
              'id': t.id,
              'version': t.version,
              'state': t.state,
              'stateRows': () {
                final q = session.threadStates
                    .query(ThreadState_.thread.equals(t.id))
                    .build();
                try {
                  return q.count();
                } finally {
                  q.close();
                }
              }(),
            },
        ],
        'totalThreads': session.threads.count(),
        'totalStateRows': session.threadStates.count(),
      };
    } finally {
      query.close();
    }
  });
  await gate.close();
  stdout.writeln(jsonEncode(result));
  await stdout.flush();
  // Deliberately no exit(0) – see gated_writer_worker.dart's doc comment.
}
