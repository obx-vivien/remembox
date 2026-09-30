/// Tests for the WP1 registry primitives (memory_service_registry.dart) —
/// 2026-09-21, areas and facts (0.3.0), plan §2.1/§5, addendum M1/M2/M4.
///
/// Coverage note: `_ensureProjectScope`, `_nearDuplicateProjects`,
/// `_resolveAreaProjects` and `_currentFactsForKey` are library-private
/// (leading underscore) extension methods on [MemoryService] — Dart
/// privacy is per-LIBRARY, and this test file is a separate library from
/// `package:remembox/src/memory_service.dart` (part files cannot be test
/// entry points: `dart test` needs a real, independently-importable
/// library). They are therefore exercised here THROUGH the public
/// `areaSet`/`projectSet` surface, which is what WP1 ships. The two
/// primitives with no WP1-shipped public caller at all
/// (`_resolveAreaProjects`'s merged-exclusion/empty-area behavior,
/// `_currentFactsForKey`'s future-`validFrom` handling) get their direct
/// behavioral pinning once WP2 (`areasList`/`project_merge`/the `area`
/// filter on `recall`/`list_recent`) and WP3 (`fact_set`/`fact_get`) land
/// and call them for real — this file instead pins that the underlying
/// data model (AreaMembership rows keyed by name, many-to-many) is sound,
/// via `projectSet`'s own read of "which areas is this project in".
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
    tempDir = Directory.systemTemp.createTempSync('remembox_registry_test_');
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

  Box<ProjectScope> projects() => store.box<ProjectScope>();
  Box<Area> areas() => store.box<Area>();
  Box<AreaMembership> memberships() => store.box<AreaMembership>();

  group('ScopeKey.of', () {
    test('normalizes case, whitespace, - and _', () {
      expect(ScopeKey.of('Acme-App'), 'acmeapp');
      expect(ScopeKey.of('acme_app'), 'acmeapp');
      expect(ScopeKey.of(' acme app '), 'acmeapp');
      expect(ScopeKey.of('acme-app'), 'acmeapp');
    });
  });

  group('projectSet / _ensureProjectScope (byte-exact registration)', () {
    test('registers an unregistered project, byte-exact, and logs '
        'creation exactly once (idempotent on repeat)', () async {
      final first = await service.projectSet(name: 'acme-app');
      expect(first['action'], 'created');
      final id = first['id'] as int;
      expect(id, greaterThan(0));
      expect(projects().get(id)!.name, 'acme-app');

      final creationLogs = logLines.where(
        (l) => l.contains('registered project "acme-app"'),
      );
      expect(creationLogs, hasLength(1));

      // Second call: same row, no second registration log line, no
      // duplicate ProjectScope row.
      final second = await service.projectSet(name: 'acme-app');
      expect(second['id'], id);
      expect(projects().count(), 1);
      expect(
        logLines.where((l) => l.contains('registered project "acme-app"')),
        hasLength(1),
        reason: '_ensureProjectScope must be idempotent — no second create',
      );
    });

    test('names with spaces and case variants stay separate rows '
        '(byte-exact, never trimmed — addendum M2)', () async {
      final exact = await service.projectSet(name: 'acme-app');
      final spaced = await service.projectSet(name: ' acme-app');
      final cased = await service.projectSet(name: 'Acme-App');

      expect({exact['id'], spaced['id'], cased['id']}, hasLength(3));
      expect(projects().count(), 3);
      expect(
        projects().getAll().map((p) => p.name),
        containsAll(['acme-app', ' acme-app', 'Acme-App']),
      );
    });

    test('near-duplicate project name is warned about, not merged', () async {
      await service.projectSet(name: 'acme-app');
      final result = await service.projectSet(name: 'Acme_App');
      expect(result['warning'], contains('acme-app'));
      expect(result['warning'], contains('differs from existing'));
      // Still two separate rows — a warning is not a silent merge.
      expect(projects().count(), 2);
    });

    test('rejects an all-blank name', () {
      expect(
        () => service.projectSet(name: '   '),
        throwsA(isA<ValidationException>()),
      );
    });
  });

  group('projectSet: description / status / archive', () {
    test('description: created -> updated -> unchanged', () async {
      // "created" wins even when a description is set in the SAME call
      // that registers the row — creation is the dominant fact about
      // this call.
      final created = await service.projectSet(
        name: 'acme-app',
        description: 'first description',
      );
      expect(created['action'], 'created');
      expect(projects().get(created['id'] as int)!.description, 'first description');

      final unchanged = await service.projectSet(
        name: 'acme-app',
        description: 'first description',
      );
      expect(unchanged['action'], 'unchanged');

      final updated = await service.projectSet(
        name: 'acme-app',
        description: 'second description',
      );
      expect(updated['action'], 'updated');
      final id = updated['id'] as int;
      expect(projects().get(id)!.description, 'second description');
    });

    test('archive sets status=archived; status=merged is rejected', () async {
      await service.projectSet(name: 'acme-app');
      final archived = await service.projectSet(
        name: 'acme-app',
        status: ProjectStatus.archived,
      );
      expect(archived['status'], ProjectStatus.archived);
      expect(projects().getAll().single.status, ProjectStatus.archived);

      expect(
        () => service.projectSet(
          name: 'acme-app',
          status: ProjectStatus.merged,
        ),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            contains('project_merge'),
          ),
        ),
      );
    });

    test('warns when the project has no entries or facts yet', () async {
      final result = await service.projectSet(name: 'acme-app');
      expect(result['warning'], contains('no entries or facts yet'));
    });

    test('no "no entries" warning once the project has an entry', () async {
      await service.remember(
        text: 'synthetic memory for acme-app',
        project: 'acme-app',
      );
      final result = await service.projectSet(
        name: 'acme-app',
        description: 'has entries now',
      );
      expect(result['warning'], isNot(contains('no entries or facts yet')));
    });
  });

  group('projectSet <-> areaSet: area assignment', () {
    test('projectSet rejects an unknown area and lists it', () async {
      await expectLater(
        service.projectSet(name: 'acme-app', addAreas: ['ghost']),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            allOf(contains('unknown area'), contains('ghost')),
          ),
        ),
      );
      // Nothing was written — no partial project/membership row.
      expect(projects().count(), 0);
      expect(memberships().count(), 0);
      // Review minor 10: no "registered project" log line survives either
      // – the unknown-area check now runs BEFORE _ensureProjectScope, so
      // the log line for a registration that gets rolled back is never
      // written in the first place.
      expect(
        logLines,
        isNot(contains(contains('registered project "acme-app"'))),
      );
    });

    test('add then remove an area; areas list reflects both', () async {
      await service.areaSet(name: 'work');
      final added = await service.projectSet(
        name: 'acme-app',
        addAreas: ['work'],
      );
      expect(added['added'], ['work']);
      expect(added['areas'], ['work']);
      expect(memberships().count(), 1);

      // Idempotent: adding the same area again does not duplicate the
      // membership row or report it as newly added.
      final addedAgain = await service.projectSet(
        name: 'acme-app',
        addAreas: ['work'],
      );
      expect(addedAgain['added'], isEmpty);
      expect(memberships().count(), 1);

      final removed = await service.projectSet(
        name: 'acme-app',
        removeAreas: ['work'],
      );
      expect(removed['removed'], ['work']);
      expect(removed['areas'], isEmpty);
      expect(memberships().count(), 0);
    });

    test('one project in two areas; one area with two projects '
        '(many-to-many)', () async {
      await service.areaSet(name: 'work');
      await service.areaSet(name: 'finance');
      await service.areaSet(name: 'home');

      final acme = await service.projectSet(
        name: 'acme-app',
        addAreas: ['work', 'finance'],
      );
      expect(acme['areas'], containsAll(['work', 'finance']));
      expect((acme['areas'] as List), hasLength(2));

      await service.projectSet(name: 'garden', addAreas: ['home']);
      await service.projectSet(name: 'household', addAreas: ['home']);

      // Verify the many-to-many shape directly on the AreaMembership box
      // (the data _resolveAreaProjects reads, area-first — see the file
      // doc comment for why this test cannot call that method directly).
      final homeMembers = memberships()
          .query(AreaMembership_.area.equals('home'))
          .build()
          .find()
          .map((m) => m.project)
          .toSet();
      expect(homeMembers, {'garden', 'household'});

      final acmeAreas = memberships()
          .query(AreaMembership_.project.equals('acme-app'))
          .build()
          .find()
          .map((m) => m.area)
          .toSet();
      expect(acmeAreas, {'work', 'finance'});
    });
  });

  group('areaSet', () {
    test('creates, then updates description, then unchanged', () async {
      final created = await service.areaSet(
        name: 'work',
        description: 'first',
      );
      expect(created['action'], 'created');
      final id = created['id'] as int;

      final updated = await service.areaSet(
        name: 'work',
        description: 'second',
      );
      expect(updated['action'], 'updated');
      expect(updated['id'], id);
      expect(areas().get(id)!.description, 'second');

      final unchanged = await service.areaSet(
        name: 'work',
        description: 'second',
      );
      expect(unchanged['action'], 'unchanged');
    });

    test(
      'review minor 6: an unchanged call does not write (updatedAt stays '
      'put, no needless sync traffic)',
      () async {
        final created = await service.areaSet(
          name: 'work',
          description: 'first',
        );
        final id = created['id'] as int;
        final updatedAtBefore = areas().get(id)!.updatedAt;

        await Future.delayed(const Duration(milliseconds: 20));
        final unchanged = await service.areaSet(
          name: 'work',
          description: 'first',
        );
        expect(unchanged['action'], 'unchanged');
        expect(areas().get(id)!.updatedAt, updatedAtBefore);
      },
    );

    test('warns on a near-duplicate area name (case/space/-/_)', () async {
      await service.areaSet(name: 'home-life');
      final result = await service.areaSet(name: 'Home_Life');
      expect(result['warning'], contains('home-life'));
      expect(areas().count(), 2);
    });

    test('rejects a blank name and a non-trimmed name', () async {
      expect(
        () => service.areaSet(name: '   '),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => service.areaSet(name: ' work'),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            contains('leading/trailing whitespace'),
          ),
        ),
      );
    });

    test('rejects control characters, including the key separator', () {
      expect(
        () => service.areaSet(name: 'work${kFactKeySep}area'),
        throwsA(isA<ValidationException>()),
      );
    });
  });
}
