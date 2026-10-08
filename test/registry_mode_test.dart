/// Tests for the strict registry mode (`OBX_MEMORY_REGISTRY_MODE=strict`):
/// project and tag checks on every write path, `tag_define`, the registry
/// fields on `tags_list`/`areas_list`/`stats`, keeping definitions
/// consistent through `tag_merge`/`tag_remove`/`tags_normalize` – and the
/// open-mode pin (open mode must behave exactly as before).
///
/// Synthetic data only: projects `acme-app`, `garden`, `family`; areas
/// `work`, `home`; tags `lesson`, `status`, `alice`, `appsScript`.
library;

import 'dart:io';

import 'package:remembox/objectbox.g.dart';
import 'package:remembox/src/memory_service.dart';
import 'package:remembox/src/model.dart';
import 'package:remembox/src/store.dart' show RegistryMode;
import 'package:test/test.dart';

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

  void logCapture(String line) => logLines.add(line);

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('remembox_registry_mode_');
    logLines = [];
    testGate = await openTestGate(tempDir.path, log: logCapture);
    store = testGate.store;
    embedder = FakeEmbedder();
    open = MemoryService(
      gate: testGate.gate,
      embedder: embedder,
      log: logCapture,
    );
    strict = MemoryService(
      gate: testGate.gate,
      embedder: embedder,
      log: logCapture,
      registryMode: RegistryMode.strict,
    );
  });

  tearDown(() async {
    await open.dispose();
    await strict.dispose();
    await testGate.close();
    tempDir.deleteSync(recursive: true);
  });

  Box<TagDefinition> defs() => store.box<TagDefinition>();
  Box<MemoryEntry> entries() => store.box<MemoryEntry>();
  Box<ProjectScope> projects() => store.box<ProjectScope>();
  Box<Fact> facts() => store.box<Fact>();
  Box<Tag> tags() => store.box<Tag>();

  /// Box counts that every strict rejection must leave unchanged.
  Map<String, int> counts() => {
    'entries': entries().count(),
    'projects': projects().count(),
    'facts': facts().count(),
    'tags': tags().count(),
    'defs': defs().count(),
    'index': store.box<MemoryIndex>().count(),
    'docs': store.box<SourceDocument>().count(),
    'links': store.box<MemoryLink>().count(),
    'areas': store.box<Area>().count(),
    'memberships': store.box<AreaMembership>().count(),
  };

  /// Runs [call], expects a strict-mode [ValidationException] whose
  /// message contains every string in [contains], and checks that nothing
  /// was written, nothing was embedded and one `[registry] strict:
  /// rejected <tool>` line was logged. Returns the message.
  Future<String> expectStrictRejection(
    Future<Object?> Function() call, {
    required String tool,
    List<String> messageContains = const [],
  }) async {
    final before = counts();
    final embedsBefore = embedder.calls.length;
    logLines.clear();
    String? message;
    try {
      await call();
    } on ValidationException catch (e) {
      message = e.message;
    }
    expect(message, isNotNull, reason: 'expected a ValidationException');
    for (final c in messageContains) {
      expect(message, contains(c));
    }
    expect(counts(), before, reason: 'a rejection must write nothing');
    expect(
      embedder.calls.length,
      embedsBefore,
      reason: 'a rejection must not embed',
    );
    expect(
      logLines.where(
        (l) => l.startsWith('[registry] strict: rejected $tool – '),
      ),
      hasLength(1),
      reason: 'logs: $logLines',
    );
    return message!;
  }

  Future<void> register(String project) => strict.projectSet(
    name: project,
    description: 'Synthetic test project $project.',
  );

  group('stats.registry', () {
    test('reports the mode and the TagDefinition count', () async {
      final openStats = await open.stats();
      final openRegistry = openStats['registry'] as Map<String, Object?>;
      expect(openRegistry['mode'], 'open');
      expect(openRegistry['tagDefinitions'], 0);

      defs().put(TagDefinition(name: 'lesson', description: 'Learned.'));
      final strictStats = await strict.stats();
      final strictRegistry = strictStats['registry'] as Map<String, Object?>;
      expect(strictRegistry['mode'], 'strict');
      expect(strictRegistry['tagDefinitions'], 1);
      expect(strictRegistry['tagAliases'], 0);
      store.box<TagAlias>().put(TagAlias(name: 'chores', tag: 'housework'));
      final withAlias = await strict.stats();
      expect((withAlias['registry'] as Map)['tagAliases'], 1);
    });
  });

  group('strict projects', () {
    test('remember under an unregistered project is rejected, with no '
        'similar spelling', () async {
      final message = await expectStrictRejection(
        () => strict.remember(text: 'probe one', project: 'acme-app'),
        tool: 'remember',
        messageContains: [
          'project "acme-app" is not registered (strict registry mode).',
          'No registered project has a similar spelling – call areas_list',
          'register it first with project_set (name: "acme-app", '
              'description: "<one sentence: what this project is about>"), '
              'then retry.',
          'Nothing was written.',
        ],
      );
      expect(message, isNot(contains('already used')));
    });

    test('a registered project is accepted', () async {
      await register('acme-app');
      final r = await strict.remember(text: 'ok', project: 'acme-app');
      expect(r['duplicate'], isFalse);
      expect(entries().count(), 1);
    });

    test('a spelling or case variant is rejected and the registered name '
        'is suggested (ScopeKey)', () async {
      await register('acme-app');
      await expectStrictRejection(
        () => strict.remember(text: 'probe', project: 'acme_app'),
        tool: 'remember',
        messageContains: [
          'project "acme_app" is not registered',
          'Registered projects with a similar spelling: "acme-app". Use '
              '"acme-app".',
          'description: "<one sentence: what this project is about>", '
              'allowSimilar: true – needed because of the similar names '
              'above), then retry.',
        ],
      );
      await expectStrictRejection(
        () => strict.remember(text: 'probe', project: 'Acme-App'),
        tool: 'remember',
        messageContains: [
          'Registered projects with a similar spelling: "acme-app"',
        ],
      );
    });

    test('an archived project is accepted', () async {
      await register('garden');
      await strict.projectSet(name: 'garden', status: ProjectStatus.archived);
      final r = await strict.remember(
        text: 'still writable',
        project: 'garden',
      );
      expect(r['duplicate'], isFalse);
      final f = await strict.factSet(
        subject: 'Bed 1',
        attribute: 'crop',
        project: 'garden',
        valueText: 'beans',
      );
      expect(f['action'], 'created');
    });

    test('a merged project is rejected naming the target; a suggestion '
        'annotates merged rows', () async {
      await register('garden');
      await register('garden-old');
      await strict.remember(text: 'old bed notes', project: 'garden-old');
      await strict.projectMerge(from: 'garden-old', into: 'garden');
      await expectStrictRejection(
        () => strict.remember(text: 'probe', project: 'garden-old'),
        tool: 'remember',
        messageContains: [
          'project "garden-old" was merged into "garden" (project_merge) '
              'and no longer accepts writes in strict registry mode. Use '
              '"garden" instead. Nothing was written.',
        ],
      );
      // "garden_old" is unregistered; its ScopeKey matches the tombstone.
      await expectStrictRejection(
        () => strict.remember(text: 'probe', project: 'garden_old'),
        tool: 'remember',
        messageContains: ['"garden-old" (merged into "garden")'],
      );
    });

    test('a project already used by entries/facts but without a registry '
        'row is rejected pointing at project_set/project_merge (reindex '
        'only as the bulk migration step), and accepted after reindex',
        () async {
      await open.remember(text: 'legacy one', project: 'family');
      await open.factSet(
        subject: 'Car',
        attribute: 'colour',
        project: 'family',
        valueText: 'blue',
      );
      // Simulate a store from before the registry existed.
      projects().removeAll();
      await expectStrictRejection(
        () => strict.remember(text: 'probe', project: 'family'),
        tool: 'remember',
        messageContains: [
          'It is already used by 1 entry / 1 fact but has no registry row: '
              'if it is the right name, register it with project_set as '
              'above; if it is a variant of an existing project, move its '
              'data there with project_merge (from: "family", into: '
              '"<an existing project>"). (reindex registers every name '
              'already in use at once – it is the one-time migration step '
              'before switching to strict mode.)',
        ],
      );
      await strict.reindex();
      final r = await strict.remember(
        text: 'after reindex',
        project: 'family',
      );
      expect(r['duplicate'], isFalse);
    });

    test('the duplicate path is rejected too (no duplicate:true answer for '
        'an unregistered project)', () async {
      await register('garden');
      await strict.remember(text: 'same text', project: 'garden');
      await expectStrictRejection(
        () => strict.remember(text: 'same text', project: 'acme-app'),
        tool: 'remember',
        messageContains: ['project "acme-app" is not registered'],
      );
    });

    test('a bad link target is reported before the registry check (same '
        'order as before, nothing written)', () async {
      // A bad link target is reported before the registry check, the same
      // in both modes (nothing is written either way).
      final before = counts();
      logLines.clear();
      await expectLater(
        strict.remember(
          text: 'probe',
          project: 'acme-app',
          links: [LinkSpec(toId: 999, type: LinkType.related)],
        ),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            contains('Link target with id 999 does not exist'),
          ),
        ),
      );
      expect(counts(), before);
      expect(embedder.calls, isEmpty);
      expect(logLines.where((l) => l.startsWith('[registry]')), isEmpty);
    });

    test('supersede with an explicit unregistered project is rejected and '
        'the old entry stays current', () async {
      await register('garden');
      final old = await strict.remember(text: 'v1', project: 'garden');
      final oldId = old['id'] as int;
      await expectStrictRejection(
        () => strict.supersede(oldId, text: 'v2', project: 'acme-app'),
        tool: 'supersede',
        messageContains: ['project "acme-app" is not registered'],
      );
      expect(entries().get(oldId)!.supersededBy.targetId, 0);
    });

    test('supersede inheriting a merged project says it was inherited and '
        'names the project to pass', () async {
      await register('garden');
      await register('garden-old');
      await strict.projectMerge(from: 'garden-old', into: 'garden');
      // Written after the merge under the tombstone name (open mode only
      // warns) – the case strict mode must catch on supersede.
      final old = await open.remember(text: 'late note', project: 'garden-old');
      final oldId = old['id'] as int;
      await expectStrictRejection(
        () => strict.supersede(oldId, text: 'late note v2'),
        tool: 'supersede',
        messageContains: [
          'project "garden-old" (inherited from entry $oldId because '
              'supersede was called without project – pass project: '
              '"garden") was merged into "garden"',
        ],
      );
      expect(entries().get(oldId)!.supersededBy.targetId, 0);
    });

    test('supersede inheriting a registered project is accepted', () async {
      await register('garden');
      final old = await strict.remember(text: 'v1', project: 'garden');
      final r = await strict.supersede(old['id'] as int, text: 'v2');
      expect(r['newId'], isNot(old['id']));
    });

    test('fact_set under an unregistered project is rejected; registered '
        'is accepted', () async {
      await expectStrictRejection(
        () => strict.factSet(
          subject: 'Car',
          attribute: 'colour',
          project: 'family',
          valueText: 'blue',
        ),
        tool: 'fact_set',
        messageContains: ['project "family" is not registered'],
      );
      await register('family');
      final r = await strict.factSet(
        subject: 'Car',
        attribute: 'colour',
        project: 'family',
        valueText: 'blue',
      );
      expect(r['action'], 'created');
    });

    test('entries_move into an unregistered project is rejected, for a dry '
        'run too; registered is accepted', () async {
      await register('garden');
      final e = await strict.remember(text: 'move me', project: 'garden');
      final id = e['id'] as int;
      for (final dryRun in [true, false]) {
        await expectStrictRejection(
          () => strict.entriesMove(
            ids: [id],
            toProject: 'acme-app',
            dryRun: dryRun,
          ),
          tool: 'entries_move',
          messageContains: ['project "acme-app" is not registered'],
        );
      }
      expect(entries().get(id)!.project, 'garden');
      await register('acme-app');
      final moved = await strict.entriesMove(ids: [id], toProject: 'acme-app');
      expect(moved['moved'], 1);
    });

    test('project_merge into an unregistered project is rejected (dry run '
        'too) and nothing changes; into a registered one works', () async {
      await register('garden');
      await strict.remember(text: 'bed notes', project: 'garden');
      for (final dryRun in [true, false]) {
        await expectStrictRejection(
          () => strict.projectMerge(
            from: 'garden',
            into: 'family',
            dryRun: dryRun,
          ),
          tool: 'project_merge',
          messageContains: [
            'project_merge: "into" ("family") is not registered (strict '
                'registry mode) – register it first with project_set (with '
                'a description), then retry. Nothing was changed.',
          ],
        );
      }
      expect(entries().getAll().single.project, 'garden');
      await register('family');
      final r = await strict.projectMerge(from: 'garden', into: 'family');
      expect(r['entriesMoved'], 1);
    });

    group('project_set', () {
      test('creating without a description is rejected (missing or blank)',
          () async {
        for (final description in [null, '   ']) {
          await expectStrictRejection(
            () => strict.projectSet(name: 'garden', description: description),
            tool: 'project_set',
            messageContains: [
              'project_set: "garden" is not registered yet – in strict '
                  'registry mode a new project needs a description (one '
                  'sentence: what this project is about).',
            ],
          );
        }
      });

      test('creating with a description registers and logs it; updating '
          'needs no description', () async {
        logLines.clear();
        final r = await strict.projectSet(
          name: 'garden',
          description: 'Vegetable beds.',
        );
        expect(r['action'], 'created');
        expect(projects().getAll().single.description, 'Vegetable beds.');
        expect(
          logLines.any(
            (l) => l.startsWith('[memory] registered project "garden"'),
          ),
          isTrue,
        );
        final u = await strict.projectSet(
          name: 'garden',
          status: ProjectStatus.archived,
        );
        expect(u['action'], 'updated');
      });

      test('creating a ScopeKey variant is rejected; allowSimilar: true '
          'registers it', () async {
        await register('acme-app');
        await expectStrictRejection(
          () => strict.projectSet(
            name: 'Acme_App',
            description: 'Something else.',
          ),
          tool: 'project_set',
          messageContains: [
            'project_set: "Acme_App" looks like a variant of the registered '
                'project "acme-app". Use "acme-app", or pass allowSimilar: '
                'true if "Acme_App" is genuinely a different project.',
          ],
        );
        final r = await strict.projectSet(
          name: 'Acme_App',
          description: 'Something else.',
          allowSimilar: true,
        );
        expect(r['action'], 'created');
      });

      test('the missing-description message names similar projects',
          () async {
        await register('acme-app');
        await expectStrictRejection(
          () => strict.projectSet(name: 'acme_app'),
          tool: 'project_set',
          messageContains: [
            'Registered projects with a similar spelling: "acme-app".',
          ],
        );
      });

      test('updating a merged tombstone is allowed without a description',
          () async {
        await register('garden');
        await register('garden-old');
        await strict.projectMerge(from: 'garden-old', into: 'garden');
        final r = await strict.projectSet(
          name: 'garden-old',
          description: 'Old name, kept as history.',
        );
        expect(r['action'], 'updated');
        expect(r['status'], ProjectStatus.merged);
      });
    });
  });

  Future<void> define(String tag) =>
      strict.tagDefine(name: tag, description: 'Synthetic tag $tag.');

  List<String> tagsOf(Map<String, Object?> rememberResult) {
    final entry = entries().get(rememberResult['id'] as int)!;
    return entry.tags.map((t) => t.name).toList()..sort();
  }

  group('strict tags', () {
    setUp(() => register('garden'));

    test('an unregistered tag is rejected with a suggestion; nothing is '
        'written', () async {
      await define('lesson');
      await expectStrictRejection(
        () => strict.remember(
          text: 'probe',
          project: 'garden',
          tags: ['lessons'],
        ),
        tool: 'remember',
        messageContains: [
          // "lessons" is a spelling variant of "lesson", so tag_define
          // would refuse it without allowSimilar – no plain "register it"
          // advice.
          'tag(s) not registered (strict registry mode): "lessons" '
              '(similar registered tag: "lesson"; tag_define accepts it only '
              'with allowSimilar: true). Use a registered tag or drop it. '
              'tags_list shows every registered tag. Nothing was written.',
        ],
      );
    });

    test('every unregistered tag is listed, with its raw spelling when it '
        'was normalized', () async {
      await define('lesson');
      await expectStrictRejection(
        () => strict.remember(
          text: 'probe',
          project: 'garden',
          tags: ['lesson', 'lessons', 'garden-tools'],
        ),
        tool: 'remember',
        messageContains: [
          '"lessons" (similar registered tag: "lesson"; tag_define accepts '
              'it only with allowSimilar: true), "gardenTools" (from '
              '"garden-tools"; no similar registered tag). Use a registered '
              'tag or drop it. If a tag is genuinely new, register it first '
              'with tag_define',
        ],
      );
    });

    test('registered tags are accepted, matched on the normalized name',
        () async {
      await define('lesson');
      await strict.tagDefine(
        name: 'apps-script',
        description: 'Automation scripts.',
      );
      final r = await strict.remember(
        text: 'tagged',
        project: 'garden',
        tags: ['Lesson', 'apps-script'],
      );
      expect(tagsOf(r), ['appsScript', 'lesson']);
    });

    test('blank, control-character and redundant tags are dropped with a '
        'warning, not rejected', () async {
      final r = await strict.remember(
        text: 'only droppable tags',
        project: 'garden',
        tags: ['---', 'bad\u0007tag', 'garden', 'decision'],
      );
      expect(tagsOf(r), isEmpty);
      final warning = r['warning'] as String;
      expect(warning, contains('dropped: empty after normalization'));
      expect(warning, contains('dropped: contains control characters'));
      expect(warning, contains('matches the project name'));
      expect(warning, contains('matches a memory kind'));
    });

    test('an empty tag list stores the entry without tags', () async {
      final r = await strict.remember(text: 'no tags', project: 'garden');
      expect(tagsOf(r), isEmpty);
    });

    test('the project error wins when project and tag are both invalid',
        () async {
      final message = await expectStrictRejection(
        () => strict.remember(
          text: 'probe',
          project: 'acme-app',
          tags: ['nope'],
        ),
        tool: 'remember',
        messageContains: ['project "acme-app" is not registered'],
      );
      expect(message, isNot(contains('tag(s) not registered')));
    });

    test('supersede checks tags too and logs as supersede', () async {
      final old = await strict.remember(text: 'v1', project: 'garden');
      await expectStrictRejection(
        () => strict.supersede(old['id'] as int, text: 'v2', tags: ['nope']),
        tool: 'supersede',
        messageContains: ['"nope" (no similar registered tag)'],
      );
      expect(entries().get(old['id'] as int)!.supersededBy.targetId, 0);
    });

    test('suggestions are deterministic: same loose key first, then '
        'containment, at most three', () async {
      for (final t in [
        'lessonsLearned',
        'lessonPlan',
        'lessonsTaught',
        'les',
        'lesson',
      ]) {
        await strict.tagDefine(
          name: t,
          description: 'Synthetic tag $t.',
          allowSimilar: true,
        );
      }
      // "lesson" shares the loose key; "les" (length difference 4),
      // "lessonsTaught" (6) and "lessonsLearned" (7) contain or are
      // contained in "lessons"; "lessonPlan" is neither. Capped at three.
      await expectStrictRejection(
        () => strict.remember(text: 'p', project: 'garden', tags: ['lessons']),
        tool: 'remember',
        messageContains: [
          '"lessons" (similar registered tags: "lesson", "les", '
              '"lessonsTaught"; tag_define accepts it only with allowSimilar: '
              'true)',
        ],
      );
    });
  });

  group('tag_define', () {
    test('normalizes and creates, logging the registration', () async {
      logLines.clear();
      final r = await open.tagDefine(
        name: 'Apps Script',
        description: 'Automation scripts.',
      );
      expect(r['name'], 'appsScript');
      expect(r['action'], 'created');
      expect(r['description'], 'Automation scripts.');
      expect(r['normalizedFrom'], 'Apps Script');
      expect(defs().getAll().single.name, 'appsScript');
      expect(
        logLines,
        contains(
          startsWith('[memory] tag_define: registered tag "appsScript"'),
        ),
      );
    });

    test('a missing, blank or too long description is rejected', () async {
      for (final description in [null, '  ']) {
        await expectLater(
          strict.tagDefine(name: 'lesson', description: description),
          throwsA(isA<ValidationException>()),
        );
      }
      await expectLater(
        strict.tagDefine(name: 'lesson', description: 'x' * 1025),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            contains('description is too long'),
          ),
        ),
      );
      expect(defs().count(), 0);
    });

    test('the missing-description message says what is needed', () async {
      await expectLater(
        strict.tagDefine(name: 'lesson'),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            'tag_define: "lesson" is not registered yet – a description is '
                'required to register a new tag (one sentence: what the tag '
                'marks).',
          ),
        ),
      );
    });

    test('an existing definition is updated or left unchanged', () async {
      await define('lesson');
      final same = await strict.tagDefine(name: 'lesson');
      expect(same['action'], 'unchanged');
      final again = await strict.tagDefine(
        name: 'lesson',
        description: 'Synthetic tag lesson.',
      );
      expect(again['action'], 'unchanged');
      final updated = await strict.tagDefine(
        name: 'lesson',
        description: 'What we learned the hard way.',
      );
      expect(updated['action'], 'updated');
      expect(
        defs().getAll().single.description,
        'What we learned the hard way.',
      );
    });

    test('a loose-key variant of a definition is rejected unless '
        'allowSimilar', () async {
      await define('lesson');
      await expectLater(
        strict.tagDefine(name: 'lessons', description: 'Plural.'),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            'tag_define: "lessons" looks like a variant of the registered tag '
                '"lesson" (same word apart from case, plural or separators). '
                'Use "lesson", or pass allowSimilar: true if "lessons" is '
                'genuinely a different label.',
          ),
        ),
      );
      final r = await strict.tagDefine(
        name: 'lessons',
        description: 'Plural.',
        allowSimilar: true,
      );
      expect(r['action'], 'created');
    });

    test('an exact project, area or kind is rejected; a near kind warns',
        () async {
      await register('acme-app');
      await strict.areaSet(name: 'work');
      final expectations = {
        'acmeApp': 'tag_define: "acmeApp" matches the registered project '
            '"acme-app" – projects, kinds and areas are already filterable, '
            'so a tag must not repeat one.',
        'Work': 'tag_define: "work" matches the area "work" –',
        'decision': 'tag_define: "decision" matches the memory kind '
            '"decision" –',
      };
      for (final entry in expectations.entries) {
        await expectLater(
          strict.tagDefine(name: entry.key, description: 'Redundant.'),
          throwsA(
            isA<ValidationException>().having(
              (e) => e.message,
              'message',
              startsWith(entry.value),
            ),
          ),
        );
      }
      final near = await strict.tagDefine(
        name: 'episodes',
        description: 'Plural of a kind.',
      );
      expect(near['action'], 'created');
      expect(
        near['warning'],
        contains('"episodes" looks like a near-duplicate of the kind '
            '"episode"'),
      );
      expect(defs().count(), 1);
    });

    test('control characters or an empty name are rejected', () async {
      for (final name in ['bad\u0007tag', '---']) {
        await expectLater(
          strict.tagDefine(name: name, description: 'Nope.'),
          throwsA(isA<ValidationException>()),
        );
      }
      expect(defs().count(), 0);
    });

    test('an identifier-like name warns; unregistered spelling variants in '
        'use suggest tag_merge', () async {
      await open.remember(text: 'legacy', project: 'garden', tags: ['Lesson']);
      final r = await strict.tagDefine(name: 't42', description: 'Ticket.');
      expect(r['warning'], contains('looks like an identifier or version'));
      final l = await strict.tagDefine(
        name: 'lessons',
        description: 'What we learned.',
      );
      // "Lesson" was stored as "lesson" by remember's normalization.
      expect(
        l['warning'],
        contains(
          'Existing unregistered tag "lesson" looks like a spelling variant '
          'of "lessons" – consider tag_merge (from: ["lesson"], into: '
          '"lessons").',
        ),
      );
    });

    test('registering a tag already in use works in open mode', () async {
      await open.remember(text: 'used', project: 'garden', tags: ['status']);
      final r = await open.tagDefine(
        name: 'status',
        description: 'A status update.',
      );
      expect(r['action'], 'created');
      expect(r.containsKey('warning'), isFalse);
    });
  });

  group('tags_list and areas_list', () {
    test('tags_list marks registered tags, lists unused definitions and '
        'counts unregistered tags in use', () async {
      await register('garden');
      await open.remember(text: 'a', project: 'garden', tags: ['status']);
      await open.remember(text: 'b', project: 'garden', tags: ['alice']);
      await define('status');
      await define('lesson'); // registered, never used
      final r = await strict.tagsList();
      final rows = (r['tags'] as List).cast<Map<String, Object?>>();
      expect(rows, [
        {
          'name': 'status',
          'count': 1,
          'registered': true,
          'description': 'Synthetic tag status.',
          // Registered rows list their aliases (none here).
          'aliases': <String>[],
        },
        {'name': 'alice', 'count': 1, 'registered': false, 'description': null},
        {
          'name': 'lesson',
          'count': 0,
          'registered': true,
          'description': 'Synthetic tag lesson.',
          'aliases': <String>[],
        },
      ]);
      expect(r['registryMode'], 'strict');
      expect(r['registered'], 2);
      expect(r['unregisteredInUse'], 1);
      expect(r['unused'], 1);
      expect(r['total'], 3);
    });

    test('open-mode pin: with nothing registered every row is '
        'registered:false and the order is count desc, then name', () async {
      await open.remember(text: 'a', project: 'garden', tags: ['bob']);
      await open.remember(text: 'b', project: 'garden', tags: ['alice']);
      await open.remember(text: 'c', project: 'garden', tags: ['bob']);
      final r = await open.tagsList();
      final rows = (r['tags'] as List).cast<Map<String, Object?>>();
      expect(rows.map((t) => t['name']), ['bob', 'alice']);
      expect(rows.every((t) => t['registered'] == false), isTrue);
      expect(r['registryMode'], 'open');
      expect(r['registered'], 0);
      expect(r['unregisteredInUse'], 2);
    });

    test('a definition-only name joins variantGroups', () async {
      await open.remember(text: 'a', project: 'garden', tags: ['lessons']);
      await define('lesson');
      final r = await open.tagsList();
      final groups = (r['variantGroups'] as List).cast<Map<String, Object?>>();
      final names = (groups.single['tags'] as List)
          .cast<Map<String, Object?>>()
          .map((t) => t['name']);
      expect(names, unorderedEquals(['lesson', 'lessons']));
    });

    test('areas_list lists the register: projects with description and '
        'areas, merged tombstones, and the mode', () async {
      await strict.areaSet(name: 'home');
      await register('garden');
      await register('family');
      await register('garden-old');
      await strict.projectSet(name: 'garden', addAreas: ['home']);
      await strict.projectSet(name: 'family', status: ProjectStatus.archived);
      await strict.projectMerge(from: 'garden-old', into: 'garden');
      final r = await strict.areasList();
      expect(r['registryMode'], 'strict');
      expect(r['projects'], [
        {
          'name': 'family',
          'status': ProjectStatus.archived,
          'description': 'Synthetic test project family.',
          'areas': <String>[],
        },
        {
          'name': 'garden',
          'status': ProjectStatus.active,
          'description': 'Synthetic test project garden.',
          'areas': ['home'],
        },
      ]);
      expect(r['mergedProjects'], [
        {'name': 'garden-old', 'mergedInto': 'garden'},
      ]);
      // The pre-existing keys are untouched.
      expect(r.keys, containsAll(['areas', 'projectsWithoutArea']));
    });
  });

  group('merge and remove keep definitions consistent', () {
    setUp(() => register('garden'));

    test('tag_merge carries a "from" definition to an unregistered target',
        () async {
      await open.remember(text: 'a', project: 'garden', tags: ['lessons']);
      await strict.tagDefine(name: 'lessons', description: 'Learned.');
      logLines.clear();
      final r = await strict.tagMerge(from: ['lessons'], into: 'lesson');
      expect(r['intoDefinition'], 'carried');
      expect(r['carriedFrom'], 'lessons');
      expect(r['definitionsRemoved'], 1);
      expect(defs().getAll().map((d) => (d.name, d.description)), [
        ('lesson', 'Learned.'),
      ]);
      expect(
        logLines,
        contains(
          startsWith('[memory] tag_merge: carried the definition of '
              '"lessons" to "lesson"'),
        ),
      );
    });

    test('tag_merge keeps the target definition and logs a dropped "from" '
        'description', () async {
      await define('lesson');
      await strict.tagDefine(
        name: 'lessons',
        description: 'Plural spelling.',
        allowSimilar: true,
      );
      logLines.clear();
      final r = await strict.tagMerge(from: ['lessons'], into: 'lesson');
      expect(r['intoDefinition'], 'kept');
      expect(r.containsKey('carriedFrom'), isFalse);
      expect(r['definitionsRemoved'], 1);
      // A definition-only "from" is not "not found".
      expect(r['notFound'], isEmpty);
      expect(defs().getAll().single.description, 'Synthetic tag lesson.');
      expect(
        logLines,
        contains(contains('its description was not carried over: '
            '"Plural spelling."')),
      );
    });

    test('tag_merge with no definition on either side: open reports none, '
        'strict rejects and changes nothing', () async {
      await open.remember(text: 'a', project: 'garden', tags: ['alice']);
      await open.remember(text: 'b', project: 'garden', tags: ['Alice2']);
      await expectStrictRejection(
        () => strict.tagMerge(from: ['alice2'], into: 'alice'),
        tool: 'tag_merge',
        messageContains: [
          'tag_merge: "into" ("alice") is not a registered tag and none of '
              'the "from" tags has a definition to carry over (strict '
              'registry mode). Register it first with tag_define, then '
              'retry. Nothing was changed.',
        ],
      );
      final r = await open.tagMerge(from: ['alice2'], into: 'alice');
      expect(r['intoDefinition'], 'none');
      expect(r['definitionsRemoved'], 0);
      expect(r['tagsRemoved'], 1);
    });

    test('tag_merge dryRun reports the same without writing', () async {
      await open.remember(text: 'a', project: 'garden', tags: ['lessons']);
      await strict.tagDefine(name: 'lessons', description: 'Learned.');
      final dry = await strict.tagMerge(
        from: ['lessons'],
        into: 'lesson',
        dryRun: true,
      );
      expect(dry['intoDefinition'], 'carried');
      expect(dry['definitionsRemoved'], 1);
      expect(defs().getAll().single.name, 'lessons');
      expect(tags().getAll().single.name, 'lessons');
    });

    test('tag_remove removes matching definitions (dryRun writes nothing)',
        () async {
      await open.remember(text: 'a', project: 'garden', tags: ['status']);
      await define('status');
      await define('lesson'); // definition only
      final dry = await open.tagRemove(
        tags: ['status', 'lesson'],
        dryRun: true,
      );
      expect(dry['definitionsRemoved'], 2);
      expect(dry['notFound'], isEmpty);
      expect(defs().count(), 2);
      logLines.clear();
      final r = await open.tagRemove(tags: ['status', 'lesson', 'nope']);
      expect(r['definitionsRemoved'], 2);
      expect(r['tagsRemoved'], 1);
      expect(r['notFound'], ['nope']);
      expect(defs().count(), 0);
      expect(
        logLines.where(
          (l) => l.startsWith('[memory] tag_remove: removed the definition'),
        ),
        hasLength(2),
      );
    });

    test('tags_normalize keeps the target definition', () async {
      await define('appsScript');
      // A legacy, pre-normalization spelling written directly.
      final legacy = Tag(name: 'apps-script');
      final e = await open.remember(text: 'legacy', project: 'garden');
      store.runInTransaction(TxMode.write, () {
        final entry = entries().get(e['id'] as int)!;
        entry.tags.add(legacy);
        entries().put(entry);
      });
      final r = await strict.tagsNormalize();
      expect(r['definitionsRemoved'], 0);
      expect(defs().getAll().single.name, 'appsScript');
      expect(tags().getAll().single.name, 'appsScript');
    });
  });

  group('open mode stays as it was', () {
    test('default and explicit open give identical results for a scripted '
        'run; projects and tags are created on write, no definitions',
        () async {
      Future<List<Map<String, Object?>>> script(MemoryService s) async {
        final out = <Map<String, Object?>>[];
        out.add(await s.remember(
          text: 'first',
          project: 'acme-app',
          tags: ['Apps Script', 'decision', 'status'],
        ));
        out.add(await s.remember(text: 'first', project: 'acme-app'));
        out.add(await s.remember(text: 'second', project: 'Acme_App'));
        out.add(await s.factSet(
          subject: 'Car',
          attribute: 'colour',
          project: 'family',
          valueText: 'blue',
          validFrom: DateTime.utc(2026, 1, 1),
        ));
        out.add(await s.projectSet(name: 'garden'));
        out.add(await s.supersede(out.first['id'] as int, text: 'first v2'));
        out.add(await s.entriesMove(
          ids: [out.first['id'] as int],
          toProject: 'garden',
        ));
        out.add(await s.projectMerge(from: 'Acme_App', into: 'acme-app'));
        out.add(await s.remember(text: 'third', project: 'Acme_App'));
        return out;
      }

      final defaultResults = await script(open);
      final defaultCounts = counts();

      // A second store, explicitly open.
      final otherDir = Directory.systemTemp.createTempSync(
        'remembox_registry_mode_open_',
      );
      final otherGate = await openTestGate(otherDir.path, log: logCapture);
      final explicitOpen = MemoryService(
        gate: otherGate.gate,
        embedder: FakeEmbedder(),
        log: logCapture,
        registryMode: RegistryMode.open,
      );
      addTearDown(() async {
        await explicitOpen.dispose();
        await otherGate.close();
        otherDir.deleteSync(recursive: true);
      });
      final explicitResults = await script(explicitOpen);

      // Wall-clock creation stamps differ between two runs by design.
      Object? withoutClock(Object? v) => switch (v) {
        Map() => {
          for (final e in v.entries)
            if (e.key != 'createdAt') e.key: withoutClock(e.value),
        },
        List() => [for (final x in v) withoutClock(x)],
        _ => v,
      };
      expect(withoutClock(explicitResults), withoutClock(defaultResults));
      expect(defaultCounts['defs'], 0);
      expect(
        projects().getAll().map((p) => p.name).toSet(),
        {'acme-app', 'Acme_App', 'family', 'garden'},
      );
      expect(tags().getAll().map((t) => t.name).toSet(), {
        'appsScript',
        'status',
      });
      expect(
        logLines.where((l) => l.startsWith('[registry]')),
        isEmpty,
        reason: 'open mode never logs a strict-mode line',
      );
    });
  });

  group('review fixes', () {
    group('merge chains', () {
      test('A -> B -> C: the rejection names the current project C',
          () async {
        await register('garden-2019');
        await register('garden-old');
        await register('garden');
        await strict.projectMerge(from: 'garden-2019', into: 'garden-old');
        await strict.projectMerge(from: 'garden-old', into: 'garden');
        await expectStrictRejection(
          () => strict.remember(text: 'probe', project: 'garden-2019'),
          tool: 'remember',
          messageContains: [
            'project "garden-2019" was merged into "garden-old" '
                '(project_merge) (merge chain: "garden-2019" → "garden-old" '
                '→ "garden") and no longer accepts writes in strict registry '
                'mode. Use "garden" instead.',
          ],
        );
        // A suggestion never offers a merged name to use.
        final message = await expectStrictRejection(
          () => strict.remember(text: 'probe', project: 'garden_2019'),
          tool: 'remember',
          messageContains: [
            '"garden-2019" (merged into "garden-old") – use "garden". Use '
                '"garden".',
          ],
        );
        expect(message, isNot(contains('Use "garden-2019"')));
        expect(message, isNot(contains('Use "garden-old"')));
      });

      test('a merged row without a target is not suggested and is logged',
          () async {
        projects().put(
          ProjectScope(
            name: 'garden-old',
            nameKey: ScopeKey.of('garden-old'),
            status: ProjectStatus.merged,
          ),
        );
        await expectStrictRejection(
          () => strict.remember(text: 'probe', project: 'garden-old'),
          tool: 'remember',
          messageContains: [
            'project "garden-old" was merged (project_merge) and no longer '
                'accepts writes in strict registry mode, but "garden-old" is '
                'marked as merged but has no merge target – call areas_list '
                'to find the project to use. Nothing was written.',
          ],
        );
        expect(
          logLines,
          contains(
            startsWith('[registry] broken merge chain for "garden-old"'),
          ),
        );
        final message = await expectStrictRejection(
          () => strict.remember(text: 'probe', project: 'garden_old'),
          tool: 'remember',
          messageContains: [
            '"garden-old" (merged, no merge target – see areas_list). Call '
                'areas_list to see every registered project.',
          ],
        );
        expect(message, isNot(contains('Use "garden-old"')));
      });

      test('a merge cycle is reported as broken, not followed forever',
          () async {
        for (final (name, into) in [
          ('garden-a', 'garden-b'),
          ('garden-b', 'garden-a'),
        ]) {
          projects().put(
            ProjectScope(
              name: name,
              nameKey: ScopeKey.of(name),
              status: ProjectStatus.merged,
              mergedInto: into,
            ),
          );
        }
        await expectStrictRejection(
          () => strict.remember(text: 'probe', project: 'garden-a'),
          tool: 'remember',
          messageContains: ['the merge chain loops back to "garden-a"'],
        );
      });
    });

    test('project_set without a description mentions allowSimilar when a '
        'similar project exists', () async {
      await register('acme-app');
      await expectStrictRejection(
        () => strict.projectSet(name: 'acme_app'),
        tool: 'project_set',
        messageContains: [
          'Use "acme-app". If "acme_app" is genuinely a different project, '
              'pass a description and allowSimilar: true.',
        ],
      );
    });

    test('reindex reports newly registered near-duplicate project names',
        () async {
      await open.remember(text: 'one', project: 'acme-app');
      await open.remember(text: 'two', project: 'Acme_App');
      projects().removeAll();
      final r = await open.reindex();
      final registry = r['registry'] as Map<String, Object?>;
      expect(registry['registered'], 2);
      expect(registry['nearDuplicates'], [
        {'name': 'Acme_App', 'similarTo': ['acme-app']},
        {'name': 'acme-app', 'similarTo': ['Acme_App']},
      ]);
      expect(
        r['warning'],
        '2 newly registered project name(s) differ from another registered '
        'name only by case/space/-/_: "Acme_App" (like "acme-app"), '
        '"acme-app" (like "Acme_App"). Merge the variants with project_merge '
        '(dryRun first) before switching to strict registry mode.',
      );
    });

    test('the reindex report resolves a merged variant to its current '
        'project instead of naming the tombstone', () async {
      await register('garden');
      await register('garden-old');
      await strict.projectMerge(from: 'garden-old', into: 'garden');
      await open.remember(text: 'late', project: 'Garden_Old');
      projects().query(ProjectScope_.name.equals('Garden_Old')).build()
        ..remove()
        ..close();
      final r = await open.reindex();
      final registry = r['registry'] as Map<String, Object?>;
      expect(registry['nearDuplicates'], [
        {'name': 'Garden_Old', 'similarTo': ['garden']},
      ]);
      expect(r['warning'], contains('"Garden_Old" (like "garden")'));
      expect(r['warning'], isNot(contains('"garden-old"')));
    });

    test('a reindex without near-duplicates adds no warning', () async {
      await open.remember(text: 'one', project: 'acme-app');
      projects().removeAll();
      final r = await open.reindex();
      expect(r.containsKey('warning'), isFalse);
      expect(
        (r['registry'] as Map<String, Object?>).containsKey('nearDuplicates'),
        isFalse,
      );
    });

    group('tag_define names the project status', () {
      test('archived', () async {
        await register('garden');
        await strict.projectSet(name: 'garden', status: ProjectStatus.archived);
        await expectLater(
          strict.tagDefine(name: 'garden', description: 'Nope.'),
          throwsA(
            isA<ValidationException>().having(
              (e) => e.message,
              'message',
              startsWith('tag_define: "garden" matches the archived project '
                  '"garden" –'),
            ),
          ),
        );
      });

      // 2026-10-07: a merged-away project name is a tombstone, no longer
      // filterable – it no longer blocks a tag of the same name.
      test('merged: no longer blocks the tag', () async {
        await register('garden');
        await register('garden-old');
        await strict.projectMerge(from: 'garden-old', into: 'garden');
        final r = await strict.tagDefine(
          name: 'garden-old',
          description: 'Things from the old garden.',
        );
        expect(r['name'], 'gardenOld');
        expect(r['action'], 'created');
      });
    });

    test('a strict tag rejection says a project/area/kind name cannot be '
        'registered', () async {
      await register('garden');
      await register('family');
      final message = await expectStrictRejection(
        () => strict.remember(
          text: 'probe',
          project: 'family',
          tags: ['garden'],
        ),
        tool: 'remember',
        messageContains: [
          '"garden" (repeats the registered project "garden", so it cannot '
              'be registered as a tag – drop it)',
        ],
      );
      expect(message, isNot(contains('tag_define')));
    });

    group('a merge never carries a definition tag_define would refuse', () {
      setUp(() async {
        await register('garden');
        await register('family');
        await define('foo');
        await open.remember(text: 'a', project: 'family', tags: ['foo']);
      });

      test('strict: tag_merge into a project name is rejected, nothing '
          'changed', () async {
        await expectLater(
          strict.tagDefine(name: 'garden', description: 'Nope.'),
          throwsA(isA<ValidationException>()),
        );
        for (final dryRun in [true, false]) {
          await expectStrictRejection(
            () => strict.tagMerge(
              from: ['foo'],
              into: 'garden',
              dryRun: dryRun,
            ),
            tool: 'tag_merge',
            messageContains: [
              'tag_merge: the definition of "foo" cannot be carried over to '
                  '"garden" (strict registry mode): "garden" matches the '
                  'registered project "garden" – projects, kinds and areas '
                  'are already filterable, so a tag must not repeat one. '
                  '"garden" cannot be registered – merge into a registered '
                  'tag (tags_list) instead. Nothing was changed.',
            ],
          );
        }
        expect(defs().getAll().single.name, 'foo');
        // The repro: "garden" never became a registered tag.
        await expectStrictRejection(
          () => strict.remember(
            text: 'probe',
            project: 'family',
            tags: ['garden'],
          ),
          tool: 'remember',
        );
      });

      test('strict: a carry that would create a variant of a registered '
          'tag is rejected', () async {
        await define('lesson');
        await expectStrictRejection(
          () => strict.tagMerge(from: ['foo'], into: 'lessons'),
          tool: 'tag_merge',
          messageContains: [
            '"lessons" looks like a variant of the registered tag "lesson" '
                '(same word apart from case, plural or separators). Merge '
                'into that registered tag instead, or – if "lessons" is '
                'genuinely a different label – register it first with '
                'tag_define (allowSimilar: true), then merge.',
          ],
        );
      });

      test('strict: without any definition to carry, a project-named '
          'target is not sent to tag_define', () async {
        await open.remember(text: 'b', project: 'family', tags: ['bar']);
        final message = await expectStrictRejection(
          () => strict.tagMerge(from: ['bar'], into: 'garden'),
          tool: 'tag_merge',
          messageContains: [
            'It cannot be registered: "garden" matches the registered '
                'project "garden" – projects, kinds and areas are already '
                'filterable, so a tag must not repeat one. Merge into a '
                'registered tag (tags_list) instead. Nothing was changed.',
          ],
        );
        expect(message, isNot(contains('Register it first')));
      });

      test('strict: without any definition to carry, a variant target '
          'mentions allowSimilar', () async {
        await define('lesson');
        await open.remember(text: 'b', project: 'family', tags: ['bar']);
        await expectStrictRejection(
          () => strict.tagMerge(from: ['bar'], into: 'lessons'),
          tool: 'tag_merge',
          messageContains: [
            'register it first with tag_define (allowSimilar: true), then '
                'retry.',
          ],
        );
      });

      test('a carry reports the near-match warnings tag_define would give',
          () async {
        await strict.areaSet(name: 'work');
        final r = await strict.tagMerge(from: ['foo'], into: 'works');
        expect(r['intoDefinition'], 'carried');
        expect(
          r['warning'],
          contains('"works" looks like a near-duplicate of the area "work" – '
              'registered, but consider the area filter instead of a tag.'),
        );
      });

      test('open: the merge happens without the carry and says why',
          () async {
        logLines.clear();
        final r = await open.tagMerge(from: ['foo'], into: 'garden');
        expect(r['intoDefinition'], 'none');
        expect(r.containsKey('carriedFrom'), isFalse);
        expect(r['definitionsRemoved'], 1);
        expect(
          r['warning'],
          contains('The definition of "foo" was not carried over to "garden": '
              '"garden" matches the registered project "garden"'),
        );
        expect(r['warning'], contains('"garden" stays unregistered.'));
        expect(defs().count(), 0);
        expect(
          logLines,
          contains(startsWith('[memory] tag_merge: did not carry the '
              'definition of "foo" to "garden"')),
        );
      });

      test('tags_normalize never rejects: blocked carry and (strict) an '
          'unregistered target are warnings', () async {
        // A legacy, pre-normalization spelling with a definition of its own.
        final legacyTag = Tag(name: 'Garden');
        final e = await open.remember(text: 'legacy', project: 'family');
        store.runInTransaction(TxMode.write, () {
          final entry = entries().get(e['id'] as int)!;
          entry.tags.add(legacyTag);
          entries().put(entry);
        });
        defs().put(TagDefinition(name: 'Garden', description: 'Legacy.'));
        final r = await strict.tagsNormalize();
        expect(r['definitionsRemoved'], 1);
        final warning = r['warning'] as String;
        expect(
          warning,
          contains('The definition of "Garden" was not carried over to '
              '"garden"'),
        );
        expect(
          warning,
          contains('"garden" is not a registered tag (strict registry mode) '
              '– writes using it are rejected; it cannot be registered (it '
              'repeats the registered project "garden") – tag_merge it into '
              'a real tag or tag_remove it.'),
        );
        expect(warning, isNot(contains('register it with tag_define')));
        expect(defs().getAll().single.name, 'foo');
      });

      test('tags_normalize in open mode warns about the blocked carry only',
          () async {
        final legacyTag = Tag(name: 'Garden');
        final e = await open.remember(text: 'legacy', project: 'family');
        store.runInTransaction(TxMode.write, () {
          final entry = entries().get(e['id'] as int)!;
          entry.tags.add(legacyTag);
          entries().put(entry);
        });
        defs().put(TagDefinition(name: 'Garden', description: 'Legacy.'));
        final r = await open.tagsNormalize();
        final warning = r['warning'] as String;
        expect(warning, contains('was not carried over to "garden"'));
        expect(warning, isNot(contains('is not a registered tag')));
      });
    });
  });

  group('merged project names do not block tags', () {
    setUp(() async {
      await register('family');
      await register('hobby');
      await strict.projectMerge(from: 'hobby', into: 'family');
    });

    test('strict remember: an undefined tag named like a merged project is '
        'registrable, and accepted once defined', () async {
      final message = await expectStrictRejection(
        () => strict.remember(text: 'p', project: 'family', tags: ['hobby']),
        tool: 'remember',
        messageContains: [
          '"hobby" (no similar registered tag)',
          'If a tag is genuinely new, register it first with tag_define',
        ],
      );
      expect(message, isNot(contains('cannot be registered')));
      await define('hobby');
      final r = await strict.remember(
        text: 'knitting on weekends',
        project: 'family',
        tags: ['hobby'],
      );
      expect(tagsOf(r), ['hobby']);
    });

    test('active and archived project names still block a tag', () async {
      await register('garden');
      await register('attic');
      await strict.projectSet(name: 'attic', status: ProjectStatus.archived);
      for (final (name, phrase) in [
        ('garden', 'the registered project "garden"'),
        ('attic', 'the archived project "attic"'),
      ]) {
        await expectLater(
          strict.tagDefine(name: name, description: 'Nope.'),
          throwsA(
            isA<ValidationException>().having(
              (e) => e.message,
              'message',
              contains('matches $phrase'),
            ),
          ),
        );
        final message = await expectStrictRejection(
          () => strict.remember(text: 'p', project: 'family', tags: [name]),
          tool: 'remember',
        );
        expect(message, contains('repeats $phrase, so it cannot be '
            'registered as a tag – drop it'));
      }
      // Open mode still drops a tag equal to the entry's own project.
      final own = await open.remember(
        text: 'own project tag',
        project: 'garden',
        tags: ['garden'],
      );
      expect(tagsOf(own), isEmpty);
    });

    test('an alias named like a merged project is allowed', () async {
      final r = await strict.tagDefine(
        name: 'pastime',
        description: 'Free-time activities.',
        aliases: ['hobby'],
      );
      expect(r['aliases'], ['hobby']);
    });
  });
}
