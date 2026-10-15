/// tool/hooks/cockpit-sync-hook.sh (0.5.0): fail-open and quiet – it always
/// exits 0 with no output, and every failure (missing launcher, non-zero
/// exit, a run killed after the timeout) becomes one JSON line in the
/// compare log. A fake launcher stands in for `remembox`; the compare log
/// is a temp path (OBX_MEMORY_COCKPIT_LOG), never the operator's.
@TestOn('mac-os || linux')
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late String logPath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('remembox_hook_');
    logPath = p.join(tempDir.path, 'logs', 'compare.log');
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  String fakeLauncher(String body) {
    final path = p.join(tempDir.path, 'remembox');
    File(path).writeAsStringSync('#!/bin/bash\n$body\n');
    Process.runSync('chmod', ['+x', path]);
    return path;
  }

  Future<ProcessResult> runHook(
    String bin, {
    String timeout = '20',
    String cockpit = 'cockpit.md',
  }) => Process.run(
    'bash',
    ['tool/hooks/cockpit-sync-hook.sh'],
    environment: {
      'REMEMBOX_BIN': bin,
      'REMEMBOX_COCKPIT_HOOK_TIMEOUT': timeout,
      'OBX_MEMORY_COCKPIT_LOG': logPath,
      'OBX_MEMORY_COCKPIT_FILE': cockpit,
    },
  );

  List<Map<String, Object?>> logLines() => File(logPath).existsSync()
      ? [
          for (final l in File(logPath).readAsLinesSync())
            if (l.trim().isNotEmpty) jsonDecode(l) as Map<String, Object?>,
        ]
      : const [];

  test('success: exit 0, no output, nothing logged; the subcommand is '
      'passed', () async {
    final marker = p.join(tempDir.path, 'args');
    final bin = fakeLauncher('echo "\$@" > "$marker"; echo noise >&2');
    final r = await runHook(bin);
    expect(r.exitCode, 0);
    expect(r.stdout, isEmpty);
    expect(r.stderr, isEmpty);
    expect(File(marker).readAsStringSync().trim(), 'cockpit-sync');
    expect(logLines(), isEmpty);
  });

  test('a failing run is logged with its exit code and its last [cockpit] '
      'line', () async {
    final bin = fakeLauncher(
      'echo "[cockpit] first" >&2; '
      'echo "[cockpit] cockpit not written: \\"markers\\"" >&2; '
      'echo "usage: something" >&2; echo "native noise" >&2; exit 4',
    );
    final r = await runHook(bin);
    expect(r.exitCode, 0);
    expect(r.stdout, isEmpty);
    final line = logLines().single;
    expect(line['event'], 'hook-failure');
    expect(
      line['error'],
      'cockpit-sync exited 4: [cockpit] cockpit not written: markers',
    );
  });

  test('without OBX_MEMORY_COCKPIT_FILE the hook does nothing and logs '
      'nothing', () async {
    final marker = p.join(tempDir.path, 'ran');
    final bin = fakeLauncher('touch "$marker"; exit 2');
    final r = await runHook(bin, cockpit: '');
    expect(r.exitCode, 0);
    expect(r.stdout, isEmpty);
    expect(r.stderr, isEmpty);
    expect(File(marker).existsSync(), isFalse);
    expect(logLines(), isEmpty);
  });

  test('a run longer than the timeout is killed and logged', () async {
    final bin = fakeLauncher('sleep 30');
    final watch = Stopwatch()..start();
    final r = await runHook(bin, timeout: '1');
    expect(r.exitCode, 0);
    expect(r.stdout, isEmpty);
    expect(r.stderr, isEmpty);
    expect(watch.elapsed, lessThan(const Duration(seconds: 15)));
    expect(logLines().single['error'], contains('was killed after 1s'));
  });

  test('a missing launcher is logged, still exit 0', () async {
    final r = await runHook(p.join(tempDir.path, 'nope'));
    expect(r.exitCode, 0);
    expect(logLines().single['error'], contains('missing or not executable'));
  });
  group('launcher and log resolution without REMEMBOX_BIN', () {
    String hookSource() =>
        File('tool/hooks/cockpit-sync-hook.sh').readAsStringSync();

    /// Installs a copy of the hook at `<root>/<hookDir>/` and, when
    /// [launcherAt] is given, a fake launcher (it leaves [marker]) at
    /// `<root>/<launcherAt>`. Returns the root.
    String install(
      String name,
      String hookDir, {
      String? launcherAt,
      required String marker,
    }) {
      final root = p.join(tempDir.path, name);
      final hook = File(p.join(root, hookDir, 'cockpit-sync-hook.sh'))
        ..createSync(recursive: true)
        ..writeAsStringSync(hookSource());
      Process.runSync('chmod', ['+x', hook.path]);
      if (launcherAt != null) {
        final launcher = File(p.join(root, launcherAt))
          ..createSync(recursive: true)
          ..writeAsStringSync('#!/bin/bash\necho "\$@" > "$marker"\n');
        Process.runSync('chmod', ['+x', launcher.path]);
      }
      return root;
    }

    /// Runs the installed hook by a RELATIVE path from [root] with a bare
    /// environment (no REMEMBOX_BIN, no OBX_* from the test runner).
    Future<ProcessResult> runInstalled(
      String root,
      String hookDir, {
      Map<String, String> env = const {},
      String? pathPrefix,
    }) => Process.run(
      'bash',
      ['$hookDir/cockpit-sync-hook.sh'],
      workingDirectory: root,
      includeParentEnvironment: false,
      environment: {
        'PATH': [
          ?pathPrefix,
          Platform.environment['PATH'] ?? '/usr/bin:/bin',
        ].join(':'),
        'HOME': tempDir.path,
        'OBX_MEMORY_COCKPIT_FILE': 'cockpit.md',
        ...env,
      },
    );

    test('release ZIP layout: hooks/ finds ../dist/remembox', () async {
      final marker = p.join(tempDir.path, 'zip-ran');
      final root = install(
        'zip',
        'hooks',
        launcherAt: 'dist/remembox',
        marker: marker,
      );
      final r = await runInstalled(
        root,
        'hooks',
        env: {'OBX_MEMORY_COCKPIT_LOG': logPath},
      );
      expect(r.exitCode, 0);
      expect(r.stdout, isEmpty);
      expect(r.stderr, isEmpty);
      expect(File(marker).readAsStringSync().trim(), 'cockpit-sync');
      expect(logLines(), isEmpty);
    });

    test('repository layout: tool/hooks/ finds ../../dist/remembox', () async {
      final marker = p.join(tempDir.path, 'repo-ran');
      final root = install(
        'repo',
        'tool/hooks',
        launcherAt: 'dist/remembox',
        marker: marker,
      );
      final r = await runInstalled(
        root,
        'tool/hooks',
        env: {'OBX_MEMORY_COCKPIT_LOG': logPath},
      );
      expect(r.exitCode, 0);
      expect(r.stdout, isEmpty);
      expect(r.stderr, isEmpty);
      expect(File(marker).readAsStringSync().trim(), 'cockpit-sync');
      expect(logLines(), isEmpty);
    });

    test('REMEMBOX_BIN wins over a launcher next to the script', () async {
      final nearby = p.join(tempDir.path, 'nearby-ran');
      final chosen = p.join(tempDir.path, 'chosen-ran');
      final root = install(
        'both',
        'hooks',
        launcherAt: 'dist/remembox',
        marker: nearby,
      );
      final bin = fakeLauncher('echo "\$@" > "$chosen"');
      final r = await runInstalled(
        root,
        'hooks',
        env: {'OBX_MEMORY_COCKPIT_LOG': logPath, 'REMEMBOX_BIN': bin},
      );
      expect(r.exitCode, 0);
      expect(File(chosen).existsSync(), isTrue);
      expect(File(nearby).existsSync(), isFalse);
    });

    test('nothing found: one log line naming what was tried, exit 0, '
        'no output', () async {
      final root = install(
        'bare',
        'hooks',
        marker: p.join(tempDir.path, 'never'),
      );
      // A directory named like the launcher does not count.
      Directory(p.join(root, 'dist', 'remembox')).createSync(recursive: true);
      final r = await runInstalled(
        root,
        'hooks',
        env: {'OBX_MEMORY_COCKPIT_LOG': logPath},
      );
      expect(r.exitCode, 0);
      expect(r.stdout, isEmpty);
      expect(r.stderr, isEmpty);
      final error = logLines().single['error'] as String;
      expect(error, contains('missing or not executable'));
      expect(error, contains('REMEMBOX_BIN unset'));
      expect(error, contains('/hooks/../dist/remembox'));
      expect(error, contains('/hooks/../../dist/remembox'));
    });

    test('without OBX_MEMORY_COCKPIT_FILE nothing runs and nothing is '
        'logged, even with no launcher anywhere', () async {
      final root = install(
        'unconfigured',
        'hooks',
        marker: p.join(tempDir.path, 'never'),
      );
      final r = await runInstalled(
        root,
        'hooks',
        env: {'OBX_MEMORY_COCKPIT_FILE': '', 'OBX_MEMORY_COCKPIT_LOG': logPath},
      );
      expect(r.exitCode, 0);
      expect(r.stdout, isEmpty);
      expect(r.stderr, isEmpty);
      expect(logLines(), isEmpty);
    });

    test('a symlinked hook (absolute, relative and chained links) still '
        'finds ../dist/remembox; a copy elsewhere does not', () async {
      final marker = p.join(tempDir.path, 'sym-ran');
      final root = install(
        'sym',
        'hooks',
        launcherAt: 'dist/remembox',
        marker: marker,
      );
      final real = p.join(root, 'hooks', 'cockpit-sync-hook.sh');
      final env = {'OBX_MEMORY_COCKPIT_LOG': logPath};
      Future<void> expectRuns(String link) async {
        if (File(marker).existsSync()) File(marker).deleteSync();
        final r = await Process.run(
          'bash',
          [link],
          workingDirectory: p.dirname(link),
          includeParentEnvironment: false,
          environment: {
            'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
            'HOME': tempDir.path,
            'OBX_MEMORY_COCKPIT_FILE': 'cockpit.md',
            ...env,
          },
        );
        expect(r.exitCode, 0, reason: link);
        expect(r.stdout, isEmpty);
        expect(r.stderr, isEmpty);
        expect(File(marker).readAsStringSync().trim(), 'cockpit-sync',
            reason: link);
      }

      Directory(p.join(tempDir.path, 'links', 'a')).createSync(recursive: true);
      Directory(p.join(tempDir.path, 'links', 'b')).createSync(recursive: true);
      final absolute = p.join(tempDir.path, 'links', 'a', 'abs-hook.sh');
      Link(absolute).createSync(real);
      await expectRuns(absolute);
      // A relative target counts from the link's directory.
      final relative = p.join(tempDir.path, 'links', 'b', 'rel-hook.sh');
      Link(relative).createSync(p.relative(real, from: p.dirname(relative)));
      await expectRuns(relative);
      // A link to a link (relative, then absolute).
      final chained = p.join(tempDir.path, 'links', 'chained-hook.sh');
      Link(chained).createSync(p.join('b', 'rel-hook.sh'));
      await expectRuns(chained);
      Link(p.join(tempDir.path, 'links', 'chained2.sh')).createSync(absolute);
      await expectRuns(p.join(tempDir.path, 'links', 'chained2.sh'));

      // A copy next to nothing has no launcher to find: logged, not run.
      final copy = File(p.join(tempDir.path, 'copy', 'cockpit-sync-hook.sh'))
        ..createSync(recursive: true)
        ..writeAsStringSync(hookSource());
      Process.runSync('chmod', ['+x', copy.path]);
      File(marker).deleteSync();
      final r = await Process.run(
        'bash',
        [copy.path],
        includeParentEnvironment: false,
        environment: {
          'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
          'HOME': tempDir.path,
          'OBX_MEMORY_COCKPIT_FILE': 'cockpit.md',
          ...env,
        },
      );
      expect(r.exitCode, 0);
      expect(File(marker).existsSync(), isFalse);
      expect(logLines().single['error'], contains('REMEMBOX_BIN unset'));
    });

    test('the sleeping watcher does not hold the hook stdout open (even '
        'when pkill does nothing)', () async {
      final root = install(
        'watcher',
        'hooks',
        launcherAt: 'dist/remembox',
        marker: p.join(tempDir.path, 'watcher-ran'),
      );
      // "pkill removed from PATH": a pkill that kills nothing, so the
      // watcher's sleep survives the hook.
      final fakeDir = Directory(p.join(tempDir.path, 'no-pkill'))
        ..createSync();
      final pkill = File(p.join(fakeDir.path, 'pkill'))
        ..writeAsStringSync('#!/bin/sh\nexit 0\n');
      Process.runSync('chmod', ['+x', pkill.path]);
      final watch = Stopwatch()..start();
      final r = await runInstalled(
        root,
        'hooks',
        pathPrefix: fakeDir.path,
        env: {
          'OBX_MEMORY_COCKPIT_LOG': logPath,
          'REMEMBOX_COCKPIT_HOOK_TIMEOUT': '30',
        },
      );
      expect(r.exitCode, 0);
      expect(r.stdout, isEmpty);
      expect(
        watch.elapsed,
        lessThan(const Duration(seconds: 15)),
        reason: 'the reader must not wait for the 30s watcher',
      );
    });

    test('a log first created by the hook is private: directory 700, '
        'file 600; an existing directory and file are left as they are',
        () async {
      final root = install(
        'perms',
        'hooks',
        marker: p.join(tempDir.path, 'never'),
      );
      final dir = p.join(tempDir.path, 'fresh', 'logs');
      final log = p.join(dir, 'compare.log');
      var r = await runInstalled(root, 'hooks',
          env: {'OBX_MEMORY_COCKPIT_LOG': log});
      expect(r.exitCode, 0);
      expect(File(log).statSync().mode & 0x1FF, 0x180, reason: 'file 600');
      expect(Directory(dir).statSync().mode & 0x1FF, 0x1C0, reason: 'dir 700');
      // An existing, looser log keeps its mode (cockpit-sync tightens it).
      Process.runSync('chmod', ['644', log]);
      r = await runInstalled(root, 'hooks',
          env: {'OBX_MEMORY_COCKPIT_LOG': log});
      expect(r.exitCode, 0);
      expect(File(log).statSync().mode & 0x1FF, 420, reason: 'still 644');
      expect(File(log).readAsLinesSync(), hasLength(2));
    });

    /// A `uname` that reports [os], first on PATH.
    String fakeUname(String os) {
      final dir = Directory(p.join(tempDir.path, 'fake-$os'))
        ..createSync(recursive: true);
      final f = File(p.join(dir.path, 'uname'))
        ..writeAsStringSync('#!/bin/sh\necho $os\n');
      Process.runSync('chmod', ['+x', f.path]);
      return dir.path;
    }

    test('default log on Darwin: ~/Library/Logs/remembox', () async {
      final root = install(
        'darwin',
        'hooks',
        marker: p.join(tempDir.path, 'never'),
      );
      final r = await runInstalled(
        root,
        'hooks',
        pathPrefix: fakeUname('Darwin'),
        env: {'XDG_STATE_HOME': p.join(tempDir.path, 'ignored')},
      );
      expect(r.exitCode, 0);
      expect(
        File(
          p.join(
            tempDir.path,
            'Library',
            'Logs',
            'remembox',
            'cockpit-compare.log',
          ),
        ).readAsStringSync(),
        contains('"event":"hook-failure"'),
      );
      expect(Directory(p.join(tempDir.path, 'ignored')).existsSync(), isFalse);
    });

    test(
      'default log elsewhere: XDG_STATE_HOME, else ~/.local/state',
      () async {
        final root = install(
          'linux',
          'hooks',
          marker: p.join(tempDir.path, 'never'),
        );
        final xdg = p.join(tempDir.path, 'xdg-state');
        var r = await runInstalled(
          root,
          'hooks',
          pathPrefix: fakeUname('Linux'),
          env: {'XDG_STATE_HOME': xdg},
        );
        expect(r.exitCode, 0);
        expect(
          File(
            p.join(xdg, 'remembox', 'cockpit-compare.log'),
          ).readAsStringSync(),
          contains('"event":"hook-failure"'),
        );
        r = await runInstalled(root, 'hooks', pathPrefix: fakeUname('Linux'));
        expect(r.exitCode, 0);
        expect(
          File(
            p.join(
              tempDir.path,
              '.local',
              'state',
              'remembox',
              'cockpit-compare.log',
            ),
          ).readAsStringSync(),
          contains('"event":"hook-failure"'),
        );
        expect(
          Directory(p.join(tempDir.path, 'Library')).existsSync(),
          isFalse,
        );
      },
    );
  });
  group('docs', () {
    /// The ```json fence of [path] that wires the hook script.
    Map<String, Object?> hookSettings(String path) {
      final text = File(path).readAsStringSync();
      final fences = RegExp(r'```json\n(.*?)\n```', dotAll: true)
          .allMatches(text)
          .map((m) => m.group(1)!)
          .where((f) => f.contains('cockpit-sync-hook.sh'))
          .toList();
      expect(fences, hasLength(1), reason: '$path: one hook settings example');
      return jsonDecode(fences.single) as Map<String, Object?>;
    }

    test('README and usage guide show the same generic settings.json '
        'hooks example (SessionStart + Stop, placeholder paths)', () {
      final readme = hookSettings('README.md');
      expect(hookSettings('docs/usage-guide.md'), readme);
      final hooks = readme['hooks']! as Map<String, Object?>;
      expect(hooks.keys.toSet(), {'SessionStart', 'Stop'});
      final raw = jsonEncode(readme);
      expect(raw, contains('/path/to/remembox/hooks/cockpit-sync-hook.sh'));
      expect(raw, contains(r'OBX_MEMORY_COCKPIT_FILE=\"$HOME/path/to/cockpit.md\"'));
      expect(raw, isNot(contains('/Users/')));
    });

    test('the documented ZIP path of the script is the shipped one', () {
      for (final path in [
        'README.md',
        'docs/usage-guide.md',
        'skill/SKILL.md',
        'templates/global-CLAUDE.md',
        'CHANGELOG.md',
      ]) {
        expect(
          File(path).readAsStringSync(),
          contains('hooks/cockpit-sync-hook.sh'),
          reason: path,
        );
      }
    });
  });
}
