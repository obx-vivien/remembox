/// `remembox cockpit-sync` (0.5.0): the parser (template shapes and the
/// synthetic real-file shapes, incl. the empty-bold and label rules), the
/// renderer, the section replace, the comparison, and end-to-end runs of
/// [runCockpitSync] against a temp store (gated gate) and a temp cockpit.
///
/// Every run sets OBX_MEMORY_DIR, OBX_MEMORY_COCKPIT_FILE and
/// OBX_MEMORY_COCKPIT_LOG to temp paths – never the operator's store,
/// cockpit or log. Synthetic data only (projects `company1`, `client3`).
library;

import 'dart:convert';
import 'dart:io';

import 'package:remembox/src/cockpit_sync.dart';
import 'package:remembox/src/memory_service.dart';
import 'package:remembox/src/model.dart';
import 'package:remembox/src/store_gate.dart';
import 'package:test/test.dart';

import 'support/fake_embedder.dart';

/// A synthetic file with the line shapes of a hand-kept cockpit – invented
/// content only.
const _synthetic = '''
# WORK — company1
## Sales
**▶ Website relaunch** — staging online · #12 #345
▶ **client3 brand guide offer** — waiting since 2026-10-07
⏳ Studio rent renewal — waiting for the landlord. Follow up
**▶** 12 sketches in the drawer, mostly old — sort them later
**▶ Todo:** order new pencils · check the plotter
▶ **When the printer is repaired, reprint the menu cards:** call the shop · later
· detail line ▶ not a thread
**⚠ Deadline risk** — check
**04.10.** ✅ closed thing
~~**▶ Old idea**~~ dropped
**▶ ~~Struck title~~** — gone
| 2026-10-10 | VAT | ▶ figures ready |
1. Numbered ▶ item
  - ▶ nested item
## Private
▶\u{FE0F} **Emoji variant** — with a variation selector
**❓ Hiring plan** — to decide
- **✅ Logo delivered** — done
**⏳ Garden fence. Neighbour asked about the height** – next week
**▶ Tax return **2025** draft** — almost done
**▶ Bike repair.** — tyre ordered
▶
**▶ ** —
<!-- remembox:threads:start -->
- ▶ **Generated** – since 2026-10-01 · thread 1
<!-- remembox:threads:end -->
''';

/// Noon of a LOCAL calendar day as stored ISO text: its local date is that
/// day in every time zone (a fixed UTC time is not – UTC−10 and UTC+14 are
/// a whole day apart), so the renderer fixtures do not depend on the zone
/// the tests run in.
String _localNoon(int y, int m, int d) =>
    DateTime(y, m, d, 12).toUtc().toIso8601String();

