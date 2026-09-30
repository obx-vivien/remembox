/// Tests for `entriesMove` (memory_service_areas.dart) – 2026-09-21,
/// entries move (0.3.0).
///
/// `entriesMove` splits a catch-all project by moving SELECTED entries (by
/// id) into another project – as opposed to `projectMerge`, which moves an
/// entire project. Modeled on areas_test.dart's `projectMerge` group (same
/// dryRun/chunking/registry discipline, shared via
/// `_rewriteEntriesProject`).
///
/// Synthetic data only (maintainer rule): projects `general`, `garden`,
/// `car`; area `home`.
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
    tempDir = Directory.systemTemp.createTempSync(
      'remembox_entries_move_test_',
    );
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
  Box<Fact> facts() => store.box<Fact>();
  Box<MemoryIndex> index() => store.box<MemoryIndex>();

  int idOf(Map<String, Object?> rememberResult) =>
      rememberResult['id'] as int;

  int newIdOf(Map<String, Object?> supersedeResult) =>
      supersedeResult['newId'] as int;

  group('entriesMove', () {
    test('moves the given ids and registers the target project', () async {
      final e1 = await service.remember(
        text: 'watering schedule',
        project: 'general',
      );
      final e2 = await service.remember(
        text: 'tomato bed notes',
        project: 'general',
      );
      await service.remember(text: 'unrelated memo', project: 'general');

      final result = await service.entriesMove(
        ids: [idOf(e1), idOf(e2)],
        toProject: 'garden',
        includeChain: false,
      );

      expect(result['moved'], 2);
      expect(result['alreadyThere'], 0);
      expect(result['chainEntriesAdded'], 0);
      expect(result['fromProjects'], {'general': 2});
      expect(result['toProject'], 'garden');
      expect(result['dryRun'], false);
      expect(result['factsUnaffected'], true);

      expect(entries().get(idOf(e1))!.project, 'garden');
      expect(entries().get(idOf(e2))!.project, 'garden');

      final gardenRow = projects()
          .query(ProjectScope_.name.equals('garden', caseSensitive: true))
          .build()
          .findFirst();
      expect(gardenRow, isNotNull);
    });

    test(
      'includeChain:true pulls in the whole supersede chain (predecessor '
      'and successor) and reports chainEntriesAdded',
      () async {
        final v1 = await service.remember(
          text: 'car insurer v1',
          project: 'general',
        );
        final v2 = await service.supersede(
          idOf(v1),
          text: 'car insurer v2',
          project: 'general',
        );
        final v3 = await service.supersede(
          newIdOf(v2),
          text: 'car insurer v3',
          project: 'general',
        );

        // Move only the MIDDLE link of the chain – both the predecessor
        // (v1) and the successor (v3) must still be pulled in.
        final result = await service.entriesMove(
          ids: [newIdOf(v2)],
          toProject: 'car',
        );

        expect(result['moved'], 3);
        expect(result['chainEntriesAdded'], 2);
        // review3 m2 fix: the actual chain-added ids, not only a count.
        expect(
          (result['chainEntryIds'] as List).cast<int>().toSet(),
          {idOf(v1), newIdOf(v3)},
        );
        expect(result['fromProjects'], {'general': 3});

        expect(entries().get(idOf(v1))!.project, 'car');
        expect(entries().get(newIdOf(v2))!.project, 'car');
        expect(entries().get(newIdOf(v3))!.project, 'car');
      },
    );

    test(
      'includeChain:false moves only the given ids, leaving the rest of '
      'the chain behind',
      () async {
        final v1 = await service.remember(
          text: 'car insurer v1',
          project: 'general',
        );
        final v2 = await service.supersede(
          idOf(v1),
          text: 'car insurer v2',
          project: 'general',
        );

        final result = await service.entriesMove(
          ids: [newIdOf(v2)],
          toProject: 'car',
          includeChain: false,
        );

        expect(result['moved'], 1);
        expect(result['chainEntriesAdded'], 0);
        expect(entries().get(idOf(v1))!.project, 'general');
        expect(entries().get(newIdOf(v2))!.project, 'car');
      },
    );

    test('a missing id throws ValidationException and writes nothing', () async {
      final e1 = await service.remember(text: 'e1', project: 'general');
      final ghostId = idOf(e1) + 100000;

      // expectLater (not expect) so the async rejection is fully awaited
      // before the post-state assertions below run.
      await expectLater(
        service.entriesMove(ids: [idOf(e1), ghostId], toProject: 'garden'),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            contains('$ghostId'),
          ),
        ),
      );

      // Nothing written: the existing id's project is untouched.
      expect(entries().get(idOf(e1))!.project, 'general');
      expect(
        projects()
            .query(ProjectScope_.name.equals('garden', caseSensitive: true))
            .build()
            .findFirst(),
        isNull,
      );
    });

    test('duplicate ids are rejected', () async {
      final e1 = await service.remember(text: 'e1', project: 'general');
      expect(
        () => service.entriesMove(
          ids: [idOf(e1), idOf(e1)],
          toProject: 'garden',
        ),
        throwsA(isA<ValidationException>()),
      );
    });

    test('more than 500 ids is rejected', () async {
      expect(
        () => service.entriesMove(
          ids: List<int>.generate(501, (i) => i + 1),
          toProject: 'garden',
        ),
        throwsA(isA<ValidationException>()),
      );
    });

    test('id 0 is rejected', () async {
      expect(
        () => service.entriesMove(ids: [0], toProject: 'garden'),
        throwsA(isA<ValidationException>()),
      );
    });

    test('dryRun writes nothing and reports identical counts', () async {
      final e1 = await service.remember(text: 'e1', project: 'general');

      final dry = await service.entriesMove(
        ids: [idOf(e1)],
        toProject: 'garden',
        dryRun: true,
      );
      expect(dry['moved'], 1);
      expect(dry['dryRun'], true);

      // Nothing written.
      expect(entries().get(idOf(e1))!.project, 'general');
      expect(
        projects()
            .query(ProjectScope_.name.equals('garden', caseSensitive: true))
            .build()
            .findFirst(),
        isNull,
      );

      final real = await service.entriesMove(
        ids: [idOf(e1)],
        toProject: 'garden',
      );
      expect(real['moved'], 1);
      expect(entries().get(idOf(e1))!.project, 'garden');
    });

    test(
      'entries already in toProject are counted as alreadyThere, not '
      'moved and not errors',
      () async {
        final already = await service.remember(
          text: 'already in garden',
          project: 'garden',
        );
        final toMove = await service.remember(
          text: 'needs moving',
          project: 'general',
        );

        final result = await service.entriesMove(
          ids: [idOf(already), idOf(toMove)],
          toProject: 'garden',
        );

        expect(result['moved'], 1);
        expect(result['alreadyThere'], 1);
        expect(result['fromProjects'], {'general': 1});
      },
    );

    test('target registered in the registry with a near-duplicate warning',
        () async {
      await service.projectSet(name: 'Garden');
      final e1 = await service.remember(text: 'e1', project: 'general');

      final result = await service.entriesMove(
        ids: [idOf(e1)],
        toProject: 'garden',
      );

      expect(
        result['warning'],
        contains('only by case/space/-/_'),
      );
    });

    test('facts are never touched', () async {
      facts().put(
        Fact(
          project: 'general',
          subject: 'Flat B',
          attribute: 'status',
          factKey: Fact.keyFor('general', 'Flat B', 'status'),
          valueType: FactValueType.text,
          valueText: 'ok',
          sourceType: MemorySource.note,
        ),
      );
      final e1 = await service.remember(text: 'e1', project: 'general');

      final result = await service.entriesMove(
        ids: [idOf(e1)],
        toProject: 'garden',
      );

      expect(result['factsUnaffected'], true);
      expect(facts().getAll().single.project, 'general');
    });

    test(
      'vector index row count and entry contentHash are unchanged',
      () async {
        final e1 = await service.remember(
          text: 'unaffected content',
          project: 'general',
        );
        final beforeHash = entries().get(idOf(e1))!.contentHash;
        final beforeText = entries().get(idOf(e1))!.text;
        final beforeIndexCount = index().count();

        await service.entriesMove(ids: [idOf(e1)], toProject: 'garden');

        final after = entries().get(idOf(e1))!;
        expect(after.contentHash, beforeHash);
        expect(after.text, beforeText);
        expect(index().count(), beforeIndexCount);
      },
    );

    test('area filter reflects the move: target in an area shows the '
        'moved entries via list_recent(area:)', () async {
      await service.areaSet(name: 'home');
      await service.projectSet(name: 'garden', addAreas: ['home']);
      final e1 = await service.remember(text: 'e1', project: 'general');

      await service.entriesMove(ids: [idOf(e1)], toProject: 'garden');

      final listed = await service.listRecent(area: 'home');
      expect(listed['count'], 1);
    });

    test('moves more than one 500-row chunk', () async {
      const total = 1200;
      final ids = <int>[];
      for (var i = 0; i < total; i++) {
        final id = entries().put(
          MemoryEntry(
            title: '',
            text: 'synthetic memo #$i',
            kind: MemoryKind.fact,
            project: 'general',
            sourceType: MemorySource.note,
            contentHash: 'entries-move-hash-$i',
          ),
        );
        ids.add(id);
      }

      // The 500-id-per-call cap applies to the caller-supplied `ids` list,
      // not the number of rows actually rewritten inside the transaction –
      // move them in two batches of 500 + one of 200 to also exercise the
      // internal _rewriteEntriesProject chunking (_scanPageSize == 500)
      // within a single call.
      final firstBatch = ids.sublist(0, 500);
      final secondBatch = ids.sublist(500, 1000);
      final thirdBatch = ids.sublist(1000, 1200);

      await service.entriesMove(
        ids: firstBatch,
        toProject: 'garden',
        includeChain: false,
      );
      await service.entriesMove(
        ids: secondBatch,
        toProject: 'garden',
        includeChain: false,
      );
      final last = await service.entriesMove(
        ids: thirdBatch,
        toProject: 'garden',
        includeChain: false,
      );

      expect(last['moved'], 200);
      expect(
        entries().getMany(ids).whereType<MemoryEntry>().every(
              (e) => e.project == 'garden',
            ),
        isTrue,
      );
    });

    test(
      'rejects a move whose total (ids + chain) exceeds the '
      '${MemoryService.entriesMoveMaxTotalIds} cap, naming the total '
      '(review3 m2 fix)',
      () async {
        const chainLength = MemoryService.entriesMoveMaxTotalIds + 5;
        final ids = <int>[];
        for (var i = 0; i < chainLength; i++) {
          final id = entries().put(
            MemoryEntry(
              title: '',
              text: 'cap probe #$i',
              kind: MemoryKind.fact,
              project: 'general',
              sourceType: MemorySource.note,
              contentHash: 'entries-move-cap-hash-$i',
            ),
          );
          ids.add(id);
        }
        // Link them into one long supersede chain: ids[i] -> ids[i+1].
        for (var i = 0; i < chainLength - 1; i++) {
          final e = entries().get(ids[i])!;
          e.supersededBy.targetId = ids[i + 1];
          entries().put(e);
        }

        await expectLater(
          service.entriesMove(ids: [ids.first], toProject: 'garden'),
          throwsA(
            isA<ValidationException>().having(
              (e) => e.message,
              'message',
              contains('${MemoryService.entriesMoveMaxTotalIds}'),
            ),
          ),
        );

        // Nothing written: the transaction rolled back before any rewrite.
        expect(entries().get(ids.first)!.project, 'general');
      },
    );

    test(
      'moving into a merged-away project name warns clearly, identically '
      'in dryRun and a real run, naming mergedInto (review3 m1 fix)',
      () async {
        await service.remember(text: 'old data', project: 'oldGarden');
        await service.remember(text: 'new data', project: 'newGarden');
        await service.projectMerge(from: 'oldGarden', into: 'newGarden');

        final e = await service.remember(text: 'e', project: 'general');

        final dry = await service.entriesMove(
          ids: [idOf(e)],
          toProject: 'oldGarden',
          dryRun: true,
        );
        final real = await service.entriesMove(
          ids: [idOf(e)],
          toProject: 'oldGarden',
        );

        for (final result in [dry, real]) {
          final warning = (result['warning'] as String?) ?? '';
          expect(warning, contains('was merged into'));
          expect(warning, contains('"newGarden"'));
          expect(warning, contains('re-creates'));
        }
      },
    );
  });
}
