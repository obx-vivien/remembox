/// Tests for the 0.5.0 link directions: the `partOf` type, the `relation`
/// field on `get`/`recall` links, strict registry mode rejecting the
/// legacy `parent`/`child` types, and the partOf two-way rejection.
///
/// Synthetic data only: project `garden`.
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

const _legacyMessage =
    'link type "child" is not accepted in strict registry mode: its '
    'direction is undefined. Use partOf (A belongs to B): link(fromId: '
    '<the part>, toId: <the whole>, type: "partOf"); a continuation is '
    'supersede, "follows from" is derivedFrom. Nothing was written.';

void main() {
  late Directory tempDir;
  late TestGate testGate;
  late Store store;
  late MemoryService open;
  late MemoryService strict;
  late List<String> logLines;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('remembox_links_');
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

  Future<int> entry(String text) async =>
      (await open.remember(text: text, project: 'garden'))['id'] as int;

  Map<String, Object?> linkOn(Map<String, Object?> got, int linkId) =>
      (got['links'] as List).cast<Map<String, Object?>>().singleWhere(
        (l) => l['linkId'] == linkId,
      );

  test('LinkType: partOf appended, parent/child kept and marked legacy', () {
    expect(LinkType.all, [
      'parent',
      'child',
      'related',
      'contradicts',
      'derivedFrom',
      'partOf',
    ]);
    expect(LinkType.legacy, {'parent', 'child'});
  });

  test('get shows each link from both ends as `relation`, for every type',
      () async {
    final expected = <String, (String, String)>{
      LinkType.partOf: ('partOf', 'hasPart'),
      LinkType.derivedFrom: ('derivedFrom', 'sourceOf'),
      LinkType.contradicts: ('contradicts', 'contradictedBy'),
      LinkType.related: ('related', 'related'),
      LinkType.parent: ('parent', 'parent'),
      LinkType.child: ('child', 'child'),
    };
    for (final MapEntry(key: type, value: (out, inc)) in expected.entries) {
      final a = await entry('part side for $type');
      final b = await entry('whole side for $type');
      final created = await open.link(a, b, type);
      expect(
        created.containsKey('relation'),
        isFalse,
        reason: 'write results keep their shape',
      );
      final linkId = created['linkId'] as int;
      final fromA = linkOn(await open.get(a), linkId);
      expect(fromA['direction'], 'out');
      expect(fromA['type'], type);
      expect(fromA['relation'], out, reason: type);
      final fromB = linkOn(await open.get(b), linkId);
      expect(fromB['direction'], 'in');
      expect(fromB['type'], type);
      expect(fromB['relation'], inc, reason: type);
    }
  });

  test('recall hits carry the relation too', () async {
    final whole = await entry('the whole garden plan');
    final part = await entry('the herb bed, one part of the plan');
    await open.link(part, whole, LinkType.partOf);
    final r = await open.recall(query: 'the whole garden plan', k: 5);
    final hit = (r['hits'] as List).cast<Map<String, Object?>>().singleWhere(
      (h) => h['id'] == whole,
    );
    final link = (hit['links'] as List).single as Map<String, Object?>;
    expect(link['relation'], 'hasPart');
    expect(link['otherId'], part);
  });

  group('strict registry mode rejects parent/child', () {
    for (final type in [LinkType.parent, LinkType.child]) {
      test('link with $type: nothing written, one strict log line', () async {
        final a = await entry('a for $type');
        final b = await entry('b for $type');
        logLines.clear();
        await expectLater(
          strict.link(a, b, type),
          throwsA(
            isA<ValidationException>().having(
              (e) => e.message,
              'message',
              _legacyMessage.replaceAll('"child"', '"$type"'),
            ),
          ),
        );
        expect(store.box<MemoryLink>().count(), 0);
        expect(
          logLines.where(
            (l) => l.startsWith('[registry] strict: rejected link – '),
          ),
          hasLength(1),
        );
      });
    }

    test('remember with a child link: no entry, no link, no embedding',
        () async {
      final target = await entry('existing whole');
      final entriesBefore = store.box<MemoryEntry>().count();
      logLines.clear();
      await expectLater(
        strict.remember(
          text: 'new part via links',
          project: 'garden',
          links: [LinkSpec(toId: target, type: LinkType.child)],
        ),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            _legacyMessage,
          ),
        ),
      );
      expect(store.box<MemoryEntry>().count(), entriesBefore);
      expect(store.box<MemoryLink>().count(), 0);
      expect(
        logLines.where(
          (l) => l.startsWith('[registry] strict: rejected remember – '),
        ),
        hasLength(1),
      );
    });

    test('partOf is accepted in strict mode', () async {
      final whole = await entry('strict whole');
      final r = await strict.remember(
        text: 'strict part',
        project: 'garden',
        links: [LinkSpec(toId: whole, type: LinkType.partOf)],
      );
      expect((r['links'] as List).single, containsPair('type', 'partOf'));
    });
  });

  test('open mode still accepts parent/child', () async {
    final a = await entry('open a');
    final b = await entry('open b');
    final r = await open.link(a, b, LinkType.parent);
    expect(r['duplicate'], isFalse);
    final c = await open.remember(
      text: 'open child via links',
      project: 'garden',
      links: [LinkSpec(toId: a, type: LinkType.child)],
    );
    expect((c['links'] as List).single, containsPair('type', 'child'));
  });

  group('partOf in both directions is rejected', () {
    for (final (mode, label) in [
      (RegistryMode.open, 'open'),
      (RegistryMode.strict, 'strict'),
    ]) {
      test('$label mode, via link', () async {
        final service = mode == RegistryMode.open ? open : strict;
        final whole = await entry('$label whole');
        final part = await entry('$label part');
        await service.link(part, whole, LinkType.partOf);
        logLines.clear();
        await expectLater(
          service.link(whole, part, LinkType.partOf),
          throwsA(
            isA<ValidationException>().having(
              (e) => e.message,
              'message',
              'Entry $part is already partOf entry $whole – partOf in both '
                  'directions would make each part of the other. Nothing was '
                  'written.',
            ),
          ),
        );
        expect(store.box<MemoryLink>().count(), 1);
        expect(
          logLines.where(
            (l) => l.startsWith('[memory] link $whole -(partOf)-> $part '
                'rejected: '),
          ),
          hasLength(1),
        );
        // Other types in the reverse direction stay allowed.
        await service.link(whole, part, LinkType.related);
      });
    }
  });

  test('relatedHint names partOf with its direction', () {
    final hint = MemoryService.relatedHintFor(
      hasItems: true,
      more: 0,
      moreIsLowerBound: false,
    );
    expect(
      hint,
      contains('(related, derivedFrom, contradicts, partOf – A belongs to B)'),
    );
    expect(hint, isNot(contains('parent/child')));
  });

  group('tool texts', () {
    late TestServer srv;
    setUp(() async => srv = await TestServer.open());
    tearDown(() async => srv.close());

    const directions =
        'link(fromId A, toId B, type): derivedFrom – A follows from B; '
        'contradicts – A contradicts B; partOf – A belongs to B (B shows it '
        'as hasPart); related – undirected. parent/child are legacy '
        '(direction undefined): open registry mode only, use partOf. In '
        "remember's links the new entry is A.";

    test('link and remember.links spell out every direction', () async {
      final link = await srv.tool('link');
      expect(link.description, contains(directions));
      expect(link.description, contains('hasPart'));
      final remember = await srv.tool('remember');
      final links =
          remember.inputSchema.properties!['links']! as Map<String, Object?>;
      expect(links['description'], contains(directions));
    });
  });
}