void main() {
  group('parseCockpit', () {
    test('the template: 13 thread lines with titles, states and section '
        'paths; tables, the numbered focus list and the archive are '
        'skipped', () {
      final parsed = parseCockpit(
        File('templates/cockpit.md').readAsStringSync(),
      );
      expect(parsed.unparsed, isEmpty);
      expect(parsed.lines.map((l) => l.title), [
        'Second designer hire',
        'Studio rent renewal',
        'Website relaunch',
        'Spring newsletter',
        'client3 brand guide offer',
        'client4 workshop',
        'Month-end closing February',
        'Radiator repair',
        'Garden allotment',
        'Cat vaccination',
        'kid1 school registration',
        'Summer holiday',
        'Tax return 2025',
      ]);
      final hire = parsed.lines.first;
      expect(hire.state, ThreadStates.inProgress);
      expect(hire.sectionPath, ['Work – company1', 'Management']);
      expect(parsed.lines[1].state, ThreadStates.paused);
      expect(parsed.lines[4].state, ThreadStates.waiting);
      expect(parsed.skipped['numbered'], 3);
      expect(parsed.skipped['archive'], 3);
      expect(parsed.skipped['table'], greaterThanOrEqualTo(14));
    });

    test('the real-file shapes: bold-first, symbol-first, plain, empty '
        'bold, label with colon; skip reasons counted; unparsed only for '
        'symbol lines without a title', () {
      final parsed = parseCockpit(_synthetic);
      expect(parsed.lines.map((l) => (l.state, l.title)), [
        (ThreadStates.inProgress, 'Website relaunch'),
        (ThreadStates.inProgress, 'client3 brand guide offer'),
        (ThreadStates.waiting, 'Studio rent renewal'),
        (ThreadStates.inProgress, '12 sketches in the drawer, mostly old'),
        (ThreadStates.inProgress, 'Todo: order new pencils'),
        // A label of more than three words is taken alone.
        (
          ThreadStates.inProgress,
          'When the printer is repaired, reprint the menu cards',
        ),
        (ThreadStates.inProgress, 'Emoji variant'),
        (ThreadStates.planned, 'Hiring plan'),
        (ThreadStates.done, 'Logo delivered'),
        // The bold text is cut at its first separator.
        (ThreadStates.waiting, 'Garden fence'),
        // Nested bold inside the outer bold does not end the title.
        (ThreadStates.inProgress, 'Tax return 2025 draft'),
        // A trailing full stop is dropped.
        (ThreadStates.inProgress, 'Bike repair'),
      ]);
      expect(parsed.lines.first.entryRefs, [12, 345]);
      expect(parsed.lines.first.lineNo, 3);
      expect(parsed.lines.first.sectionPath, ['WORK — company1', 'Sales']);
      expect(parsed.lines[6].sectionPath, ['WORK — company1', 'Private']);
      expect(parsed.skipped, {
        'detail': 1,
        'warning': 1,
        'archive': 1,
        'struck': 2,
        'table': 1,
        'numbered': 1,
        'nested': 1,
        'generated': 1,
      });
      expect(parsed.unparsed, [24, 25]);
      // Deterministic: a second parse gives the same titles.
      expect(
        parseCockpit(_synthetic).lines.map((l) => l.title),
        parsed.lines.map((l) => l.title),
      );
    });

    test('titles are capped at 80 code points, never splitting a '
        'surrogate pair, and flagged', () {
      final long = 'x' * 250;
      final emoji = '😀' * 90;
      final parsed = parseCockpit(
        '**▶ $long** — tail\n**▶** ${'y' * 120} — tail\n**▶ $emoji**\n',
      );
      expect(parsed.lines[0].title.runes.length, 80);
      expect(parsed.lines[0].title, endsWith('…'));
      expect(parsed.lines[0].titleTruncated, isTrue);
      expect(parsed.lines[1].title.runes.length, 80);
      expect(parsed.lines[2].title, '${'😀' * 79}…');
      expect(parsed.lines[0].toJson()['titleTruncated'], isTrue);
    });
  });

  group('render and replace', () {
    final now = DateTime(2026, 10, 14, 9, 5);
    final rows = <Map<String, Object?>>[
      {
        'id': 13,
        'title': 'client3 brand guide offer',
        'project': 'company1',
        'state': 'waiting',
        'since': null,
        'sinceRecordedAt': _localNoon(2026, 10, 13),
        'pausedUntil': null,
        'pauseElapsed': false,
        'entryCount': 1,
      },
      {
        'id': 12,
        'title': 'Website relaunch',
        'project': 'company1',
        'state': 'inProgress',
        'since': '2026-10-07T00:00:00.000Z',
        'sinceRecordedAt': _localNoon(2026, 10, 7),
        'pausedUntil': null,
        'pauseElapsed': false,
        'entryCount': 3,
      },
      {
        'id': 14,
        'title': 'Studio rent renewal',
        'project': 'company1',
        'state': 'paused',
        'since': null,
        'sinceRecordedAt': _localNoon(2026, 10, 1),
        'pausedUntil': '2026-10-10T00:00:00.000Z',
        'pauseElapsed': true,
        'entryCount': 0,
      },
      {
        'id': 2,
        'title': 'Brand workshop',
        'project': 'client3',
        'state': 'backlog',
        'since': null,
        'sinceRecordedAt': _localNoon(2026, 10, 2),
        'pausedUntil': null,
        'pauseElapsed': false,
        'entryCount': 0,
      },
    ];

    test('dates: a date-only value keeps its day, a timestamp shows the '
        'local date', () {
      const stamp = '2026-10-13T23:30:00.000Z';
      final local = DateTime.parse(stamp).toLocal();
      final localDate =
          '${local.year}-${local.month.toString().padLeft(2, '0')}-'
          '${local.day.toString().padLeft(2, '0')}';
      final section = renderThreadSection([
        {
          'id': 1,
          'title': 'A',
          'project': 'p',
          'state': 'waiting',
          'since': null,
          'sinceRecordedAt': stamp,
          'entryCount': 0,
        },
        {
          'id': 2,
          'title': 'B',
          'project': 'p',
          'state': 'waiting',
          'since': '2026-10-07T00:00:00.000Z',
          'sinceRecordedAt': stamp,
          'entryCount': 0,
        },
      ], now);
      expect(section, contains('recorded $localDate)'));
      expect(section, contains('since 2026-10-07'));
    });

    test('renderer golden', () {
      expect(renderThreadSection(rows, now), '''
<!-- remembox:threads:start -->
_Generated by `remembox cockpit-sync` 2026-10-14 09:05 – do not edit between the markers; change a state with thread_update._

### client3
- ○ **Brand workshop** – since unknown (recorded 2026-10-02) · thread 2

### company1
- ⏸ **Studio rent renewal** – until 2026-10-10 · thread 14 · pause elapsed
- ▶ **Website relaunch** – since 2026-10-07 · thread 12 · 3 entries
- ⏳ **client3 brand guide offer** – since unknown (recorded 2026-10-13) · thread 13 · 1 entry
<!-- remembox:threads:end -->''');
      expect(
        renderThreadSection(const [], now),
        contains('_No live threads._'),
      );
    });

    test('thread ids render as "thread <id>", never as a #<digits> token '
        '(#123 means a memory entry everywhere in the cockpit)', () {
      final lines = renderThreadSection(rows, now)
          .split('\n')
          .where((l) => l.startsWith('- '))
          .toList();
      expect(lines, isNotEmpty);
      for (final line in lines) {
        expect(line, isNot(matches(RegExp(r'#\d'))), reason: line);
        expect(line, matches(RegExp(r' · thread \d+(?: · |$)')), reason: line);
      }
    });

    test('missing markers: appended; same section with another timestamp: '
        'unchanged; bad marker shapes: refused', () {
      final section = renderThreadSection(rows, now);
      final appended = replaceThreadSection('# Cockpit\nhand line', section);
      expect(appended.appended, isTrue);
      expect(appended.changed, isTrue);
      expect(appended.content, '# Cockpit\nhand line\n\n$section\n');

      final again = replaceThreadSection(
        appended.content!,
        renderThreadSection(rows, now.add(const Duration(hours: 1))),
      );
      expect(again.changed, isFalse);
      expect(again.appended, isFalse);

      final changedRows = [
        {...rows[1], 'state': 'waiting'},
      ];
      expect(
        replaceThreadSection(
          appended.content!,
          renderThreadSection(changedRows, now),
        ).changed,
        isTrue,
      );

      for (final bad in [
        '$cockpitStartMarker\nx',
        'x\n$cockpitEndMarker',
        '$cockpitEndMarker\nx\n$cockpitStartMarker',
        '$cockpitStartMarker\n$cockpitEndMarker\n$cockpitStartMarker\n'
            '$cockpitEndMarker',
      ]) {
        final r = replaceThreadSection(bad, section);
        expect(r.error, isNotNull, reason: bad);
        expect(r.content, isNull);
      }
    });
  });

  group('compareCockpit', () {
    test('mismatch, noThread, noLine, ambiguous; the hash ignores line '
        'numbers', () {
      final lines = parseCockpit('''
**▶ Website relaunch** — a
**⏳ Brand guide offer** — b
**▶ Unknown topic** — c
**▶ Duplicated** — d
''').lines;
      final threads = <Map<String, Object?>>[
        {'id': 1, 'title': 'Website relaunch', 'project': 'company1',
          'state': 'waiting', 'since': null, 'closed': false},
        {'id': 2, 'title': 'brand guide offer', 'project': 'client3',
          'state': 'waiting', 'since': null, 'closed': false},
        {'id': 3, 'title': 'Duplicated', 'project': 'company1',
          'state': 'inProgress', 'since': null, 'closed': false},
        {'id': 4, 'title': 'Duplicated', 'project': 'client3',
          'state': 'inProgress', 'since': null, 'closed': false},
        {'id': 5, 'title': 'Only in the store', 'project': 'company1',
          'state': 'planned', 'since': null, 'closed': false},
        {'id': 6, 'title': 'Closed one', 'project': 'company1',
          'state': 'done', 'since': null, 'closed': true},
      ];
      final c = compareCockpit(lines, threads);
      expect(c.mismatches, [
        {
          'lineNo': 1,
          'title': 'Website relaunch',
          'lineState': 'inProgress',
          'threadId': 1,
          'threadState': 'waiting',
          'since': null,
        },
      ]);
      expect(c.noThread.map((m) => m['title']), ['Unknown topic']);
      expect(c.ambiguous.single['threadIds'], [3, 4]);
      expect(c.noLine.map((m) => m['threadId']), [5]);

      final moved = parseCockpit('''

**▶ Unknown topic** — c
**⏳ Brand guide offer** — b
**▶ Website relaunch** — a
**▶ Duplicated** — d
''').lines;
      expect(compareCockpit(moved, threads).hash, c.hash);
      final fixed = [
        {...threads[0], 'state': 'inProgress'},
        ...threads.skip(1),
      ];
      expect(compareCockpit(lines, fixed).hash, isNot(c.hash));
    });
  });

  group('cockpitCompareLogPath', () {
    // Must agree with the default of tool/hooks/cockpit-sync-hook.sh
    // (pinned there by test/cockpit_hook_test.dart).
    test('an explicit OBX_MEMORY_COCKPIT_LOG wins on every platform', () {
      for (final os in ['macos', 'linux']) {
        expect(
          cockpitCompareLogPath({
            'OBX_MEMORY_COCKPIT_LOG': '/x/c.log',
            'HOME': '/h',
          }, operatingSystem: os),
          '/x/c.log',
        );
      }
    });

    test('macOS: ~/Library/Logs/remembox/cockpit-compare.log', () {
      expect(
        cockpitCompareLogPath({
          'HOME': '/fakehome',
          'XDG_STATE_HOME': '/ignored',
        }, operatingSystem: 'macos'),
        '/fakehome/Library/Logs/remembox/cockpit-compare.log',
      );
    });

    test('elsewhere: XDG_STATE_HOME, else ~/.local/state', () {
      expect(
        cockpitCompareLogPath({
          'HOME': '/fakehome',
          'XDG_STATE_HOME': '/state',
        }, operatingSystem: 'linux'),
        '/state/remembox/cockpit-compare.log',
      );
      expect(
        cockpitCompareLogPath({
          'HOME': '/fakehome',
          'XDG_STATE_HOME': '',
        }, operatingSystem: 'linux'),
        '/fakehome/.local/state/remembox/cockpit-compare.log',
      );
      expect(
        cockpitCompareLogPath({
          'HOME': '/fakehome',
        }, operatingSystem: 'linux'),
        '/fakehome/.local/state/remembox/cockpit-compare.log',
      );
    });

    test('the default follows the host platform', () {
      final path = cockpitCompareLogPath({'HOME': '/fakehome'});
      expect(
        path,
        Platform.isMacOS
            ? '/fakehome/Library/Logs/remembox/cockpit-compare.log'
            : '/fakehome/.local/state/remembox/cockpit-compare.log',
      );
    });
  });

  group('runCockpitSync', () {
    late Directory tempDir;
    late String storeDir;
    late File cockpit;
    late String compareLog;
    late List<String> logLines;
    late Map<String, String> env;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('remembox_cockpit_');
      storeDir = '${tempDir.path}/store';
      cockpit = File('${tempDir.path}/cockpit.md')
        ..writeAsStringSync('''
# Cockpit

## company1
**▶ Website relaunch** — staging online
**⏳ Brand guide offer** — waiting

$cockpitStartMarker
$cockpitEndMarker
''');
      compareLog = '${tempDir.path}/logs/cockpit-compare.log';
      logLines = [];
      env = {
        'HOME': tempDir.path,
        'OBX_MEMORY_DIR': storeDir,
        'OBX_MEMORY_COCKPIT_FILE': cockpit.path,
        'OBX_MEMORY_COCKPIT_LOG': compareLog,
      };
    });

    tearDown(() => tempDir.deleteSync(recursive: true));

    /// Seeds threads through a gated service (closed again afterwards –
    /// runCockpitSync opens the store itself).
    Future<void> seed(
      Future<void> Function(MemoryService service) body,
    ) async {
      final gate = await StoreGate.gated(
        storeDirectory: storeDir,
        log: (_) {},
      );
      final service = MemoryService(
        gate: gate,
        embedder: FakeEmbedder(),
        log: (_) {},
      );
      try {
        await body(service);
      } finally {
        await service.dispose();
        await gate.close();
      }
    }

    Future<int> run([List<String> args = const []]) =>
        runCockpitSync(args, log: logLines.add, env: env);

    List<Map<String, Object?>> logEntries() => File(compareLog)
        .readAsLinesSync()
        .where((l) => l.trim().isNotEmpty)
        .map((l) => jsonDecode(l) as Map<String, Object?>)
        .toList();

    test('the compare log is 600 when created, and an existing looser '
        'one is tightened (logged)', () async {
      await seed((s) async {
        await s.threadUpdate(
          title: 'Website relaunch',
          project: 'company1',
          state: ThreadStates.inProgress,
        );
      });
      expect(await run(), CockpitExit.ok);
      expect(File(compareLog).statSync().mode & 0x1FF, 0x180,
          reason: 'created with 600');
      Process.runSync('chmod', ['644', compareLog]);
      logLines.clear();
      // A changed cockpit hash writes a new line into the existing log.
      cockpit.writeAsStringSync(
        '${cockpit.readAsStringSync()}\n**▶ Another matter** — new\n',
      );
      expect(await run(), CockpitExit.ok);
      expect(File(compareLog).statSync().mode & 0x1FF, 0x180,
          reason: 'tightened from 644');
      expect(logLines, contains(contains('had mode 644 – tightening to 600')));
      // Already 600: no change, no chatter.
      logLines.clear();
      cockpit.writeAsStringSync(
        '${cockpit.readAsStringSync()}\n**▶ Yet another** — new\n',
      );
      expect(await run(), CockpitExit.ok);
      expect(logLines.where((l) => l.contains('tightening')), isEmpty);
    });

    test('renders the section in place, keeps a .bak, logs the comparison '
        'once; an unchanged second run writes neither', () async {
      Process.runSync('chmod', ['600', cockpit.path]);
      await seed((s) async {
        await s.threadUpdate(
          title: 'Website relaunch',
          project: 'company1',
          state: ThreadStates.inProgress,
        );
        await s.threadUpdate(
          title: 'Brand guide offer',
          project: 'client3',
          state: ThreadStates.inProgress,
        );
      });
      final before = cockpit.readAsStringSync();
      final inode = Process.runSync('stat', ['-f', '%i', cockpit.path]).stdout;

      expect(await run(), CockpitExit.ok);
      final after = cockpit.readAsStringSync();
      expect(after, contains('- ▶ **Website relaunch** – since unknown'));
      expect(after, contains('### client3'));
      expect(after, startsWith('# Cockpit\n\n## company1\n'));
      // The backup sits next to the compare log, never next to the cockpit.
      final backup = File('${tempDir.path}/logs/cockpit.bak');
      expect(backup.readAsStringSync(), before);
      expect(backup.statSync().mode & 0x1FF, 0x180, reason: 'backup is 600');
      expect(File('${cockpit.path}.bak').existsSync(), isFalse);
      expect(
        Process.runSync('stat', ['-f', '%i', cockpit.path]).stdout,
        inode,
        reason: 'rewritten in place, same inode',
      );
      expect(cockpit.statSync().mode & 0x1FF, 0x180, reason: 'still 600');
      final entries = logEntries();
      expect(entries, hasLength(1));
      expect(entries.single['parsed'], 2);
      expect((entries.single['mismatches'] as List).single['title'],
          'Brand guide offer');
      expect(
        logLines.last,
        allOf(
          startsWith('[cockpit] parsed=2 unparsed=0 threads=2 '
              'sectionChanged=true mismatches=1'),
          endsWith('log=appended'),
        ),
      );

      final modified = cockpit.statSync().modified;
      logLines.clear();
      expect(await run(), CockpitExit.ok);
      expect(cockpit.readAsStringSync(), after);
      expect(cockpit.statSync().modified, modified);
      expect(logEntries(), hasLength(1), reason: 'same hash, not appended');
      expect(logLines.last, endsWith('sectionChanged=false mismatches=1 '
          'noThread=0 noLine=0 ambiguous=0 log=unchanged'));

      await seed((s) async {
        await s.threadUpdate(
          title: 'Brand guide offer',
          project: 'client3',
          state: ThreadStates.waiting,
        );
      });
      expect(await run(), CockpitExit.ok);
      expect(logEntries(), hasLength(2));
      expect(logEntries().last['mismatches'], isEmpty);
      expect(cockpit.readAsStringSync(), contains('- ⏳ **Brand guide offer**'));
    });

    test('--dry-run writes nothing', () async {
      await seed((s) async {
        await s.threadUpdate(
          title: 'Website relaunch',
          project: 'company1',
          state: ThreadStates.inProgress,
        );
      });
      final before = cockpit.readAsStringSync();
      expect(await run(['--dry-run']), CockpitExit.ok);
      expect(cockpit.readAsStringSync(), before);
      expect(File('${tempDir.path}/logs/cockpit.bak').existsSync(), isFalse);
      expect(File(compareLog).existsSync(), isFalse);
      expect(logLines.last, startsWith('[cockpit] dry run (nothing written)'));
    });

    test('--parse-only prints the parsed lines as JSON and needs no store',
        () async {
      final outFile = File('${tempDir.path}/out.json');
      final sink = outFile.openWrite();
      final code = await runCockpitSync(
        ['--parse-only', '--cockpit', cockpit.path],
        log: logLines.add,
        env: {...env, 'OBX_MEMORY_DIR': '${tempDir.path}/none'},
        out: sink,
      );
      await sink.close();
      expect(code, CockpitExit.ok);
      final json = jsonDecode(outFile.readAsStringSync()) as Map;
      expect(json['parsed'], 2);
      expect((json['lines'] as List).first['title'], 'Website relaunch');
      expect(Directory('${tempDir.path}/none').existsSync(), isFalse);
    });

    test('bad markers: exit 4, nothing written, a failure line logged',
        () async {
      await seed((s) => s.stats());
      cockpit.writeAsStringSync('$cockpitStartMarker\nonly a start\n');
      expect(await run(), CockpitExit.badMarkers);
      expect(cockpit.readAsStringSync(), '$cockpitStartMarker\nonly a start\n');
      expect(logEntries().single['error'], contains('expected exactly one'));
    });

    test('a cockpit changed during the sync is not written (exit 3)',
        () async {
      await seed((s) async {
        await s.threadUpdate(
          title: 'Website relaunch',
          project: 'company1',
          state: ThreadStates.inProgress,
        );
      });
      final code = await runCockpitSync(
        const [],
        log: logLines.add,
        env: env,
        debugBeforeWrite: () =>
            cockpit.writeAsStringSync('edited meanwhile\n', mode: FileMode.append),
      );
      expect(code, CockpitExit.changedDuringSync);
      expect(cockpit.readAsStringSync(), endsWith('edited meanwhile\n'));
      expect(cockpit.readAsStringSync(), isNot(contains('_Generated by')));
      expect(logEntries().single['error'], contains('changed during sync'));
    });

    test('no store, no cockpit, unknown argument', () async {
      expect(await run(), CockpitExit.error);
      expect(logLines, contains(contains('no RememBox store')));
      expect(Directory(storeDir).existsSync(), isFalse);
      expect(
        await runCockpitSync(
          const [],
          log: logLines.add,
          env: {...env, 'OBX_MEMORY_COCKPIT_FILE': ''},
        ),
        CockpitExit.usage,
      );
      expect(await run(['--frobnicate']), CockpitExit.usage);
      expect(
        await run(['--cockpit', '${tempDir.path}/missing.md']),
        CockpitExit.error,
      );
    });

    test('--dry-run writes no failure line to the compare log either',
        () async {
      await seed((s) => s.stats());
      cockpit.writeAsStringSync('$cockpitStartMarker\nonly a start\n');
      expect(await run(['--dry-run']), CockpitExit.badMarkers);
      expect(File(compareLog).existsSync(), isFalse);
      Directory(storeDir).deleteSync(recursive: true);
      expect(await run(['--dry-run']), CockpitExit.error);
      expect(File(compareLog).existsSync(), isFalse);
    });

    test('an unreadable store is a logged error (exit 1), not a crash',
        () async {
      Directory(storeDir).createSync(recursive: true);
      File('$storeDir/data.mdb').writeAsStringSync('not a database' * 100);
      final before = cockpit.readAsStringSync();
      expect(await run(), CockpitExit.error);
      expect(logLines, contains(startsWith('[cockpit] could not read the store')));
      expect(logEntries().single['error'], contains('could not read the store'));
      expect(cockpit.readAsStringSync(), before);
    });

    test('a truncated read of the live threads is never written', () async {
      final gate = await StoreGate.gated(storeDirectory: storeDir, log: (_) {});
      final now = DateTime.now().toUtc();
      await gate.withStore('seed-many', (session) {
        session.threads.putMany([
          for (var i = 0; i <= threadReadMaxRows; i++)
            Thread(
              title: 'Thread $i',
              titleKey: ScopeKey.of('Thread $i'),
              project: 'company1',
              state: ThreadStates.planned,
              stateRecordedAt: now,
            ),
        ]);
      });
      await gate.close();
      final before = cockpit.readAsStringSync();
      expect(await run(), CockpitExit.error);
      expect(cockpit.readAsStringSync(), before);
      final line = logEntries().single;
      expect(line['truncated'], isTrue);
      expect(line['error'], contains('could be read'));
    });

    test('relative paths resolve against REMEMBOX_CALLER_CWD', () async {
      await seed((s) => s.stats());
      final caller = Directory('${tempDir.path}/caller')..createSync();
      final rel = File('${caller.path}/my-cockpit.md')
        ..writeAsStringSync('# Mine\n');
      final code = await runCockpitSync(
        const [],
        log: logLines.add,
        env: {
          ...env,
          'REMEMBOX_CALLER_CWD': caller.path,
          'OBX_MEMORY_COCKPIT_FILE': 'my-cockpit.md',
          'OBX_MEMORY_COCKPIT_LOG': 'logs/compare.log',
        },
      );
      expect(code, CockpitExit.ok, reason: logLines.join('\n'));
      expect(rel.readAsStringSync(), contains(cockpitStartMarker));
      expect(File('${caller.path}/logs/compare.log').existsSync(), isTrue);
      expect(File('${caller.path}/logs/cockpit.bak').existsSync(), isTrue);
    });

    test('a compare log over 1 MB is rotated to .1 (logged)', () async {
      await seed((s) => s.stats());
      File(compareLog)
        ..createSync(recursive: true)
        ..writeAsStringSync('{"old":true}\n' * 90000);
      expect(File(compareLog).lengthSync(), greaterThan(1024 * 1024));
      expect(await run(), CockpitExit.ok);
      expect(File('$compareLog.1').existsSync(), isTrue);
      expect(logEntries(), hasLength(1));
      expect(logLines, contains(contains('rotated to $compareLog.1')));
    });
  });
}
