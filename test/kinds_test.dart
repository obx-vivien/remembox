/// Tests for the 0.5.0 kinds `snapshot`, `lesson` and `deadEnd`: valid on
/// every write and filter path, tags of the same name dropped in both
/// registry modes, 0.4.0 aliases named like a kind inert, `tags_list`'s
/// `kindCollisions`, `list_recent`'s `kind` filter and the tool texts.
///
/// Synthetic data only: projects `garden`, `acme-app`; tags `insight`,
/// `todo`, `housework`.
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
  late MemoryService open;
  late MemoryService strict;
  late List<String> logLines;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('remembox_kinds_');
    logLines = [];
    testGate = await openTestGate(tempDir.path, log: logLines.add);
    store = testGate.store;
    final embedder = FakeEmbedder();
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

  List<String> tagsOf(Map<String, Object?> result) => store
      .box<MemoryEntry>()
      .get(result['id'] as int)!
      .tags
      .map((t) => t.name)
      .toList();

  test('the three new kinds are valid and appended in order', () {
    expect(MemoryKind.all, [
      'fact',
      'decision',
      'preference',
      'episode',
      'reference',
      'snapshot',
      'lesson',
      'deadEnd',
    ]);
    expect(MemoryKind.meanings.keys, MemoryKind.all);
  });

  test('an unknown kind in the wrong case gets "Did you mean"', () async {
    await expectLater(
      open.remember(text: 'x', project: 'garden', kind: 'deadend'),
      throwsA(
        isA<ValidationException>().having(
          (e) => e.message,
          'message',
          'Unknown kind "deadend". Valid kinds: fact, decision, preference, '
              'episode, reference, snapshot, lesson, deadEnd. Did you mean '
              '"deadEnd"?',
        ),
      ),
    );
    await expectLater(
      open.remember(text: 'x', project: 'garden', kind: 'mistake'),
      throwsA(
        isA<ValidationException>().having(
          (e) => e.message,
          'message',
          isNot(contains('Did you mean')),
        ),
      ),
    );
  });

  for (final (mode, label) in [
    (RegistryMode.open, 'open'),
    (RegistryMode.strict, 'strict'),
  ]) {
    test('$label mode: tags equal to a kind are dropped with the kind '
        'warning, never rejected', () async {
      final service = mode == RegistryMode.open ? open : strict;
      final r = await service.remember(
        text: 'kind-named tags in $label mode',
        project: 'garden',
        kind: MemoryKind.episode,
        tags: ['lesson', 'DeadEnd', 'snapshot'],
      );
      expect(tagsOf(r), isEmpty);
      final warning = r['warning'] as String;
      for (final (tag, kind) in [
        ('lesson', 'lesson'),
        ('deadEnd', 'deadEnd'),
        ('snapshot', 'snapshot'),
      ]) {
        expect(
          warning,
          contains(
            'Tag "$tag" dropped: matches a memory kind ("$kind") – kind is '
            'already filterable.',
          ),
        );
      }
    });
  }

  test('near-kind tags are kept with the near-duplicate warning', () async {
    final r = await open.remember(
      text: 'near-kind tags',
      project: 'garden',
      tags: ['lessons', 'deadEnds', 'snapshots'],
    );
    expect(tagsOf(r), ['lessons', 'deadEnds', 'snapshots']);
    for (final (tag, kind) in [
      ('lessons', 'lesson'),
      ('deadEnds', 'deadEnd'),
      ('snapshots', 'snapshot'),
    ]) {
      expect(
        r['warning'],
        contains(
          'Tag "$tag" looks like a near-duplicate of the kind "$kind" – '
          'kept, but consider the kind filter instead of a tag.',
        ),
      );
    }
  });

  test('tag_define rejects a kind name', () async {
    await expectLater(
      strict.tagDefine(name: 'deadEnd', description: 'Dropped approaches.'),
      throwsA(
        isA<ValidationException>().having(
          (e) => e.message,
          'message',
          contains('matches the memory kind "deadEnd"'),
        ),
      ),
    );
  });

  group('a 0.4.0 alias named like a new kind is inert', () {
    setUp(() {
      // What a 0.4.0 store may hold: `lesson` registered as an alias of
      // `insight` before `lesson` became a kind.
      store.box<TagDefinition>().put(
        TagDefinition(name: 'insight', description: 'Something learned.'),
      );
      store.box<TagAlias>().put(TagAlias(name: 'lesson', tag: 'insight'));
    });

    for (final (mode, label) in [
      (RegistryMode.open, 'open'),
      (RegistryMode.strict, 'strict'),
    ]) {
      test('$label mode: remember drops it as a kind instead of storing '
          '"insight"', () async {
        final service = mode == RegistryMode.open ? open : strict;
        logLines.clear();
        final r = await service.remember(
          text: 'alias named like a kind, $label',
          project: 'garden',
          tags: ['lesson'],
        );
        expect(tagsOf(r), isEmpty);
        expect(
          r['warning'],
          contains('Tag "lesson" dropped: matches a memory kind ("lesson")'),
        );
        expect(r['warning'], isNot(contains('is an alias of')));
        expect(
          logLines,
          contains(
            '[memory] tag alias not resolved: "lesson" is a memory kind '
            '(aliases named like a kind are inert since 0.5.0)',
          ),
        );
      });
    }

    test('tag_merge into the kind name does not resolve the alias', () async {
      await open.remember(
        text: 'carries lessonLearned',
        project: 'garden',
        tags: ['lessonLearned'],
      );
      logLines.clear();
      final r = await open.tagMerge(
        from: ['lessonLearned'],
        into: 'lesson',
        dryRun: true,
      );
      expect(r['into'], 'lesson');
      expect(
        logLines,
        contains(
          '[memory] tag_merge: target "lesson" is a memory kind – its alias '
          'of "insight" is inert since 0.5.0, not resolved',
        ),
      );
    });
  });

  group('tags_list kindCollisions', () {
    test('absent while no name equals a kind', () async {
      await open.remember(text: 'a', project: 'garden', tags: ['todo']);
      final r = await open.tagsList();
      expect(r.containsKey('kindCollisions'), isFalse);
      expect(r.containsKey('warning'), isFalse);
    });

    test('lists tag rows, registered tags and aliases named like a kind, '
        'with the migration warning', () async {
      // 0.4.0-era data, written below the tag rules: an entry tagged
      // deadEnd, a registered tag "lesson" and an alias "snapshot".
      final entries = store.box<MemoryEntry>();
      final entry = MemoryEntry(
        title: 'old episode',
        text: 'a dropped approach from before 0.5.0',
        kind: MemoryKind.episode,
        sourceType: MemorySource.note,
        project: 'garden',
        contentHash: 'kinds-test-old-episode',
      )..tags.add(Tag(name: 'deadEnd'));
      entries.put(entry);
      store.box<TagDefinition>()
        ..put(TagDefinition(name: 'lesson', description: 'Learned.'))
        ..put(TagDefinition(name: 'housework', description: 'Chores.'));
      store.box<TagAlias>().put(TagAlias(name: 'snapshot', tag: 'housework'));

      logLines.clear();
      final r = await open.tagsList();
      expect(r['kindCollisions'], [
        {'name': 'deadEnd', 'as': 'tag', 'kind': 'deadEnd', 'count': 1},
        {'name': 'lesson', 'as': 'registeredTag', 'kind': 'lesson', 'count': 0},
        {'name': 'snapshot', 'as': 'alias', 'kind': 'snapshot', 'count': 0},
      ]);
      expect(
        r['warning'],
        'Tag names equal to a memory kind are dropped on write since 0.5.0 – '
        'migrate entries with kind_migrate/entries_update, then tag_remove '
        'the tag or removeAliases the alias.',
      );
      expect(r['warning'], kindCollisionWarning);
      expect(
        logLines.where((l) => l.startsWith('[memory] tags_list: 3 tag name')),
        hasLength(1),
      );
    });
  });

  group('the new kinds on remember, recall and list_recent', () {
    test('remember/recall/list_recent accept and filter by them', () async {
      final ids = <String, int>{};
      for (final kind in [
        MemoryKind.snapshot,
        MemoryKind.lesson,
        MemoryKind.deadEnd,
        MemoryKind.fact,
      ]) {
        final r = await strict.remember(
          text: 'garden note of kind $kind',
          project: 'garden',
          kind: kind,
        );
        ids[kind] = r['id'] as int;
      }
      final recalled = await open.recall(
        query: 'garden note',
        k: 10,
        kind: MemoryKind.deadEnd,
      );
      expect(
        (recalled['hits'] as List).map((h) => (h as Map)['id']),
        [ids[MemoryKind.deadEnd]],
      );
      for (final kind in [
        MemoryKind.snapshot,
        MemoryKind.lesson,
        MemoryKind.deadEnd,
      ]) {
        final listed = await open.listRecent(kind: kind);
        expect(listed['count'], 1);
        final row = (listed['entries'] as List).single as Map;
        expect(row['id'], ids[kind]);
        expect(row['kind'], kind);
      }
      final all = await open.listRecent();
      expect(all['count'], 4);

      final stats = await open.stats();
      final byKind = stats['byKind'] as Map<String, Object?>;
      expect(byKind.keys, MemoryKind.all);
      expect(byKind['deadEnd'], 1);
      expect(byKind['snapshot'], 1);
      expect(byKind['lesson'], 1);
    });

    test('list_recent combines kind with project and limit, newest first',
        () async {
      await open.remember(
        text: 'acme dead end',
        project: 'acme-app',
        kind: MemoryKind.deadEnd,
      );
      final older = await open.remember(
        text: 'first garden dead end',
        project: 'garden',
        kind: MemoryKind.deadEnd,
      );
      final newer = await open.remember(
        text: 'second garden dead end',
        project: 'garden',
        kind: MemoryKind.deadEnd,
      );
      await open.remember(text: 'garden fact', project: 'garden');
      final r = await open.listRecent(
        project: 'garden',
        kind: MemoryKind.deadEnd,
        n: 5,
      );
      expect(
        (r['entries'] as List).map((e) => (e as Map)['id']).toSet(),
        {older['id'], newer['id']},
      );
      final limited = await open.listRecent(kind: MemoryKind.deadEnd, n: 1);
      expect(limited['count'], 1);
    });

    test('list_recent rejects an invalid kind', () async {
      await expectLater(
        open.listRecent(kind: 'Lesson'),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            endsWith('Did you mean "lesson"?'),
          ),
        ),
      );
    });
  });

  group('tool texts', () {
    late TestServer srv;
    setUp(() async => srv = await TestServer.open());
    tearDown(() async => srv.close());

    test('remember.kind lists all eight kinds with their meaning', () async {
      final tool = await srv.tool('remember');
      final props = tool.inputSchema.properties!;
      final kindText = (props['kind']! as Map)['description'] as String;
      for (final kind in MemoryKind.all) {
        expect(kindText, contains('$kind (${MemoryKind.meanings[kind]})'));
      }
      final tagsText = (props['tags']! as Map)['description'] as String;
      expect(tagsText, isNot(contains('status')));
      expect(tagsText, isNot(contains('lesson')));
    });

    test('list_recent takes a kind filter over the wire', () async {
      final tool = await srv.tool('list_recent');
      expect(tool.inputSchema.properties!.keys, contains('kind'));
      await srv.callOk('remember', {
        'text': 'a lesson over the wire',
        'project': 'garden',
        'kind': 'lesson',
      });
      await srv.callOk('remember', {
        'text': 'a fact over the wire',
        'project': 'garden',
      });
      final r = await srv.callOk('list_recent', {'kind': 'lesson'});
      expect(r['count'], 1);
      final bad = await srv.callInvalid('list_recent', {'kind': 'Lesson'});
      expect(bad['message'], contains('Did you mean "lesson"?'));
    });

    test('the server instructions point at kinds, not marker tags', () {
      expect(srv.instructions, contains('list_recent with kind'));
      expect(srv.instructions, contains('with its kind, not a tag'));
    });
  });
}
