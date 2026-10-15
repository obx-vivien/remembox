/// Tests for `kind_migrate` (0.5.0): marker tags to kinds in place –
/// precedence, review, multi-marker, already-the-kind, listing, legacy
/// links, dry run, idempotency, no re-embedding, strict mode – and the
/// documented way to retype a link or a continuation without a tool.
///
/// Synthetic data only: project `garden`; marker tags `deadEnd`,
/// `learning`/`takeaway`, `status`, `rule` written as 0.4.0 data (below
/// today's tag rules, which drop kind names).
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

const _rules = [
  KindMigrationRule(tags: ['deadEnd'], kind: MemoryKind.deadEnd),
  KindMigrationRule(tags: ['learning', 'takeaway'], kind: MemoryKind.lesson),
  KindMigrationRule(tags: ['status'], kind: MemoryKind.snapshot),
  KindMigrationRule(tags: ['rule'], list: true),
];

void main() {
  late Directory tempDir;
  late TestGate testGate;
  late Store store;
  late FakeEmbedder embedder;
  late MemoryService open;
  late MemoryService strict;
  late List<String> logLines;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('remembox_kind_migrate_');
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
  });

  tearDown(() async {
    await open.dispose();
    await strict.dispose();
    await testGate.close();
    tempDir.deleteSync(recursive: true);
  });

  Box<MemoryEntry> entries() => store.box<MemoryEntry>();

  /// An entry (indexed, via remember) that also carries [markers] as
  /// 0.4.0 data – attached below the tag rules, reusing one Tag row per
  /// name.
  Future<int> legacy(String text, String kind, List<String> markers) async {
    final id =
        (await open.remember(text: text, project: 'garden', kind: kind))['id']
            as int;
    final tagBox = store.box<Tag>();
    final entry = entries().get(id)!;
    for (final name in markers) {
      final existing = tagBox
          .query(Tag_.name.equals(name))
          .build()
          .findFirst();
      entry.tags.add(existing ?? Tag(name: name));
    }
    entries().put(entry);
    return id;
  }

  String kindOf(int id) => entries().get(id)!.kind;
  List<String> tagsOf(int id) =>
      entries().get(id)!.tags.map((t) => t.name).toList()..sort();

  test('precedence, review, already-the-kind, multi-marker, listing and '
      'legacy links', () async {
    final e1 = await legacy('dropped approach', MemoryKind.episode, ['deadEnd']);
    final e2 = await legacy('status report', MemoryKind.fact, ['status']);
    final e3 = await legacy(
      'learned while reporting',
      MemoryKind.fact,
      ['status', 'learning'],
    );
    final e4 = await legacy(
      'dead end with a lesson',
      MemoryKind.episode,
      ['learning', 'deadEnd'],
    );
    final e5 = await legacy('a decision with a marker', MemoryKind.decision, [
      'deadEnd',
      'todo',
    ]);
    final e6 = await legacy('already a lesson', MemoryKind.lesson, ['takeaway']);
    final e7 = await legacy('a rule we follow', MemoryKind.decision, ['rule']);
    final untouchedId = await legacy('plain entry', MemoryKind.fact, ['todo']);
    final link = await open.link(e2, e7, LinkType.child);
    await open.link(e1, e2, LinkType.related);

    final r = await open.kindMigrate(rules: _rules);
    expect(r['dryRun'], isFalse);
    expect(r['scope'], 'all');
    expect(r['examined'], 7);

    final converted = {
      for (final c in (r['converted'] as List).cast<Map<String, Object?>>())
        c['id']: c,
    };
    expect(converted.keys, unorderedEquals([e1, e2, e3, e4]));
    expect(converted[e1]!['kindTo'], 'deadEnd');
    expect(converted[e2]!['kindTo'], 'snapshot');
    // learning (rule 2) precedes status (rule 3).
    expect(converted[e3]!['kindTo'], 'lesson');
    // Markers in rule order.
    expect(converted[e3]!['markersRemoved'], ['learning', 'status']);
    expect(converted[e3]!['overridden'], [
      {'tags': ['status'], 'kind': 'snapshot'},
    ]);
    // deadEnd (rule 1) precedes learning (rule 2).
    expect(converted[e4]!['kindTo'], 'deadEnd');
    expect(converted[e4]!['overridden'], [
      {'tags': ['learning', 'takeaway'], 'kind': 'lesson'},
    ]);

    final review = (r['review'] as List).cast<Map<String, Object?>>();
    expect(review, [
      {
        'id': e5,
        'title': 'a decision with a marker',
        'kind': 'decision',
        'markers': ['deadEnd'],
        'suggestedKind': 'deadEnd',
        'reasons': [
          '"deadEnd" does not convert kind decision (not in '
              'convertFrom/dropFrom) – review.',
        ],
      },
    ]);

    final removed = {
      for (final m in (r['markerRemoved'] as List).cast<Map<String, Object?>>())
        m['id']: m,
    };
    expect(removed.keys, unorderedEquals([e6, e7]));
    expect(removed[e6]!['markersRemoved'], ['takeaway']);
    expect(removed[e7]!['kind'], 'decision');

    final listed = (r['listed'] as Map)['rule'] as Map;
    expect(listed['count'], 1);
    expect(listed['superseded'], 0);
    final listedEntry = (listed['entries'] as List).single as Map;
    expect(listedEntry['id'], e7);
    expect(listedEntry['links'], [
      {'type': 'child', 'direction': 'in', 'otherId': e2},
    ]);

    expect(r['legacyLinks'], [
      {'linkId': link['linkId'], 'type': 'child', 'fromId': e2, 'toId': e7},
    ]);
    expect(r['notFound'], isEmpty);
    // Applied outcomes only; review counted separately.
    expect(r['byRule'], [
      {
        'tags': ['deadEnd'],
        'kind': 'deadEnd',
        'matched': 3,
        'converted': 2,
        'markerRemoved': 0,
        'overridden': 0,
        'kept': 0,
        'review': 1,
      },
      {
        'tags': ['learning', 'takeaway'],
        'kind': 'lesson',
        'matched': 3,
        'converted': 1,
        'markerRemoved': 2,
        'overridden': 1,
        'kept': 0,
        'review': 0,
      },
      {
        'tags': ['status'],
        'kind': 'snapshot',
        'matched': 2,
        'converted': 1,
        'markerRemoved': 1,
        'overridden': 1,
        'kept': 0,
        'review': 0,
      },
      {
        'tags': ['rule'],
        'kind': null,
        'matched': 1,
        'converted': 0,
        'markerRemoved': 1,
        'overridden': 0,
        'kept': 0,
        'review': 0,
      },
    ]);
    expect(
      r['warning'],
      allOf(
        contains('1 entry needs review and was left unchanged'),
        contains('1 parent/child link(s) have no defined direction'),
      ),
    );
    // status/learning/takeaway/rule are gone; deadEnd stays on the review
    // entry, todo on others.
    expect(r['tagsNowUnused'], ['learning', 'rule', 'status', 'takeaway']);

    expect(kindOf(e1), 'deadEnd');
    expect(tagsOf(e1), isEmpty);
    expect(kindOf(e3), 'lesson');
    expect(tagsOf(e3), isEmpty);
    expect(kindOf(e5), 'decision');
    expect(tagsOf(e5), ['deadEnd', 'todo']);
    expect(kindOf(e6), 'lesson');
    expect(tagsOf(e6), isEmpty);
    expect(tagsOf(untouchedId), ['todo']);
    expect(
      logLines,
      contains(
        '[memory] kind_migrate: scope=all examined=7 converted=4 '
        'markerRemoved=2 review=1 legacyLinks=1 notFound=0 tagsNowUnused=4',
      ),
    );
  });

  test('dryRun writes nothing and matches the real run; a second run is '
      'a no-op; nothing is re-embedded', () async {
    final a = await legacy('one', MemoryKind.episode, ['deadEnd']);
    final b = await legacy('two', MemoryKind.fact, ['status']);
    final embeds = embedder.calls.length;
    final dry = await open.kindMigrate(rules: _rules, dryRun: true);
    expect(kindOf(a), 'episode');
    expect(tagsOf(b), ['status']);
    final real = await open.kindMigrate(rules: _rules);
    expect({...real}..remove('dryRun'), {...dry}..remove('dryRun'));
    expect(kindOf(a), 'deadEnd');
    expect(kindOf(b), 'snapshot');

    final again = await open.kindMigrate(rules: _rules);
    expect(again['examined'], 0);
    expect(again['converted'], isEmpty);
    // The deadEnd/status Tag rows stay, so only the never-used ones are
    // not found.
    expect(again['notFound'], ['learning', 'takeaway', 'rule']);
    expect(embedder.calls.length, embeds);
    final reindex = await open.reindex();
    expect(reindex['reembedded'], 0);
    expect(reindex['created'], 0);
  });

  test('convertFrom/dropFrom/fromKinds and scope live', () async {
    final decision = await legacy('decided', MemoryKind.decision, ['learning']);
    final preference = await legacy('prefer', MemoryKind.preference, ['learning']);
    final old = await legacy('old fact', MemoryKind.fact, ['status']);
    await open.supersede(old, text: 'new fact');
    final r = await open.kindMigrate(
      rules: const [
        KindMigrationRule(
          tags: ['learning'],
          kind: MemoryKind.lesson,
          convertFrom: [MemoryKind.decision],
          dropFrom: [MemoryKind.preference],
        ),
        KindMigrationRule(tags: ['status'], kind: MemoryKind.snapshot),
      ],
      fromKinds: const [MemoryKind.fact, MemoryKind.decision],
      scope: 'live',
    );
    expect(kindOf(decision), 'lesson');
    expect(kindOf(preference), 'preference');
    expect(tagsOf(preference), isEmpty);
    // The superseded entry is out of scope.
    expect(kindOf(old), 'fact');
    expect(tagsOf(old), ['status']);
    expect(r['examined'], 2);
    expect(r['notFound'], isEmpty);
  });

  test('keep: true lists the marker for review and leaves it', () async {
    final onlyRule = await legacy('a house rule', MemoryKind.decision, ['rule']);
    final both = await legacy(
      'a rule from a dead end',
      MemoryKind.episode,
      ['rule', 'deadEnd'],
    );
    const rules = [
      KindMigrationRule(tags: ['deadEnd'], kind: MemoryKind.deadEnd),
      KindMigrationRule(tags: ['rule'], list: true, keep: true),
    ];
    final dry = await open.kindMigrate(rules: rules, dryRun: true);
    final r = await open.kindMigrate(rules: rules);
    expect({...r}..remove('dryRun'), {...dry}..remove('dryRun'));
    expect(tagsOf(onlyRule), ['rule']);
    expect(kindOf(both), MemoryKind.deadEnd);
    expect(tagsOf(both), ['rule']);
    expect(r['markerRemoved'], isEmpty);
    final converted = (r['converted'] as List).single as Map;
    expect(converted['id'], both);
    expect(converted['markersRemoved'], ['deadEnd']);
    final listed = (r['listed'] as Map)['rule'] as Map;
    expect(
      (listed['entries'] as List).map((e) => (e as Map)['id']),
      unorderedEquals([onlyRule, both]),
    );
    expect((r['byRule'] as List).last, containsPair('kept', 2));
    expect((r['byRule'] as List).last, containsPair('markerRemoved', 0));
    expect(r['tagsNowUnused'], ['deadEnd']);
  });

  test('tags that do not exist are reported in notFound', () async {
    final r = await open.kindMigrate(rules: _rules);
    expect(r['examined'], 0);
    expect(r['notFound'], ['deadEnd', 'learning', 'takeaway', 'status', 'rule']);
    expect(r['warning'], startsWith('No tag named "deadEnd", "learning"'));
  });

  test('strict registry mode does not block removing retired markers',
      () async {
    final a = await legacy('status in strict', MemoryKind.fact, ['status']);
    await open.tagRetire(name: 'status', hint: 'use kind snapshot');
    final r = await strict.kindMigrate(rules: _rules);
    expect((r['converted'] as List), hasLength(1));
    expect(kindOf(a), 'snapshot');
    expect(tagsOf(a), isEmpty);
  });

  test('dropFrom overlapping the default convertFrom is rejected, the '
      'marked entry stays', () async {
    final a = await legacy('status fact', MemoryKind.fact, ['status']);
    await expectLater(
      open.kindMigrate(
        rules: const [
          KindMigrationRule(
            tags: ['status'],
            kind: MemoryKind.snapshot,
            dropFrom: [MemoryKind.fact],
          ),
        ],
      ),
      throwsA(isA<ValidationException>()),
    );
    expect(kindOf(a), MemoryKind.fact);
    expect(tagsOf(a), ['status']);
    // With convertFrom narrowed, fact only loses the marker.
    final r = await open.kindMigrate(
      rules: const [
        KindMigrationRule(
          tags: ['status'],
          kind: MemoryKind.snapshot,
          convertFrom: [MemoryKind.episode],
          dropFrom: [MemoryKind.fact],
        ),
      ],
    );
    expect((r['markerRemoved'] as List).single, containsPair('id', a));
    expect(kindOf(a), MemoryKind.fact);
    expect(tagsOf(a), isEmpty);
  });

  test('rejects bad rules before touching anything', () async {
    final cases = <(List<KindMigrationRule>, Map<String, Object?>, String)>[
      (const [], const {}, 'kind_migrate: "rules" must not be empty.'),
      (
        [for (var i = 0; i < 21; i++) KindMigrationRule(tags: ['m$i'])],
        const {},
        'kind_migrate: 21 rules exceed the 20 rule limit.',
      ),
      (
        const [KindMigrationRule(tags: [])],
        const {},
        'kind_migrate: rule 1 has no tags.',
      ),
      (
        const [KindMigrationRule(tags: ['x'], kind: 'Lesson')],
        const {},
        'Unknown kind "Lesson". Valid kinds: fact, decision, preference, '
            'episode, reference, snapshot, lesson, deadEnd. Did you mean '
            '"lesson"?',
      ),
      (
        const [
          KindMigrationRule(
            tags: ['x'],
            kind: MemoryKind.lesson,
            convertFrom: [MemoryKind.decision],
          ),
        ],
        const {},
        'kind_migrate: rule 1 converts from decision, which is not in '
            'fromKinds (fact, episode).',
      ),
      (
        const [KindMigrationRule(tags: ['x'], dropFrom: [MemoryKind.fact])],
        const {},
        'kind_migrate: rule 1 has no kind – convertFrom/dropFrom need one (a '
            'rule without kind only removes its markers).',
      ),
      (
        const [
          KindMigrationRule(tags: ['status'], kind: MemoryKind.snapshot),
          KindMigrationRule(tags: ['Status'], kind: MemoryKind.lesson),
        ],
        const {},
        'kind_migrate: tag "Status" appears in rule 1 and rule 2 – a tag '
            'belongs to one rule only.',
      ),
      (
        const [
          KindMigrationRule(
            tags: ['status'],
            kind: MemoryKind.snapshot,
            dropFrom: [MemoryKind.fact],
          ),
        ],
        const {},
        'kind_migrate: rule 1 lists fact in dropFrom, but it also converts '
            '(convertFrom defaults to fromKinds: fact, episode) – a kind either '
            'converts or only loses the marker. Pass convertFrom without it. '
            'Nothing was written.',
      ),
      (
        const [
          KindMigrationRule(
            tags: ['status'],
            kind: MemoryKind.snapshot,
            convertFrom: [MemoryKind.fact, MemoryKind.episode],
            dropFrom: [MemoryKind.episode, MemoryKind.fact],
          ),
        ],
        const {},
        'kind_migrate: rule 1 lists episode, fact in dropFrom, but they also '
            'convert (convertFrom: fact, episode) – a kind either converts or '
            'only loses the marker. Pass convertFrom without them. Nothing '
            'was written.',
      ),
      (
        const [KindMigrationRule(tags: ['rule'], keep: true)],
        const {},
        'kind_migrate: rule 1 has keep: true – only valid together with '
            'list: true and without kind (it lists the marker for review and '
            'leaves it on the entries).',
      ),
      (
        const [
          KindMigrationRule(
            tags: ['rule'],
            kind: MemoryKind.decision,
            list: true,
            keep: true,
          ),
        ],
        const {},
        'kind_migrate: rule 1 has keep: true – only valid together with '
            'list: true and without kind (it lists the marker for review and '
            'leaves it on the entries).',
      ),
      (_rules, const {'scope': 'recent'},
          'kind_migrate: "scope" must be "all" or "live", got "recent".'),
    ];
    for (final (rules, extra, message) in cases) {
      await expectLater(
        open.kindMigrate(
          rules: rules,
          scope: (extra['scope'] as String?) ?? 'all',
        ),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            message,
          ),
        ),
      );
    }
  });

  group('retyping without a tool', () {
    test('a link: unlink, then link with the new type', () async {
      final whole = (await open.remember(
        text: 'the whole plan',
        project: 'garden',
      ))['id'] as int;
      final part = (await open.remember(
        text: 'one part of the plan',
        project: 'garden',
      ))['id'] as int;
      final old = await open.link(whole, part, LinkType.parent);
      await open.unlink(old['linkId'] as int);
      final retyped = await open.link(part, whole, LinkType.partOf);
      final got = await open.get(whole);
      final link = (got['links'] as List).single as Map;
      expect(link['linkId'], retyped['linkId']);
      expect(link['relation'], 'hasPart');
    });

    test('a continuation: supersede onto an existing entry links it as the '
        'successor – and overwrites an earlier supersededBy', () async {
      final a = (await open.remember(
        text: 'status of the beds, spring',
        project: 'garden',
      ))['id'] as int;
      final b = (await open.remember(
        text: 'status of the beds, summer',
        project: 'garden',
      ))['id'] as int;
      final c = (await open.remember(
        text: 'status of the beds, autumn',
        project: 'garden',
      ))['id'] as int;
      // Text identical to b: dedups onto b and links a -> b.
      final r = await open.supersede(a, text: 'status of the beds, summer');
      expect(r['newId'], b);
      expect(r['newEntryWasDuplicate'], isTrue);
      expect(entries().get(a)!.supersededBy.targetId, b);
      expect(entries().count(), 3);
      // Caveat: a second supersede of a replaces that pointer.
      await open.supersede(a, text: 'status of the beds, autumn');
      expect(entries().get(a)!.supersededBy.targetId, c);
    });
  });

  group('tool', () {
    late TestServer srv;
    setUp(() async => srv = await TestServer.open());
    tearDown(() async => srv.close());

    test('closed schema; unknown rule keys are rejected', () async {
      final tool = await srv.tool('kind_migrate');
      expect(tool.inputSchema.required, ['rules']);
      expect(
        tool.inputSchema.properties!.keys,
        unorderedEquals(['rules', 'fromKinds', 'scope', 'dryRun']),
      );
      expect(tool.inputSchema.additionalProperties, isFalse);
      final bad = await srv.callInvalid('kind_migrate', {
        'rules': [
          {'tags': ['status'], 'kind': 'snapshot', 'convertFrm': ['fact']},
        ],
      });
      expect(
        bad['message'],
        'kind_migrate: unknown field(s) in rule 1: "convertFrm". Allowed: '
        'tags, kind, convertFrom, dropFrom, list, keep.',
      );
      final ok = await srv.callOk('kind_migrate', {
        'rules': [
          {'tags': ['status'], 'kind': 'snapshot'},
        ],
        'dryRun': true,
      });
      expect(ok['notFound'], ['status']);
    });
  });
}
