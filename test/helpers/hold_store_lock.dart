/// Standalone helper script (NOT a test-framework file): opens a REAL
/// persistent-mode [StoreGate] against the store directory given as
/// `args[0]` — acquiring `store.lock` exclusively and holding it for this
/// process's lifetime, exactly like a real `OBX_MEMORY_STORE_MODE=persistent`
/// RememBox process would — signals readiness on stdout, then blocks until
/// the parent process closes stdin (clean shutdown, mirrors
/// hold_shared_lock.dart/hold_exclusive_lock.dart) OR is SIGKILLed (unclean
/// death, for the kill-9 recovery test).
///
/// LOAD-BEARING CHOICE (2026-09-01, found the hard way — see the 2026-09-01
/// store-gate engineering log, internal): this MUST block on
/// `stdin.drain()`, not on a bare `Completer<void>().future`. A first draft
/// of this file used the Completer and the process exited on its own within
/// ~400ms even though nothing ever completed it — a plain suspended Future
/// with no live Dart-level event source (Timer/Port/Stream subscription)
/// does NOT keep the standalone Dart VM's isolate alive; the native
/// ObjectBox Sync client's background reconnect activity doesn't count
/// either (it isn't a Dart-level event). `stdin.drain()` is a real, live
/// stream subscription, exactly like the two existing sibling helpers use —
/// proven to actually keep the process alive.
///
/// Used by test/store_gate_test.dart for things a purely in-process test
/// cannot prove:
/// - a `SIGKILL`ed lock holder releases `store.lock` with NO cooperation
///   from the dying process (the kernel drops fcntl locks on process death);
/// - a `gated`-mode process starting beside a genuine PERSISTENT peer fails
///   fast with a naming error (this script IS that persistent peer).
///
/// `print()`/direct stdout writes are acceptable here ONLY because this is a
/// throwaway standalone script under test/helpers/ — never in production
/// lib/ or bin/ code.
library;

import 'dart:io';

import 'package:remembox/objectbox.g.dart';
import 'package:remembox/src/store.dart';
import 'package:remembox/src/store_gate.dart';

Future<void> main(List<String> args) async {
  final storeDir = args[0];
  void log(String m) => stderr.writeln(m);
  final store = openMemoryStore(storeDir, log: log);
  final syncClient =
      SyncClient(store, [localActivationSyncUrl], [SyncCredentials.none()])
        ..start();
  final gate = await StoreGate.persistent(
    store: store,
    syncClient: syncClient,
    storeDirectory: storeDir,
    log: log,
  );
  stdout.writeln('LOCK_HELD');
  await stdout.flush();
  log('[hold_store_lock] holding store.lock in ${gate.mode.name} mode');
  // Blocks until the parent closes stdin — a real live stream subscription,
  // not a bare unresolved Future (see the load-bearing note above). A
  // SIGKILL test never reaches this cleanly: the process dies mid-drain and
  // the kernel drops the fcntl lock regardless.
  await stdin.drain<void>();
  await gate.close();
  exit(0);
}
