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
///
/// 2026-09-09 (store mode derived from configuration; gated is the
/// default): also pins the new startup-mode log line and its two
/// non-explicit branches (`gated (default)`, `persistent (--serve)`) —
/// `main()`-level behavior for the same reason as the tests above: the
/// branch depends on `serveModeRequested(args)` combined with
/// `MemoryConfig`, which only exists together inside `main()`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
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

  test(
    'no OBX_MEMORY_STORE_MODE, no OBX_MEMORY_SYNC_URL, and no --serve logs '
    'the gated (default) startup line and creates store.lock (2026-09-09, '
    'store mode derived from configuration; gated is the default)',
    () async {
      final tempDir = Directory.systemTemp.createTempSync(
        'remembox_main_gated_default_',
      );
      addTearDown(() {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });

      final proc = await Process.start(
        Platform.resolvedExecutable,
        ['run', 'bin/remembox.dart'],
        environment: {
          'OBX_MEMORY_DIR': tempDir.path,
          // Explicitly cleared, not merely omitted — Process.start merges
          // into the parent environment by default (same reasoning as the
          // OBX_MEMORY_HTTP_TOKEN override in the test above), so a shell
          // that happens to export any of these would otherwise silently
          // pick a different branch than the one under test.
          'OBX_MEMORY_STORE_MODE': '',
          'OBX_MEMORY_SYNC_URL': '',
          // Avoids an unbounded model-pull attempt against a real Ollama
          // if the configured embedding model happens to be missing —
          // irrelevant to what this test checks (startup-mode resolution
          // happens before the embedder is even constructed) but a pull
          // could otherwise make this test slow or flaky.
          'OBX_MEMORY_AUTO_PULL': 'false',
        },
      );
      // Defensive: harmless no-op if the process already exited via the
      // stdin-EOF shutdown path below.
      addTearDown(() => proc.kill(ProcessSignal.sigkill));

      final stderrLines = <String>[];
      final sawTargetLine = Completer<void>();
      const targetLine =
          '[startup] store mode: gated (default) – several processes may '
          'share this store; each tool call opens the store behind '
          'store.lock';
      final stderrSub = proc.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            stderrLines.add(line);
            if (line.contains(targetLine) && !sawTargetLine.isCompleted) {
              sawTargetLine.complete();
            }
          });
      // Closing stdin immediately gives the stdio channel its EOF as soon
      // as the server attaches to it, so the process runs its normal
      // shutdown/cleanup sequence instead of blocking on stdin forever —
      // no MCP handshake is needed for that (server.done completes on
      // channel close, matching a normal client disconnect).
      unawaited(proc.stdin.close());

      await sawTargetLine.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          fail(
            'never saw the gated (default) startup line; stderr so far:\n'
            '${stderrLines.join('\n')}',
          );
        },
      );

      final exitCode = await proc.exitCode.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          proc.kill(ProcessSignal.sigkill);
          fail(
            'process did not exit after stdin EOF; stderr so far:\n'
            '${stderrLines.join('\n')}',
          );
        },
      );
      expect(exitCode, 0, reason: 'stderr: ${stderrLines.join('\n')}');

      expect(
        File(p.join(tempDir.path, 'store.lock')).existsSync(),
        isTrue,
        reason:
            'gated mode must create store.lock during its startup probe '
            '(StoreGate.gated) even with no tool call made — stderr: '
            '${stderrLines.join('\n')}',
      );

      await stderrSub.cancel();
    },
  );

  test(
    '--serve (token set, no explicit OBX_MEMORY_STORE_MODE) logs the '
    'persistent (--serve) startup line (2026-09-09, store mode derived '
    'from configuration; gated is the default)',
    () async {
      final tempDir = Directory.systemTemp.createTempSync(
        'remembox_main_serve_default_',
      );
      addTearDown(() {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });

      final proc = await Process.start(
        Platform.resolvedExecutable,
        // --serve=0: an OS-assigned ephemeral port, so this test cannot
        // collide with another instance (real or test) already bound to
        // the default HTTP port.
        ['run', 'bin/remembox.dart', '--serve=0'],
        environment: {
          'OBX_MEMORY_DIR': tempDir.path,
          'OBX_MEMORY_STORE_MODE': '',
          'OBX_MEMORY_HTTP_TOKEN': 'test-startup-log-token',
          'OBX_MEMORY_AUTO_PULL': 'false',
        },
      );
      addTearDown(() => proc.kill(ProcessSignal.sigkill));

      final stderrLines = <String>[];
      final sawTargetLine = Completer<void>();
      const targetLine =
          '[startup] store mode: persistent (--serve) – the daemon holds '
          'the store for its lifetime';
      // The mode line above prints early (right after MemoryConfig is
      // built), well before _runServeMode installs its SIGINT/SIGTERM
      // watchers — that only happens after the guard/store/embedder/
      // MemoryService setup and daemon.start() have all completed. Sending
      // SIGTERM right after the mode line races ahead of the watcher and
      // just kills the process outright (observed: exitCode -15, no
      // graceful cleanup). Wait for "HTTP daemon listening", logged AFTER
      // the watchers are registered, before signaling.
      final sawListeningLine = Completer<void>();
      const listeningMarker = '[startup] HTTP daemon listening on';
      final stderrSub = proc.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            stderrLines.add(line);
            if (line.contains(targetLine) && !sawTargetLine.isCompleted) {
              sawTargetLine.complete();
            }
            if (line.contains(listeningMarker) &&
                !sawListeningLine.isCompleted) {
              sawListeningLine.complete();
            }
          });

      await sawTargetLine.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          fail(
            'never saw the persistent (--serve) startup line; stderr so '
            'far:\n${stderrLines.join('\n')}',
          );
        },
      );
      await sawListeningLine.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          fail(
            'never saw the HTTP daemon listening line (needed so the '
            'SIGTERM watcher is registered before signaling); stderr so '
            'far:\n${stderrLines.join('\n')}',
          );
        },
      );
      // ProcessSignal.watch()'s OS-level registration is itself
      // asynchronous and completes a moment after the .listen() call
      // returns (observed empirically: signaling immediately after the
      // "HTTP daemon listening" line still raced ahead of it, killing the
      // process outright with exitCode -15 instead of running the
      // documented graceful-shutdown path). A short grace period is the
      // pragmatic fix here — there's no externally observable "watcher is
      // now armed" signal to synchronize on instead.
      await Future<void>.delayed(const Duration(milliseconds: 500));

      // Graceful shutdown, same signal the daemon documents handling
      // (bin/remembox.dart's _runServeMode) — proves the process is a real,
      // live daemon at this point, not something that happened to print
      // the line and then crash.
      proc.kill(ProcessSignal.sigterm);
      final exitCode = await proc.exitCode.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          proc.kill(ProcessSignal.sigkill);
          fail(
            'daemon did not exit after SIGTERM; stderr so far:\n'
            '${stderrLines.join('\n')}',
          );
        },
      );
      expect(exitCode, 0, reason: 'stderr: ${stderrLines.join('\n')}');

      await stderrSub.cancel();
    },
  );
}
