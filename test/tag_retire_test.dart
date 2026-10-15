/// Tests for retired tags (0.5.0): `tag_retire`, the `_prepareTags` Step 1a
/// check in both registry modes, the guards in tag_define/tag_merge/
/// tag_remove, `tags_list.retiredTags` and `stats.registry.tagRetirements`.
///
/// Synthetic data only: project `garden`; retired tags `status` ("use kind
/// snapshot (and fact_set state on the thread)"), `learning` with the
/// aliases `takeaway`/`lessonLearned` ("use kind lesson") and `rule`
/// ("store as kind decision; the effective rule belongs in CLAUDE.md or a
/// skill"); ordinary tags `housework`, `insight`.
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

const _statusHint = 'use kind snapshot (and fact_set state on the thread)';
const _learningHint = 'use kind lesson';
const _ruleHint =
    'store as kind decision; the effective rule belongs in CLAUDE.md or a '
    'skill';

void main() {
  late Directory tempDir;
  late TestGate testGate;
  late Store store;
  late FakeEmbedder embedder;
  late MemoryService open;
  late MemoryService strict;
  late List<String> logLines;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('remembox_retire_');
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

  Box<TagRetirement> retirements() => store.box<TagRetirement>();

  Map<String, int> counts() => {
    'entries': store.box<MemoryEntry>().count(),
    'tags': store.box<Tag>().count(),
    'links': store.box<MemoryLink>().count(),
    'index': store.box<MemoryIndex>().count(),
    'defs': store.box<TagDefinition>().count(),
    'aliases': store.box<TagAlias>().count(),
    'retirements': retirements().count(),
  };

  /// The standard retirements: `status`, and `learning` (registered, with
  /// the TagAlias `takeaway`) plus the extra name `lessonLearned`.
  Future<void> retireStandard() async {
    await open.tagDefine(
      name: 'learning',
      description: 'Something learned.',
      addAliases: ['takeaway'],
    );
    await open.tagRetire(name: 'status', hint: _statusHint);
    await open.tagRetire(
      name: 'learning',
      hint: _learningHint,
      aliases: ['lessonLearned'],
    );
  }

  Future<String> expectStrictRejection(
    Future<Object?> Function() call, {
    required String tool,
  }) async {
    final before = counts();
    final embeds = embedder.calls.length;
    logLines.clear();
    String? message;
    try {
      await call();
    } on ValidationException catch (e) {
      message = e.message;
    }
    expect(message, isNotNull, reason: 'expected a ValidationException');
    expect(counts(), before, reason: 'a rejection must write nothing');
    expect(embedder.calls.length, embeds);
    expect(
      logLines.where(
        (l) => l.startsWith('[registry] strict: rejected $tool – '),
      ),
      hasLength(1),
      reason: '$logLines',
    );
    return message!;
  }

  group('tag_retire', () {
    test('creates the retirement with the tag\'s aliases and extra names',
        () async {
      await open.tagDefine(
        name: 'learning',
        description: 'Something learned.',
        addAliases: ['takeaway'],
      );
      final r = await open.tagRetire(
        name: 'learning',
        hint: _learningHint,
        aliases: ['Lesson-Learned'],
      );
      expect(r['name'], 'learning');
      expect(r['action'], 'created');
      expect(r['hint'], _learningHint);
      expect(r['aliasesRetired'], ['lessonLearned', 'takeaway']);
      expect(r['inUse'], {'learning': 0, 'lessonLearned': 0, 'takeaway': 0});
      expect(r.containsKey('warning'), isFalse);
      final rows = {
        for (final row in retirements().getAll()) row.name: row.aliasOf,
      };
      expect(rows, {
        'learning': '',
        'lessonLearned': 'learning',
        'takeaway': 'learning',
      });
      // The register itself is untouched.
      expect(store.box<TagDefinition>().count(), 1);
      expect(store.box<TagAlias>().count(), 1);
    });

    test('updates the hint on every row, adds names, is otherwise '
        'unchanged', () async {
      await retireStandard();
      final same = await open.tagRetire(name: 'learning');
      expect(same['action'], 'unchanged');
      final updated = await open.tagRetire(
        name: 'learning',
        hint: 'use kind lesson instead',
        aliases: ['insightNote'],
      );
      expect(updated['action'], 'updated');
      expect(updated['aliasesRetired'], [
        'insightNote',
        'lessonLearned',
        'takeaway',
      ]);
      for (final row in retirements().getAll()) {
        if (row.name == 'status') continue;
        expect(row.hint, 'use kind lesson instead', reason: row.name);
      }
    });

    test('remove: true lifts the retirement with every name retired with '
        'it', () async {
      await retireStandard();
      final r = await open.tagRetire(name: 'learning', remove: true);
      expect(r['action'], 'removed');
      expect(r['aliasesRetired'], ['lessonLearned', 'takeaway']);
      expect(retirements().getAll().map((r) => r.name), ['status']);
      // Writes are no longer affected.
      final w = await strict.remember(
        text: 'learning is usable again',
        project: 'garden',
        tags: ['takeaway'],
      );
      expect(
        store.box<MemoryEntry>().get(w['id'] as int)!.tags.map((t) => t.name),
        ['learning'],
      );
      final again = await open.tagRetire(name: 'learning', remove: true);
      expect(again['action'], 'unchanged');
      expect(again['warning'], '"learning" is not retired – nothing removed.');
    });

    test('a kind, project or area name may be retired', () async {
      final kind = await open.tagRetire(name: 'deadEnd', hint: 'use kind deadEnd');
      expect(kind['action'], 'created');
      final project = await open.tagRetire(name: 'garden', hint: 'use the project');
      expect(project['action'], 'created');
      final rule = await open.tagRetire(name: 'rule', hint: _ruleHint);
      expect(rule['hint'], _ruleHint);
    });

    test('rejects bad input, nothing written', () async {
      await retireStandard();
      final before = counts();
      for (final (call, message) in <(Future<Object?> Function(), String)>[
        (
          () => open.tagRetire(name: 'rule'),
          'tag_retire: "rule" is not retired yet – a hint is required (one '
              'sentence: what to do instead).',
        ),
        (
          () => open.tagRetire(name: 'rule', hint: '  '),
          'tag_retire: hint must not be blank (one sentence: what to do '
              'instead).',
        ),
        (
          () => open.tagRetire(name: 'status', remove: true, hint: 'x'),
          'tag_retire: "remove" lifts the whole retirement – pass it '
              'without "hint" and "aliases".',
        ),
        (
          () => open.tagRetire(name: 'takeaway', hint: 'x'),
          'tag_retire: "takeaway" is retired as an alternative name of '
              '"learning" – change it through tag_retire(name: "learning").',
        ),
        (
          () => open.tagRetire(name: 'rule', hint: 'x', aliases: ['status']),
          'tag_retire: alias(es) rejected for "rule": "status" is retired on '
              'its own. Nothing was written.',
        ),
        (
          () => open.tagRetire(name: 'rule', hint: 'x', aliases: ['takeaway']),
          'tag_retire: alias(es) rejected for "rule": "takeaway" is already '
              'retired with "learning". Nothing was written.',
        ),
        (
          () => open.tagRetire(name: 'bad\u0007name', hint: 'x'),
          'tag_retire: "badname" contains control characters.',
        ),
      ]) {
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
      expect(counts(), before);
    });

    test('inUse counts live entries and the result warns', () async {
      await open.remember(text: 'old status 1', project: 'garden', tags: ['status']);
      final superseded = await open.remember(
        text: 'old status 2',
        project: 'garden',
        tags: ['status'],
      );
      await open.supersede(
        superseded['id'] as int,
        text: 'old status 2, corrected',
      );
      final r = await open.tagRetire(name: 'status', hint: _statusHint);
      // The superseded entry no longer counts; its successor has no tags.
      expect(r['inUse'], {'status': 1});
      expect(
        r['warning'],
        'Live entries still carry the retired tag(s) "status" (1) – '
        'kind_migrate or entries_update (removeTags) moves them; until then '
        'a write naming them is rejected in strict registry mode and warned '
        'about in open mode.',
      );
      expect(
        logLines,
        contains('[memory] tag_retire "status": action=created aliases=0 '
            'inUse=1'),
      );
    });
  });

  group('strict registry mode rejects retired tags', () {
    setUp(retireStandard);

    test('a retired tag directly: exact message, nothing written', () async {
      final message = await expectStrictRejection(
        () => strict.remember(
          text: 'status update',
          project: 'garden',
          tags: ['status'],
        ),
        tool: 'remember',
      );
      expect(
        message,
        'tag(s) retired (strict registry mode): "status" – $_statusHint. '
        'Remove these tags and follow the hint. Nothing was written.',
      );
    });

    test('an alias of a retired tag (TagAlias) and a raw variant of a name '
        'retired with it', () async {
      final message = await expectStrictRejection(
        () => strict.remember(
          text: 'lessons',
          project: 'garden',
          tags: ['status', 'takeaway', 'Lesson-Learned'],
        ),
        tool: 'remember',
      );
      expect(
        message,
        'tag(s) retired (strict registry mode): "status" – $_statusHint; '
        '"takeaway" (alias of the retired tag "learning") – $_learningHint; '
        '"lessonLearned" (alias of the retired tag "learning") – '
        '$_learningHint. Remove these tags and follow the hint. Nothing was '
        'written.',
      );
    });

    test('an alias added after the retirement is caught through the alias '
        'table', () async {
      // A TagAlias row written after tag_retire (e.g. replicated from
      // another device) has no retirement row of its own.
      store.box<TagAlias>().put(TagAlias(name: 'insightNote', tag: 'learning'));
      final message = await expectStrictRejection(
        () => strict.remember(
          text: 'via the alias table',
          project: 'garden',
          tags: ['insightNote'],
        ),
        tool: 'remember',
      );
      expect(
        message,
        contains('"insightNote" (alias of the retired tag "learning") – '
            '$_learningHint'),
      );
    });

    test('retired and unregistered tags in one message', () async {
      final message = await expectStrictRejection(
        () => strict.remember(
          text: 'mixed',
          project: 'garden',
          tags: ['status', 'housework'],
        ),
        tool: 'remember',
      );
      expect(
        message,
        'tag(s) retired (strict registry mode): "status" – $_statusHint. '
        'Remove these tags and follow the hint. tag(s) not registered '
        '(strict registry mode): "housework" (no similar registered tag). '
        'Use a registered tag or drop it. If a tag is genuinely new, '
        'register it first with tag_define (name, description: "<one '
        'sentence: what the tag marks>"), then retry. tags_list shows every '
        'registered tag. Nothing was written.',
      );
    });

    test('without retired tags the unregistered message is unchanged',
        () async {
      final message = await expectStrictRejection(
        () => strict.remember(
          text: 'only unregistered',
          project: 'garden',
          tags: ['housework'],
        ),
        tool: 'remember',
      );
      expect(message, startsWith('tag(s) not registered (strict registry '
          'mode): "housework"'));
    });

    test('supersede is checked too', () async {
      final old = await strict.remember(text: 'v1', project: 'garden');
      final message = await expectStrictRejection(
        () => strict.supersede(
          old['id'] as int,
          text: 'v2',
          tags: ['status'],
        ),
        tool: 'supersede',
      );
      expect(message, contains('"status" – $_statusHint'));
      expect(
        store.box<MemoryEntry>().get(old['id'] as int)!.supersededBy.targetId,
        0,
      );
    });
  });

  group('open registry mode warns', () {
    setUp(retireStandard);

    test('the tag is stored with the exact warning', () async {
      final r = await open.remember(
        text: 'open status',
        project: 'garden',
        tags: ['status'],
      );
      expect(
        store.box<MemoryEntry>().get(r['id'] as int)!.tags.map((t) => t.name),
        ['status'],
      );
      expect(
        r['warning'],
        contains(
          'Tag "status" is retired – $_statusHint. Stored anyway (open '
          'registry mode).',
        ),
      );
    });

    test('an alias of a retired tag warns and resolves as before', () async {
      final r = await open.remember(
        text: 'open takeaway',
        project: 'garden',
        tags: ['takeaway'],
      );
      expect(
        r['warning'],
        contains(
          'Tag "takeaway" (alias of the retired tag "learning") is retired – '
          '$_learningHint. Stored anyway (open registry mode).',
        ),
      );
      expect(
        store.box<MemoryEntry>().get(r['id'] as int)!.tags.map((t) => t.name),
        ['learning'],
      );
    });

  });

  test('open mode: no warning on a store without retirements', () async {
    final r = await open.remember(
      text: 'nothing retired',
      project: 'garden',
      tags: ['status'],
    );
    expect(r.containsKey('warning'), isFalse);
  });

  group('kind names always win over retirements', () {
    test('the 0.4.0 upgrade path: alias lesson -> insight, then tag_retire '
        'insight skips the kind-named alias', () async {
      store.box<TagDefinition>().put(
        TagDefinition(name: 'insight', description: 'Something noticed.'),
      );
      store.box<TagAlias>().put(TagAlias(name: 'lesson', tag: 'insight'));
      store.box<TagAlias>().put(TagAlias(name: 'takeaway', tag: 'insight'));
      logLines.clear();
      final r = await open.tagRetire(name: 'insight', hint: 'use kind lesson');
      expect(r['aliasesRetired'], ['takeaway']);
      expect(r['aliasesSkippedAsKind'], ['lesson']);
      expect(
        r['warning'],
        contains(
          '"lesson" is a memory kind – not retired with "insight" (a tag of '
          'that name is dropped as a kind on every write anyway). To drop '
          'the alias: tag_define(name: "insight", removeAliases: '
          '["lesson"]).',
        ),
      );
      expect(
        logLines,
        contains('[memory] tag_retire: skipped "lesson" for "insight" – it is '
            'a memory kind'),
      );
      expect(
        retirements().getAll().map((r) => r.name),
        unorderedEquals(['insight', 'takeaway']),
      );

      for (final (mode, label) in [
        (RegistryMode.open, 'open'),
        (RegistryMode.strict, 'strict'),
      ]) {
        final service = mode == RegistryMode.open ? open : strict;
        final w = await service.remember(
          text: 'kind-named alias after the retirement, $label',
          project: 'garden',
          tags: ['lesson'],
        );
        expect(
          store.box<MemoryEntry>().get(w['id'] as int)!.tags,
          isEmpty,
          reason: label,
        );
        expect(
          w['warning'],
          'Tag "lesson" dropped: matches a memory kind ("lesson") – kind is '
          'already filterable.',
          reason: label,
        );
      }
      // The retired tag itself and its other alias still are retired.
      await expectLater(
        strict.remember(text: 'x', project: 'garden', tags: ['takeaway']),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            contains('"takeaway" (alias of the retired tag "insight")'),
          ),
        ),
      );
    });

    test('retiring a kind name warns and changes no write – no double '
        'warning, no strict rejection', () async {
      final r = await open.tagRetire(name: 'deadEnd', hint: 'use kind deadEnd');
      expect(r['action'], 'created');
      expect(
        r['warning'],
        contains('"deadEnd" is a memory kind – a tag of that name is dropped '
            'as a kind on every write anyway, so this retirement changes no '
            'write.'),
      );
      for (final (service, label) in [(open, 'open'), (strict, 'strict')]) {
        final w = await service.remember(
          text: 'a dead end, $label',
          project: 'garden',
          tags: ['deadEnd', 'DeadEnd'],
        );
        expect(
          w['warning'],
          isNot(contains('retired')),
          reason: label,
        );
        expect(
          w['warning'],
          contains('Tag "deadEnd" dropped: matches a memory kind ("deadEnd")'),
          reason: label,
        );
      }
    });

    test('a tag equal to the entry\'s own project or area is dropped as '
        'redundant, never rejected as retired; retiring such a root name '
        'warns', () async {
      await open.areaSet(name: 'home');
      await strict.projectSet(name: 'garden', addAreas: ['home']);
      final r = await open.tagRetire(name: 'garden', hint: 'use the project');
      expect(
        r['warning'],
        contains('"garden" repeats the registered project "garden" – on an '
            'entry of that project or area the tag is dropped as redundant '
            'anyway; the retirement applies to entries elsewhere.'),
      );
      final area = await open.tagRetire(name: 'home', hint: 'use the area');
      expect(area['warning'], contains('"home" repeats the area "home"'));
      for (final (service, label) in [(open, 'open'), (strict, 'strict')]) {
        final w = await service.remember(
          text: 'garden entry tagged with its own project, $label',
          project: 'garden',
          tags: ['garden', 'home'],
        );
        expect(
          store.box<MemoryEntry>().get(w['id'] as int)!.tags,
          isEmpty,
          reason: label,
        );
        expect(w['warning'], isNot(contains('retired')), reason: label);
        expect(
          w['warning'],
          allOf(
            contains('Tag "garden" dropped: matches the project name '
                '"garden"'),
            contains('Tag "home" dropped: matches an area this project '
                'belongs to'),
          ),
          reason: label,
        );
      }
      // Elsewhere the retirement applies.
      await strict.projectSet(name: 'family', description: 'Synthetic.');
      await expectLater(
        strict.remember(text: 'x', project: 'family', tags: ['garden']),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            startsWith('tag(s) retired (strict registry mode): "garden" – '
                'use the project.'),
          ),
        ),
      );
    });

    test('a kind name that is both an extra name and an alias gets the '
        'removeAliases hint', () async {
      store.box<TagDefinition>().put(
        TagDefinition(name: 'insight', description: 'Something noticed.'),
      );
      store.box<TagAlias>().put(TagAlias(name: 'lesson', tag: 'insight'));
      final r = await open.tagRetire(
        name: 'insight',
        hint: 'use kind lesson',
        aliases: ['lesson'],
      );
      expect(r['aliasesSkippedAsKind'], ['lesson']);
      expect(
        r['warning'],
        contains('To drop the alias: tag_define(name: "insight", '
            'removeAliases: ["lesson"]).'),
      );
    });

    test('strict suggestions never offer an inert kind-named alias', () async {
      store.box<TagDefinition>().put(
        TagDefinition(name: 'insight', description: 'Something noticed.'),
      );
      store.box<TagAlias>().put(TagAlias(name: 'lesson', tag: 'insight'));
      await expectLater(
        strict.remember(text: 'x', project: 'garden', tags: ['lessons']),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('"lessons" (no similar registered tag). Use a '
                  'registered tag or drop it. If a tag is genuinely new'),
              isNot(contains('(alias "lesson")')),
            ),
          ),
        ),
      );
    });

    test('extra names that repeat a project are retired with a warning; kind '
        'names are skipped', () async {
      final r = await open.tagRetire(
        name: 'rule',
        hint: _ruleHint,
        aliases: ['garden', 'snapshot'],
      );
      expect(r['aliasesRetired'], ['garden']);
      expect(r['aliasesSkippedAsKind'], ['snapshot']);
      expect(
        r['warning'],
        allOf(
          contains('"garden" repeats the registered project "garden" – '
              'retired as a tag name anyway.'),
          contains('"snapshot" is a memory kind – not retired with "rule"'),
        ),
      );
    });
  });

  group('guards (both modes)', () {
    setUp(retireStandard);

    for (final (mode, label) in [
      (RegistryMode.open, 'open'),
      (RegistryMode.strict, 'strict'),
    ]) {
      test('$label: tag_define refuses a retired name', () async {
        final service = mode == RegistryMode.open ? open : strict;
        logLines.clear();
        await expectLater(
          service.tagDefine(name: 'status', description: 'Status reports.'),
          throwsA(
            isA<ValidationException>().having(
              (e) => e.message,
              'message',
              'tag_define: "status" is retired ($_statusHint). Lift the '
                  'retirement first with tag_retire(name: "status", remove: '
                  'true).',
            ),
          ),
        );
        expect(
          logLines.where((l) => l.startsWith('[memory] tag_define: rejected')),
          hasLength(1),
        );
      });
    }

    test('tag_define refuses a name retired with another tag, and a '
        'retired alias', () async {
      await expectLater(
        open.tagDefine(name: 'takeaway', description: 'Takeaways.'),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            'tag_define: "takeaway" is retired with "learning" '
                '($_learningHint). Lift the retirement first with '
                'tag_retire(name: "learning", remove: true).',
          ),
        ),
      );
      await open.tagDefine(name: 'insight', description: 'Insights.');
      await expectLater(
        open.tagDefine(name: 'insight', addAliases: ['status']),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            'tag_define: alias(es) rejected for "insight": "status" is '
                'retired ($_statusHint) – lift the retirement first with '
                'tag_retire(name: "status", remove: true). Nothing was '
                'written.',
          ),
        ),
      );
      expect(store.box<TagAlias>().count(), 1);
    });

    test('tag_define removeAliases alone works on a retired tag (the path '
        'the hints point at); the alias stays retired', () async {
      final r = await open.tagDefine(
        name: 'learning',
        removeAliases: ['takeaway'],
      );
      expect(r['aliasesRemoved'], ['takeaway']);
      expect(store.box<TagAlias>().count(), 0);
      // Retired names stay retired after the alias row is gone.
      await expectLater(
        strict.remember(text: 'x', project: 'garden', tags: ['takeaway']),
        throwsA(isA<ValidationException>()),
      );
      // Anything more than removing aliases is still refused.
      for (final call in <Future<Object?> Function()>[
        () => open.tagDefine(
          name: 'learning',
          description: 'New text.',
          removeAliases: ['takeaway'],
        ),
        () => open.tagDefine(name: 'learning', addAliases: ['insightNote']),
        () => open.tagDefine(name: 'learning', aliases: const []),
      ]) {
        await expectLater(
          call(),
          throwsA(
            isA<ValidationException>().having(
              (e) => e.message,
              'message',
              startsWith('tag_define: "learning" is retired'),
            ),
          ),
        );
      }
    });

    test('the tag_remove alias hint leads to a working call after a '
        'retirement', () async {
      await open.remember(text: 'x', project: 'garden', tags: ['takeaway']);
      final r = await open.tagRemove(tags: ['takeaway']);
      expect(
        r['warning'],
        contains('tag_define(name: "learning", removeAliases: ["takeaway"])'),
      );
      final followed = await open.tagDefine(
        name: 'learning',
        removeAliases: ['takeaway'],
      );
      expect(followed['aliasesRemoved'], ['takeaway']);
    });

    test('tag_merge refuses a retired "into", dry run too', () async {
      await open.remember(text: 'x', project: 'garden', tags: ['insight']);
      for (final dryRun in [true, false]) {
        await expectLater(
          open.tagMerge(from: ['insight'], into: 'status', dryRun: dryRun),
          throwsA(
            isA<ValidationException>().having(
              (e) => e.message,
              'message',
              'tag_merge: "into" – "status" is retired ($_statusHint). '
                  'Merge into another tag, or lift the retirement first with '
                  'tag_retire(name: "status", remove: true). Nothing was '
                  'changed.',
            ),
          ),
        );
      }
      expect(store.box<Tag>().getAll().map((t) => t.name), ['insight']);
    });

    test('tag_remove keeps the retirement and says so', () async {
      await open.remember(text: 'x', project: 'garden', tags: ['status']);
      final r = await open.tagRemove(tags: ['status', 'learning']);
      expect(r['retirementsKept'], ['learning', 'status']);
      expect(
        r['warning'],
        contains('The retirement of "learning", "status" stays – tag_remove '
            'does not lift it; tag_retire(name, remove: true) does.'),
      );
      expect(retirements().count(), 4);
      expect(r['definitionsRemoved'], 1);
    });

    test('tag_remove without a retired name has no retirementsKept',
        () async {
      await open.remember(text: 'x', project: 'garden', tags: ['insight']);
      final r = await open.tagRemove(tags: ['insight']);
      expect(r.containsKey('retirementsKept'), isFalse);
    });
  });

  group('reports', () {
    test('tags_list.retiredTags only when something is retired', () async {
      final none = await open.tagsList();
      expect(none.containsKey('retiredTags'), isFalse);
      await open.remember(text: 'x', project: 'garden', tags: ['status']);
      await retireStandard();
      final r = await open.tagsList();
      expect(r['retiredTags'], [
        {'name': 'learning', 'hint': _learningHint, 'inUse': 0},
        {
          'name': 'lessonLearned',
          'hint': _learningHint,
          'aliasOf': 'learning',
          'inUse': 0,
        },
        {'name': 'status', 'hint': _statusHint, 'inUse': 1},
        {
          'name': 'takeaway',
          'hint': _learningHint,
          'aliasOf': 'learning',
          'inUse': 0,
        },
      ]);
    });

    test('stats.registry.tagRetirements counts every retired name',
        () async {
      expect(((await open.stats())['registry'] as Map)['tagRetirements'], 0);
      await retireStandard();
      expect(((await open.stats())['registry'] as Map)['tagRetirements'], 4);
    });
  });

  group('tool', () {
    late TestServer srv;
    setUp(() async => srv = await TestServer.open());
    tearDown(() async => srv.close());

    test('tag_retire is listed with a closed schema', () async {
      final tool = await srv.tool('tag_retire');
      expect(tool.inputSchema.required, ['name']);
      expect(
        tool.inputSchema.properties!.keys,
        unorderedEquals(['name', 'hint', 'aliases', 'remove']),
      );
      expect(tool.inputSchema.additionalProperties, isFalse);
    });

    test('works over the wire; an unknown key is rejected', () async {
      final r = await srv.callOk('tag_retire', {
        'name': 'status',
        'hint': _statusHint,
      });
      expect(r['action'], 'created');
      final bad = await srv.call('tag_retire', {
        'name': 'rule',
        'hnt': _ruleHint,
      });
      expect(bad.isError, isTrue);
      expect(srv.store.box<TagRetirement>().count(), 1);
    });
  });
}
