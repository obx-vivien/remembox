import 'dart:io';

import 'package:remembox/objectbox.g.dart';
import 'package:remembox/src/embedder.dart';
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
    tempDir = Directory.systemTemp.createTempSync('remembox_test_');
    logLines = [];
    // 2026-09-01 (Store-Gate, the 2026-09-01 store-gate engineering log
    // (internal)): openTestGate wraps the exact persistent-mode sequence
    // bin/remembox.dart uses (openMemoryStore -> startSyncClient ->
    // StoreGate.persistent) — MemoryService now takes a StoreGate, not a
    // raw Store, but tests still get [store] back for direct inspection
    // (entries()/index() below).
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
  Box<MemoryIndex> index() => store.box<MemoryIndex>();

  group('remember', () {
    test('stores entry and index row transaction-safely', () async {
      final result = await service.remember(
        text: 'Dart uses ARC-free garbage collection.',
        kind: MemoryKind.fact,
        sourceType: MemorySource.note,
        project: 'remembox',
        tags: ['dart', 'gc'],
      );
      expect(result['duplicate'], isFalse);
      expect(result['indexed'], isTrue);
      final id = result['id'] as int;

      final entry = entries().get(id)!;
      expect(entry.kind, MemoryKind.fact);
      expect(entry.tags.map((t) => t.name), containsAll(['dart', 'gc']));

      final row =
          index()
              .query(
                MemoryIndex_.sourceKey.equals(MemoryIndex.sourceKeyFor(id)),
              )
              .build()
              .findFirst()!;
      expect(row.entryId, id);
      expect(row.textHash, entry.contentHash);
      expect(row.embedModel, embedder.modelId);
      expect(row.dims, 768);
      expect(row.status, IndexStatus.ok);
      expect(row.embedding, hasLength(768));
    });

    test(
      'FIX-8/FIX-9: defaults are sourceType=note and language="" '
      '(unknown) — never guessed',
      () async {
        final result = await service.remember(text: 'no metadata given', project: 'test');
        final entry = entries().get(result['id'] as int)!;
        expect(
          entry.sourceType,
          MemorySource.note,
          reason: 'FIX-9: note is the honest default for an unattributed '
              'memory (was "chat")',
        );
        expect(
          entry.language,
          '',
          reason: 'FIX-8: unknown/unspecified, never guessed (was "en", '
              'which silently mis-tagged non-English text)',
        );
      },
    );

    test('rejects unknown kind and sourceType with clear errors', () async {
      expect(
        () => service.remember(text: 'x', kind: 'gossip', project: 'test'),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            contains('Unknown kind "gossip"'),
          ),
        ),
      );
      expect(
        () => service.remember(text: 'x', sourceType: 'telepathy', project: 'test'),
        throwsA(isA<ValidationException>()),
      );
    });

    test(
      'SEC-6: rejects text over maxTextChars with the limit and actual '
      'size named, never silently truncates',
      () async {
        final capped = MemoryService(
          gate: gate,
          embedder: embedder,
          log: logCapture,
          maxTextChars: 10,
        );
        expect(
          () => capped.remember(text: 'x' * 11, project: 'test'),
          throwsA(
            isA<ValidationException>().having(
              (e) => e.message,
              'message',
              allOf(contains('11'), contains('10')),
            ),
          ),
        );
        // Nothing was stored — a rejected remember() must not leave a
        // truncated entry behind.
        expect(entries().count(), 0);
        // Exactly at the limit must succeed.
        embedder.register('x' * 10, embedder.planeVector(0));
        final ok = await capped.remember(text: 'x' * 10, project: 'test');
        expect(ok['duplicate'], isFalse);
        await capped.dispose();
      },
    );

    test(
      'deduplicates on normalized text, logs, and returns existing id',
      () async {
        final first = await service.remember(
          text: 'ObjectBox has  HNSW vector search.',
          project: 'test',
        );
        final second = await service.remember(
          text: '  ObjectBox has HNSW   vector search. ',
          project: 'test',
        );
        expect(second['duplicate'], isTrue);
        expect(second['id'], first['id']);
        expect(entries().count(), 1);
        expect(index().count(), 1);
        expect(
          logLines.join('\n'),
          contains('duplicate remember()'),
          reason: 'duplicate handling must be logged, never silent',
        );
      },
    );

    test('stores entry but reports un-indexed when embedding fails', () async {
      embedder.failWith = EmbedderException(
        'Cannot reach Ollama at http://test (down).',
      );
      final result = await service.remember(text: 'embedding will fail', project: 'test');
      expect(result['indexed'], isFalse);
      expect(result['warning'], contains('NOT indexed'));
      expect(entries().count(), 1);
      expect(index().count(), 0);
    });

    test('creates and reuses SourceDocument by content hash', () async {
      final r1 = await service.remember(
        text: 'chunk one of the paper',
        docName: 'paper.pdf',
        docContentHash: 'dochash-1',
        project: 'test',
      );
      final r2 = await service.remember(
        text: 'chunk two of the paper',
        docName: 'paper.pdf',
        docContentHash: 'dochash-1',
        project: 'test',
      );
      expect(store.box<SourceDocument>().count(), 1);
      final e1 = entries().get(r1['id'] as int)!;
      final e2 = entries().get(r2['id'] as int)!;
      expect(e1.source.targetId, e2.source.targetId);
      expect(logLines.join('\n'), contains('already known as doc'));
    });

    test(
      'FIX-7: still stores an entry with expiresAt in the past, but warns',
      () async {
        final pastExpiry = DateTime.now().toUtc().subtract(
          const Duration(days: 1),
        );
        final result = await service.remember(
          text: 'already stale on arrival',
          expiresAt: pastExpiry,
          project: 'test',
        );
        expect(result['duplicate'], isFalse);
        final id = result['id'] as int;
        expect(
          entries().get(id),
          isNotNull,
          reason: 'the entry must still be stored, not rejected',
        );
        expect(
          result['warning'],
          allOf(
            contains('expiresAt'),
            contains('in the past'),
            contains('immediately invisible to recall'),
          ),
        );
        // And it really is immediately invisible to recall, matching the
        // warning's claim.
        embedder.register('past query', embedder.planeVector(0));
        embedder.register(
          'already stale on arrival',
          embedder.planeVector(1),
        );
        final recallResult = await service.recall(
          query: 'past query',
          k: 5,
        );
        expect(
          (recallResult['hits'] as List).any(
            (h) => (h as Map)['id'] == id,
          ),
          isFalse,
        );
      },
    );

    test(
      'FIX-7: supersede forwards the past-expiresAt warning too',
      () async {
        final old = await service.remember(text: 'will be corrected', project: 'test');
        final result = await service.supersede(
          old['id'] as int,
          text: 'corrected but already expired',
          expiresAt: DateTime.now().toUtc().subtract(
            const Duration(hours: 1),
          ),
        );
        expect(
          result['warning'],
          allOf(contains('expiresAt'), contains('in the past')),
        );
      },
    );

    // 2026-09-06 (Fix 1, the 2026-09-06 project-required engineering log
    // (internal)): project became required, enforced in the service (not
    // just documented convention) — an entry stored with an empty project
    // is invisible to a targeted recall() (which filters ONLY by project)
    // and noise in every other one. See MemoryService._requireProject.
    test(
      'rejects a missing project with an actionable ValidationException',
      () {
        expect(
          () => service.remember(text: 'no project given'),
          throwsA(
            isA<ValidationException>().having(
              (e) => e.message,
              'message',
              contains('project is required'),
            ),
          ),
        );
      },
    );

    test('rejects a whitespace-only project the same way as a missing one', () {
      expect(
        () => service.remember(text: 'blank project', project: '   '),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            contains('project is required'),
          ),
        ),
      );
    });

    group('M-4: bounded argument lengths (2026-09-07 security review)', () {
      test('rejects an oversized title with the limit and actual size', () {
        expect(
          () => service.remember(
            text: 'x',
            title: 'a' * 513,
            project: 'test',
          ),
          throwsA(
            isA<ValidationException>().having(
              (e) => e.message,
              'message',
              allOf(contains('title'), contains('513'), contains('512')),
            ),
          ),
        );
      });

      test('accepts a title exactly at the 512 char limit', () async {
        embedder.register('at the limit', embedder.planeVector(0));
        final result = await service.remember(
          text: 'at the limit',
          title: 'a' * 512,
          project: 'test',
        );
        expect(result['duplicate'], isFalse);
      });

      test('rejects an oversized project with the limit named', () {
        expect(
          () => service.remember(text: 'x', project: 'p' * 201),
          throwsA(
            isA<ValidationException>().having(
              (e) => e.message,
              'message',
              allOf(contains('project'), contains('201'), contains('200')),
            ),
          ),
        );
      });

      test('rejects an oversized sourceRef', () {
        expect(
          () => service.remember(
            text: 'x',
            project: 'test',
            sourceRef: 'r' * 4097,
          ),
          throwsA(
            isA<ValidationException>().having(
              (e) => e.message,
              'message',
              contains('sourceRef'),
            ),
          ),
        );
      });

      test('rejects an oversized language', () {
        expect(
          () => service.remember(
            text: 'x',
            project: 'test',
            language: 'l' * 17,
          ),
          throwsA(
            isA<ValidationException>().having(
              (e) => e.message,
              'message',
              contains('language'),
            ),
          ),
        );
      });

      test('rejects a single oversized tag', () {
        expect(
          () => service.remember(
            text: 'x',
            project: 'test',
            tags: ['t' * 129],
          ),
          throwsA(
            isA<ValidationException>().having(
              (e) => e.message,
              'message',
              contains('tag'),
            ),
          ),
        );
      });

      test('rejects more than 64 tags', () {
        expect(
          () => service.remember(
            text: 'x',
            project: 'test',
            tags: List.generate(65, (i) => 'tag$i'),
          ),
          throwsA(
            isA<ValidationException>().having(
              (e) => e.message,
              'message',
              allOf(contains('Too many tags'), contains('65'), contains('64')),
            ),
          ),
        );
      });

      test('rejects oversized doc* metadata fields', () {
        expect(
          () => service.remember(
            text: 'x',
            project: 'test',
            docName: 'd' * 4097,
          ),
          throwsA(
            isA<ValidationException>().having(
              (e) => e.message,
              'message',
              contains('docName'),
            ),
          ),
        );
      });

      test(
        'supersede() rejects an oversized title BEFORE reading the old '
        'entry (fails fast, same cap as remember())',
        () async {
          final old = await service.remember(text: 'will stay', project: 'test');
          expect(
            () => service.supersede(
              old['id'] as int,
              text: 'replacement',
              title: 'a' * 513,
            ),
            throwsA(
              isA<ValidationException>().having(
                (e) => e.message,
                'message',
                contains('title'),
              ),
            ),
          );
        },
      );

      test(
        'a caller-echoing error message (Unknown kind) truncates the '
        'echoed value instead of reflecting it back unbounded',
        () {
          final hugeKind = 'k' * 10000;
          expect(
            () => service.remember(text: 'x', kind: hugeKind, project: 'test'),
            throwsA(
              isA<ValidationException>().having(
                (e) => e.message,
                'message',
                allOf(contains('…'), predicate<String>((m) => m.length < 1000)),
              ),
            ),
          );
        },
      );
    });
  });

  group('schema-enforced identity', () {
    test('MemoryIndex.sourceKey uniqueness throws UniqueViolationException '
        'on conflicting put (fail strategy, local-only entity)', () {
      index().put(
        MemoryIndex(
          sourceKey: 'memory:999',
          entryId: 999,
          embedModel: 'm',
          dims: 768,
          textHash: 'h',
        ),
      );
      expect(
        () => index().put(
          MemoryIndex(
            sourceKey: 'memory:999',
            entryId: 999,
            embedModel: 'm',
            dims: 768,
            textHash: 'h2',
          ),
        ),
        throwsA(isA<UniqueViolationException>()),
      );
    });

    test(
      'MemoryEntry.contentHash uses sync-mandated replace strategy: '
      'conflicting put replaces instead of throwing (documented deviation)',
      () {
        final firstId = entries().put(
          MemoryEntry(
            title: 'a',
            text: 'a',
            kind: MemoryKind.fact,
            sourceType: MemorySource.note,
            contentHash: 'same-hash',
          ),
        );
        final secondId = entries().put(
          MemoryEntry(
            title: 'b',
            text: 'b',
            kind: MemoryKind.fact,
            sourceType: MemorySource.note,
            contentHash: 'same-hash',
          ),
        );
        expect(
          entries().count(),
          1,
          reason: 'replace-on-conflict must leave a single row',
        );
        expect(entries().get(firstId), isNull);
        expect(entries().get(secondId)!.title, 'b');
      },
    );
  });

  group('recall', () {
    test(
      'ranks by cosine similarity and exposes distance + score parts',
      () async {
        // Zero boosts => pure similarity ordering.
        final pure = MemoryService(
          gate: gate,
          embedder: embedder,
          rankWeightRecency: 0,
          rankWeightFrequency: 0,
          log: logCapture,
        );
        embedder.register('query', embedder.planeVector(0));
        embedder.register('close match', embedder.planeVector(10));
        embedder.register('medium match', embedder.planeVector(45));
        embedder.register('far match', embedder.planeVector(90));
        await pure.remember(text: 'far match', project: 'test');
        await pure.remember(text: 'close match', project: 'test');
        await pure.remember(text: 'medium match', project: 'test');

        final result = await pure.recall(query: 'query', k: 3);
        final hits = result['hits'] as List;
        expect(hits, hasLength(3));
        expect(hits.map((h) => (h as Map)['text']).toList(), [
          'close match',
          'medium match',
          'far match',
        ]);
        final top = hits.first as Map;
        expect(top['distance'], closeTo(1 - 0.9848, 0.01)); // 1 - cos(10°)
        expect(
          top['similarity'],
          closeTo(1 - (top['distance'] as double) / 2, 1e-9),
        );
        expect(
          top.keys,
          containsAll([
            'recencyBoost',
            'frequencyBoost',
            'score',
            'embedModel',
          ]),
        );
        await pure.dispose();
      },
    );

    test('frequency boost lifts an equally-similar entry', () async {
      embedder.register('query', embedder.planeVector(0));
      embedder.register('twin a', embedder.planeVector(30));
      embedder.register('twin b', embedder.planeVector(-30));
      final a = await service.remember(text: 'twin a', project: 'test');
      await service.remember(text: 'twin b', project: 'test');
      // Bump accessCount of twin a directly.
      final entry = entries().get(a['id'] as int)!;
      entry.accessCount = 10;
      entries().put(entry);

      final result = await service.recall(query: 'query', k: 2);
      final hits = result['hits'] as List;
      expect((hits.first as Map)['text'], 'twin a');
      expect((hits.first as Map)['frequencyBoost'], greaterThan(0));
    });

    test(
      'excludes expired and superseded; includeSuperseded overrides',
      () async {
        embedder.register('query', embedder.planeVector(0));
        embedder.register('old truth', embedder.planeVector(5));
        embedder.register('new truth', embedder.planeVector(10));
        embedder.register('temporary', embedder.planeVector(15));
        final old = await service.remember(text: 'old truth', project: 'test');
        await service.supersede(old['id'] as int, text: 'new truth');
        await service.remember(
          text: 'temporary',
          expiresAt: DateTime.now().toUtc().subtract(const Duration(days: 1)),
          project: 'test',
        );

        final result = await service.recall(query: 'query', k: 5);
        final texts =
            (result['hits'] as List).map((h) => (h as Map)['text']).toList();
        expect(texts, ['new truth']);
        expect(
          (result['warnings'] as List).join(' '),
          contains('after filtering'),
        );

        final withSuperseded = await service.recall(
          query: 'query',
          k: 5,
          includeSuperseded: true,
        );
        final texts2 =
            (withSuperseded['hits'] as List)
                .map((h) => (h as Map)['text'])
                .toList();
        expect(texts2, containsAll(['new truth', 'old truth']));
      },
    );

    test('filters by kind/project and reports shortfall below k', () async {
      embedder.register('query', embedder.planeVector(0));
      embedder.register('in scope', embedder.planeVector(5));
      embedder.register('other project', embedder.planeVector(10));
      await service.remember(
        text: 'in scope',
        project: 'alpha',
        kind: MemoryKind.decision,
      );
      await service.remember(text: 'other project', project: 'beta');

      final result = await service.recall(
        query: 'query',
        k: 3,
        project: 'alpha',
      );
      final hits = result['hits'] as List;
      expect(hits, hasLength(1));
      expect((hits.single as Map)['project'], 'alpha');
      expect(
        (result['warnings'] as List).join(' '),
        allOf(
          contains('Only 1 of the requested 3'),
          contains('filter mismatches: 1'),
        ),
        reason: 'post-filter shrinkage below k must be reported explicitly',
      );
    });

    test('updates lastAccessedAt and accessCount of returned hits', () async {
      embedder.register('query', embedder.planeVector(0));
      embedder.register('hit me', embedder.planeVector(5));
      final r = await service.remember(text: 'hit me', project: 'test');
      await service.recall(query: 'query', k: 1);
      final entry = entries().get(r['id'] as int)!;
      expect(entry.accessCount, 1);
      expect(entry.lastAccessedAt, isNotNull);
    });

    test(
      'excludes stale rows (text drift) with warning and marks them',
      () async {
        embedder.register('query', embedder.planeVector(0));
        embedder.register('original text', embedder.planeVector(5));
        final r = await service.remember(text: 'original text', project: 'test');
        // Simulate the entry text changing without re-indexing (e.g. an edit
        // arriving via sync).
        final entry = entries().get(r['id'] as int)!;
        entry.text = 'edited text';
        entry.contentHash = MemoryService.contentHashOf(entry.text);
        entries().put(entry);

        final result = await service.recall(query: 'query', k: 5);
        expect(result['hits'], isEmpty);
        expect(
          (result['warnings'] as List).join(' '),
          contains('stale embeddings'),
        );
        final row = index().getAll().single;
        expect(row.status, IndexStatus.stale);
        expect(logLines.join('\n'), contains('marked index row'));
      },
    );

    test('excludes rows from a different embed model with warning', () async {
      embedder.register('query', embedder.planeVector(0));
      embedder.register('foreign model text', embedder.planeVector(5));
      final r = await service.remember(text: 'foreign model text', project: 'test');
      final row = index().getAll().single;
      row.embedModel = 'ancient-model-v0';
      index().put(row);

      final result = await service.recall(query: 'query', k: 5);
      expect(result['hits'], isEmpty);
      expect(
        (result['warnings'] as List).join(' '),
        contains('different model'),
      );
      expect(entries().get(r['id'] as int), isNotNull);
    });

    test(
      'R2-4: rejects empty/whitespace-only query (mirrors remember\'s '
      'empty-text guard)',
      () async {
        expect(
          () => service.recall(query: ''),
          throwsA(isA<ValidationException>()),
        );
        expect(
          () => service.recall(query: '   '),
          throwsA(isA<ValidationException>()),
        );
      },
    );

    test(
      'SEC-4: frames results as untrusted retrieved content, and flags '
      'url/file hits as externallySourced',
      () async {
        embedder.register('query', embedder.planeVector(0));
        embedder.register('typed note', embedder.planeVector(5));
        embedder.register('fetched page', embedder.planeVector(6));
        embedder.register('read file', embedder.planeVector(7));
        await service.remember(
          text: 'typed note',
          sourceType: MemorySource.note,
          project: 'test',
        );
        await service.remember(
          text: 'fetched page',
          sourceType: MemorySource.url,
          project: 'test',
        );
        await service.remember(
          text: 'read file',
          sourceType: MemorySource.file,
          project: 'test',
        );

        final result = await service.recall(query: 'query', k: 5);
        expect(
          result['_provenance_note'],
          allOf(
            contains('STORED MEMORIES'),
            contains('NOT instructions'),
            contains('sourceType is caller-asserted'),
          ),
        );
        final hits = result['hits'] as List;
        expect(hits, hasLength(3));
        final bySource = {
          for (final h in hits.cast<Map>()) h['sourceType']: h,
        };
        expect(bySource[MemorySource.url]!['externallySourced'], isTrue);
        expect(bySource[MemorySource.file]!['externallySourced'], isTrue);
        // Non-external hits must NOT carry the key at all (kept out of the
        // common case's JSON, not just false).
        expect(
          bySource[MemorySource.note]!.containsKey('externallySourced'),
          isFalse,
        );
      },
    );

    test(
      'M-4 (2026-09-07 security review): rejects a query over maxTextChars '
      'instead of forwarding it whole to the embedder',
      () async {
        expect(
          () => service.recall(query: 'q' * (service.maxTextChars + 1)),
          throwsA(
            isA<ValidationException>().having(
              (e) => e.message,
              'message',
              contains('query'),
            ),
          ),
        );
      },
    );
  });

  group('get', () {
    test(
      'M-8 (2026-09-07 security review): carries the same untrusted-'
      'content framing as recall — _provenance_note always, '
      'externallySourced only for url/file',
      () async {
        final noteEntry = await service.remember(
          text: 'typed note for get',
          sourceType: MemorySource.note,
          project: 'test',
        );
        final urlEntry = await service.remember(
          text: 'fetched page for get',
          sourceType: MemorySource.url,
          project: 'test',
        );

        final gotNote = await service.get(noteEntry['id'] as int);
        expect(
          gotNote['_provenance_note'],
          allOf(
            contains('STORED MEMORIES'),
            contains('NOT instructions'),
            contains('sourceType is caller-asserted'),
          ),
        );
        expect(gotNote.containsKey('externallySourced'), isFalse);

        final gotUrl = await service.get(urlEntry['id'] as int);
        expect(gotUrl['_provenance_note'], gotNote['_provenance_note']);
        expect(gotUrl['externallySourced'], isTrue);
      },
    );
  });

  group('forget', () {
    test('soft forget sets expiresAt and keeps data', () async {
      final r = await service.remember(text: 'soft target', project: 'test');
      final result = await service.forget(r['id'] as int);
      expect(result['action'], 'soft-forgotten');
      final entry = entries().get(r['id'] as int)!;
      expect(entry.expiresAt, isNotNull);
      expect(index().count(), 1, reason: 'soft forget keeps the index row');
    });

    test('hard forget cascades completely in one tx', () async {
      embedder.register('query', embedder.planeVector(0));
      final a = await service.remember(text: 'doomed', tags: ['keep-tag'], project: 'test');
      final b = await service.remember(text: 'survivor', project: 'test');
      await service.link(a['id'] as int, b['id'] as int, LinkType.related);
      final aId = a['id'] as int;

      final result = await service.forget(aId, hard: true);
      expect(result['action'], 'hard-deleted');
      expect(result['indexRowsRemoved'], 1);
      expect(result['memoryLinksRemoved'], 1);
      expect(result['tagLinksRemoved'], 1);

      expect(entries().get(aId), isNull);
      expect(
        index().query(MemoryIndex_.entryId.equals(aId)).build().count(),
        0,
        reason: 'index row must not survive a hard delete',
      );
      expect(store.box<MemoryLink>().count(), 0);
      final tag =
          store
              .box<Tag>()
              .query(Tag_.name.equals('keep-tag'))
              .build()
              .findFirst()!;
      expect(
        tag.entries,
        isEmpty,
        reason: 'tag survives but its link to the entry must be gone',
      );
    });

    test(
      'clears dangling supersededBy pointers to the deleted entry',
      () async {
        final old = await service.remember(text: 'v1', project: 'test');
        final sup = await service.supersede(old['id'] as int, text: 'v2');
        await service.forget(sup['newId'] as int, hard: true);
        final oldEntry = entries().get(old['id'] as int)!;
        expect(
          oldEntry.supersededBy.targetId,
          0,
          reason: 'no misleading references to deleted rows (contract §8)',
        );
      },
    );
  });

  group('supersede', () {
    // 2026-09-06 (Fix 1): the old entry here carries project: 'test' and
    // supersede() below passes NO explicit project — this is the pin for
    // "omitting project inherits the old entry's non-empty project". A
    // separate test for that alone would duplicate this one; cited instead
    // per CLAUDE.md's "no duplicated logic" rule.
    test('links old to new without deleting history, inheriting the old '
        "entry's project when none is passed explicitly", () async {
      final old = await service.remember(text: 'the api port is 8080', project: 'test');
      final result = await service.supersede(
        old['id'] as int,
        text: 'the api port is 9090',
      );
      final oldEntry = entries().get(old['id'] as int)!;
      expect(oldEntry.supersededBy.targetId, result['newId']);
      expect(entries().count(), 2);
      final newEntry = entries().get(result['newId'] as int)!;
      expect(
        newEntry.project,
        'test',
        reason: 'omitting project on supersede() must inherit the old '
            "entry's project — never silently fall back to empty",
      );
    });

    test('rejects self-supersede on identical text', () async {
      final old = await service.remember(text: 'identical', project: 'test');
      expect(
        () => service.supersede(old['id'] as int, text: 'identical'),
        throwsA(isA<ValidationException>()),
      );
    });

    test(
      'rejects an explicit empty project on supersede() — never silently '
      "swaps it for the old entry's project",
      () async {
        final old = await service.remember(
          text: 'has a real project',
          project: 'test',
        );
        expect(
          () => service.supersede(
            old['id'] as int,
            text: 'corrected',
            project: '',
          ),
          throwsA(
            isA<ValidationException>().having(
              (e) => e.message,
              'message',
              contains('project is required'),
            ),
          ),
        );
      },
    );

    test(
      'rejects supersede() that omits project when the OLD entry itself '
      'has none to inherit (e.g. seeded before project became required, '
      'or arrived via sync from an older client)',
      () async {
        // Raw box put bypassing remember()'s validation — the only way to
        // construct an entry with an empty project now that remember()
        // itself rejects one (same technique other tests in this file use
        // to seed rows directly, e.g. the "schema-enforced identity" group
        // above).
        final oldId = entries().put(
          MemoryEntry(
            title: 'legacy entry, no project',
            text: 'legacy entry, no project',
            kind: MemoryKind.fact,
            sourceType: MemorySource.note,
            contentHash: MemoryService.contentHashOf(
              'legacy entry, no project',
            ),
          ),
        );
        expect(
          () => service.supersede(oldId, text: 'corrected'),
          throwsA(
            isA<ValidationException>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('has no project'),
                contains('pass project explicitly'),
              ),
            ),
          ),
        );
      },
    );
  });

  group('link / unlink', () {
    test('creates typed links, detects duplicates, unlinks', () async {
      final a = await service.remember(text: 'parent note', project: 'test');
      final b = await service.remember(text: 'child note', project: 'test');
      final l1 = await service.link(
        a['id'] as int,
        b['id'] as int,
        LinkType.parent,
      );
      expect(l1['duplicate'], isFalse);
      final l2 = await service.link(
        a['id'] as int,
        b['id'] as int,
        LinkType.parent,
      );
      expect(l2['duplicate'], isTrue);
      expect(l2['linkId'], l1['linkId']);

      final got = await service.get(a['id'] as int);
      final links = got['links'] as List;
      expect(links, hasLength(1));
      expect((links.single as Map)['type'], LinkType.parent);
      expect((links.single as Map)['direction'], 'out');

      final removed = await service.unlink(l1['linkId'] as int);
      expect(removed['removed'], isTrue);
      expect(store.box<MemoryLink>().count(), 0);
    });

    test('rejects unknown link type and missing entries', () async {
      final a = await service.remember(text: 'only entry', project: 'test');
      // 2026-09-01 (Store-Gate, plan §14 MAJOR-5): link() now returns a
      // Future, so the ValidationException arrives via the Future, not
      // synchronously — throwsA matches a Future directly (no `() =>`
      // wrapper needed); await via expectLater so the test doesn't
      // complete before the async expectation resolves.
      await expectLater(
        service.link(a['id'] as int, 424242, LinkType.related),
        throwsA(isA<ValidationException>()),
      );
      await expectLater(
        service.link(a['id'] as int, a['id'] as int, 'friendship'),
        throwsA(isA<ValidationException>()),
      );
    });

    test(
      'M-4 (2026-09-07 security review): rejects an oversized link note, '
      'and truncates an echoed oversized link type in the error message',
      () async {
        final a = await service.remember(text: 'link source', project: 'test');
        final b = await service.remember(text: 'link target', project: 'test');
        await expectLater(
          service.link(
            a['id'] as int,
            b['id'] as int,
            LinkType.related,
            note: 'n' * 4097,
          ),
          throwsA(
            isA<ValidationException>().having(
              (e) => e.message,
              'message',
              contains('note'),
            ),
          ),
        );
        final hugeType = 't' * 10000;
        await expectLater(
          service.link(a['id'] as int, b['id'] as int, hugeType),
          throwsA(
            isA<ValidationException>().having(
              (e) => e.message,
              'message',
              allOf(contains('…'), predicate<String>((m) => m.length < 1000)),
            ),
          ),
        );
      },
    );
  });

  group('list_recent / stats', () {
    test('list_recent returns newest first with project filter', () async {
      for (var i = 0; i < 5; i++) {
        await service.remember(
          text: 'entry $i',
          project: i.isEven ? 'even' : 'odd',
        );
      }
      final recent = await service.listRecent(n: 3);
      expect(recent['count'], 3);
      final all = await service.listRecent(n: 10, project: 'even');
      expect(
        (all['entries'] as List).map((e) => (e as Map)['project']),
        everyElement('even'),
      );
    });

    test('stats counts by kind/source and reports index health', () async {
      // sourceType is explicit on every call here on purpose — the test
      // must not depend on remember()'s ambient sourceType default (FIX-9:
      // that default is 'note', chosen deliberately; a test coupling to
      // "whatever the default happens to be" would silently drift with it).
      await service.remember(
        text: 'a fact',
        kind: MemoryKind.fact,
        sourceType: MemorySource.chat,
        project: 'test',
      );
      await service.remember(
        text: 'a decision',
        kind: MemoryKind.decision,
        sourceType: MemorySource.note,
        project: 'test',
      );
      // Create an inconsistency: one entry without index row + one orphan.
      final r = await service.remember(
        text: 'lost index',
        sourceType: MemorySource.note,
        project: 'test',
      );
      index()
          .query(MemoryIndex_.entryId.equals(r['id'] as int))
          .build()
          .remove();
      index().put(
        MemoryIndex(
          sourceKey: 'memory:31337',
          entryId: 31337,
          embedModel: embedder.modelId,
          dims: 768,
          textHash: 'x',
        ),
      );

      final stats = await service.stats();
      expect((stats['byKind'] as Map)[MemoryKind.fact], 2);
      expect((stats['byKind'] as Map)[MemoryKind.decision], 1);
      expect((stats['bySourceType'] as Map)[MemorySource.chat], 1);
      expect((stats['bySourceType'] as Map)[MemorySource.note], 2);
      final indexStats = stats['index'] as Map;
      expect(indexStats['entriesWithoutIndex'], 1);
      expect(indexStats['orphanedRows'], 1);
    });

    test(
      'stats reports orphaned SourceDocuments and dangling MemoryLinks '
      '(FIX-2d) without deleting anything',
      () async {
        final withDoc = await service.remember(
          text: 'chunk of a doc',
          docName: 'paper.pdf',
          docContentHash: 'doc-hash-1',
          project: 'test',
        );
        final a = await service.remember(text: 'link source A2', project: 'test');
        final b = await service.remember(text: 'link target B2', project: 'test');
        await service.link(a['id'] as int, b['id'] as int, LinkType.related);

        // Orphan the source document: hard-delete its only referring entry
        // via forget(hard: true) — the cascade removes the entry's index
        // row/tags/links but source documents are shared and deliberately
        // NOT cascade-deleted.
        await service.forget(withDoc['id'] as int, hard: true);
        expect(store.box<SourceDocument>().count(), 1);

        // Orphan the link the same way FIX-2's reindex test does: raw
        // remove of the target entry, simulating a sync-side replace.
        entries().remove(b['id'] as int);

        final stats = await service.stats();
        expect(stats['orphanedSourceDocuments'], 1);
        expect(stats['danglingMemoryLinks'], 1);
        // Report-only: nothing was deleted by calling stats().
        expect(store.box<SourceDocument>().count(), 1);
        expect(store.box<MemoryLink>().count(), 1);
      },
    );

    // 2026-09-07 (ObjectBox conformance review R10): forget(hard: true)
    // clears the entry↔tag link but never removes a Tag left with zero
    // entries — same report-only discipline as orphaned SourceDocuments/
    // dangling MemoryLinks above, so stats() must surface it too.
    test(
      'stats reports orphanedTags after hard-forgetting the only entry '
      'that used a tag, without deleting the Tag row',
      () async {
        final r = await service.remember(
          text: 'entry with a tag',
          project: 'test',
          tags: ['solo-tag'],
        );
        expect(store.box<Tag>().count(), 1);

        await service.forget(r['id'] as int, hard: true);

        final stats = await service.stats();
        expect(stats['orphanedTags'], 1);
        // Report-only: the Tag row itself still exists after stats().
        expect(store.box<Tag>().count(), 1);
      },
    );
  });

  group('reindex', () {
    test(
      'repairs missing, stale and orphaned rows deterministically',
      () async {
        final missing = await service.remember(text: 'lost my index row', project: 'test');
        final stale = await service.remember(text: 'text will drift', project: 'test');
        await service.remember(text: 'healthy', project: 'test');
        // Break things directly at the box level.
        index()
            .query(MemoryIndex_.entryId.equals(missing['id'] as int))
            .build()
            .remove();
        final staleEntry = entries().get(stale['id'] as int)!;
        staleEntry.text = 'drifted text';
        staleEntry.contentHash = MemoryService.contentHashOf('drifted text');
        entries().put(staleEntry);
        index().put(
          MemoryIndex(
            sourceKey: 'memory:404',
            entryId: 404,
            embedModel: embedder.modelId,
            dims: 768,
            textHash: 'x',
          ),
        );

        final dry = await service.reindex(dryRun: true);
        expect(dry['created'], 1);
        expect(dry['reembedded'], 1);
        expect(dry['orphanedRowsRemoved'], 1);
        expect(
          index()
              .query(MemoryIndex_.sourceKey.equals('memory:404'))
              .build()
              .count(),
          1,
          reason: 'dryRun must not write',
        );

        final run = await service.reindex();
        expect(run['created'], 1);
        expect(run['reembedded'], 1);
        expect(run['orphanedRowsRemoved'], 1);
        expect(run['failed'], isEmpty);

        final again = await service.reindex();
        expect(again['created'], 0);
        expect(again['reembedded'], 0);
        expect(again['unchanged'], 3);
        expect(logLines.join('\n'), contains('[reindex] summary'));
      },
    );

    test('marks rows failed and reports when embedding breaks', () async {
      final r = await service.remember(text: 'will go stale', project: 'test');
      final entry = entries().get(r['id'] as int)!;
      entry.text = 'drifted';
      entry.contentHash = MemoryService.contentHashOf('drifted');
      entries().put(entry);
      embedder.failWith = EmbedderException('Ollama down (test)');

      final run = await service.reindex();
      expect((run['failed'] as List), hasLength(1));
      expect(index().getAll().single.status, IndexStatus.failed);
    });

    // 2026-09-07 (ObjectBox conformance review R7): reindex's write batch
    // now commits all of a batch's row upserts in ONE outer write
    // transaction instead of one per row (see the comment at
    // memory_service.dart's 'reindex-write-batch' session). This test
    // exercises the exact caveat that change introduces: an entry removed
    // between scan and write (the existing per-row TOCTOU re-check) must
    // still be SKIPPED without aborting the shared transaction that the
    // OTHER rows in the same batch are committing through.
    test(
      'a batch containing an entry removed between scan and write still '
      'indexes the others (R7: one write transaction per batch)',
      () async {
        final a = await service.remember(text: 'batch entry A', project: 'test');
        final b = await service.remember(text: 'batch entry B', project: 'test');
        final c = await service.remember(text: 'batch entry C', project: 'test');
        // Force all three to need re-creation, same setup as the sibling
        // 'repairs missing...' test above.
        for (final r in [a, b, c]) {
          index()
              .query(MemoryIndex_.entryId.equals(r['id'] as int))
              .build()
              .remove();
        }
        final cId = c['id'] as int;
        // Fires once, on the FIRST embed call inside reindex's phase 2 (the
        // 3 embeds from remember() above already happened, so this is call
        // #4 overall) — i.e. before ANY of this batch's writes (phase 3)
        // have run, regardless of which work item is embedded first. Raw
        // box removal, exactly like the other TOCTOU-simulating tests in
        // this file (e.g. the dangling-link test above).
        embedder.onEmbed = () {
          if (embedder.calls.length == 3) entries().remove(cId);
        };

        final run = await service.reindex();

        expect(run['created'], 2, reason: 'A and B must still be indexed');
        expect(
          index().query(MemoryIndex_.entryId.equals(a['id'] as int)).build().count(),
          1,
        );
        expect(
          index().query(MemoryIndex_.entryId.equals(b['id'] as int)).build().count(),
          1,
        );
        expect(
          index().query(MemoryIndex_.entryId.equals(cId)).build().count(),
          0,
          reason: 'C was removed before its write; no row must exist for it',
        );
        expect(
          logLines.join('\n'),
          contains('SKIPPED create for entry $cId: entry no longer exists'),
        );
      },
    );

    test(
      'detects dangling MemoryLinks (FIX-2) left by a simulated sync-side '
      'replace, reports by default, purges only with purgeDanglingLinks',
      () async {
        final a = await service.remember(text: 'link source A', project: 'test');
        final b = await service.remember(text: 'link target B', project: 'test');
        final linkResult = await service.link(
          a['id'] as int,
          b['id'] as int,
          LinkType.related,
        );

        // Simulate a sync-side cross-device contentHash replace: B's row is
        // gone (raw box remove, bypassing forget()'s cascade) but the link
        // that pointed at it survives, exactly like a replace minting a new
        // id would leave the old id dangling.
        entries().remove(b['id'] as int);

        final dry = await service.reindex(dryRun: true);
        expect(dry['danglingLinks'], 1);
        expect(dry['danglingLinksPurged'], 0);
        final details = (dry['danglingLinkDetails'] as List).single as Map;
        expect(details['linkId'], linkResult['linkId']);
        expect(details['toMissing'], isTrue);
        expect(
          store.box<MemoryLink>().count(),
          1,
          reason: 'dryRun must not remove anything',
        );

        final defaultRun = await service.reindex();
        expect(
          defaultRun['danglingLinks'],
          1,
          reason: 'dangling link must still be reported',
        );
        expect(
          defaultRun['danglingLinksPurged'],
          0,
          reason:
              'default sweep must NOT auto-purge — a link can legitimately '
              'arrive before its target via sync',
        );
        expect(
          store.box<MemoryLink>().count(),
          1,
          reason: 'the dangling link must survive the default sweep',
        );
        expect(
          logLines.join('\n'),
          contains('dangling MemoryLink'),
          reason: 'dangling links must be logged, never silently ignored',
        );

        final purged = await service.reindex(purgeDanglingLinks: true);
        expect(purged['danglingLinks'], 1);
        expect(purged['danglingLinksPurged'], 1);
        expect(
          store.box<MemoryLink>().count(),
          0,
          reason: 'purgeDanglingLinks:true must remove the dangling link',
        );
        expect(logLines.join('\n'), contains('purged 1 dangling'));
      },
    );
  });

  group('dimension mismatch', () {
    test('service constructor rejects embedder dims != schema dims', () {
      final wrong = FakeEmbedder(dims: 512);
      expect(
        () => MemoryService(gate: gate, embedder: wrong, log: logCapture),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            allOf(contains('512'), contains('768')),
          ),
        ),
      );
    });

    test(
      'embed-time wrong vector length is rejected naming both numbers',
      () async {
        final liar = FakeEmbedder(emitDims: 512); // claims 768, emits 512
        final svc = MemoryService(
          gate: gate,
          embedder: liar,
          log: logCapture,
        );
        final result = await svc.remember(text: 'liar vector', project: 'test');
        expect(result['indexed'], isFalse);
        expect(result['warning'], allOf(contains('512'), contains('768')));
        await svc.dispose();
      },
    );
  });

  group('observer-driven indexing', () {
    test('entries put directly (as if arrived via sync) get indexed by the '
        'watcher sweep', () async {
      service.startIndexWatcher(debounce: const Duration(milliseconds: 50));
      // Simulate a sync arrival: direct box put, bypassing remember().
      final id = entries().put(
        MemoryEntry(
          title: 'from another device',
          text: 'synced knowledge',
          kind: MemoryKind.fact,
          sourceType: MemorySource.chat,
          contentHash: MemoryService.contentHashOf('synced knowledge'),
        ),
      );
      // Wait for debounce + sweep.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final row =
          index()
              .query(
                MemoryIndex_.sourceKey.equals(MemoryIndex.sourceKeyFor(id)),
              )
              .build()
              .findFirst();
      expect(
        row,
        isNotNull,
        reason: 'observer sweep must index sync-arrived entries',
      );
      expect(row!.status, IndexStatus.ok);
      expect(logLines.join('\n'), contains('index watcher started'));
    });

    test(
      'R2-1/R2-2: recall (accessCount bump) schedules a sweep, but the '
      'sweep causes zero embedder calls (idempotence guarantee, not '
      'suppression)',
      () async {
        embedder.register('query', embedder.planeVector(0));
        final r = await service.remember(text: 'hit me for stats', project: 'test');
        service.startIndexWatcher(debounce: const Duration(milliseconds: 50));

        final callsBeforeRecall = embedder.calls.length;
        await service.recall(query: 'query', k: 1);
        // recall's own embed call happens synchronously as part of recall
        // itself — that's expected. What must NOT happen is the debounced
        // sweep the accessCount-bump write schedules re-embedding the entry:
        // the sweep MAY run (it is no longer suppressed), but it must find
        // nothing stale and therefore call the embedder zero times.
        final callsRightAfterRecall = embedder.calls.length;

        // Let the debounced sweep, which IS scheduled now, run to
        // completion.
        await Future<void>.delayed(const Duration(milliseconds: 300));

        expect(
          embedder.calls.length,
          callsRightAfterRecall,
          reason:
              'no extra embed calls should happen after recall returns — '
              'the debounced sweep triggered by the accessCount bump must '
              'be a true no-op (idempotence), even though it does run',
        );
        expect(embedder.calls.length, greaterThan(callsBeforeRecall));
        expect(
          logLines.join('\n'),
          contains('incremental sweep: no discrepancies'),
          reason:
              'the sweep triggered by the self-write must actually run '
              '(not be suppressed/dropped) and find nothing to do',
        );
        // Entry stays correctly indexed throughout.
        final row = index().query(
          MemoryIndex_.entryId.equals(r['id'] as int),
        ).build().findFirst()!;
        expect(row.status, IndexStatus.ok);
      },
    );

    test(
      'an out-of-band (simulated sync-arrived) write is still '
      'incrementally indexed via the watcher sweep, and the sweep logs '
      'the incremental summary (not a full reindex)',
      () async {
        embedder.register('external entry', embedder.planeVector(0));
        service.startIndexWatcher(debounce: const Duration(milliseconds: 50));
        // Raw box put, bypassing remember() entirely — the only way to
        // simulate a second store/device writing without a second process
        // (a real second device's write would arrive via Sync and fire the
        // same store.entityChanges notification this exercises).
        final id = entries().put(
          MemoryEntry(
            title: 'external',
            text: 'external entry',
            kind: MemoryKind.fact,
            sourceType: MemorySource.chat,
            contentHash: MemoryService.contentHashOf('external entry'),
          ),
        );
        expect(
          index().query(MemoryIndex_.entryId.equals(id)).build().count(),
          0,
          reason: 'no sweep has run yet — must not be indexed',
        );

        // Wait for debounce + the incremental sweep it schedules.
        await Future<void>.delayed(const Duration(milliseconds: 400));

        final row = index().query(
          MemoryIndex_.entryId.equals(id),
        ).build().findFirst();
        expect(row, isNotNull);
        expect(row!.status, IndexStatus.ok);
        expect(
          logLines.join('\n'),
          contains('incremental sweep: examined'),
          reason: 'the observer path must use the incremental sweep, not a '
              'full reindex',
        );
      },
    );

    test(
      'R2-1: an out-of-band raw write immediately surrounded by service '
      'writes still gets indexed once the debounce elapses — nothing is '
      'ever dropped',
      () async {
        embedder.register('query', embedder.planeVector(0));
        embedder.register(
          'external amid self-writes',
          embedder.planeVector(20),
        );
        service.startIndexWatcher(debounce: const Duration(milliseconds: 50));

        // A self-write immediately before...
        final r = await service.remember(text: 'hit me for stats', project: 'test');
        // ...the out-of-band raw write simulating a sync arrival landing in
        // the same short window...
        final externalId = entries().put(
          MemoryEntry(
            title: 'external amid self-writes',
            text: 'external amid self-writes',
            kind: MemoryKind.fact,
            sourceType: MemorySource.chat,
            contentHash: MemoryService.contentHashOf(
              'external amid self-writes',
            ),
          ),
        );
        // ...immediately followed by another self-write (recall's
        // accessCount bump). Under the OLD grace-window design, the
        // external write above could land inside the grace window opened
        // by either self-write and be discarded forever.
        await service.recall(query: 'query', k: 1);

        await Future<void>.delayed(const Duration(milliseconds: 400));

        final externalRow = index()
            .query(MemoryIndex_.entryId.equals(externalId))
            .build()
            .findFirst();
        expect(
          externalRow,
          isNotNull,
          reason:
              'the sync-arrived write must be indexed even though it was '
              'sandwiched between two of this service\'s own writes — '
              'nothing may be silently dropped',
        );
        expect(externalRow!.status, IndexStatus.ok);
        final ownRow = index()
            .query(MemoryIndex_.entryId.equals(r['id'] as int))
            .build()
            .findFirst()!;
        expect(ownRow.status, IndexStatus.ok);
      },
    );

    test(
      'R2-1/R2-2: continuous notifications faster than the debounce '
      'interval still produce a sweep within the max-latency cap',
      () async {
        embedder.register('external cap test', embedder.planeVector(30));
        // Debounce longer than the polling interval below, and a short cap,
        // so a naive re-arm-forever debounce would never fire within the
        // test's wait, but the cap forces a sweep well before it.
        service.startIndexWatcher(
          debounce: const Duration(milliseconds: 200),
          maxLatency: const Duration(milliseconds: 300),
        );

        final id = entries().put(
          MemoryEntry(
            title: 'external cap test',
            text: 'external cap test',
            kind: MemoryKind.fact,
            sourceType: MemorySource.chat,
            contentHash: MemoryService.contentHashOf('external cap test'),
          ),
        );

        // Keep re-arming the debounce with unrelated self-writes faster
        // than the 200ms debounce interval, for longer than the 300ms cap.
        final stopwatch = Stopwatch()..start();
        while (stopwatch.elapsedMilliseconds < 900) {
          await service.remember(
            text: 'filler ${stopwatch.elapsedMicroseconds}',
            project: 'test',
          );
          await Future<void>.delayed(const Duration(milliseconds: 80));
        }

        final row = index().query(
          MemoryIndex_.entryId.equals(id),
        ).build().findFirst();
        expect(
          row,
          isNotNull,
          reason:
              'the max-latency cap must force at least one sweep even '
              'under continuous sub-debounce-interval notifications',
        );
        expect(row!.status, IndexStatus.ok);
        expect(
          logLines.join('\n'),
          contains('max latency cap'),
          reason: 'the cap firing must be logged, not a silent behavior '
              'change',
        );
      },
    );

    test(
      'R2-3: a raw-deleted entry (simulating a sync-arrived delete) has '
      'its orphaned index row removed by the incremental sweep, logged',
      () async {
        embedder.register('will be deleted', embedder.planeVector(0));
        final r = await service.remember(text: 'will be deleted', project: 'test');
        final id = r['id'] as int;
        expect(
          index().query(MemoryIndex_.entryId.equals(id)).build().count(),
          1,
        );

        service.startIndexWatcher(debounce: const Duration(milliseconds: 50));
        // Raw entry delete, bypassing forget() entirely — simulates a
        // sync-arrived delete that leaves the index row behind (forget()'s
        // own cascade already removes the row for local hard-deletes; this
        // exercises the path where the row survives independently of it).
        entries().remove(id);

        await Future<void>.delayed(const Duration(milliseconds: 400));

        expect(
          index().query(MemoryIndex_.entryId.equals(id)).build().count(),
          0,
          reason: 'the incremental sweep must remove the now-orphaned '
              'index row, not just the forward (missing/stale) diff',
        );
        expect(
          logLines.join('\n'),
          contains('removed 1 orphaned index row(s)'),
          reason: 'orphan removal must be logged with count and ids',
        );
      },
    );
  });

  group('SEC-5: sanitizeForLog', () {
    test('strips newlines and ESC sequences, leaves normal text alone', () {
      const poisoned =
          'innocent title\n10:00:00 [ERROR] fake log line'
          '\x1b[31mred text\x1b[0m\x07bell';
      final sanitized = MemoryService.sanitizeForLog(poisoned);
      expect(sanitized, isNot(contains('\n')));
      expect(sanitized, isNot(contains('\x1b')));
      expect(sanitized, isNot(contains('\x07')));
      expect(sanitized, contains('innocent title'));
      expect(sanitized, contains('fake log line'));
      expect(
        MemoryService.sanitizeForLog('plain ascii title'),
        'plain ascii title',
      );
    });

    test(
      'a tag name with a forged log line is sanitized in the produced '
      'log, but stored verbatim',
      () async {
        const poisonedTag = 'gc\n10:00:00 [FATAL] fake shutdown\x1b[31m!';
        await service.remember(text: 'y', tags: [poisonedTag], project: 'test');

        // Stored data is untouched (only the LOG line is sanitized).
        final storedTag = store.box<Tag>().getAll().single;
        expect(storedTag.name, poisonedTag);

        // The log line must not contain the raw newline/ESC byte.
        final combinedLog = logLines.join('\n---\n');
        expect(combinedLog, isNot(contains('\n10:00:00 [FATAL]')));
        expect(combinedLog, isNot(contains('\x1b[31m')));
        expect(combinedLog, contains('created tag'));
      },
    );

    test(
      'M-5 (2026-09-07 security review): the duplicate-remember log line '
      "sanitizes the existing entry's title, but the stored title is "
      'untouched',
      () async {
        const poisonedTitle = 'dup title\n10:00:00 [FATAL] forged\x1b[31m!';
        final first = await service.remember(
          text: 'M-5 duplicate probe text',
          title: poisonedTitle,
          project: 'test',
        );
        logLines.clear();
        final second = await service.remember(
          text: 'M-5 duplicate probe text',
          project: 'test',
        );
        expect(second['duplicate'], isTrue);
        expect(second['id'], first['id']);

        final storedEntry = entries().get(first['id'] as int)!;
        expect(
          storedEntry.title,
          poisonedTitle,
          reason: 'only the LOG line is sanitized, not the stored title',
        );

        final combinedLog = logLines.join('\n---\n');
        expect(combinedLog, contains('duplicate remember()'));
        expect(combinedLog, isNot(contains('\n10:00:00 [FATAL]')));
        expect(combinedLog, isNot(contains('\x1b[31m')));
      },
    );
  });

  // ---------------------------------------------------------------------
  // 2026-09-07 (contract §5 query-first, reviewer finding L-5): the three
  // getAll()-and-filter sites below (_findDanglingLinks, stats()'s
  // orphaned-SourceDocument computation, _incrementalSweep's scan) were
  // refactored to bounded, query-first reads. These tests exercise each
  // path at a scale (500-600+ rows) that crosses _pageThrough's default
  // page size (500) or otherwise stresses the property-projection zip, to
  // catch a correctness regression that a handful of rows would not
  // reveal (e.g. a positional misalignment between two separate
  // PropertyQuery projections, or a page-boundary off-by-one).
  // ---------------------------------------------------------------------
  group('query-first refactor at scale (2026-09-07, L-5)', () {
    test(
      '_findDanglingLinks detects exactly the dangling links across a '
      '600-link box spanning more than one _pageThrough page',
      () async {
        const n = 300;
        final ids = <int>[];
        for (var i = 0; i < n; i++) {
          final r = await service.remember(
            text: 'link-scale entry $i',
            project: 'test',
          );
          ids.add(r['id'] as int);
        }
        // 2 links per entry (offsets 1 and 2) = 600 links total, more than
        // one _pageThrough page (default 500).
        for (var i = 0; i < n; i++) {
          await service.link(ids[i], ids[(i + 1) % n], LinkType.related);
          await service.link(ids[i], ids[(i + 2) % n], LinkType.related);
        }
        expect(store.box<MemoryLink>().count(), 2 * n);

        // Hard-delete 5 entries spaced far enough apart (60 > offset 2)
        // that no two deleted entries share a link — each contributes
        // exactly 4 dangling links (2 outgoing + 2 incoming), so the
        // expected total is exactly 20, not an estimate.
        final deletePositions = [0, 60, 120, 180, 240];
        for (final p in deletePositions) {
          entries().remove(ids[p]);
        }

        final stats = await service.stats();
        expect(stats['danglingMemoryLinks'], 20);

        final dry = await service.reindex(dryRun: true);
        expect(dry['danglingLinks'], 20);
        final details = dry['danglingLinkDetails'] as List;
        expect(details, hasLength(20));
        // Nothing was purged — report-only by default.
        expect(store.box<MemoryLink>().count(), 2 * n);
      },
    );

    test(
      'stats() orphaned-SourceDocument computation is exact across a '
      '550-entry box spanning more than one _pageThrough page',
      () async {
        const n = 550;
        const docCount = 10;
        final entriesByDoc = <int, List<int>>{
          for (var d = 0; d < docCount; d++) d: [],
        };
        for (var i = 0; i < n; i++) {
          final docIndex = i % docCount;
          final r = await service.remember(
            text: 'doc-scale entry $i',
            project: 'test',
            docName: 'doc-$docIndex.pdf',
            docContentHash: 'doc-scale-hash-$docIndex',
          );
          entriesByDoc[docIndex]!.add(r['id'] as int);
        }
        expect(store.box<SourceDocument>().count(), docCount);

        // Hard-forget every entry citing doc 0 — doc 0 becomes the ONLY
        // orphan; docs 1..9 keep at least one live citing entry.
        for (final id in entriesByDoc[0]!) {
          await service.forget(id, hard: true);
        }

        final stats = await service.stats();
        expect(stats['orphanedSourceDocuments'], 1);
        // Report-only: no SourceDocument is ever deleted by stats().
        expect(store.box<SourceDocument>().count(), docCount);
      },
    );

    test(
      '_incrementalSweep repairs exactly the broken rows (missing, stale, '
      'wrong status, null embedding, orphan) across a 600+ entry box, '
      'leaving every healthy row untouched',
      () async {
        const n = 600;
        final ids = <int>[];
        for (var i = 0; i < n; i++) {
          final r = await service.remember(
            text: 'sweep-scale entry $i',
            project: 'test',
          );
          ids.add(r['id'] as int);
        }

        // Every broken position is distinct and spread across
        // start/middle/end so the property-projection zip is exercised at
        // both page-adjacent and mid-range offsets.
        const missingPositions = [0, 300, 599];
        const stalePositions = [1, 301, 598];
        const failedStatusPositions = [2, 597];
        const nullEmbeddingPositions = [3, 596];

        for (final p in missingPositions) {
          index()
              .query(MemoryIndex_.entryId.equals(ids[p]))
              .build()
              .remove();
        }
        final staleHashes = <int, String>{};
        for (final p in stalePositions) {
          final e = entries().get(ids[p])!;
          e.text = 'drifted ${e.text}';
          e.contentHash = MemoryService.contentHashOf(e.text);
          entries().put(e);
          staleHashes[p] = e.contentHash;
        }
        for (final p in failedStatusPositions) {
          final row = index()
              .query(MemoryIndex_.entryId.equals(ids[p]))
              .build()
              .findFirst()!;
          row.status = IndexStatus.failed;
          index().put(row);
        }
        for (final p in nullEmbeddingPositions) {
          final row = index()
              .query(MemoryIndex_.entryId.equals(ids[p]))
              .build()
              .findFirst()!;
          row.embedding = null;
          index().put(row);
        }
        // 4 orphaned index rows: entryId points at nothing live.
        for (var k = 0; k < 4; k++) {
          index().put(
            MemoryIndex(
              sourceKey: 'memory:orphan-scale-$k',
              entryId: 900000 + k,
              embedModel: embedder.modelId,
              dims: 768,
              textHash: 'x',
            ),
          );
        }
        expect(store.box<MemoryIndex>().count(), n - 3 + 4);

        final callsBeforeSweep = embedder.calls.length;
        service.startIndexWatcher(debounce: const Duration(milliseconds: 50));
        // The watcher only reacts to MemoryEntry changes (not MemoryIndex
        // puts above) — one more healthy entry after starting the watcher
        // fires entityChanges and arms the debounce; the sweep it runs
        // re-scans the WHOLE current state, including everything broken
        // above regardless of what triggered it.
        final trigger = await service.remember(
          text: 'sweep-scale trigger entry',
          project: 'test',
        );

        // Poll instead of a long fixed sleep — still bounded, but resilient
        // to slow CI without inflating the common-case runtime.
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (DateTime.now().isBefore(deadline) &&
            !logLines.join('\n').contains('incremental sweep: examined')) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }

        final combinedLog = logLines.join('\n');
        expect(
          combinedLog,
          contains('incremental sweep: examined ${n + 1} entries, '
              '10 diff(s), 10 indexed'),
          reason: combinedLog,
        );
        expect(
          combinedLog,
          contains('removed 4 orphaned index row(s)'),
        );

        // Every broken position was actually repaired, with the RIGHT
        // entry's data — this is the check that would catch a positional
        // misalignment in the property-projection zip.
        for (final p in [
          ...missingPositions,
          ...stalePositions,
          ...failedStatusPositions,
          ...nullEmbeddingPositions,
        ]) {
          final entry = entries().get(ids[p])!;
          final row = index()
              .query(MemoryIndex_.entryId.equals(ids[p]))
              .build()
              .findFirst();
          expect(row, isNotNull, reason: 'position $p must be re-indexed');
          expect(row!.status, IndexStatus.ok, reason: 'position $p');
          expect(
            row.textHash,
            entry.contentHash,
            reason: 'position $p must hash the CURRENT (possibly drifted) '
                'text, not some other entry\'s',
          );
          expect(row.embedding, isNotNull, reason: 'position $p');
        }

        // The 4 synthetic orphan rows are gone.
        for (var k = 0; k < 4; k++) {
          expect(
            index()
                .query(MemoryIndex_.sourceKey.equals('memory:orphan-scale-$k'))
                .build()
                .count(),
            0,
          );
        }

        // Exactly 10 repaired entries + the 1 healthy trigger entry were
        // ever embedded by the sweep/its own remember() call — nothing
        // else. (601 remember() calls + 1 trigger already embedded once
        // each on creation; the sweep must add exactly 10 more, not touch
        // any of the n - 10 healthy pre-existing rows again.)
        expect(embedder.calls.length, callsBeforeSweep + 1 + 10);
        // trigger entry itself must stay untouched by the sweep repair
        // count (it was already healthy).
        final triggerRow = index()
            .query(MemoryIndex_.entryId.equals(trigger['id'] as int))
            .build()
            .findFirst()!;
        expect(triggerRow.status, IndexStatus.ok);
      },
    );
  });
}
