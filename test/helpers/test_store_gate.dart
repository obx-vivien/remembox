/// Test-only convenience for building a persistent-mode [StoreGate] around
/// a freshly-opened temp [Store], mirroring bin/remembox.dart's own
/// persistent-mode startup sequence (openMemoryStore → startSyncClient →
/// StoreGate.persistent). Centralizes the ~90 call sites' worth of
/// boilerplate that would otherwise be repeated in every test file that
/// constructs a [MemoryService] (2026-09-01, Store-Gate, the 2026-09-01
/// store-gate engineering log, internal).
library;

import 'package:remembox/objectbox.g.dart';
import 'package:remembox/src/store.dart';
import 'package:remembox/src/store_gate.dart';

/// Opens a fresh [Store] at [storeDir] (creating it if needed), activates
/// local writes with the reserved-port sync client (same trick production
/// code uses for local-only mode — see [localActivationSyncUrl]), and wraps
/// both in a persistent-mode [StoreGate]. Callers get the [Store] back too
/// (via [TestGate.store]) for direct post-hoc inspection in assertions
/// (`entries().get(id)` etc.) — exactly the pattern the pre-Store-Gate
/// tests used.
Future<TestGate> openTestGate(String storeDir, {LogSink log = stderrLog}) async {
  final store = openMemoryStore(storeDir, log: log);
  final syncClient = SyncClient(
    store,
    [localActivationSyncUrl],
    [SyncCredentials.none()],
  )..start();
  final gate = await StoreGate.persistent(
    store: store,
    syncClient: syncClient,
    storeDirectory: storeDir,
    log: log,
  );
  return TestGate._(gate, store, syncClient);
}

/// Bundle returned by [openTestGate]: the [StoreGate] to hand to
/// [MemoryService], plus direct [store]/[syncClient] references for tests
/// that inspect the store directly or need to close things themselves.
class TestGate {
  final StoreGate gate;
  final Store store;
  final SyncClient syncClient;

  TestGate._(this.gate, this.store, this.syncClient);

  /// Closes the gate (which closes the sync client then the store, in that
  /// order — see [StoreGate.close]). Use this in `tearDown` instead of
  /// closing [store]/[syncClient] directly.
  Future<void> close() => gate.close();
}
