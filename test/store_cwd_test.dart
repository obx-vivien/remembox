/// Pins the 2026-09-07 fix for CLAUDE.md platform gotcha 3 / the 2026-09-02
/// store-gate status note (internal): rebuilding `dist/` (`rm -rf dist`)
/// orphans the cwd of every already-running gated server (the launcher
/// `cd`s into `dist/`), and in gated mode every tool call re-opens the
/// store — which used to mean every call of every running server died with
/// an opaque `PathNotFoundException` the instant `Directory.current` was
/// evaluated. This file pins two independent fixes:
///   - `ensureNativeLibraryLoaded()` (store.dart) skips the cwd-relative
///     dylib candidate (logging why) instead of throwing when the cwd is
///     gone, and still offers that candidate when the cwd is alive.
///   - `MemoryConfig.fromEnvironment()`'s `HOME` fallback throws an
///     actionable `ArgumentError` instead of the opaque native exception
///     when both `HOME` is unset and the cwd is gone.
///
/// All four scenarios below run in a REAL SUBPROCESS
/// (`test/helpers/dead_cwd_probe.dart`), not in-process. `Directory.current`
/// (`chdir`) is process-global, not per-isolate, and `dart test` runs every
/// test file as a separate isolate inside ONE shared OS process — an
/// earlier in-process version of this file that did
/// `Directory.current = tempDir; tempDir.deleteSync()` directly corrupted
/// the cwd for the whole test run and caused unrelated suites
/// (`test/instance_guard_test.dart`,
/// `test/acceptance/multi_process_gated_test.dart`, both of which spawn
/// real subprocesses / resolve relative helper paths) to fail
/// nondeterministically. See the helper script's doc comment for the full
/// story.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// Platform.resolvedExecutable: the VM running this test — no PATH
// dependency, same SDK as the test (matches test/instance_guard_test.dart
// and test/acceptance/multi_process_gated_test.dart's established pattern).
final _dartExe = Platform.resolvedExecutable;
final _repoRoot = Directory.current.path;
final _probeScript = p.join(_repoRoot, 'test', 'helpers', 'dead_cwd_probe.dart');

Future<ProcessResult> _runProbe(List<String> args) => Process.run(
  _dartExe,
  ['run', _probeScript, ...args],
  workingDirectory: _repoRoot,
);

void main() {
  group('ensureNativeLibraryLoaded: cwd tolerance', () {
    test(
      'deleted cwd does NOT throw, and logs a skip line for the '
      'cwd-relative candidate (regression for the dist/ rebuild crash)',
      () async {
        final result = await _runProbe(['native-dead']);
        expect(
          result.exitCode,
          0,
          reason: 'probe stderr: ${result.stderr}',
        );
        final out = result.stdout as String;
        expect(out, isNot(contains('THREW:')));
        expect(out, contains('OK'));
        expect(
          out,
          allOf(
            contains('[store] cwd is gone'),
            contains('skipping the cwd-relative dylib candidate'),
            contains('exe-relative candidates still apply'),
          ),
        );
      },
    );

    test(
      'a live cwd with lib/<dylib> still offers the cwd-relative candidate '
      '(the fix must not remove it, only tolerate its absence)',
      () async {
        final result = await _runProbe(['native-live', _repoRoot]);
        expect(
          result.exitCode,
          0,
          reason: 'probe stderr: ${result.stderr}',
        );
        final out = result.stdout as String;
        expect(out, contains('OK'));
        // exe-relative candidates (the `dart` VM binary running this probe)
        // do not carry a dylib next to them, so the cwd candidate is the
        // one that resolves — proving it is still tried and still wins.
        expect(out, contains('pre-loaded from'));
      },
    );
  });

  group('MemoryConfig.fromEnvironment: HOME / cwd fallback', () {
    test(
      'HOME unset + dead cwd throws an actionable ArgumentError naming '
      'both HOME and the cwd (instead of the opaque native exception)',
      () async {
        final result = await _runProbe(['home-unset']);
        expect(
          result.exitCode,
          0,
          reason: 'probe stderr: ${result.stderr}',
        );
        final out = result.stdout as String;
        expect(out, isNot(contains('NO_ERROR')));
        expect(out, isNot(contains('OTHER:')));
        expect(
          out,
          allOf(contains('ARGERROR:'), contains('HOME'), contains('working directory')),
        );
      },
    );

    test('HOME set + dead cwd works fine (cwd is never consulted)', () async {
      final result = await _runProbe(['home-set', '/tmp/remembox-fake-home']);
      expect(
        result.exitCode,
        0,
        reason: 'probe stderr: ${result.stderr}',
      );
      final out = result.stdout as String;
      expect(
        out,
        contains('STOREDIR: ${p.join('/tmp/remembox-fake-home', '.remembox')}'),
      );
    });
  });
}
