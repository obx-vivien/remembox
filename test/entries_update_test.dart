/// Tests for `entries_update` (0.5.0): kind and tag edits in place –
/// content, links and the index row untouched; strict registry rules on
/// added tags; removal always allowed; dry run; caps; flags.
///
/// Synthetic data only: projects `garden`, `acme-app`; tags `housework`,
/// `insight`, `todo`, `status` (retired).
library;

import 'dart:io';

import 'package:remembox/objectbox.g.dart';
import 'package:remembox/src/memory_service.dart';
import 'package:remembox/src/model.dart';
import 'package:remembox/src/store.dart' show RegistryMode;
import 'package:test/test.dart';

import 'helpers/test_server.dart';
import 'helpers/test_store_gate.dart';
import 'support/fake_embedder.dart';

void main() {
  late Directory tempDir;
  late TestGate testGate;
  late Store store;
  late FakeEmbedder embedder;
  late MemoryService open;
  late MemoryService strict;
  late List<String> logLines;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('remembox_entries_update_');
    logLines = [];
    testGate = await openTestGate(tempDir.path, log: logLines.add);
    store = testGate.store;
    embedder = FakeEmbedder();
    open = MemoryService(
      gate: testGate.gate,
      embedder: embedder,
      log: logLines.add,
    );
    strict = MemoryService(
      gate: testGate.gate,
      embedder: embedder,
      log: logLines.add,
      registryMode: RegistryMode.strict,
    );
    await strict.projectSet(name: 'garden', description: 'Synthetic beds.');
  });

  tearDown(() async {
    await open.dispose();
    await strict.dispose();
    await testGate.close();
    tempDir.deleteSync(recursive: true);
  });

  Box<MemoryEntry> entries() => store.box<MemoryEntry>();

  List<String> tagsOf(int id) =>
      entries().get(id)!.tags.map((t) => t.name).toList();

  /// Everything entries_update must never change, per entry.
  Map<String, Object?> untouched(int id) {
    final e = entries().get(id)!;
    final row = store
        .box<MemoryIndex>()
        .query(MemoryIndex_.entryId.equals(id))
        .build()
        .findFirst()!;
    return {
      'text': e.text,
      'title': e.title,
      'project': e.project,
      'hash': e.contentHash,
      'createdAt': e.createdAt,
      'supersededBy': e.supersededBy.targetId,
      'source': e.source.targetId,
      'indexRow': row.id,
      'textHash': row.textHash,
      'indexedAt': row.indexedAt,
      'embedding': row.embedding,
      'links': store.box<MemoryLink>().count(),
    };
  }

  Future<int> remember(String text, {List<String> tags = const []}) async =>
      (await open.remember(text: text, project: 'garden', tags: tags))['id']
          as int;

  test('changes kind and tags in place; content, links and the index row '
      'stay; reindex re-embeds nothing', () async {
    final a = await remember('a dropped approach', tags: ['housework']);
    final b = await remember('a takeaway', tags: ['housework', 'todo']);
    await open.link(a, b, LinkType.related);
    final before = {a: untouched(a), b: untouched(b)};
    final embeds = embedder.calls.length;

    logLines.clear();
    final r = await open.entriesUpdate(
      ids: [a, b],
      kind: MemoryKind.deadEnd,
      addTags: ['insight'],
      removeTags: ['todo'],
    );
    expect(r['dryRun'], isFalse);
    expect(r['changed'], 2);
    expect(r['unchanged'], 0);
    final rows = (r['entries'] as List).cast<Map<String, Object?>>();
    expect(rows.first, {
      'id': a,
      'title': 'a dropped approach',
      'kindFrom': 'fact',
      'kindTo': 'deadEnd',
      'tagsAdded': ['insight'],
      'tagsRemoved': <String>[],
      'alreadyPresent': <String>[],
      'notPresent': ['todo'],
    });
    expect(rows.last['tagsRemoved'], ['todo']);
    expect(r['tagsNowUnused'], ['todo']);
    expect(entries().get(a)!.kind, MemoryKind.deadEnd);
    expect(tagsOf(a), ['housework', 'insight']);
    expect(tagsOf(b), ['housework', 'insight']);
    expect(store.box<Tag>().getAll().map((t) => t.name), contains('todo'));
    expect({a: untouched(a), b: untouched(b)}, before);
    expect(embedder.calls.length, embeds);
    expect(
      logLines.where((l) => l.startsWith('[memory] entries_update: entry ')),
      hasLength(2),
    );
    expect(
      logLines,
      contains('[memory] entries_update: 2 entries, changed=2 unchanged=0 '
          'tagsNowUnused=1'),
    );

    final reindex = await open.reindex();
    expect(reindex['reembedded'], 0);
    expect(reindex['created'], 0);
    expect(reindex['unchanged'], 2);
  });

  test('dryRun reports the same and writes nothing', () async {
    final a = await remember('dry run target', tags: ['todo']);
    final dry = await open.entriesUpdate(
      ids: [a],
      kind: MemoryKind.lesson,
      addTags: ['insight'],
      removeTags: ['todo'],
      dryRun: true,
    );
    expect(dry['dryRun'], isTrue);
    expect(dry['changed'], 1);
    expect(dry['tagsNowUnused'], ['todo']);
    expect(entries().get(a)!.kind, MemoryKind.fact);
    expect(tagsOf(a), ['todo']);
    expect(store.box<Tag>().getAll().map((t) => t.name), ['todo']);
    final real = await open.entriesUpdate(
      ids: [a],
      kind: MemoryKind.lesson,
      addTags: ['insight'],
      removeTags: ['todo'],
    );
    expect(
      {...real}..remove('dryRun'),
      {...dry}..remove('dryRun'),
    );
  });

  test('removeTags matches the normalized form; alreadyPresent and '
      'unchanged entries are reported', () async {
    final a = await remember('apps entry', tags: ['appsScript', 'insight']);
    final r = await open.entriesUpdate(
      ids: [a],
      addTags: ['insight'],
      removeTags: ['apps-script'],
    );
    final row = (r['entries'] as List).single as Map;
    expect(row['tagsRemoved'], ['appsScript']);
    expect(row['alreadyPresent'], ['insight']);
    expect(row['tagsAdded'], isEmpty);
    final none = await open.entriesUpdate(ids: [a], kind: MemoryKind.fact);
    expect(none['changed'], 0);
    expect(none['unchanged'], 1);
  });

  test('an added alias that resolves to a removed tag is netted out, never '
      'reported as now unused', () async {
    await open.tagDefine(
      name: 'insight',
      description: 'Something noticed.',
      addAliases: ['insights'],
    );
    final carrier = await remember('carries insight', tags: ['insight']);
    final bare = await remember('carries nothing');
    final r = await open.entriesUpdate(
      ids: [carrier, bare],
      addTags: ['insights'],
      removeTags: ['insight'],
    );
    final rows = (r['entries'] as List).cast<Map<String, Object?>>();
    for (final row in rows) {
      expect(row['tagsAdded'], isEmpty, reason: '${row['id']}');
      expect(row['tagsRemoved'], isEmpty, reason: '${row['id']}');
      expect(row['notPresent'], isEmpty, reason: '${row['id']}');
    }
    expect(r['changed'], 0);
    expect(r['tagsNowUnused'], isEmpty);
    expect(tagsOf(carrier), ['insight']);
    expect(tagsOf(bare), isEmpty);
    expect(
      r['warning'],
      contains('Tag "insight" is both added (after alias resolution) and '
          'removed – left as it is. (entries $carrier, $bare)'),
    );
  });

  test('netting covers an old unnormalized stored spelling', () async {
    await open.tagDefine(
      name: 'myTag',
      description: 'A synthetic tag.',
      addAliases: ['mt'],
    );
    final a = await remember('legacy spelling');
    // A 0.2-era spelling, stored below today's normalization.
    final entry = entries().get(a)!..tags.add(Tag(name: 'my_tag'));
    entries().put(entry);
    final r = await open.entriesUpdate(
      ids: [a],
      addTags: ['mt'],
      removeTags: ['my_tag'],
    );
    final row = (r['entries'] as List).single as Map;
    expect(row['tagsAdded'], isEmpty);
    expect(row['tagsRemoved'], isEmpty);
    expect(row['notPresent'], isEmpty);
    expect(r['changed'], 0);
    expect(r['tagsNowUnused'], isEmpty);
    expect(tagsOf(a), ['my_tag']);
    expect(
      r['warning'],
      contains('Tag "myTag" is both added (after alias resolution) and '
          'removed – left as it is. (entry $a)'),
    );
  });

  test('the more-than-5 warning counts tags that stay, each once', () async {
    final a = await remember(
      'five tags',
      tags: ['label1', 'label2', 'label3', 'label4', 'label5'],
    );
    // Re-adding two present tags while removing one: still five.
    final r = await open.entriesUpdate(
      ids: [a],
      addTags: ['label1', 'label2'],
      removeTags: ['label5'],
    );
    expect(r['warning'] ?? '', isNot(contains('tags on one entry')));
    // A genuinely sixth tag warns with the real count.
    final six = await open.entriesUpdate(
      ids: [a],
      addTags: ['label6', 'label7'],
    );
    expect(six['warning'], contains('6 tags on one entry'));
  });

  test('a tag equal to the project or the new kind is dropped with the '
      'warning', () async {
    final a = await remember('garden thing');
    final r = await open.entriesUpdate(
      ids: [a],
      kind: MemoryKind.snapshot,
      addTags: ['garden', 'snapshot', 'todo'],
    );
    expect(tagsOf(a), ['todo']);
    expect(
      r['warning'],
      allOf(
        contains(
          'Tag "garden" dropped: matches the project name "garden" – '
          'project is already filterable. (entry $a)',
        ),
        contains('Tag "snapshot" dropped: matches a memory kind '
            '("snapshot")'),
      ),
    );
  });

  test('superseded and expired entries are updated and flagged', () async {
    final old = await remember('version one');
    await open.supersede(old, text: 'version two');
    final gone = await remember('soon forgotten');
    await open.forget(gone);
    final r = await open.entriesUpdate(
      ids: [old, gone],
      addTags: ['insight'],
    );
    final rows = (r['entries'] as List).cast<Map<String, Object?>>();
    expect(rows.first['superseded'], isTrue);
    expect(rows.first.containsKey('expired'), isFalse);
    expect(rows.last['expired'], isTrue);
    expect(tagsOf(old), ['insight']);
    expect(tagsOf(gone), ['insight']);
  });

  group('strict registry mode', () {
    setUp(() async {
      await strict.tagDefine(name: 'insight', description: 'Insights.');
      await strict.tagDefine(name: 'housework', description: 'Chores.');
      await open.tagRetire(name: 'status', hint: 'use kind snapshot');
    });

    test('an unregistered or retired added tag rejects the call for every '
        'id, nothing written', () async {
      final a = await remember('one', tags: ['housework']);
      final b = await remember('two', tags: ['housework']);
      for (final (tags, expected) in [
        (['insight', 'nope'], 'tag(s) not registered (strict registry mode): '
            '"nope"'),
        (['status'], 'tag(s) retired (strict registry mode): "status" – use '
            'kind snapshot.'),
      ]) {
        logLines.clear();
        await expectLater(
          strict.entriesUpdate(
            ids: [a, b],
            kind: MemoryKind.lesson,
            addTags: tags,
          ),
          throwsA(
            isA<ValidationException>().having(
              (e) => e.message,
              'message',
              startsWith(expected),
            ),
          ),
        );
        expect(entries().get(a)!.kind, MemoryKind.fact);
        expect(tagsOf(a), ['housework']);
        expect(tagsOf(b), ['housework']);
        expect(
          logLines.where(
            (l) => l.startsWith('[registry] strict: rejected entries_update – '),
          ),
          hasLength(1),
        );
      }
    });

    test('dryRun runs the strict check too', () async {
      final a = await remember('three');
      await expectLater(
        strict.entriesUpdate(ids: [a], addTags: ['nope'], dryRun: true),
        throwsA(isA<ValidationException>()),
      );
    });

    test('removing a retired or unregistered tag is allowed', () async {
      final a = await remember('status carrier', tags: ['status', 'legacyTag']);
      final r = await strict.entriesUpdate(
        ids: [a],
        kind: MemoryKind.snapshot,
        removeTags: ['status', 'legacyTag'],
      );
      expect(r['changed'], 1);
      expect(tagsOf(a), isEmpty);
      expect(entries().get(a)!.kind, MemoryKind.snapshot);
      expect(r['tagsNowUnused'], ['legacyTag', 'status']);
    });
  });

  group('input validation', () {
    test('rejects bad input before touching anything', () async {
      final a = await remember('only entry');
      final cases = <(Future<Object?> Function(), String)>[
        (
          () => open.entriesUpdate(ids: [a]),
          'entries_update: pass at least one of "kind", "addTags", '
              '"removeTags".',
        ),
        (
          () => open.entriesUpdate(ids: [], kind: MemoryKind.fact),
          'entries_update: "ids" must not be empty.',
        ),
        (
          () => open.entriesUpdate(ids: [a, a], kind: MemoryKind.fact),
          'entries_update: duplicate id(s) in "ids": $a.',
        ),
        (
          () => open.entriesUpdate(
            ids: [for (var i = 1; i <= 501; i++) i],
            kind: MemoryKind.fact,
          ),
          'entries_update: "ids" has 501 entries, exceeding the 500 id limit.',
        ),
        (
          () => open.entriesUpdate(ids: [a, 9998, 9999], kind: MemoryKind.lesson),
          'entries_update: id(s) do not exist, nothing changed: 9998, 9999.',
        ),
        (
          () => open.entriesUpdate(
            ids: [a],
            addTags: ['Apps Script'],
            removeTags: ['apps-script'],
          ),
          'entries_update: "Apps Script" appear in both "addTags" and '
              '"removeTags".',
        ),
        (
          () => open.entriesUpdate(ids: [a], kind: 'Lesson'),
          'Unknown kind "Lesson". Valid kinds: fact, decision, preference, '
              'episode, reference, snapshot, lesson, deadEnd. Did you mean '
              '"lesson"?',
        ),
      ];
      for (final (call, message) in cases) {
        await expectLater(
          call(),
          throwsA(
            isA<ValidationException>().having(
              (e) => e.message,
              'message',
              message,
            ),
          ),
        );
      }
      expect(entries().get(a)!.kind, MemoryKind.fact);
    });

    test('more than 64 tags on one entry afterwards is rejected', () async {
      final a = await remember(
        'many tags',
        tags: [for (var i = 0; i < 60; i++) 'label$i'],
      );
      await expectLater(
        open.entriesUpdate(
          ids: [a],
          addTags: [for (var i = 0; i < 5; i++) 'extra$i'],
        ),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            'entries_update: entry $a would carry 65 tags, exceeding the 64 '
                'tag limit. Nothing was written.',
          ),
        ),
      );
      expect(tagsOf(a), hasLength(60));
    });
  });

  group('tool', () {
    late TestServer srv;
    setUp(() async => srv = await TestServer.open());
    tearDown(() async => srv.close());

    test('closed schema, works over the wire', () async {
      final tool = await srv.tool('entries_update');
      expect(tool.inputSchema.required, ['ids']);
      expect(
        tool.inputSchema.properties!.keys,
        unorderedEquals(['ids', 'kind', 'addTags', 'removeTags', 'dryRun']),
      );
      expect(tool.inputSchema.additionalProperties, isFalse);
      final r = await srv.callOk('remember', {
        'text': 'wire entry',
        'project': 'garden',
      });
      final u = await srv.callOk('entries_update', {
        'ids': [r['id']],
        'kind': 'lesson',
      });
      expect(u['changed'], 1);
      final bad = await srv.call('entries_update', {
        'ids': [r['id']],
        'removeTag': ['x'],
      });
      expect(bad.isError, isTrue);
    });
  });
}
