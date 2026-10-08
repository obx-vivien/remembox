/// `remember`/`supersede` return `related` (similar live entries) and
/// `remember` accepts `links` created atomically with the entry.
///
/// Vectors are registered explicitly on the [FakeEmbedder] (unit vectors in
/// one plane): the cosine between two of them is cos(angle difference), so
/// similarity = (1 + cos) / 2 is exact – 10 degrees apart is 0.992, 50 is
/// 0.821, 60 is 0.75, 90 is 0.5. The thresholds under test are
/// [MemoryService.relatedMinSimilarity] (0.86 = about 43.95 degrees) and
/// [MemoryService.relatedLikelySameSimilarity] (0.90 = about 36.87 degrees).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp/client.dart';
import 'package:remembox/src/embedder.dart';
import 'package:remembox/src/memory_service.dart';
import 'package:remembox/src/model.dart';
import 'package:remembox/src/server.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

import 'helpers/test_store_gate.dart';
import 'support/fake_embedder.dart';

base class _TestClient extends MCPClient {
  _TestClient() : super(Implementation(name: 'test client', version: '0.1'));
}

void main() {
  late Directory tempDir;
  late TestGate testGate;
  late FakeEmbedder embedder;
  late MemoryService service;
  late List<String> logLines;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('remembox_related_test_');
    logLines = [];
    testGate = await openTestGate(tempDir.path, log: logLines.add);
    embedder = FakeEmbedder();
    service = MemoryService(
      gate: testGate.gate,
      embedder: embedder,
      log: logLines.add,
    );
  });

  tearDown(() async {
    await service.dispose();
    await testGate.close();
    tempDir.deleteSync(recursive: true);
  });

  /// Registers [text] at [degrees] in the plane and remembers it.
  Future<Map<String, Object?>> put(
    String text,
    double degrees, {
    String project = 'acme-app',
    List<LinkSpec> links = const [],
  }) {
    embedder.register(text, embedder.planeVector(degrees));
    return service.remember(text: text, project: project, links: links);
  }

  List<Map<String, Object?>> relatedOf(Map<String, Object?> result) => [
    for (final r in (result['related'] as List)) r as Map<String, Object?>,
  ];

  group('related', () {
    test('returns a clearly related same-project entry with its fields', () async {
      final old = await put('acme-app uses Postgres for the backend', 0);
      final result = await put(
        'acme-app backend database is Postgres since March',
        10,
      );

      final related = relatedOf(result);
      expect(related, hasLength(1));
      final r = related.single;
      expect(r['id'], old['id']);
      expect(r['title'], 'acme-app uses Postgres for the backend');
      expect(r['project'], 'acme-app');
      expect(r['kind'], MemoryKind.fact);
      // 10 degrees apart: cos = 0.9848, similarity = (1 + cos) / 2.
      expect(r['similarity'], closeTo(0.992, 0.001));
      expect(DateTime.tryParse(r['createdAt'] as String), isNotNull);
      expect(
        result['relatedHint'],
        MemoryService.relatedHintFor(hasItems: true, more: 0, moreIsLowerBound: false),
      );
      expect(result['relatedHint'], contains('`link`'));
      expect(result['relatedHint'], contains('`supersede`'));
      expect(result['relatedHint'], contains('`fact_set`'));
      expect(result['relatedHint'], contains('likelySameThing'));
      // Nothing was cut off: no count keys.
      expect(result.containsKey('relatedMore'), isFalse);
      expect(result.containsKey('relatedMoreIsLowerBound'), isFalse);
    });

    test('same-project candidates rank before other projects and the cap',
        () async {
      // The other-project entry is MORE similar than all five same-project
      // ones – the project preference must still win, and the cap then
      // leaves it out (counted in relatedMore).
      final other = await put('garden: tomato plan', 1, project: 'garden');
      final same = <int>[];
      for (final deg in [25.0, 28.0, 31.0, 34.0, 37.0]) {
        same.add((await put('acme-app: note at $deg', deg))['id'] as int);
      }
      final result = await put('acme-app: new note', 0);

      final related = relatedOf(result);
      expect(related.map((r) => r['id']), same);
      expect(related.map((r) => r['id']), isNot(contains(other['id'])));
      expect(related.map((r) => r['project']), everyElement('acme-app'));
      expect(result['relatedMore'], 1);
    });

    test('at most 5 are shown and relatedMore counts the rest', () async {
      expect(MemoryService.relatedMax, 5);
      // Seven candidates above the bar, nearest first at 5, 8, ... degrees.
      final ids = <int>[];
      for (var i = 0; i < 7; i++) {
        ids.add((await put('acme-app: note ${i + 1}', 5.0 + 3 * i))['id'] as int);
      }
      final result = await put('acme-app: probe', 0);

      final related = relatedOf(result);
      expect(related.map((r) => r['id']), ids.take(5).toList());
      expect(result['relatedMore'], 2);
      // 7 candidates + the probe are far fewer than the fetch size: the
      // count is exact.
      expect(result.containsKey('relatedMoreIsLowerBound'), isFalse);
      expect(
        result['relatedHint'],
        MemoryService.relatedHintFor(hasItems: true, more: 2, moreIsLowerBound: false),
      );
      expect(result['relatedHint'], contains('2 further'));
      expect(result['relatedHint'], contains('`recall`'));
      final line = logLines.lastWhere((l) => l.contains('related for entry'));
      expect(line, contains('5 shown, 2 more'));
      expect(line, isNot(contains('saturated')));
    });

    test('relatedMore is omitted when exactly the cap qualifies', () async {
      for (var i = 0; i < MemoryService.relatedMax; i++) {
        await put('acme-app: note ${i + 1}', 5.0 + 3 * i);
      }
      final result = await put('acme-app: probe', 0);
      expect(relatedOf(result), hasLength(MemoryService.relatedMax));
      expect(result.containsKey('relatedMore'), isFalse);
      expect(result.containsKey('relatedMoreIsLowerBound'), isFalse);
    });

    test('a saturated candidate fetch reports relatedMore as a lower bound',
        () async {
      // The fetch holds relatedFetchK (20) hits: the probe itself plus the
      // 19 nearest of these 21 entries – all above the bar, so entries
      // beyond the fetch are unknown and the count is only a minimum.
      for (var i = 1; i <= 21; i++) {
        await put('acme-app: note $i', i.toDouble());
      }
      final result = await put('acme-app: probe', 0);

      expect(relatedOf(result), hasLength(MemoryService.relatedMax));
      expect(result['relatedMore'], 19 - MemoryService.relatedMax);
      expect(result['relatedMoreIsLowerBound'], isTrue);
      expect(result['relatedHint'], contains('At least'));
      expect(result['relatedHint'], contains('lower bound'));
      expect(result['relatedHint'], contains('`recall` lists them all'));
      final line = logLines.lastWhere((l) => l.contains('related for entry'));
      expect(line, contains('saturated'));
    });

    test('a full fetch that reaches below the bar is not a lower bound',
        () async {
      // 10 close candidates, then enough far ones to fill the fetch: its
      // farthest hit is below the bar, so everything above it was seen.
      for (var i = 1; i <= 10; i++) {
        await put('acme-app: close $i', i.toDouble());
      }
      for (var i = 0; i < 15; i++) {
        await put('acme-app: far $i', 60.0 + i);
      }
      final result = await put('acme-app: probe', 0);

      expect(relatedOf(result), hasLength(MemoryService.relatedMax));
      expect(result['relatedMore'], 5);
      expect(result.containsKey('relatedMoreIsLowerBound'), isFalse);
      final line = logLines.lastWhere((l) => l.contains('related for entry'));
      expect(line, isNot(contains('saturated')));
      expect(line, contains('20 ANN candidate(s)'));
    });

    test('likelySameThing marks items at or above 0.90 only', () async {
      // 36 degrees = 0.9045 (above), 37.5 = 0.8967 (below 0.90, above the
      // 0.86 bar), 43 = 0.8658 (just above the bar).
      final above = await put('acme-app: well above', 36);
      final below = await put('acme-app: just below', 37.5);
      final nearBar = await put('acme-app: near the bar', 43);
      final close = await put('acme-app: very close', 5);
      final result = await put('acme-app: probe', 0);

      final byId = {for (final r in relatedOf(result)) r['id']: r};
      expect(byId.keys, containsAll([above['id'], below['id'], nearBar['id']]));
      expect(byId[close['id']], containsPair('likelySameThing', true));
      expect(byId[above['id']], containsPair('likelySameThing', true));
      expect(byId[below['id']]!.containsKey('likelySameThing'), isFalse);
      expect(byId[nearBar['id']]!.containsKey('likelySameThing'), isFalse);
      expect(MemoryService.relatedLikelySameSimilarity, 0.90);
    });

    test('likelySameThing uses the unrounded similarity', () async {
      // 36.9 degrees = 0.89984...: rounds to 0.900 in the result, but is
      // below 0.90 and so is not flagged.
      final almost = await put('acme-app: almost there', 36.9);
      final result = await put('acme-app: probe', 0);
      final r = relatedOf(result).single;
      expect(r['id'], almost['id']);
      expect(r['similarity'], 0.9);
      expect(r.containsKey('likelySameThing'), isFalse);
    });

    test('a saturated fetch with few survivors: relatedMore 0 plus the flag',
        () async {
      final ids = <int>[];
      for (var i = 1; i <= 20; i++) {
        ids.add((await put('acme-app: note $i', i.toDouble()))['id'] as int);
      }
      // Leave only 2 live candidates among the 19 nearest.
      for (final id in ids.sublist(2, 19)) {
        await service.forget(id);
      }
      final result = await put('acme-app: probe', 0);

      expect(relatedOf(result), hasLength(2));
      expect(result['relatedMore'], 0);
      expect(result['relatedMoreIsLowerBound'], isTrue);
      expect(
        result['relatedHint'],
        MemoryService.relatedHintFor(
          hasItems: true,
          more: 0,
          moreIsLowerBound: true,
        ),
      );
      expect(result['relatedHint'], contains('may exist'));
    });

    test('saturated and nothing survives: only the saturation sentence',
        () async {
      final ids = <int>[];
      for (var i = 1; i <= 20; i++) {
        ids.add((await put('acme-app: note $i', i.toDouble()))['id'] as int);
      }
      for (final id in ids.sublist(0, 19)) {
        await service.forget(id);
      }
      final result = await put('acme-app: probe', 0);
      expect(result.containsKey('related'), isFalse);
      expect(result['relatedMore'], 0);
      expect(result['relatedMoreIsLowerBound'], isTrue);
      expect(
        result['relatedHint'],
        MemoryService.relatedHintFor(
          hasItems: false,
          more: 0,
          moreIsLowerBound: true,
        ),
      );
      expect(result['relatedHint'], isNot(contains('likelySameThing')));
      expect(result['relatedHint'], contains('`recall` lists them'));
    });

    test('supersede passes the lower-bound flag through', () async {
      final old = await put('acme-app: state v1', 0);
      for (var i = 1; i <= 20; i++) {
        await put('acme-app: sibling $i', 2.0 + i);
      }
      embedder.register('acme-app: state v2', embedder.planeVector(1));
      final result = await service.supersede(
        old['id'] as int,
        text: 'acme-app: state v2',
      );
      expect(result['relatedMoreIsLowerBound'], isTrue);
      expect(result['relatedMore'], greaterThan(0));
    });

    group('weak tier', () {
      // 0.83 = cos 0.66 = 48.7 degrees; 0.80 = cos 0.60 = 53.13 degrees.
      test('the nearest same-project neighbour at ~0.83 is offered as weak',
          () async {
        await put('acme-app: farther neighbour', 52); // 0.809
        final near = await put('acme-app: nearest neighbour', 48.7); // 0.830
        final result = await put('acme-app: probe', 0);

        final r = relatedOf(result).single;
        expect(r['id'], near['id']);
        expect(r['weak'], isTrue);
        expect(r.containsKey('likelySameThing'), isFalse);
        expect(r['similarity'], closeTo(0.83, 0.001));
        expect(result['relatedHint'], contains('weak: true'));
        expect(result['relatedHint'], contains('previous entry'));
        expect(result.containsKey('relatedMore'), isFalse);
        final line = logLines.lastWhere((l) => l.contains('related for entry'));
        expect(line, contains('1 shown (1 weak), 0 more'));
        expect(MemoryService.relatedWeakMinSimilarity, 0.80);
      });

      test('not offered when a same-project candidate reaches the bar',
          () async {
        final strong = await put('acme-app: strong', 40); // 0.883
        await put('acme-app: weakish', 48.7); // 0.830
        final result = await put('acme-app: probe', 0);
        final related = relatedOf(result);
        expect(related.map((r) => r['id']), [strong['id']]);
        expect(related.any((r) => r.containsKey('weak')), isFalse);
        expect(result['relatedHint'], isNot(contains('weak: true')));
      });

      test('never from another project', () async {
        await put('garden: tomato plan', 48.7, project: 'garden');
        final result = await put('acme-app: probe', 0);
        expect(result.containsKey('related'), isFalse);
        expect(result.containsKey('relatedHint'), isFalse);
      });

      test('never below 0.80', () async {
        // 54 degrees = 0.794.
        await put('acme-app: too far', 54);
        final result = await put('acme-app: probe', 0);
        expect(result.containsKey('related'), isFalse);
      });

      test('comes first, takes a slot of the cap and is not in relatedMore',
          () async {
        // Seven other-project candidates above the bar (the weak one is the
        // only same-project neighbour): 1 weak + 4 strong shown, 3 more.
        final weak = await put('acme-app: weak', 48.7);
        for (var i = 0; i < 7; i++) {
          await put('garden: note $i', 5.0 + 3 * i, project: 'garden');
        }
        final result = await put('acme-app: probe', 0);
        final related = relatedOf(result);
        expect(related, hasLength(MemoryService.relatedMax));
        expect(related.first['id'], weak['id']);
        expect(related.first['weak'], isTrue);
        expect(related.skip(1).any((r) => r.containsKey('weak')), isFalse);
        expect(result['relatedMore'], 3);
      });

      test('supersede does not offer the replaced entry as weak', () async {
        final old = await put('acme-app: state v1', 48.7);
        embedder.register('acme-app: state v2', embedder.planeVector(0));
        final result = await service.supersede(
          old['id'] as int,
          text: 'acme-app: state v2',
        );
        expect(result.containsKey('related'), isFalse);
        expect(result.containsKey('relatedHint'), isFalse);
      });
    });

    test('other-project candidates follow the same-project ones', () async {
      final g = await put('garden: tomato plan', 5, project: 'garden');
      final a = await put('acme-app: note one', 40);
      final result = await put('acme-app: new note', 0);
      final related = relatedOf(result);
      expect(related.map((r) => r['id']), [a['id'], g['id']]);
      expect(related.map((r) => r['project']), ['acme-app', 'garden']);
    });

    test('superseded and expired entries are not suggested', () async {
      final superseded = await put('acme-app: old state', 0);
      final expired = await put('acme-app: forgotten note', 5);
      final live = await put('acme-app: live note', 10);
      await service.supersede(
        superseded['id'] as int,
        text: 'acme-app: replaced state',
      );
      await service.forget(expired['id'] as int);

      embedder.register('acme-app: probe', embedder.planeVector(3));
      final result = await service.remember(
        text: 'acme-app: probe',
        project: 'acme-app',
      );
      final ids = relatedOf(result).map((r) => r['id']).toList();
      expect(ids, isNot(contains(superseded['id'])));
      expect(ids, isNot(contains(expired['id'])));
      expect(ids, contains(live['id']));
      final line = logLines.lastWhere((l) => l.contains('related for entry'));
      expect(line, contains('superseded 1'));
      expect(line, contains('expired 1'));
    });

    test('the new entry itself is never returned', () async {
      final result = await put('acme-app: only entry', 0);
      expect(result.containsKey('related'), isFalse);
      expect(result.containsKey('relatedHint'), isFalse);

      final second = await put('acme-app: second entry', 5);
      expect(relatedOf(second).map((r) => r['id']), isNot(contains(second['id'])));
    });

    test('a deduplicated duplicate returns no related and is not suggested',
        () async {
      final first = await put('acme-app: same text', 0);
      await put('acme-app: close neighbour', 5);
      final dupe = await service.remember(
        text: 'acme-app: same text',
        project: 'acme-app',
      );
      expect(dupe['duplicate'], isTrue);
      expect(dupe['id'], first['id']);
      expect(dupe.containsKey('related'), isFalse);
      expect(dupe.containsKey('relatedHint'), isFalse);
    });

    test('candidates below the threshold are excluded and keys omitted',
        () async {
      await put('acme-app: unrelated topic', 70); // cos 0.34, sim 0.67
      final result = await put('acme-app: new topic', 0);
      expect(result.containsKey('related'), isFalse);
      expect(result.containsKey('relatedHint'), isFalse);
    });

    test('the 0.86 bar sits between 43.5 and 44.5 degrees', () async {
      // similarity 0.86 = cos 0.72 = 43.95 degrees from the probe at 0.
      final justIn = await put('acme-app: just in', 43.5); // 0.8627
      await put('acme-app: just out', 44.5); // 0.8566
      final result = await put('acme-app: probe', 0);
      expect(relatedOf(result).map((r) => r['id']), [justIn['id']]);
      expect(MemoryService.relatedMinSimilarity, 0.86);
      final line = logLines.lastWhere((l) => l.contains('related for entry'));
      expect(line, contains('below 0.86 1'));
    });

    test('index rows of another embed model or with a stale hash are skipped',
        () async {
      final otherModel = await put('acme-app: other model', 0);
      final stale = await put('acme-app: stale hash', 2);
      final fine = await put('acme-app: fine', 4);
      final rows = testGate.store.box<MemoryIndex>();
      for (final row in rows.getAll()) {
        if (row.entryId == otherModel['id']) row.embedModel = 'some-other-model';
        if (row.entryId == stale['id']) row.textHash = 'not-the-entry-hash';
        rows.put(row);
      }
      final result = await put('acme-app: probe', 1);
      expect(relatedOf(result).map((r) => r['id']), [fine['id']]);
      final line = logLines.lastWhere((l) => l.contains('related for entry'));
      expect(line, contains('other model 1'));
      expect(line, contains('stale/orphaned 1'));
    });

    test('related titles are framed as untrusted and flag external sources',
        () async {
      embedder.register('acme-app: fetched page', embedder.planeVector(0));
      final fetched = await service.remember(
        text: 'acme-app: fetched page',
        project: 'acme-app',
        sourceType: MemorySource.url,
      );
      final typed = await put('acme-app: typed note', 5);
      final result = await put('acme-app: probe', 2);
      expect(result['_provenance_note'], contains('untrusted'));
      final byId = {for (final r in relatedOf(result)) r['id']: r};
      expect(byId[fetched['id']], containsPair('externallySourced', true));
      expect(byId[typed['id']]!.containsKey('externallySourced'), isFalse);

      // supersede passes both through.
      final old = await put('acme-app: state v1', 60);
      embedder.register('acme-app: state v2', embedder.planeVector(3));
      final superseded = await service.supersede(
        old['id'] as int,
        text: 'acme-app: state v2',
      );
      expect(superseded['_provenance_note'], contains('untrusted'));
      expect(
        (superseded['related'] as List).cast<Map>().map((r) => r['id']),
        contains(fetched['id']),
      );

      // No related, no note.
      final lone = await put('acme-app: far away', 90);
      expect(lone.containsKey('_provenance_note'), isFalse);
    });

    test('search failure: write succeeds, warning present, failure logged',
        () async {
      await put('acme-app: neighbour', 0);
      service.debugBeforeRelatedSearch = () => throw StateError('boom');
      embedder.register('acme-app: after failure', embedder.planeVector(5));
      final result = await service.remember(
        text: 'acme-app: after failure',
        project: 'acme-app',
      );
      service.debugBeforeRelatedSearch = null;

      expect(result['duplicate'], isFalse);
      expect(result['indexed'], isTrue);
      expect(result.containsKey('related'), isFalse);
      expect(result['warning'], contains('related-entries search failed'));
      expect(result['warning'], contains('boom'));
      final stored = testGate.store.box<MemoryEntry>().get(result['id'] as int);
      expect(stored, isNotNull);
      expect(
        logLines.where(
          (l) => l.contains('related search failed') && l.contains('boom'),
        ),
        isNotEmpty,
      );
    });

    test('embedding failure: no related, reason logged', () async {
      embedder.failWith = EmbedderException('ollama down');
      final result = await service.remember(
        text: 'acme-app: not indexed',
        project: 'acme-app',
      );
      embedder.failWith = null;
      expect(result['indexed'], isFalse);
      expect(result.containsKey('related'), isFalse);
      expect(
        logLines.where((l) => l.contains('related search skipped')),
        isNotEmpty,
      );
    });

    test('supersede returns related and does not offer the replaced entry',
        () async {
      final old = await put('acme-app: state v1', 0);
      final sibling = await put('acme-app: sibling note', 8);
      embedder.register('acme-app: state v2', embedder.planeVector(2));
      final result = await service.supersede(
        old['id'] as int,
        text: 'acme-app: state v2',
      );
      expect(result['newId'], isNotNull);
      final ids = [
        for (final r in (result['related'] as List)) (r as Map)['id'],
      ];
      expect(ids, [sibling['id']]);
      expect(ids, isNot(contains(old['id'])));
      expect(
        result['relatedHint'],
        MemoryService.relatedHintFor(hasItems: true, more: 0, moreIsLowerBound: false),
      );
    });

    test('supersede passes likelySameThing and relatedMore through', () async {
      final old = await put('acme-app: state v1', 0);
      for (var i = 0; i < 6; i++) {
        await put('acme-app: sibling ${i + 1}', 3.0 + 3 * i);
      }
      embedder.register('acme-app: state v2', embedder.planeVector(1));
      final result = await service.supersede(
        old['id'] as int,
        text: 'acme-app: state v2',
      );
      final related = [
        for (final r in (result['related'] as List)) r as Map<String, Object?>,
      ];
      expect(related, hasLength(MemoryService.relatedMax));
      expect(related.first, containsPair('likelySameThing', true));
      // 6 siblings, the superseded entry is excluded: 1 more than shown.
      expect(result['relatedMore'], 1);
      expect(result.containsKey('relatedMoreIsLowerBound'), isFalse);
      expect(
        result['relatedHint'],
        MemoryService.relatedHintFor(hasItems: true, more: 1, moreIsLowerBound: false),
      );
    });

    test('supersede without candidates omits the keys', () async {
      final old = await put('acme-app: lonely v1', 0);
      embedder.register('acme-app: lonely v2', embedder.planeVector(90));
      final result = await service.supersede(
        old['id'] as int,
        text: 'acme-app: lonely v2',
      );
      expect(result.containsKey('related'), isFalse);
      expect(result.containsKey('relatedHint'), isFalse);
    });
  });

  group('remember links', () {
    int entryCount() => testGate.store.box<MemoryEntry>().count();
    int linkCount() => testGate.store.box<MemoryLink>().count();

    test('creates links in the same call and lists them', () async {
      final a = await put('alice owns the garden plot', 0, project: 'garden');
      final b = await put('Flat B: key handover', 90, project: 'flat-b');
      final result = await put(
        'alice waters the garden plot on Sundays',
        90,
        project: 'garden',
        links: [
          LinkSpec(toId: a['id'] as int, type: LinkType.related, note: 'same plot'),
          LinkSpec(toId: b['id'] as int, type: LinkType.derivedFrom),
        ],
      );

      final links = (result['links'] as List).cast<Map<String, Object?>>();
      expect(links, hasLength(2));
      expect(links[0]['fromId'], result['id']);
      expect(links[0]['toId'], a['id']);
      expect(links[0]['type'], 'related');
      expect(links[0]['note'], 'same plot');
      expect(links[1]['type'], 'derivedFrom');
      expect(linkCount(), 2);

      final got = await service.get(result['id'] as int);
      final stored = got['links'] as List;
      expect(stored.map((l) => (l as Map)['otherId']), [a['id'], b['id']]);
    });

    test('an unknown toId rejects the whole call, nothing is written',
        () async {
      final a = await put('acme-app: target', 0);
      final before = entryCount();
      await expectLater(
        put('acme-app: would-be entry', 90, links: [
          LinkSpec(toId: a['id'] as int, type: LinkType.related),
          const LinkSpec(toId: 99999, type: LinkType.related),
        ]),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            allOf(contains('Link target'), contains('99999')),
          ),
        ),
      );
      expect(entryCount(), before);
      expect(linkCount(), 0);
    });

    test('an unknown type rejects the whole call, nothing is written',
        () async {
      final a = await put('acme-app: target', 0);
      final before = entryCount();
      await expectLater(
        put('acme-app: would-be entry', 90, links: [
          LinkSpec(toId: a['id'] as int, type: LinkType.related),
          LinkSpec(toId: a['id'] as int, type: 'friend'),
        ]),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            contains('Unknown link type "friend"'),
          ),
        ),
      );
      expect(entryCount(), before);
      expect(linkCount(), 0);
    });

    test('the cap is enforced', () async {
      final a = await put('acme-app: target', 0);
      final id = a['id'] as int;
      final before = entryCount();
      final tooMany = [
        for (var i = 0; i <= MemoryService.maxLinksPerRemember; i++)
          LinkSpec(toId: id, type: LinkType.related, note: 'n$i'),
      ];
      await expectLater(
        put('acme-app: too many links', 90, links: tooMany),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            contains('Too many links'),
          ),
        ),
      );
      expect(entryCount(), before);

      final atCap = await put('acme-app: exactly at cap', 91, links: [
        for (var i = 0; i < MemoryService.maxLinksPerRemember; i++)
          LinkSpec(toId: id, type: LinkType.related, note: 'n$i'),
      ]);
      // Identical (from, to, type) triples collapse into one link: the
      // shared creation path reports the repeats as duplicates.
      final created = (atCap['links'] as List).cast<Map<String, Object?>>();
      expect(created, hasLength(MemoryService.maxLinksPerRemember));
      expect(created.where((l) => l['duplicate'] == false), hasLength(1));
      expect(linkCount(), 1);
    });

    test('a duplicate text creates no links and says so', () async {
      final a = await put('acme-app: target', 0);
      final first = await put('acme-app: existing text', 90);
      final linksBefore = linkCount();
      final dupe = await put('acme-app: existing text', 90, links: [
        LinkSpec(toId: a['id'] as int, type: LinkType.related),
      ]);
      expect(dupe['duplicate'], isTrue);
      expect(dupe['id'], first['id']);
      expect(dupe['warning'], contains('NOT created'));
      expect(linkCount(), linksBefore);
    });

    test('a duplicate text with an invalid link target is still rejected',
        () async {
      await put('acme-app: existing text', 90);
      final before = entryCount();
      await expectLater(
        put('acme-app: existing text', 90, links: [
          const LinkSpec(toId: 99999, type: LinkType.related),
        ]),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            contains('99999'),
          ),
        ),
      );
      expect(entryCount(), before);
      expect(linkCount(), 0);
    });

    test('an over-long note rejects the whole call', () async {
      final a = await put('acme-app: target', 0);
      final before = entryCount();
      await expectLater(
        put('acme-app: would-be entry', 90, links: [
          LinkSpec(
            toId: a['id'] as int,
            type: LinkType.related,
            note: 'x' * 5000,
          ),
        ]),
        throwsA(isA<ValidationException>()),
      );
      expect(entryCount(), before);
    });

    test('the link tool and remember links share one validation path',
        () async {
      final a = await put('acme-app: target', 0);
      final b = await put('acme-app: other', 90);
      final viaTool = await service.link(
        b['id'] as int,
        a['id'] as int,
        LinkType.contradicts,
        note: 'x',
      );
      expect(viaTool['duplicate'], isFalse);
      final again = await service.link(
        b['id'] as int,
        a['id'] as int,
        LinkType.contradicts,
      );
      expect(again['duplicate'], isTrue);
      await expectLater(
        service.link(b['id'] as int, b['id'] as int, LinkType.related),
        throwsA(isA<ValidationException>()),
      );
    });
  });

  group('remember tool (MCP)', () {
    late RememboxServer server;
    late ServerConnection connection;
    late _TestClient client;

    setUp(() async {
      final clientToServer = StreamController<String>();
      final serverToClient = StreamController<String>();
      final serverChannel = StreamChannel<String>.withCloseGuarantee(
        clientToServer.stream,
        serverToClient.sink,
      );
      final clientChannel = StreamChannel<String>.withCloseGuarantee(
        serverToClient.stream,
        clientToServer.sink,
      );
      server = RememboxServer(serverChannel, service: service);
      client = _TestClient();
      connection = client.connectServer(clientChannel);
      await connection.initialize(
        InitializeRequest(
          protocolVersion: ProtocolVersion.latestSupported,
          capabilities: client.capabilities,
          clientInfo: client.implementation,
        ),
      );
      connection.notifyInitialized(InitializedNotification());
      await server.initialized;
    });

    tearDown(() async {
      await client.shutdown();
      await server.shutdown();
    });

    Future<CallToolResult> call(Map<String, Object?> args) =>
        connection.callTool(CallToolRequest(name: 'remember', arguments: args));

    String textOf(CallToolResult r) => (r.content.single as TextContent).text;

    test('links and related travel through the tool', () async {
      final a = await put('acme-app: tool target', 0);
      embedder.register('acme-app: tool entry', embedder.planeVector(4));
      final result = await call({
        'text': 'acme-app: tool entry',
        'project': 'acme-app',
        'links': [
          {'toId': a['id'], 'type': 'related', 'note': 'via tool'},
        ],
      });
      expect(result.isError ?? false, isFalse, reason: textOf(result));
      final json = jsonDecode(textOf(result)) as Map<String, Object?>;
      expect((json['links'] as List).single, containsPair('type', 'related'));
      expect((json['related'] as List).single, containsPair('id', a['id']));
      expect(json['relatedHint'], isA<String>());
    });

    test('malformed links are rejected with an actionable message', () async {
      for (final bad in <Object?>[
        'not a list',
        ['not an object'],
        [
          {'toId': 1}, // no type
        ],
        [
          {'toId': 0, 'type': 'related'},
        ],
        [
          {'toId': 1, 'type': 'related', 'note': 5},
        ],
        [
          {'toId': 1, 'type': 'related', 'nte': 'misspelled key'},
        ],
        [
          {'toId': 1.5, 'type': 'related'},
        ],
      ]) {
        final result = await call({
          'text': 'acme-app: bad links ${bad.hashCode}',
          'project': 'acme-app',
          'links': bad,
        });
        expect(result.isError, isTrue, reason: 'links=$bad');
      }
      expect(testGate.store.box<MemoryEntry>().count(), 0);

      // Per-item errors name the item, not the whole list.
      final badId = await call({
        'text': 'acme-app: bad id',
        'project': 'acme-app',
        'links': [
          {'toId': 0, 'type': 'related'},
        ],
      });
      expect(textOf(badId), contains('item needs an integer'));
      final unknownKey = await call({
        'text': 'acme-app: unknown key',
        'project': 'acme-app',
        'links': [
          {'toId': 1, 'type': 'related', 'nte': 'x'},
        ],
      });
      expect(textOf(unknownKey), contains('nte'));
    });
  });
}
