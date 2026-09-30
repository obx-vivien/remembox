/// Integration tests for WP4's hooks into the EXISTING tools
/// (memory_service.dart: `remember`/`supersede`, `recall`, `listRecent`,
/// `stats`, `forget`, `reindex`) – 2026-09-21, areas and facts (0.3.0),
/// plan §2.4/§5, addendum M1-M4.
///
/// Synthetic data only (projects `acme-app`, `garden`; areas `work`,
/// `finance`, `home`) – no real names, places or companies.
///
/// Coverage note on `reindex`'s "registry" phase: integration follow-up,
/// 2026-09-21 – WP2 has landed, so `backfillProjectRegistry`
/// (memory_service_areas.dart) is a real implementation, not the
/// transitional `UnimplementedError` stub the parallel work packages
/// compiled against. `reindex()`'s registry phase now calls it directly
/// and lets a real failure propagate like any other reindex error; the
/// tests below pin that real wiring (registers legacy rows, is
/// idempotent, dry-run writes nothing) instead of the removed fallback.
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
    tempDir = Directory.systemTemp.createTempSync('remembox_areas_it_test_');
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

  group('remember: project registry hook', () {
    test(
      'registers the project lazily, byte-exact (incl. trailing '
      'whitespace)',
      () async {
        await service.remember(text: 'first note', project: 'acme-app ');
        final rows = projects().getAll();
        expect(rows, hasLength(1));
        // Byte-exact: the trailing space is NOT trimmed by the registry
        // hook (addendum M2 – must never be stricter than `remember`'s
        // own `_requireProject`).
        expect(rows.single.name, 'acme-app ');

        final entry = entries().getAll().single;
        expect(entry.project, 'acme-app ');
      },
    );

    test('is idempotent: a second remember into the same project does '
        'not create a second registry row', () async {
      await service.remember(text: 'first', project: 'acme-app');
      await service.remember(text: 'second', project: 'acme-app');
      expect(projects().count(), 1);
    });

    test('warns on a near-duplicate project name', () async {
      await service.remember(text: 'first', project: 'acme-app');
      final result = await service.remember(
        text: 'second',
        project: 'Acme-App',
      );
      expect(result['warning'], contains('differs from existing'));
      expect(result['warning'], contains('acme-app'));
      // Two separate rows – a warning is not a silent merge.
      expect(projects().count(), 2);
    });

    test(
      'remember() into a name merged-away by project_merge warns, and '
      'still writes under the old name (no silent redirect, addendum Q3)',
      () async {
        // Simulate project_merge's tombstone directly (project_merge
        // itself is WP2's tool) – this is exactly the state
        // `_ensureProjectScope` (WP1) must react to, and is the case
        // WP4's `remember` hook must surface a warning for.
        final created = await service.projectSet(name: 'acme-old');
        final row = projects().get(created['id'] as int)!
          ..status = ProjectStatus.merged
          ..mergedInto = 'acme-app';
        projects().put(row);

        final result = await service.remember(
          text: 'note under the old name',
          project: 'acme-old',
        );
        expect(result['warning'], contains('merged into'));
        expect(result['warning'], contains('acme-app'));
        final storedEntry = entries().get(result['id'] as int)!;
        expect(storedEntry.project, 'acme-old');
      },
    );

    test(
      'the dedup (duplicate-content) path is unchanged: no registry '
      'warning surfaces on a duplicate remember()',
      () async {
        await service.remember(text: 'identical text', project: 'acme-app');
        // Same content -> dedup path; a near-duplicate NAME warning would
        // be misleading here since nothing new was registered/written.
        final dup = await service.remember(
          text: 'identical text',
          project: 'Acme-App',
        );
        expect(dup['duplicate'], isTrue);
        expect(dup['warning'], isNull);
      },
    );

    test(
      'supersede carries the near-duplicate-project warning through '
      '(inherits via remember, no own hook – plan §2.4)',
      () async {
        await service.remember(text: 'first', project: 'acme-app');
        final old = await service.remember(
          text: 'old text',
          project: 'acme-app',
        );
        final result = await service.supersede(
          old['id'] as int,
          text: 'new text, superseding the old one',
          project: 'Acme-App',
        );
        expect(result['warning'], contains('differs from existing'));
      },
    );
  });

  group('recall: area filter', () {
    Future<void> seedWorkArea() async {
      await service.areaSet(name: 'work');
      await service.projectSet(name: 'acme-app', addAreas: ['work']);
      await service.projectSet(name: 'other-app', addAreas: ['work']);
    }

    test(
      'returns only entries whose project belongs to the area '
      '(many-to-many)',
      () async {
        await seedWorkArea();
        embedder.register('query', embedder.planeVector(0));
        embedder.register('acme note', embedder.planeVector(1));
        embedder.register('other note', embedder.planeVector(2));
        embedder.register('garden note', embedder.planeVector(3));
        await service.remember(text: 'acme note', project: 'acme-app');
        await service.remember(text: 'other note', project: 'other-app');
        await service.remember(text: 'garden note', project: 'garden');

        final result = await service.recall(query: 'query', k: 5, area: 'work');
        final seenProjects = (result['hits'] as List)
            .map((h) => (h as Map)['project'])
            .toSet();
        expect(seenProjects, {'acme-app', 'other-app'});
      },
    );

    test('area + project (member) intersects to just that project', () async {
      await seedWorkArea();
      embedder.register('query', embedder.planeVector(0));
      embedder.register('acme note', embedder.planeVector(1));
      embedder.register('other note', embedder.planeVector(2));
      await service.remember(text: 'acme note', project: 'acme-app');
      await service.remember(text: 'other note', project: 'other-app');

      final result = await service.recall(
        query: 'query',
        k: 5,
        area: 'work',
        project: 'acme-app',
      );
      final seenProjects = (result['hits'] as List)
          .map((h) => (h as Map)['project'])
          .toSet();
      expect(seenProjects, {'acme-app'});
    });

    test(
      'a project outside the area yields an empty result and a warning',
      () async {
        await seedWorkArea();
        embedder.register('query', embedder.planeVector(0));
        embedder.register('garden note', embedder.planeVector(1));
        await service.remember(text: 'garden note', project: 'garden');

        final result = await service.recall(
          query: 'query',
          k: 5,
          area: 'work',
          project: 'garden',
        );
        expect(result['hits'], isEmpty);
        expect(
          (result['warnings'] as List).join(' '),
          contains('is not a member of area'),
        );
      },
    );

    test(
      'an area with zero projects yields an empty result and a warning '
      '(never builds an unbounded/empty filter silently)',
      () async {
        await service.areaSet(name: 'lonely');
        embedder.register('query', embedder.planeVector(0));
        embedder.register('unrelated', embedder.planeVector(1));
        await service.remember(text: 'unrelated', project: 'acme-app');

        final result = await service.recall(
          query: 'query',
          k: 5,
          area: 'lonely',
        );
        expect(result['hits'], isEmpty);
        expect(
          (result['warnings'] as List).join(' '),
          contains('has no projects'),
        );
      },
    );

    test('an unknown area is rejected', () {
      expect(
        () => service.recall(query: 'query', area: 'ghost'),
        throwsA(isA<ValidationException>()),
      );
    });
  });

  group('listRecent: area filter', () {
    test('filters by area, ordered by createdAt desc', () async {
      await service.areaSet(name: 'work');
      await service.projectSet(name: 'acme-app', addAreas: ['work']);
      await service.projectSet(name: 'other-app', addAreas: ['work']);

      final first = await service.remember(text: 'first', project: 'acme-app');
      await Future.delayed(const Duration(milliseconds: 10));
      final second = await service.remember(
        text: 'second',
        project: 'other-app',
      );
      await Future.delayed(const Duration(milliseconds: 10));
      // Not in the area – must be excluded.
      await service.remember(text: 'third', project: 'garden');

      final result = await service.listRecent(area: 'work');
      expect(result['count'], 2);
      final ids = (result['entries'] as List)
          .map((e) => (e as Map)['id'])
          .toList();
      expect(ids, [second['id'], first['id']]);
    });

    test(
      'combines area with an explicit project (AND, not OR)',
      () async {
        await service.areaSet(name: 'work');
        await service.projectSet(name: 'acme-app', addAreas: ['work']);
        await service.projectSet(name: 'other-app', addAreas: ['work']);
        await service.remember(text: 'acme note', project: 'acme-app');
        await service.remember(text: 'other note', project: 'other-app');

        final result = await service.listRecent(
          area: 'work',
          project: 'acme-app',
        );
        expect(result['count'], 1);
        expect((result['entries'] as List).single['project'], 'acme-app');
      },
    );

    test(
      'an area with zero projects yields count:0 and a warning',
      () async {
        await service.areaSet(name: 'lonely');
        final result = await service.listRecent(area: 'lonely');
        expect(result['count'], 0);
        expect(result['entries'], isEmpty);
        expect(result['warning'], contains('has no projects'));
      },
    );

    test('an unknown area is rejected', () {
      expect(
        () => service.listRecent(area: 'ghost'),
        throwsA(isA<ValidationException>()),
      );
    });
  });

  group('stats: byProject / byArea / registry / facts', () {
    test('byProject is case-sensitive', () async {
      await service.remember(text: 'a', project: 'acme-app');
      await service.remember(text: 'b', project: 'Acme-App');
      await service.remember(text: 'c', project: 'acme-app');

      final stats = await service.stats();
      final byProject = stats['byProject'] as Map;
      expect(byProject['acme-app'], 2);
      expect(byProject['Acme-App'], 1);
    });

    test(
      'byArea counts a project assigned to two areas in both',
      () async {
        await service.areaSet(name: 'work');
        await service.areaSet(name: 'finance');
        await service.projectSet(
          name: 'acme-app',
          addAreas: ['work', 'finance'],
        );
        await service.remember(text: 'a', project: 'acme-app');
        await service.remember(text: 'b', project: 'acme-app');

        final stats = await service.stats();
        final byArea = stats['byArea'] as Map;
        expect(byArea['work'], 2);
        expect(byArea['finance'], 2);
      },
    );

    test('byArea reports 0 for a real area with no projects', () async {
      await service.areaSet(name: 'lonely');
      final stats = await service.stats();
      expect((stats['byArea'] as Map)['lonely'], 0);
    });

    test(
      'registry block: projects/areas/archived/merged/unregistered/blank/'
      'membership-orphan counts',
      () async {
        await service.areaSet(name: 'work');
        await service.projectSet(name: 'acme-app', addAreas: ['work']);
        await service.projectSet(
          name: 'legacy-app',
          status: ProjectStatus.archived,
        );
        final mergedResult = await service.projectSet(name: 'old-name');
        final mergedRow = projects().get(mergedResult['id'] as int)!
          ..status = ProjectStatus.merged
          ..mergedInto = 'acme-app';
        projects().put(mergedRow);

        // A project used directly on an entry, never registered (written
        // straight to the box – the public API always registers, so this
        // is how a pre-existing "legacy" row is simulated).
        entries().put(
          MemoryEntry(
            title: 'legacy',
            text: 'legacy entry with no registry row',
            kind: MemoryKind.fact,
            sourceType: MemorySource.note,
            project: 'ghost-project',
            contentHash: MemoryService.contentHashOf(
              'legacy entry with no registry row',
            ),
          ),
        );
        // A blank-project entry (the legacy empty-project case).
        entries().put(
          MemoryEntry(
            title: 'blank',
            text: 'blank project entry',
            kind: MemoryKind.fact,
            sourceType: MemorySource.note,
            project: '',
            contentHash: MemoryService.contentHashOf('blank project entry'),
          ),
        );
        // A membership whose project has no ProjectScope row.
        memberships().put(
          AreaMembership(
            key: AreaMembership.keyFor('work', 'ghost-project-2'),
            area: 'work',
            project: 'ghost-project-2',
          ),
        );
        // A membership whose area has no Area row.
        memberships().put(
          AreaMembership(
            key: AreaMembership.keyFor('ghost-area', 'acme-app'),
            area: 'ghost-area',
            project: 'acme-app',
          ),
        );

        final stats = await service.stats();
        final registry = stats['registry'] as Map;
        expect(registry['projects'], 3); // acme-app, legacy-app, old-name
        expect(registry['areas'], 1); // work
        expect(registry['archived'], 1);
        expect(registry['merged'], 1);
        expect(registry['unregisteredProjects'], 1); // ghost-project
        expect(registry['blankProjectEntries'], 1);
        expect(registry['membershipsWithoutArea'], 1);
        expect(registry['membershipsWithoutProjectRows'], 1);
      },
    );

    test('facts block: total/current/conflictingKeys', () async {
      final now = DateTime.now().toUtc();
      final rentKey = Fact.keyFor('acme-app', 'Flat B', 'rent');
      facts().putMany([
        Fact(
          project: 'acme-app',
          subject: 'Flat B',
          attribute: 'rent',
          factKey: rentKey,
          valueType: FactValueType.number,
          valueNumber: 950,
          sourceType: MemorySource.note,
          validFrom: now,
        ),
        // A second CURRENT row for the SAME key – a cross-device conflict
        // WP3's write path is responsible for repairing; stats() must
        // still surface it, not hide it.
        Fact(
          project: 'acme-app',
          subject: 'Flat B',
          attribute: 'rent',
          factKey: rentKey,
          valueType: FactValueType.number,
          valueNumber: 975,
          sourceType: MemorySource.note,
          validFrom: now,
        ),
        Fact(
          project: 'acme-app',
          subject: 'Car',
          attribute: 'color',
          factKey: Fact.keyFor('acme-app', 'Car', 'color'),
          valueType: FactValueType.text,
          valueText: 'blue',
          sourceType: MemorySource.note,
          validFrom: now,
        ),
      ]);

      final stats = await service.stats();
      final facts_ = stats['facts'] as Map;
      expect(facts_['total'], 3);
      expect(facts_['current'], 3);
      expect(facts_['conflictingKeys'], 1);
    });
  });

  group('forget(hard: true): Fact.explainedBy cascade', () {
    test('clears explainedBy pointers and reports factLinksCleared', () async {
      final entry = await service.remember(
        text: 'source note for two facts',
        project: 'acme-app',
      );
      final entryId = entry['id'] as int;

      final f1 = Fact(
        project: 'acme-app',
        subject: 'Flat B',
        attribute: 'rent',
        factKey: Fact.keyFor('acme-app', 'Flat B', 'rent'),
        valueType: FactValueType.number,
        valueNumber: 950,
        sourceType: MemorySource.note,
      )..explainedBy.targetId = entryId;
      final f2 = Fact(
        project: 'acme-app',
        subject: 'Car',
        attribute: 'color',
        factKey: Fact.keyFor('acme-app', 'Car', 'color'),
        valueType: FactValueType.text,
        valueText: 'blue',
        sourceType: MemorySource.note,
      )..explainedBy.targetId = entryId;
      facts().putMany([f1, f2]);

      final result = await service.forget(entryId, hard: true);
      expect(result['action'], 'hard-deleted');
      expect(result['factLinksCleared'], 2);

      // The Fact rows survive (a fact's exact value stands on its own);
      // only the dangling ToOne is cleared.
      expect(facts().count(), 2);
      expect(facts().get(f1.id)!.explainedBy.targetId, 0);
      expect(facts().get(f2.id)!.explainedBy.targetId, 0);
    });

    test(
      'reports factLinksCleared: 0 when no fact points at the entry',
      () async {
        final entry = await service.remember(
          text: 'no facts point here',
          project: 'acme-app',
        );
        final result = await service.forget(entry['id'] as int, hard: true);
        expect(result['factLinksCleared'], 0);
      },
    );
  });

  group('reindex: registry phase wiring', () {
    test(
      'calls backfillProjectRegistry for real and reports its summary '
      'under "registry" (WP2 has landed; the transitional '
      'UnimplementedError guard is gone)',
      () async {
        // A pre-0.3.0-style legacy row, written straight to the box so it
        // has no ProjectScope row – `remember` auto-registers its project
        // since WP4, so this is the only way to give the backfill phase
        // something to actually register (byte-exact-legacy-row pattern,
        // same as areas_test.dart).
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

        final result = await service.reindex(dryRun: true);
        final registry = result['registry'] as Map;
        expect(registry['registered'], 1);
        expect(registry['skippedBlank'], 0);
        expect(registry['alreadyRegistered'], 0);
        // dryRun: true was passed through to backfillProjectRegistry, so
        // nothing was actually written.
        expect(projects().count(), 0);

        // A second reindex (not dry-run) actually registers the project;
        // a THIRD reindex then registers nothing more (idempotent).
        final real = await service.reindex();
        final realRegistry = real['registry'] as Map;
        expect(realRegistry['registered'], 1);
        expect(projects().count(), 1);

        final again = await service.reindex();
        final againRegistry = again['registry'] as Map;
        expect(againRegistry['registered'], 0);
        expect(againRegistry['alreadyRegistered'], 1);
      },
    );

    test(
      'a real backfillProjectRegistry failure propagates like any other '
      'reindex error (the transitional guard used to swallow exactly '
      'this)',
      () async {
        embedder.register('q', embedder.planeVector(0));
        await service.remember(text: 'q', project: 'acme-app');
        final result = await service.reindex();
        expect(result['entriesExamined'], 1);
        expect((result['failed'] as List), isEmpty);
        // The registry phase ran for real (no legacy rows here, so
        // nothing to register) rather than reporting a transitional
        // "pending" status.
        final registry = result['registry'] as Map;
        expect(registry['registered'], 0);
        expect(registry.containsKey('status'), isFalse);
      },
    );
  });
}
