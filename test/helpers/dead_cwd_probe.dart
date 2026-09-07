/// Standalone helper script (NOT a test-framework file): runs one of four
/// cwd-related scenarios for `test/store_cwd_test.dart` INSIDE ITS OWN OS
/// PROCESS, dispatched by `args[0]`.
///
/// Why a subprocess and not a plain in-process test: `Directory.current`
/// (`chdir`) is process-global, not per-isolate. `dart test` runs every
/// test FILE as a separate isolate but inside ONE shared OS process (proven
/// empirically: two files printed the same `pid` in the same `dart test`
/// run) — so a test that does `Directory.current = tempDir` and deletes
/// `tempDir` corrupts the *entire test run's* working directory for every
/// concurrently-running file, not just its own. That is exactly what
/// happened the first time this was tried in-process: unrelated suites
/// (`test/instance_guard_test.dart`, `test/acceptance/
/// multi_process_gated_test.dart`) — which spawn real subprocesses and
/// resolve relative helper-script paths against the current cwd — started
/// failing nondeterministically. Isolating the cwd mutation inside a
/// dedicated child process (`Process.start(..., workingDirectory: ...)`
/// sets *that child's* cwd only, never the parent's) reproduces the real
/// bug with zero blast radius on the rest of the suite, matching the
/// pattern already used by the sibling scripts in this directory
/// (`hold_store_lock.dart` et al.).
///
/// `print()`/direct stdout writes are acceptable here ONLY because this is a
/// throwaway standalone script under test/helpers/ — never in production
/// lib/ or bin/ code.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:remembox/src/store.dart';

String _libName() =>
    Platform.isMacOS
        ? 'libobjectbox.dylib'
        : Platform.isWindows
        ? 'objectbox.dll'
        : 'libobjectbox.so';

/// Creates a fresh temp dir, chdir's this process into it, then deletes it
/// out from under itself — reproducing the orphaned-cwd state a gated
/// server is left in after `tool/build.sh`'s `rm -rf dist`.
void _enterAndKillCwd() {
  // Force package:path's `Style.platform` (a lazy `static final`, cached
  // for the isolate's lifetime — package:path/src/style.dart) to resolve
  // now, while the cwd is still alive. It reads `Directory.current` via
  // `Uri.base` on first access; a real gated server has already done
  // plenty of path work by the time `tool/build.sh` can orphan its cwd
  // (config parsing, store bootstrap all happen at startup, long before a
  // rebuild race is even possible), so this warm-up just matches that
  // real ordering — it is not a workaround for anything this probe is
  // supposed to catch. Without it, this COLD process would hit the lazy
  // init AFTER the cwd is already dead and throw from an unrelated
  // package:path callsite, which is not the bug under test here.
  p.join('warmup', 'noop');
  final tempDir = Directory.systemTemp.createTempSync('remembox_dead_cwd_');
  Directory.current = tempDir;
  tempDir.deleteSync(recursive: true);
}

void main(List<String> args) {
  final scenario = args[0];
  switch (scenario) {
    case 'native-dead':
      _enterAndKillCwd();
      final logs = <String>[];
      try {
        ensureNativeLibraryLoaded(log: logs.add);
        for (final l in logs) {
          stdout.writeln('LOG: $l');
        }
        stdout.writeln('OK');
      } catch (err) {
        stdout.writeln('THREW: $err');
      }
      exit(0);

    case 'native-live':
      final repoRoot = args[1];
      final tempDir = Directory.systemTemp.createTempSync(
        'remembox_live_cwd_',
      );
      final libName = _libName();
      Directory(
        p.join(tempDir.path, 'lib'),
      ).createSync(recursive: true);
      File(
        p.join(repoRoot, 'lib', libName),
      ).copySync(p.join(tempDir.path, 'lib', libName));
      Directory.current = tempDir;

      final logs = <String>[];
      ensureNativeLibraryLoaded(log: logs.add);
      for (final l in logs) {
        stdout.writeln('LOG: $l');
      }
      stdout.writeln('OK');
      exit(0);

    case 'home-unset':
      _enterAndKillCwd();
      try {
        final config = MemoryConfig.fromEnvironment(env: const {});
        stdout.writeln('NO_ERROR: storeDir=${config.storeDir}');
      } on ArgumentError catch (err) {
        stdout.writeln('ARGERROR: ${err.message}');
      } catch (err) {
        stdout.writeln('OTHER: $err');
      }
      exit(0);

    case 'home-set':
      _enterAndKillCwd();
      try {
        final config = MemoryConfig.fromEnvironment(
          env: {'HOME': args[1]},
        );
        stdout.writeln('STOREDIR: ${config.storeDir}');
      } catch (err) {
        stdout.writeln('THREW: $err');
      }
      exit(0);

    default:
      stderr.writeln('unknown scenario: $scenario');
      exit(2);
  }
}
