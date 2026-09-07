/// Subprocess smoke test for `bin/remembox.dart`'s `main()`-level
/// validation that isn't reachable through any lower-level unit test
/// (2026-09-01, Store-Gate feature, the 2026-09-01 store-gate engineering
/// log (internal), plan §1.2/§9): `serveMode && config.storeMode ==
/// StoreMode.gated` must be
/// rejected loudly BEFORE the guard/store/embedder are ever touched (WP1
/// F5). `serveModeRequested()` reads CLI args, `MemoryConfig.storeMode`
/// reads the environment — the check that combines them lives only inside
/// `main()` itself, which is not unit-testable without actually running the
/// binary (http_transport_test.dart's own file, per plan §9, constructs
/// `RememboxHttpDaemon`/`RememboxServer` directly and never calls `main()`).
///
/// This test therefore spawns the REAL entrypoint as a subprocess — slower
/// than a unit test, but it is the only way to exercise this exact code
/// path.
library;

import 'dart:io';

import 'package:test/test.dart';

void main() {
  test(
    '--serve combined with OBX_MEMORY_STORE_MODE=gated fails loud at '
    'startup with an actionable StateError, before touching the store',
    () async {
      final tempDir = Directory.systemTemp.createTempSync(
        'remembox_main_serve_gated_',
      );
      addTearDown(() => tempDir.deleteSync(recursive: true));

      // Platform.resolvedExecutable: the VM running this test — no PATH
      // dependency, same SDK as the test.
      final result = await Process.run(
        Platform.resolvedExecutable,
        ['run', 'bin/remembox.dart', '--serve'],
        environment: {
          'OBX_MEMORY_STORE_MODE': 'gated',
          'OBX_MEMORY_DIR': tempDir.path,
        },
      );

      expect(
        result.exitCode,
        isNot(0),
        reason:
            'must refuse to start, not silently ignore the invalid '
            'combination. stdout: ${result.stdout}\nstderr: ${result.stderr}',
      );
      expect(
        result.stderr.toString(),
        allOf(
          contains('OBX_MEMORY_STORE_MODE=gated'),
          contains('--serve'),
          contains('not supported'),
        ),
        reason:
            'the rejection message must name BOTH the mode and --serve, '
            'not just crash opaquely',
      );
      // The store directory must never have been touched — this is a
      // config-time rejection, not a partial-startup failure.
      expect(
        Directory(tempDir.path).listSync(),
        isEmpty,
        reason:
            'the check must fire before openMemoryStore/instances.lock — '
            'no store.lock/instances.lock file should have been created',
      );
    },
  );

  test(
    '--serve without OBX_MEMORY_HTTP_TOKEN refuses to start with an '
    'actionable StateError, before touching the store (Fix 1, 2026-09-07, '
    'the 2026-09-07 daemon-auth engineering log (internal))',
    () async {
      final tempDir = Directory.systemTemp.createTempSync(
        'remembox_main_serve_notoken_',
      );
      addTearDown(() => tempDir.deleteSync(recursive: true));

      final result = await Process.run(
        Platform.resolvedExecutable,
        ['run', 'bin/remembox.dart', '--serve'],
        environment: {
          'OBX_MEMORY_DIR': tempDir.path,
          'OBX_MEMORY_STORE_MODE': 'persistent',
          // Explicitly overridden to empty (not merely omitted): Process.run
          // merges this map INTO the parent's environment by default, so
          // omitting the key would let an OBX_MEMORY_HTTP_TOKEN the test
          // runner's own shell happens to have exported leak through and
          // falsify this test. An explicit empty string guarantees the
          // subprocess sees it as unset (resolveHttpToken treats null and
          // empty identically).
          'OBX_MEMORY_HTTP_TOKEN': '',
        },
      );

      expect(
        result.exitCode,
        isNot(0),
        reason:
            'must refuse to start, not silently run unauthenticated. '
            'stdout: ${result.stdout}\nstderr: ${result.stderr}',
      );
      expect(
        result.stderr.toString(),
        allOf(
          contains('OBX_MEMORY_HTTP_TOKEN'),
          contains('--serve'),
          contains('required'),
        ),
        reason:
            'the rejection message must name the missing variable and how '
            'to fix it, not just crash opaquely',
      );
      // Same config-time-rejection invariant as the gated-mode test above:
      // no store.lock/instances.lock file should exist.
      expect(
        Directory(tempDir.path).listSync(),
        isEmpty,
        reason:
            'the check must fire before openMemoryStore/instances.lock — '
            'no store.lock/instances.lock file should have been created',
      );
    },
  );
}
