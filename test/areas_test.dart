/// Tests for the WP2 areas tools (memory_service_areas.dart) — 2026-09-21,
/// areas and facts (0.3.0), plan §2.2/§5, addendum M1/M2/"minor changes".
///
/// Synthetic data only (maintainer rule): projects `acme-app`, `Acme-App`
/// (deliberate case-duplicate), `home`, `garden`; areas `work`, `finance`,
/// `family`.
///
/// WP3's `factSet` is still `throw UnimplementedError('WP3')` at the time
/// this file was written (parallel work package), so every test needing a
/// [Fact] row creates it directly on the [Fact] box, inside the store the
/// test's own [openTestGate] already holds open — the same pattern
/// `registry_test.dart` uses for [ProjectScope]/[Area]/[AreaMembership]
/// rows (direct `store.box<T>()` access, no service lending needed for
/// pure test-fixture setup).
library;

import 'dart:io';

import 'package:remembox/objectbox.g.dart';
import 'package:remembox/src/memory_service.dart';
import 'package:remembox/src/model.dart';
import 'package:remembox/src/store_gate.dart';
import 'package:test/test.dart';

import 'helpers/test_store_gate.dart';
import 'support/fake_embedder.dart';

void main() {
  late Directory tempDir;
  late TestGate testGate;
  late Store store;
  late StoreGate gate;
  late FakeEmbedder embedder;
  late MemoryService service;
  late List<String> logLines;

  void logCapture(String line) => logLines.add(line);

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('remembox_areas_test_');
    logLines = [];
    testGate = await openTestGate(tempDir.path, log: logCapture);
    store = testGate.store;
    gate = testGate.gate;
    embedder = FakeEmbedder();
    service = MemoryService(gate: gate, embedder: embedder, log: logCapture);
  });

  tearDown(() async {
    await service.dispose();
    await testGate.close();
    tempDir.deleteSync(recursive: true);
  });

  Box<MemoryEntry> entries() => store.box<MemoryEntry>();
  Box<ProjectScope> projects() => store.box<ProjectScope>();
  Box<AreaMembership> memberships() => store.box<AreaMembership>();
  Box<Fact> facts() => store.box<Fact>();

  Fact syntheticFact({
    required String project,
    required String subject,
    String attribute = 'status',
    String valueText = 'ok',
    DateTime? validFrom,
    DateTime? validUntil,
    DateTime? retractedAt,
  }) => Fact(
    project: project,
    subject: subject,
    attribute: attribute,
    factKey: Fact.keyFor(project, subject, attribute),
    valueType: FactValueType.text,
    valueText: valueText,
    sourceType: MemorySource.note,
    validFrom: validFrom,
    validUntil: validUntil,
    retractedAt: retractedAt,
  );

  group('areasList', () {
    test('many-to-many: one project in two areas is counted in both',
        () async {
      await service.areaSet(name: 'work');
      await service.areaSet(name: 'finance');
      await service.projectSet(
        name: 'acme-app',
        addAreas: ['work', 'finance'],
      );
      await service.remember(text: 'first memo', project: 'acme-app');
      await service.remember(text: 'second memo', project: 'acme-app');

      final result = await service.areasList();
      final areasOut = (result['areas'] as List).cast<Map<String, Object?>>();
      final work = areasOut.singleWhere((a) => a['name'] == 'work');
      final finance = areasOut.singleWhere((a) => a['name'] == 'finance');

      for (final area in [work, finance]) {
        final projectsOut =
            (area['projects'] as List).cast<Map<String, Object?>>();
        expect(projectsOut, hasLength(1));
        expect(projectsOut.single['name'], 'acme-app');
        expect(projectsOut.single['liveEntries'], 2);
        expect(area['liveEntries'], 2);
      }
    });

    test('unregistered projects (entries with no ProjectScope row) are '
        'reported, never silently dropped', () async {
      // A pre-0.3.0-style legacy row, written straight to the box: since
      // WP4, `remember` auto-registers its project (`_ensureProjectScope`
      // hook), so going through `remember` here would no longer leave the
      // project unregistered – this bypasses that hook the same way
      // `registry_test.dart` documents doing for other legacy shapes.
      entries().put(
        MemoryEntry(
          title: '',
          text: 'legacy memo',
          kind: MemoryKind.fact,
          sourceType: MemorySource.note,
          project: 'legacy-app',
          contentHash: MemoryService.contentHashOf('legacy memo'),
        ),
      );

      final result = await service.areasList();
      expect(result['unregisteredProjects'], ['legacy-app']);
      expect(
        result['warnings'],
        contains(contains('legacy-app')),
      );
      // Review minor 2: points at a real MCP tool (`reindex`), not the
      // internal `backfill_project_registry` method name a caller cannot
      // invoke directly.
      expect(result['warnings'], contains(contains('reindex')));
      expect(
        result['warnings'],
        isNot(contains(contains('backfill_project_registry'))),
      );
    });

    test('case variants acme-app / Acme-App stay separate rows and '
        'separate counts (F3 regression)', () async {
      await service.areaSet(name: 'work');
      await service.projectSet(name: 'acme-app', addAreas: ['work']);
      await service.projectSet(name: 'Acme-App', addAreas: ['work']);
      await service.remember(text: 'lowercase memo', project: 'acme-app');
      await service.remember(
        text: 'titlecase memo one',
        project: 'Acme-App',
      );
      await service.remember(
        text: 'titlecase memo two',
        project: 'Acme-App',
      );

      final result = await service.areasList();
      final work = (result['areas'] as List)
          .cast<Map<String, Object?>>()
          .singleWhere((a) => a['name'] == 'work');
      final projectsOut =
          (work['projects'] as List).cast<Map<String, Object?>>();
      expect(projectsOut, hasLength(2));
      final byName = {
        for (final p in projectsOut) p['name'] as String: p['liveEntries'],
      };
      expect(byName, {'acme-app': 1, 'Acme-App': 2});
      expect(work['liveEntries'], 3);
    });

    test('projectsWithoutArea: a registered project with zero memberships',
        () async {
      await service.projectSet(name: 'garden');
      await service.areaSet(name: 'work');
      await service.projectSet(name: 'acme-app', addAreas: ['work']);

      final result = await service.areasList();
      expect(result['projectsWithoutArea'], ['garden']);
    });

    test('blank project entries are counted and excluded from every '
        'project/area listing', () async {
      // Legacy row with a blank project string — cannot arise through
      // `remember` (which rejects a blank project), so written directly,
      // exactly as `registry_test.dart` documents doing for other legacy
      // shapes.
      entries().put(
        MemoryEntry(
          title: '',
          text: 'legacy blank-project memo',
          kind: MemoryKind.fact,
          project: '',
          sourceType: MemorySource.note,
          contentHash: 'deadbeef',
        ),
      );

      final result = await service.areasList();
      expect(result['blankProjectEntries'], 1);
      expect(result['unregisteredProjects'], isEmpty);
      expect(
        result['warnings'],
        contains(contains('blank project string')),
      );
    });

    test(
      'review minor 8: a whitespace-only project string is treated as '
      'blank (counted, never listed as unregistered)',
      () async {
        entries().put(
          MemoryEntry(
            title: '',
            text: 'legacy whitespace-project memo',
            kind: MemoryKind.fact,
            project: '   ',
            sourceType: MemorySource.note,
            contentHash: 'deadbeef2',
          ),
        );

        final result = await service.areasList();
        expect(result['blankProjectEntries'], 1);
        expect(result['unregisteredProjects'], isEmpty);
      },
    );

    test('membershipsWithoutArea / membershipsWithoutProjectRows: rows '
        'whose target no longer exists are reported, not silently '
        'dropped (addendum M1 — replaces stats.registry.danglingMemberships)',
        () async {
      await service.areaSet(name: 'work');
      await service.projectSet(name: 'acme-app', addAreas: ['work']);

      // Simulate a cross-device replace that removed the Area row a
      // membership still points at, and a membership pointing at a
      // project name with no ProjectScope row — both written directly
      // (no normal API path produces these; they exist to prove the
      // report-only detection works, per addendum M1/U3).
      memberships().put(
        AreaMembership(
          key: AreaMembership.keyFor('ghost-area', 'acme-app'),
          area: 'ghost-area',
          project: 'acme-app',
        ),
      );
      memberships().put(
        AreaMembership(
          key: AreaMembership.keyFor('work', 'ghost-project'),
          area: 'work',
          project: 'ghost-project',
        ),
      );

      final result = await service.areasList();
      expect(result['membershipsWithoutArea'], 1);
      expect(result['membershipsWithoutProjectRows'], 1);
      expect(
        result['warnings'],
        allOf(
          contains(contains('area that no longer exists')),
          contains(contains('no registry row')),
        ),
      );
      // The valid membership (work/acme-app) is unaffected.
      final work = (result['areas'] as List)
          .cast<Map<String, Object?>>()
          .singleWhere((a) => a['name'] == 'work');
      expect(
        (work['projects'] as List).cast<Map<String, Object?>>().map(
          (p) => p['name'],
        ),
        ['acme-app'],
      );
    });

    test('archived projects are listed with status: archived and still '
        'counted (status is informational, addendum "minor changes"; '
        'areasList no longer takes an includeArchived toggle)', () async {
      await service.areaSet(name: 'work');
      await service.projectSet(name: 'acme-app', addAreas: ['work']);
      await service.remember(text: 'first memo', project: 'acme-app');
      await service.projectSet(
        name: 'acme-app',
        status: ProjectStatus.archived,
      );
      // A second, unassigned archived project – exercises
      // projectsWithoutArea too.
      await service.projectSet(
        name: 'garden',
        status: ProjectStatus.archived,
      );

      final result = await service.areasList();

      final work = (result['areas'] as List)
          .cast<Map<String, Object?>>()
          .singleWhere((a) => a['name'] == 'work');
      final workProjects =
          (work['projects'] as List).cast<Map<String, Object?>>();
      expect(workProjects, hasLength(1));
      expect(workProjects.single['name'], 'acme-app');
      expect(workProjects.single['status'], ProjectStatus.archived);
      // Still counted: the archived project's live entry is not dropped
      // from either the per-project or the per-area total.
      expect(workProjects.single['liveEntries'], 1);
      expect(work['liveEntries'], 1);

      expect(result['projectsWithoutArea'], ['garden']);
    });

    test('review M3: the result carries _provenance_note', () async {
      await service.areaSet(name: 'work');
      final result = await service.areasList();
      expect(result['_provenance_note'], isNotNull);
    });

    test(
      'review minor 13: per-project currentFacts count is reported',
      () async {
        await service.areaSet(name: 'work');
        await service.projectSet(name: 'acme-app', addAreas: ['work']);
        await service.factSet(
          subject: 'Flat B',
          attribute: 'rent',
          project: 'acme-app',
          valueNumber: 1200,
        );
        await service.factSet(
          subject: 'Car',
          attribute: 'insurer',
          project: 'acme-app',
          valueText: 'Acme Insurance',
        );
        // A retracted fact must not count as current.
        final retracted = await service.factSet(
          subject: 'Account 1',
          attribute: 'renewal',
          project: 'acme-app',
          valueText: 'X',
        );
        await service.factForget(retracted['id'] as int);

        final result = await service.areasList();
        final work = (result['areas'] as List)
            .cast<Map<String, Object?>>()
            .singleWhere((a) => a['name'] == 'work');
        final project = (work['projects'] as List)
            .cast<Map<String, Object?>>()
            .single;
        expect(project['currentFacts'], 2);
      },
    );

    test(
      'review M1: a project holding an area membership but whose own '
      'status is merged is reported (membershipsOnMergedProjects), not '
      'silently dropped',
      () async {
        await service.areaSet(name: 'work');
        await service.remember(text: 'one', project: 'x');
        await service.remember(text: 'two', project: 'X');
        await service.projectMerge(from: 'x', into: 'X');
        // A later write under the tombstoned name is allowed (with a
        // warning naming mergedInto) – it can leave the merged row
        // holding a real area membership.
        await service.projectSet(name: 'x', addAreas: ['work']);

        final result = await service.areasList();
        expect(result['membershipsOnMergedProjects'], ['x']);
        expect(
          result['warnings'],
          contains(contains('merged into another name')),
        );
        // The merged project itself still does not appear as a member of
        // "work" – only reported separately.
        final work = (result['areas'] as List)
            .cast<Map<String, Object?>>()
            .singleWhere((a) => a['name'] == 'work');
        expect(
          (work['projects'] as List).cast<Map<String, Object?>>().map(
            (p) => p['name'],
          ),
          isNot(contains('x')),
        );
      },
    );
  });

  group('projectMerge', () {
    test('moves entries and facts, carries areas, tombstones the source '
        'row, registers the target', () async {
      await service.areaSet(name: 'work');
      await service.projectSet(name: 'acme-app', addAreas: ['work']);
      final e1 = await service.remember(
        text: 'first memo',
        project: 'acme-app',
      );
      final e2 = await service.remember(
        text: 'second memo',
        project: 'acme-app',
      );
      facts().put(syntheticFact(project: 'acme-app', subject: 'Flat B'));

      final result = await service.projectMerge(
        from: 'acme-app',
        into: 'acme-corp',
      );

      expect(result['entriesMoved'], 2);
      expect(result['factsMoved'], 1);
      expect(result['areasCarried'], ['work']);
      expect(result['fromStatus'], ProjectStatus.merged);
      expect(result['mergedInto'], 'acme-corp');

      expect(entries().get(e1['id'] as int)!.project, 'acme-corp');
      expect(entries().get(e2['id'] as int)!.project, 'acme-corp');
      expect(facts().getAll().single.project, 'acme-corp');
      expect(
        facts().getAll().single.factKey,
        Fact.keyFor('acme-corp', 'Flat B', 'status'),
      );

      final fromRow = projects()
          .query(ProjectScope_.name.equals('acme-app', caseSensitive: true))
          .build()
          .findFirst()!;
      expect(fromRow.status, ProjectStatus.merged);
      expect(fromRow.mergedInto, 'acme-corp');

      final intoRow = projects()
          .query(ProjectScope_.name.equals('acme-corp', caseSensitive: true))
          .build()
          .findFirst()!;
      expect(intoRow.status, ProjectStatus.active);

      // Memberships moved, not duplicated.
      expect(memberships().count(), 1);
      final m = memberships().getAll().single;
      expect(m.area, 'work');
      expect(m.project, 'acme-corp');
    });

    test('dryRun writes nothing but reports identical counts', () async {
      await service.areaSet(name: 'work');
      await service.projectSet(name: 'acme-app', addAreas: ['work']);
      await service.remember(text: 'a memo', project: 'acme-app');
      facts().put(syntheticFact(project: 'acme-app', subject: 'Flat B'));

      final dry = await service.projectMerge(
        from: 'acme-app',
        into: 'acme-corp',
        dryRun: true,
      );
      expect(dry['entriesMoved'], 1);
      expect(dry['factsMoved'], 1);
      expect(dry['areasCarried'], ['work']);

      // Nothing written: source untouched, target never registered.
      expect(entries().getAll().single.project, 'acme-app');
      expect(facts().getAll().single.project, 'acme-app');
      expect(memberships().getAll().single.project, 'acme-app');
      expect(
        projects()
            .query(ProjectScope_.name.equals('acme-corp', caseSensitive: true))
            .build()
            .findFirst(),
        isNull,
      );
      final fromRow = projects()
          .query(ProjectScope_.name.equals('acme-app', caseSensitive: true))
          .build()
          .findFirst()!;
      expect(fromRow.status, ProjectStatus.active);

      final real = await service.projectMerge(
        from: 'acme-app',
        into: 'acme-corp',
      );
      expect(real['entriesMoved'], 1);
      expect(real['factsMoved'], 1);
    });

    test('idempotent: re-running after completion reports zero moves',
        () async {
      await service.areaSet(name: 'work');
      await service.projectSet(name: 'acme-app', addAreas: ['work']);
      await service.remember(text: 'a memo', project: 'acme-app');

      final first = await service.projectMerge(
        from: 'acme-app',
        into: 'acme-corp',
      );
      expect(first['entriesMoved'], 1);

      final second = await service.projectMerge(
        from: 'acme-app',
        into: 'acme-corp',
      );
      expect(second['entriesMoved'], 0);
      expect(second['factsMoved'], 0);
      expect(second['areasCarried'], isEmpty);
      expect(entries().getAll().single.project, 'acme-corp');
    });

    test(
      'review M1: merging into a tombstoned ("merged") project '
      'reactivates it, so the undo round trip x->X->x makes x visible '
      'again everywhere',
      () async {
        await service.areaSet(name: 'work');
        await service.remember(text: 'one', project: 'x');
        await service.remember(text: 'two', project: 'X');
        await service.projectSet(name: 'x', addAreas: ['work']);

        await service.projectMerge(from: 'x', into: 'X');
        final back = await service.projectMerge(from: 'X', into: 'x');
        expect(back['intoReactivated'], isTrue);

        final xRow = projects()
            .query(ProjectScope_.name.equals('x', caseSensitive: true))
            .build()
            .findFirst()!;
        expect(xRow.status, ProjectStatus.active);
        expect(xRow.mergedInto, isEmpty);

        // The area filter sees x's data again – the whole point of M1.
        final listRecent = await service.listRecent(area: 'work');
        expect(listRecent['count'], 2);
        expect(listRecent['warning'], isNull);

        final areasList = await service.areasList();
        final work = (areasList['areas'] as List)
            .cast<Map<String, Object?>>()
            .singleWhere((a) => a['name'] == 'work');
        expect(
          (work['projects'] as List).cast<Map<String, Object?>>().map(
            (p) => p['name'],
          ),
          contains('x'),
        );

        // A further write under x succeeds cleanly – no stale
        // mergedInto/"was merged into" warning left over from before the
        // reactivation (x and X are still near-duplicate names by
        // case, so a near-duplicate warning is expected and fine).
        final rem = await service.remember(text: 'three', project: 'x');
        expect(rem['warning'], isNot(contains('was merged into')));
      },
    );

    test(
      'dryRun reports intoReactivated truthfully instead of always false',
      () async {
        await service.remember(text: 'one', project: 'x');
        await service.remember(text: 'two', project: 'X');
        await service.projectMerge(from: 'x', into: 'X');

        // X is now tombstoned (merged into x is not the case here – x was
        // merged INTO X, so X stays active and x is the tombstone). Undo
        // once for real so X becomes the tombstone this time.
        await service.projectMerge(from: 'X', into: 'x');
        await service.projectMerge(from: 'x', into: 'X');
        // Now x is tombstoned (merged into X). A dryRun merge back INTO
        // x must predict the same reactivation the real run would do.
        final dry = await service.projectMerge(
          from: 'X',
          into: 'x',
          dryRun: true,
        );
        expect(dry['intoReactivated'], isTrue);

        // Nothing was actually written by the dryRun.
        final xRow = projects()
            .query(ProjectScope_.name.equals('x', caseSensitive: true))
            .build()
            .findFirst()!;
        expect(xRow.status, ProjectStatus.merged);

        final real = await service.projectMerge(from: 'X', into: 'x');
        expect(real['intoReactivated'], isTrue);
      },
    );

    test(
      'review M1: project_set clears the stale mergedInto pointer when '
      'it moves a project\'s status away from merged',
      () async {
        await service.remember(text: 'one', project: 'x');
        await service.projectMerge(from: 'x', into: 'X');

        final result = await service.projectSet(
          name: 'x',
          status: ProjectStatus.active,
        );
        expect(result['status'], ProjectStatus.active);

        final xRow = projects()
            .query(ProjectScope_.name.equals('x', caseSensitive: true))
            .build()
            .findFirst()!;
        expect(xRow.status, ProjectStatus.active);
        expect(xRow.mergedInto, isEmpty);
      },
    );

    test('x into X moves only the case-duplicate, not the target', () async {
      await service.projectSet(name: 'acme-app');
      await service.projectSet(name: 'Acme-App');
      await service.remember(text: 'lowercase memo', project: 'acme-app');
      await service.remember(text: 'titlecase memo', project: 'Acme-App');

      final result = await service.projectMerge(
        from: 'acme-app',
        into: 'Acme-App',
      );
      expect(result['entriesMoved'], 1);

      final remaining = entries().getAll();
      expect(remaining, hasLength(2));
      expect(remaining.every((e) => e.project == 'Acme-App'), isTrue);
    });

    test('rejects a "from" that does not exist anywhere', () {
      expect(
        () => service.projectMerge(from: 'ghost', into: 'acme-app'),
        throwsA(isA<ValidationException>()),
      );
    });

    test('rejects an empty source name', () {
      expect(
        () => service.projectMerge(from: '', into: 'acme-app'),
        throwsA(isA<ValidationException>()),
      );
    });

    test('a merged project name is excluded from later area resolution '
        '(_resolveAreaProjects, exercised through areasList — same pattern '
        'registry_test.dart uses to pin private registry primitives '
        'through a public surface)', () async {
      await service.areaSet(name: 'work');
      await service.projectSet(name: 'acme-app', addAreas: ['work']);
      await service.remember(text: 'a memo', project: 'acme-app');
      await service.projectMerge(from: 'acme-app', into: 'acme-corp');

      // The merge itself already moved the membership away from
      // "acme-app" — simulate the case addendum M1/U3 is actually about
      // (a stale membership surviving under the now-merged name, e.g.
      // from a cross-device replace) by writing one back directly, and
      // confirm area resolution still excludes it because the registry
      // row says merged, not because the membership happens to be gone.
      memberships().put(
        AreaMembership(
          key: AreaMembership.keyFor('work', 'acme-app'),
          area: 'work',
          project: 'acme-app',
        ),
      );

      final result = await service.areasList();
      final work = (result['areas'] as List)
          .cast<Map<String, Object?>>()
          .singleWhere((a) => a['name'] == 'work');
      final projectNames = (work['projects'] as List)
          .cast<Map<String, Object?>>()
          .map((p) => p['name']);
      expect(projectNames, isNot(contains('acme-app')));
      expect(projectNames, contains('acme-corp'));
    });

    test('rejects from == into', () {
      expect(
        () => service.projectMerge(from: 'acme-app', into: 'acme-app'),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            contains('must differ'),
          ),
        ),
      );
    });

    test('reports a fact key collision and keeps both current rows',
        () async {
      facts().put(
        syntheticFact(project: 'acme-app', subject: 'Flat B', valueText: 'A'),
      );
      facts().put(
        syntheticFact(project: 'acme-corp', subject: 'Flat B', valueText: 'B'),
      );

      final result = await service.projectMerge(
        from: 'acme-app',
        into: 'acme-corp',
      );

      final conflicts =
          (result['factKeyConflicts'] as List).cast<Map<String, Object?>>();
      expect(conflicts, hasLength(1));
      expect(conflicts.single['subject'], 'Flat B');
      expect(conflicts.single['attribute'], 'status');

      // Both rows survive — no silent close.
      final movedRows = facts()
          .query(Fact_.project.equals('acme-corp', caseSensitive: true))
          .build()
          .find();
      expect(movedRows, hasLength(2));
      expect(movedRows.map((f) => f.valueText), containsAll(['A', 'B']));
    });

    test('a closed (non-current) fact does not trigger a false collision',
        () async {
      facts().put(
        syntheticFact(
          project: 'acme-app',
          subject: 'Flat B',
          validUntil: DateTime.now().toUtc(),
        ),
      );
      facts().put(syntheticFact(project: 'acme-corp', subject: 'Flat B'));

      final result = await service.projectMerge(
        from: 'acme-app',
        into: 'acme-corp',
      );
      expect(result['factKeyConflicts'], isEmpty);
    });

    test(
      'a moved row that is valid RIGHT NOW but is not the open head still '
      'reports a collision – checking only the head missed this case',
      () async {
        // acme-app: A is valid now, closed at a FUTURE date by a
        // scheduled B – A is not the chain head any more, but it is
        // still genuinely in effect today.
        final a = await service.factSet(
          subject: 'Flat B',
          attribute: 'rent',
          project: 'acme-app',
          valueNumber: 800,
        );
        await service.factSet(
          subject: 'Flat B',
          attribute: 'rent',
          project: 'acme-app',
          valueNumber: 900,
          validFrom: DateTime.now().toUtc().add(const Duration(days: 5)),
        );
        // acme-corp already has a value that is valid right now for the
        // same (subject, attribute) under the target project name.
        await service.factSet(
          subject: 'Flat B',
          attribute: 'rent',
          project: 'acme-corp',
          valueNumber: 1000,
        );

        final result = await service.projectMerge(
          from: 'acme-app',
          into: 'acme-corp',
        );
        final conflicts = (result['factKeyConflicts'] as List)
            .cast<Map<String, Object?>>();
        expect(
          conflicts.map((c) => c['movedFactId']),
          contains(a['id']),
        );

        // Both rows survive – no silent close.
        final movedRows = facts()
            .query(Fact_.project.equals('acme-corp', caseSensitive: true))
            .build()
            .find();
        expect(movedRows.map((f) => f.valueNumber), containsAll([800, 1000]));
      },
    );

    test('moves more than one 500-row chunk', () async {
      const total = 1200;
      final ids = <int>[];
      for (var i = 0; i < total; i++) {
        final id = entries().put(
          MemoryEntry(
            title: '',
            text: 'synthetic memo #$i',
            kind: MemoryKind.fact,
            project: 'acme-app',
            sourceType: MemorySource.note,
            contentHash: 'hash-$i',
          ),
        );
        ids.add(id);
      }

      final result = await service.projectMerge(
        from: 'acme-app',
        into: 'acme-corp',
      );
      expect(result['entriesMoved'], total);
      expect(
        entries().getMany(ids).whereType<MemoryEntry>().every(
          (e) => e.project == 'acme-corp',
        ),
        isTrue,
      );
    });
  });

  group('backfillProjectRegistry', () {
    test('registers legacy entry and fact projects, byte-exact', () async {
      // A pre-0.3.0-style legacy MemoryEntry row, written straight to the
      // box: `remember` auto-registers its project since WP4, so it would
      // no longer leave anything for backfill to find – see the
      // `unregisteredProjects` test above for the same reasoning. The
      // Fact row is already written directly (facts() box), so it needs
      // no change.
      entries().put(
        MemoryEntry(
          title: '',
          text: 'entry memo',
          kind: MemoryKind.fact,
          sourceType: MemorySource.note,
          project: 'legacy-entries',
          contentHash: MemoryService.contentHashOf('entry memo'),
        ),
      );
      facts().put(syntheticFact(project: 'legacy-facts', subject: 'Car'));

      final result = await service.backfillProjectRegistry();
      expect(result['registered'], 2);
      expect(result['alreadyRegistered'], 0);
      expect(result['skippedBlank'], 0);

      expect(
        projects().getAll().map((p) => p.name),
        containsAll(['legacy-entries', 'legacy-facts']),
      );
    });

    test('skips and counts a blank project without throwing', () async {
      entries().put(
        MemoryEntry(
          title: '',
          text: 'legacy blank-project memo',
          kind: MemoryKind.fact,
          project: '',
          sourceType: MemorySource.note,
          contentHash: 'deadbeef2',
        ),
      );

      final result = await service.backfillProjectRegistry();
      expect(result['skippedBlank'], 1);
      expect(result['registered'], 0);
      expect(projects().count(), 0);
    });

    test(
      'review minor 8: a whitespace-only project is treated as blank '
      '(skipped, never registered as a real project)',
      () async {
        entries().put(
          MemoryEntry(
            title: '',
            text: 'legacy whitespace-project memo',
            kind: MemoryKind.fact,
            project: '  ',
            sourceType: MemorySource.note,
            contentHash: 'deadbeef3',
          ),
        );

        final result = await service.backfillProjectRegistry();
        expect(result['skippedBlank'], 1);
        expect(result['registered'], 0);
        expect(projects().count(), 0);
      },
    );

    test('dryRun writes nothing', () async {
      // Legacy row written straight to the box – see the test above for
      // why `remember` can no longer be used to set up this premise.
      entries().put(
        MemoryEntry(
          title: '',
          text: 'entry memo',
          kind: MemoryKind.fact,
          sourceType: MemorySource.note,
          project: 'legacy-entries',
          contentHash: MemoryService.contentHashOf('entry memo'),
        ),
      );

      final dry = await service.backfillProjectRegistry(dryRun: true);
      expect(dry['registered'], 1);
      expect(projects().count(), 0);

      final real = await service.backfillProjectRegistry();
      expect(real['registered'], 1);
      expect(projects().count(), 1);
    });

    test('second run registers nothing (idempotent)', () async {
      await service.remember(text: 'entry memo', project: 'legacy-entries');
      await service.backfillProjectRegistry();

      final second = await service.backfillProjectRegistry();
      expect(second['registered'], 0);
      expect(second['alreadyRegistered'], 1);
      expect(projects().count(), 1);
    });
  });
}
