/// Tests for the tag discipline package (`memory_service_tags.dart`) –
/// 2026-09-21, tag discipline (0.3.0).
///
/// Exercises `_prepareTags` indirectly through `remember`/`supersede` (it is
/// library-private, same rationale as registry_test.dart's coverage note:
/// Dart privacy is per-library and this test file is a separate library) and
/// `tagsList`/`tagMerge`/`tagRemove` directly, since those three are public.
///
/// Synthetic data only: tags `alice`, `bob`, `tax`, `status`, `lesson`,
/// `AppsScript`, `contact`/`contacts`; projects `home`, `acme-app`; areas
/// `work`.
library;

import 'dart:io';
import 'dart:math';

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
    tempDir = Directory.systemTemp.createTempSync('remembox_tags_test_');
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

  Box<Tag> tags() => store.box<Tag>();
  Box<MemoryEntry> entries() => store.box<MemoryEntry>();
  Box<MemoryIndex> index() => store.box<MemoryIndex>();

  List<String> tagNamesOf(Map<String, Object?> rememberResult) {
    final id = rememberResult['id'] as int;
    final entry = entries().get(id)!;
    return entry.tags.map((t) => t.name).toList()..sort();
  }

  String warningOf(Map<String, Object?> result) =>
      (result['warning'] as String?) ?? '';

  group('normalization – camelCase', () {
    final cases = <String, String>{
      'AppsScript': 'appsScript',
      'apps-script': 'appsScript',
      'apps_script': 'appsScript',
      'Apps Script': 'appsScript',
      'Alice': 'alice',
      'KPI': 'kpi',
      'GA4': 'ga4',
      'iso9001': 'iso9001',
      'ISO 9001': 'iso9001',
      'store-gate': 'storeGate',
      // review3 m3 fix: Unicode-aware acronym detection (\p{Lu}/\p{Nd}).
      'ÄÖÜ': 'äöü',
      // review3 m4 fix: split a glued leading acronym off a following
      // capitalized word.
      'GA4Report': 'ga4Report',
      'XMLHttpRequest': 'xmlHttpRequest',
      // Unaffected by m4: a part starting with a lowercase letter is left
      // alone (the split is anchored to the start of a part).
      'iOS': 'iOS',
      'macOS': 'macOS',
    };

    cases.forEach((raw, expected) {
      test('"$raw" normalizes to "$expected"', () async {
        final r = await service.remember(
          text: 'normalization probe for $raw',
          project: 'home',
          tags: [raw],
        );
        expect(tagNamesOf(r), [expected]);
        if (raw != expected) {
          expect(
            warningOf(r),
            contains('Tag "$raw" stored as "$expected"'),
          );
        } else {
          expect(warningOf(r), isNot(contains('stored as')));
        }
      });
    });

    test('"---" normalizes to empty and is dropped with a warning', () async {
      final r = await service.remember(
        text: 'all-separator tag probe',
        project: 'home',
        tags: ['---'],
      );
      expect(tagNamesOf(r), isEmpty);
      expect(warningOf(r), contains('dropped: empty after normalization'));
    });
  });

  group('control characters dropped (2026-09-21, entries move (0.3.0))', () {
    test(
      'a tag with a raw newline is dropped before normalization, with a '
      'sanitized warning',
      () async {
        final poisoned = 'gc${String.fromCharCode(10)}injected';
        final r = await service.remember(
          text: 'control-char tag probe (newline)',
          project: 'home',
          tags: [poisoned],
        );
        expect(tagNamesOf(r), isEmpty);
        expect(warningOf(r), contains('dropped: contains control characters'));
        expect(warningOf(r), isNot(contains(String.fromCharCode(10))));
      },
    );

    test(
      'a tag with an ESC byte is dropped before normalization, with a '
      'sanitized warning',
      () async {
        final poisoned = 'gc${String.fromCharCode(27)}[31mred';
        final r = await service.remember(
          text: 'control-char tag probe (ESC)',
          project: 'home',
          tags: [poisoned],
        );
        expect(tagNamesOf(r), isEmpty);
        expect(warningOf(r), contains('dropped: contains control characters'));
        expect(warningOf(r), isNot(contains(String.fromCharCode(27))));
      },
    );

    test(
      'a tag with a DEL byte (0x7F) is dropped, same as the 0x00-0x1F range',
      () async {
        final poisoned = 'gc${String.fromCharCode(127)}tail';
        final r = await service.remember(
          text: 'control-char tag probe (DEL)',
          project: 'home',
          tags: [poisoned],
        );
        expect(tagNamesOf(r), isEmpty);
        expect(warningOf(r), contains('dropped: contains control characters'));
      },
    );

    test(
      'a clean tag alongside a poisoned one: the clean tag is kept, only '
      'the poisoned one is dropped',
      () async {
        final poisoned = 'bad${String.fromCharCode(1)}tag';
        final r = await service.remember(
          text: 'mixed clean/poisoned tag probe',
          project: 'home',
          tags: ['goodTag', poisoned],
        );
        expect(tagNamesOf(r), ['goodTag']);
        expect(warningOf(r), contains('dropped: contains control characters'));
      },
    );

    test('does not affect tags with no control characters', () async {
      final r = await service.remember(
        text: 'plain tag probe',
        project: 'home',
        tags: ['plainTag'],
      );
      expect(tagNamesOf(r), ['plainTag']);
      expect(warningOf(r), isNot(contains('control character')));
    });
  });

  group('redundant tags dropped', () {
    test('a tag matching the project name is dropped with a warning', () async {
      final r = await service.remember(
        text: 'redundant project tag probe',
        project: 'acme-app',
        tags: ['acmeApp'],
      );
      expect(tagNamesOf(r), isEmpty);
      expect(warningOf(r), contains('matches the project name'));
    });

    test('a tag matching a memory kind is dropped with a warning', () async {
      final r = await service.remember(
        text: 'redundant kind tag probe',
        project: 'home',
        kind: MemoryKind.decision,
        tags: ['decision'],
      );
      expect(tagNamesOf(r), isEmpty);
      expect(warningOf(r), contains('matches a memory kind'));
    });

    test(
      'a tag matching an area the project belongs to is dropped with a '
      'warning',
      () async {
        await service.areaSet(name: 'work');
        await service.projectSet(name: 'home', addAreas: ['work']);
        final r = await service.remember(
          text: 'redundant area tag probe',
          project: 'home',
          tags: ['work'],
        );
        expect(tagNamesOf(r), isEmpty);
        expect(warningOf(r), contains('matches an area'));
      },
    );

    test(
      'redundancy is compared via the loose key, not literal equality '
      '(project "acme-app" vs tag "acmeApp")',
      () async {
        final r = await service.remember(
          text: 'loose-key redundancy probe',
          project: 'acme-app',
          tags: ['acme-app'], // normalizes to "acmeApp" too
        );
        expect(tagNamesOf(r), isEmpty);
        expect(warningOf(r), contains('matches the project name'));
      },
    );
  });

  group('redundancy drops only on exact match (review3 M1/M2 fix)', () {
    test(
      'a project loose-key match (not exact) is kept, at most warned – '
      'project "rul" does NOT drop tag "rule"',
      () async {
        final r = await service.remember(
          text: 'loose-key false-positive probe (rul/rule)',
          project: 'rul',
          tags: ['rule'],
        );
        expect(tagNamesOf(r), ['rule']);
        expect(warningOf(r), isNot(contains('dropped')));
      },
    );

    test('project "not" does NOT drop tag "note"', () async {
      final r = await service.remember(
        text: 'loose-key false-positive probe (not/note)',
        project: 'not',
        tags: ['note'],
      );
      expect(tagNamesOf(r), ['note']);
      expect(warningOf(r), isNot(contains('dropped')));
    });

    test('project "plane" does NOT drop tag "plan"', () async {
      final r = await service.remember(
        text: 'loose-key false-positive probe (plane/plan)',
        project: 'plane',
        tags: ['plan'],
      );
      expect(tagNamesOf(r), ['plan']);
      expect(warningOf(r), isNot(contains('dropped')));
    });

    test('project "new" does NOT drop tag "news"', () async {
      final r = await service.remember(
        text: 'loose-key false-positive probe (new/news)',
        project: 'new',
        tags: ['news'],
      );
      expect(tagNamesOf(r), ['news']);
      expect(warningOf(r), isNot(contains('dropped')));
    });

    test(
      'tag "episodes" on any entry is NOT dropped, but warned as a '
      'near-duplicate of the kind "episode"',
      () async {
        final r = await service.remember(
          text: 'kind loose-key probe (episode/episodes)',
          project: 'home',
          kind: MemoryKind.fact,
          tags: ['episodes'],
        );
        expect(tagNamesOf(r), ['episodes']);
        expect(warningOf(r), isNot(contains('dropped')));
        expect(
          warningOf(r),
          contains('near-duplicate of the kind "episode"'),
        );
      },
    );

    test(
      'exact kind names are still dropped regardless of casing ("decision", '
      '"Decision")',
      () async {
        final r = await service.remember(
          text: 'exact kind match probe',
          project: 'home',
          kind: MemoryKind.fact,
          tags: ['decision', 'Decision'],
        );
        expect(tagNamesOf(r), isEmpty);
        expect(warningOf(r), contains('matches a memory kind ("decision")'));
      },
    );

    test(
      'the kind-drop warning names the kind that MATCHED, not the entry\'s '
      'own kind (review3 M2 fix)',
      () async {
        final r = await service.remember(
          text: 'M2 probe – entry kind differs from matched kind',
          project: 'home',
          kind: MemoryKind.fact,
          tags: ['reference'],
        );
        expect(tagNamesOf(r), isEmpty);
        expect(warningOf(r), contains('matches a memory kind ("reference")'));
        expect(
          warningOf(r),
          isNot(contains('matches a memory kind ("fact")')),
        );
      },
    );
  });

  group('duplicates within one call', () {
    test('identical raw tags collapse silently (no warning)', () async {
      final r = await service.remember(
        text: 'exact duplicate probe',
        project: 'home',
        tags: ['alice', 'alice'],
      );
      expect(tagNamesOf(r), ['alice']);
      expect(warningOf(r), isNot(contains('duplicate')));
    });

    test(
      'differently-spelled raw tags that normalize the same collapse with '
      'a warning',
      () async {
        final r = await service.remember(
          text: 'spelling duplicate probe',
          project: 'home',
          tags: ['Status', 'status'],
        );
        expect(tagNamesOf(r), ['status']);
        expect(warningOf(r), contains('is a duplicate of'));
      },
    );
  });

  group('near-duplicate suggestion', () {
    test(
      'a plural variant of an existing tag warns but is still stored under '
      'its own name',
      () async {
        await service.remember(
          text: 'contact seed',
          project: 'home',
          tags: ['contact'],
        );
        final r = await service.remember(
          text: 'contacts probe',
          project: 'home',
          tags: ['contacts'],
        );
        expect(tagNamesOf(r), ['contacts']);
        expect(
          warningOf(r),
          contains('did you mean the existing "contact"?'),
        );
        // Both tags exist as separate rows – no automatic rewrite.
        expect(tags().count(), 2);
      },
    );

    test(
      'a case variant of an existing tag warns but is still stored under '
      'its own name',
      () async {
        await service.remember(
          text: 'alice seed',
          project: 'home',
          tags: ['alice'],
        );
        final r = await service.remember(
          text: 'Alice probe',
          project: 'home',
          tags: ['Alice'], // normalizes to "alice" itself: exact match
        );
        // "Alice" normalizes to the SAME string "alice" already in the
        // store – this is a re-use of the existing tag, not a near-dup.
        expect(tagNamesOf(r), ['alice']);
        expect(tags().count(), 1);
      },
    );

    test('no near-duplicate warning when the tag already exists exactly', () async {
      await service.remember(text: 'seed', project: 'home', tags: ['alice']);
      final r = await service.remember(
        text: 'reuse probe',
        project: 'home',
        tags: ['alice'],
      );
      expect(warningOf(r), isNot(contains('did you mean')));
    });

    test(
      'multiple new tags in ONE call each get their own correct '
      'near-duplicate suggestion (review3 m7 – the existing-tag key map is '
      'now built once per call, not once per new tag; behavior must stay '
      'identical for more than one new tag at a time)',
      () async {
        await service.remember(text: 'contact seed', project: 'home', tags: ['contact']);
        await service.remember(text: 'lesson seed', project: 'home', tags: ['lesson']);

        final r = await service.remember(
          text: 'two near-dups in one call',
          project: 'home',
          tags: ['contacts', 'lessons'],
        );
        expect(tagNamesOf(r), ['contacts', 'lessons']);
        expect(
          warningOf(r),
          contains('did you mean the existing "contact"?'),
        );
        expect(
          warningOf(r),
          contains('did you mean the existing "lesson"?'),
        );
      },
    );
  });

  group('more than 5 tags', () {
    test('stores all of them but warns once', () async {
      final r = await service.remember(
        text: 'six tags probe',
        project: 'home',
        tags: ['a', 'b', 'c', 'd', 'e', 'f'],
      );
      expect(tagNamesOf(r), ['a', 'b', 'c', 'd', 'e', 'f']);
      expect(warningOf(r), contains('6 tags on one entry'));
      expect(warningOf(r), contains('more than 5 rarely help grouping'));
    });

    test('exactly 5 tags does not warn', () async {
      final r = await service.remember(
        text: 'five tags probe',
        project: 'home',
        tags: ['a', 'b', 'c', 'd', 'e'],
      );
      expect(warningOf(r), isNot(contains('rarely help grouping')));
    });
  });

  group('identifier-like tags', () {
    for (final raw in ['t-42', 'gtd-7', 'phase2', 'b3']) {
      test('"$raw" is stored but warns', () async {
        final r = await service.remember(
          text: 'identifier probe for $raw',
          project: 'home',
          tags: [raw],
        );
        expect(tagNamesOf(r), isNotEmpty);
        expect(
          warningOf(r),
          contains('looks like an identifier or version'),
        );
      });
    }

    test('a version-number-shaped tag warns', () async {
      final r = await service.remember(
        text: 'version probe',
        project: 'home',
        tags: ['5.3.2'],
      );
      expect(tagNamesOf(r), ['5.3.2']);
      expect(warningOf(r), contains('looks like an identifier or version'));
    });

    test(
      'a bare "v"-prefixed version tag (no dot) warns (review3 m5 fix)',
      () async {
        final r = await service.remember(
          text: 'bare v-version probe',
          project: 'home',
          tags: ['v5'],
        );
        expect(tagNamesOf(r), ['v5']);
        expect(warningOf(r), contains('looks like an identifier or version'));
      },
    );

    test('a "v"-prefixed dotted version tag warns', () async {
      final r = await service.remember(
        text: 'v-version-with-dot probe',
        project: 'home',
        tags: ['v5.3'],
      );
      expect(tagNamesOf(r), ['v5.3']);
      expect(warningOf(r), contains('looks like an identifier or version'));
    });

    test('a digits-only tag warns', () async {
      final r = await service.remember(
        text: 'digits probe',
        project: 'home',
        tags: ['2026'],
      );
      expect(tagNamesOf(r), ['2026']);
      expect(warningOf(r), contains('looks like an identifier or version'));
    });

    test('an ordinary word tag does not warn', () async {
      final r = await service.remember(
        text: 'ordinary tag probe',
        project: 'home',
        tags: ['tax'],
      );
      expect(warningOf(r), isNot(contains('identifier or version')));
    });
  });

  group('supersede applies the same rules', () {
    test('normalizes and warns on the new entry exactly like remember', () async {
      final original = await service.remember(
        text: 'original text',
        project: 'home',
        tags: ['alice'],
      );
      final result = await service.supersede(
        original['id'] as int,
        text: 'corrected text',
        tags: ['apps-script'],
      );
      final newId = result['newId'] as int;
      final entry = entries().get(newId)!;
      expect(entry.tags.map((t) => t.name), ['appsScript']);
      expect(warningOf(result), contains('Tag "apps-script" stored as "appsScript"'));
    });
  });

  group('tagsList', () {
    test('reports live usage counts, sorted by count desc then name', () async {
      await service.remember(text: 'e1', project: 'home', tags: ['alice']);
      await service.remember(text: 'e2', project: 'home', tags: ['alice']);
      await service.remember(text: 'e3', project: 'home', tags: ['bob']);

      final r = await service.tagsList();
      final list = (r['tags'] as List).cast<Map<String, Object?>>();
      // `registered`/`description` (tag registry, 2026-10-06) are part
      // of every row; nothing is registered here.
      expect(list, [
        {'name': 'alice', 'count': 2, 'registered': false, 'description': null},
        {'name': 'bob', 'count': 1, 'registered': false, 'description': null},
      ]);
      expect(r['_provenance_note'], isNotNull);
    });

    test('excludes superseded and expired entries from the live count', () async {
      final a = await service.remember(
        text: 'to be superseded',
        project: 'home',
        tags: ['alice'],
      );
      await service.supersede(
        a['id'] as int,
        text: 'the replacement',
        tags: ['alice'],
      );
      final expired = await service.remember(
        text: 'to expire',
        project: 'home',
        tags: ['bob'],
        expiresAt: DateTime.now().toUtc().subtract(const Duration(days: 1)),
      );
      expect(expired['id'], isNotNull);

      final r = await service.tagsList();
      final byName = {
        for (final t in (r['tags'] as List).cast<Map<String, Object?>>())
          t['name']: t['count'],
      };
      // The OLD (superseded) entry no longer counts toward "alice", but the
      // NEW entry from supersede() does.
      expect(byName['alice'], 1);
      expect(byName['bob'], 0);
    });

    test('prefix filters by literal, case-sensitive prefix', () async {
      await service.remember(text: 'e1', project: 'home', tags: ['alice']);
      await service.remember(text: 'e2', project: 'home', tags: ['bob']);

      final r = await service.tagsList(prefix: 'al');
      final list = (r['tags'] as List).cast<Map<String, Object?>>();
      expect(list.map((t) => t['name']), ['alice']);
    });

    test('minCount filters by usage count', () async {
      await service.remember(text: 'e1', project: 'home', tags: ['alice']);
      await service.remember(text: 'e2', project: 'home', tags: ['alice']);
      await service.remember(text: 'e3', project: 'home', tags: ['bob']);

      final r = await service.tagsList(minCount: 2);
      final list = (r['tags'] as List).cast<Map<String, Object?>>();
      expect(list.map((t) => t['name']), ['alice']);
    });

    test('limit caps the returned list but totalMatching reports the full count', () async {
      await service.remember(text: 'e1', project: 'home', tags: ['alice']);
      await service.remember(text: 'e2', project: 'home', tags: ['bob']);

      final r = await service.tagsList(limit: 1);
      final list = (r['tags'] as List).cast<Map<String, Object?>>();
      expect(list, hasLength(1));
      expect(r['totalMatching'], 2);
      expect(r['truncated'], true);
    });

    test(
      'limit defaults to 100 and reports truncated when more exist '
      '(review3 m10 fix)',
      () async {
        for (var i = 0; i < 105; i++) {
          await service.remember(
            text: 'tag flood #$i',
            project: 'home',
            tags: ['tagNumber$i'],
          );
        }

        final r = await service.tagsList();
        final list = (r['tags'] as List).cast<Map<String, Object?>>();
        expect(list, hasLength(100));
        expect(r['totalMatching'], 105);
        expect(r['truncated'], true);
      },
    );

    test('an explicit limit above 500 is rejected (review3 m10 fix)', () async {
      expect(
        () => service.tagsList(limit: 501),
        throwsA(isA<ValidationException>()),
      );
    });

    test('truncated is false when everything fits', () async {
      await service.remember(text: 'e1', project: 'home', tags: ['alice']);
      final r = await service.tagsList();
      expect(r['truncated'], false);
    });

    test('variantGroups groups tags sharing a loose key', () async {
      await service.remember(text: 'e1', project: 'home', tags: ['contact']);
      await service.remember(text: 'e2', project: 'home', tags: ['contacts']);
      await service.remember(text: 'e3', project: 'home', tags: ['tax']);

      final r = await service.tagsList();
      final groups = (r['variantGroups'] as List).cast<Map<String, Object?>>();
      expect(groups, hasLength(1));
      final tagNames = ((groups.single['tags'] as List)
              .cast<Map<String, Object?>>())
          .map((t) => t['name'])
          .toSet();
      expect(tagNames, {'contact', 'contacts'});
    });

    test('unused counts tags with zero live entries', () async {
      final r0 = await service.remember(
        text: 'to be hard-forgotten',
        project: 'home',
        tags: ['alice'],
      );
      await service.forget(r0['id'] as int, hard: true);

      final r = await service.tagsList();
      expect(r['unused'], 1);
    });
  });

  group('tagMerge', () {
    test('replaces from with into on every live entry', () async {
      await service.remember(text: 'e1', project: 'home', tags: ['contact']);
      await service.remember(text: 'e2', project: 'home', tags: ['contacts']);

      final r = await service.tagMerge(from: ['contacts'], into: 'contact');
      expect(r['entriesChanged'], 1);
      expect(r['linksReplaced'], 1);
      expect(r['tagsRemoved'], 1);
      expect(r['dryRun'], false);

      expect(tags().count(), 1);
      expect(tags().getAll().single.name, 'contact');
    });

    test('dryRun reports the same counts but writes nothing', () async {
      await service.remember(text: 'e1', project: 'home', tags: ['contact']);
      await service.remember(text: 'e2', project: 'home', tags: ['contacts']);

      final dry = await service.tagMerge(
        from: ['contacts'],
        into: 'contact',
        dryRun: true,
      );
      expect(dry['entriesChanged'], 1);
      expect(dry['linksReplaced'], 1);
      expect(dry['tagsRemoved'], 1);
      expect(dry['dryRun'], true);

      // Nothing written: both tags still exist, links unchanged.
      expect(tags().count(), 2);

      final real = await service.tagMerge(from: ['contacts'], into: 'contact');
      expect(real['entriesChanged'], dry['entriesChanged']);
      expect(real['linksReplaced'], dry['linksReplaced']);
      expect(real['tagsRemoved'], dry['tagsRemoved']);
    });

    test('includes superseded entries, not only live ones', () async {
      final a = await service.remember(
        text: 'original',
        project: 'home',
        tags: ['contacts'],
      );
      await service.supersede(
        a['id'] as int,
        text: 'replacement, no tags',
        tags: const [],
      );
      // The OLD (now superseded) entry still carries 'contacts'.
      final r = await service.tagMerge(from: ['contacts'], into: 'contact');
      expect(r['entriesChanged'], 1);
      final oldEntry = entries().get(a['id'] as int)!;
      expect(oldEntry.tags.map((t) => t.name), ['contact']);
    });

    test('does not duplicate a link when an entry already has both from and into', () async {
      final r0 = await service.remember(
        text: 'has both',
        project: 'home',
        tags: ['contact'],
      );
      // Add 'contacts' directly via a second remember call is impossible
      // (dedup on text) – attach it via a raw store write instead to
      // simulate an entry that already carries both tags.
      final entry = entries().get(r0['id'] as int)!;
      final contactsTag = Tag(name: 'contacts');
      contactsTag.id = tags().put(contactsTag);
      entry.tags.add(contactsTag);
      entry.tags.applyToDb();
      expect(entry.tags.map((t) => t.name).toSet(), {'contact', 'contacts'});

      await service.tagMerge(from: ['contacts'], into: 'contact');

      final after = entries().get(r0['id'] as int)!;
      expect(after.tags.map((t) => t.name).toList(), ['contact']);
    });

    test('is idempotent – a second run reports zero further changes', () async {
      await service.remember(text: 'e1', project: 'home', tags: ['contact']);
      await service.remember(text: 'e2', project: 'home', tags: ['contacts']);
      await service.tagMerge(from: ['contacts'], into: 'contact');

      // 'contacts' row is gone – a re-run just reports it as notFound.
      final again = await service.tagMerge(from: ['contacts'], into: 'contact');
      expect(again['entriesChanged'], 0);
      expect(again['linksReplaced'], 0);
      expect(again['notFound'], ['contacts']);
    });

    test('unknown from names are reported in notFound, not fatal', () async {
      await service.remember(text: 'e1', project: 'home', tags: ['contact']);
      final r = await service.tagMerge(
        from: ['doesNotExist'],
        into: 'contact',
      );
      expect(r['notFound'], ['doesNotExist']);
      expect(r['entriesChanged'], 0);
    });

    test('"into" in "from" is rejected', () async {
      expect(
        () => service.tagMerge(from: ['contact'], into: 'contact'),
        throwsA(isA<ValidationException>()),
      );
    });

    test(
      'a "from" that merely NORMALIZES to "into" is a literal self-merge '
      'and is still rejected (review3 B1 – "from" contains the exact '
      'normalized "into")',
      () async {
        expect(
          () => service.tagMerge(from: ['alice'], into: 'Alice'),
          throwsA(isA<ValidationException>()),
        );
      },
    );

    test(
      'a legacy pre-normalization row can be merged into its own '
      'normalized form (review3 B1 – a "from" name that merely '
      'NORMALIZES to "into" is allowed; only a literal self-merge is '
      'rejected)',
      () async {
        // Simulate a legacy (pre-camelCase) row: a raw Tag "Alice" created
        // directly via the box, as an older store might have it, linked to
        // an entry the same way `remember` links a tag.
        final seed = await service.remember(
          text: 'legacy row seed',
          project: 'home',
        );
        final legacyTag = Tag(name: 'Alice');
        legacyTag.id = tags().put(legacyTag);
        final seedEntry = entries().get(seed['id'] as int)!
          ..tags.add(legacyTag);
        seedEntry.tags.applyToDb();

        final r = await service.tagMerge(from: ['Alice'], into: 'alice');
        expect(r['entriesChanged'], 1);
        expect(r['tagsRemoved'], 1);
        expect(r['notFound'], isEmpty);

        final after = entries().get(seed['id'] as int)!;
        expect(after.tags.map((t) => t.name), ['alice']);
        expect(tags().getAll().map((t) => t.name).toList(), ['alice']);
      },
    );

    test(
      'a legacy kebab-case row can be merged into its camelCase '
      'normalized form (review3 B1 – "apps-script" -> "appsScript")',
      () async {
        final seed = await service.remember(
          text: 'legacy kebab seed',
          project: 'home',
        );
        final legacyTag = Tag(name: 'apps-script');
        legacyTag.id = tags().put(legacyTag);
        final seedEntry = entries().get(seed['id'] as int)!
          ..tags.add(legacyTag);
        seedEntry.tags.applyToDb();

        final r = await service.tagMerge(
          from: ['apps-script'],
          into: 'appsScript',
        );
        expect(r['entriesChanged'], 1);
        expect(r['tagsRemoved'], 1);

        final after = entries().get(seed['id'] as int)!;
        expect(after.tags.map((t) => t.name), ['appsScript']);
      },
    );

    test(
      'a mixed list of legacy spelling variants all merge into one '
      'normalized target, no duplicate links, legacy rows removed '
      '(review3 B1)',
      () async {
        final e1 = await service.remember(text: 'mixed variant e1', project: 'home');
        final e2 = await service.remember(text: 'mixed variant e2', project: 'home');
        final e3 = await service.remember(text: 'mixed variant e3', project: 'home');
        // Three legacy rows an older store (or the B1 `tag_merge` bug
        // itself) might have produced for the "same" tag.
        final rowAlice = Tag(name: 'Alice');
        rowAlice.id = tags().put(rowAlice);
        final rowALICE = Tag(name: 'ALICE');
        rowALICE.id = tags().put(rowALICE);
        final rowAliceX = Tag(name: 'alice-x');
        rowAliceX.id = tags().put(rowAliceX);

        void link(Map<String, Object?> r, Tag t) {
          final e = entries().get(r['id'] as int)!..tags.add(t);
          e.tags.applyToDb();
        }

        link(e1, rowAlice);
        link(e2, rowALICE);
        link(e3, rowAliceX);

        final r = await service.tagMerge(
          from: ['Alice', 'ALICE', 'alice-x'],
          into: 'alice',
        );
        expect(r['entriesChanged'], 3);
        expect(r['tagsRemoved'], 3);
        expect(r['notFound'], isEmpty);

        expect(entries().get(e1['id'] as int)!.tags.map((t) => t.name), [
          'alice',
        ]);
        expect(entries().get(e2['id'] as int)!.tags.map((t) => t.name), [
          'alice',
        ]);
        expect(entries().get(e3['id'] as int)!.tags.map((t) => t.name), [
          'alice',
        ]);
        expect(tags().getAll().map((t) => t.name).toList(), ['alice']);
      },
    );

    test(
      '"into" containing control characters is rejected (review3 M3 fix)',
      () async {
        final poisonedInto = 'bad${String.fromCharCode(27)}[31mtag';
        await service.remember(text: 'e1', project: 'home', tags: ['rules']);
        expect(
          () => service.tagMerge(from: ['rules'], into: poisonedInto),
          throwsA(isA<ValidationException>()),
        );
        // Nothing written: no Tag row carries the control character.
        for (final t in tags().getAll()) {
          expect(
            t.name.codeUnits.any((c) => c < 32 || c == 127),
            isFalse,
            reason: 'no stored tag name may contain a control character',
          );
        }
      },
    );

    test(
      '"into" matching a memory kind is warned about, not silently '
      'accepted (review3 M3 fix / review m8)',
      () async {
        await service.remember(text: 'e1', project: 'home', tags: ['rules']);
        final r = await service.tagMerge(from: ['rules'], into: 'decision');
        expect(r['into'], 'decision');
        expect(
          (r['warning'] as String?) ?? '',
          contains('matches a memory kind ("decision")'),
        );
        // Still performs the merge – a warning, not a rejection.
        expect(tags().getAll().single.name, 'decision');
      },
    );

    test(
      '"into" that looks like an identifier/version is warned about '
      '(review3 M3 fix)',
      () async {
        await service.remember(text: 'e1', project: 'home', tags: ['rules']);
        final r = await service.tagMerge(from: ['rules'], into: 'gtd-7');
        expect(
          (r['warning'] as String?) ?? '',
          contains('looks like an identifier or version'),
        );
      },
    );

    test('"into" normalizes to camelCase and is created if missing', () async {
      await service.remember(text: 'e1', project: 'home', tags: ['contacts']);
      final r = await service.tagMerge(from: ['contacts'], into: 'my-contact');
      expect(r['into'], 'myContact');
      expect(tags().getAll().single.name, 'myContact');
    });

    test('does not touch entry text, contentHash or the vector index', () async {
      final a = await service.remember(
        text: 'unaffected text',
        project: 'home',
        tags: ['contacts'],
      );
      final id = a['id'] as int;
      final beforeHash = entries().get(id)!.contentHash;
      final beforeIndexCount = index().count();

      await service.tagMerge(from: ['contacts'], into: 'contact');

      final after = entries().get(id)!;
      expect(after.text, 'unaffected text');
      expect(after.contentHash, beforeHash);
      expect(index().count(), beforeIndexCount);
    });
  });

  group('tagRemove', () {
    test('unlinks and deletes the given tags', () async {
      await service.remember(text: 'e1', project: 'home', tags: ['alice']);
      final r = await service.tagRemove(tags: ['alice']);
      expect(r['entriesChanged'], 1);
      expect(r['linksRemoved'], 1);
      expect(r['tagsRemoved'], 1);
      expect(r['dryRun'], false);
      expect(tags().count(), 0);
    });

    test('dryRun reports the same counts but writes nothing', () async {
      await service.remember(text: 'e1', project: 'home', tags: ['alice']);
      final dry = await service.tagRemove(tags: ['alice'], dryRun: true);
      expect(dry['entriesChanged'], 1);
      expect(dry['linksRemoved'], 1);
      expect(dry['tagsRemoved'], 1);
      expect(tags().count(), 1);

      final real = await service.tagRemove(tags: ['alice']);
      expect(real['entriesChanged'], dry['entriesChanged']);
      expect(real['linksRemoved'], dry['linksRemoved']);
      expect(real['tagsRemoved'], dry['tagsRemoved']);
    });

    test('unknown names are reported in notFound, not fatal', () async {
      final r = await service.tagRemove(tags: ['doesNotExist']);
      expect(r['notFound'], ['doesNotExist']);
      expect(r['entriesChanged'], 0);
      expect(r['tagsRemoved'], 0);
    });

    test('does not touch entry text, contentHash or the vector index', () async {
      final a = await service.remember(
        text: 'unaffected text 2',
        project: 'home',
        tags: ['bob'],
      );
      final id = a['id'] as int;
      final beforeHash = entries().get(id)!.contentHash;
      final beforeIndexCount = index().count();

      await service.tagRemove(tags: ['bob']);

      final after = entries().get(id)!;
      expect(after.text, 'unaffected text 2');
      expect(after.contentHash, beforeHash);
      expect(index().count(), beforeIndexCount);
    });
  });

  // -------------------------------------------------------------------
  // review4 N1: digit-led normalization idempotency
  // (`_normalizeTag` used to case-adjust by PART INDEX, so a leading
  // digit-only part consumed "first position" and the next part got
  // upper-cased on the FIRST pass but not the second – red on 96b009c,
  // green after the "first position = no letter in the output yet" fix).
  // -------------------------------------------------------------------
  group('digit-led normalization is idempotent (review4 N1 fix)', () {
    final cases = <String, String>{
      '3 D Printing': '3dPrinting',
      '2026 Q3': '2026q3',
      '5 G': '5g',
      '4 K': '4k',
    };

    cases.forEach((raw, expected) {
      test('"$raw" normalizes to "$expected" and is stable on re-remember', () async {
        final r = await service.remember(
          text: 'N1 probe for $raw',
          project: 'home',
          tags: [raw],
        );
        final stored = tagNamesOf(r).single;
        expect(stored, expected);

        // Idempotency: re-remembering the STORED name must not change it
        // again (no "stored as" warning on the second pass).
        final r2 = await service.remember(
          text: 'N1 re-remember probe for $raw',
          project: 'home',
          tags: [stored],
        );
        expect(tagNamesOf(r2), [stored]);
        expect(warningOf(r2), isNot(contains('stored as')));
      });
    });
  });

  // -------------------------------------------------------------------
  // review4 N2: acronym plurals no longer get glue-split
  // ("APIs" used to split into "AP"+"Is" -> "apIs" – red on 96b009c, green
  // after the acronym-plural guard checked BEFORE the glued-acronym split).
  // -------------------------------------------------------------------
  group('acronym plurals normalize as a whole (review4 N2 fix)', () {
    final cases = <String, String>{
      'APIs': 'apis',
      'PDFs': 'pdfs',
      'URLs': 'urls',
      'LLMs': 'llms',
      'IDs': 'ids',
    };

    cases.forEach((raw, expected) {
      test('"$raw" normalizes to "$expected" and is stable on re-remember', () async {
        final r = await service.remember(
          text: 'N2 probe for $raw',
          project: 'home',
          tags: [raw],
        );
        final stored = tagNamesOf(r).single;
        expect(stored, expected);

        final r2 = await service.remember(
          text: 'N2 re-remember probe for $raw',
          project: 'home',
          tags: [stored],
        );
        expect(tagNamesOf(r2), [stored]);
        expect(warningOf(r2), isNot(contains('stored as')));
      });
    });

    test(
      'a glued acronym immediately followed by a real word is unaffected '
      '(e.g. "MCPServer" -> "mcpServer", not treated as an acronym plural)',
      () async {
        final r = await service.remember(
          text: 'N2 regression probe (MCPServer)',
          project: 'home',
          tags: ['MCPServer'],
        );
        expect(tagNamesOf(r), ['mcpServer']);
      },
    );
  });

  // -------------------------------------------------------------------
  // review4 N1 property test: fixed-seed fuzz over ASCII/German/digit/
  // separator/acronym/camel-hump input, asserting normalize(normalize(x))
  // == normalize(x) for every generated string, and that no stored tag
  // ever contains a leftover whitespace/-/_.
  // -------------------------------------------------------------------
  group('normalization idempotency property test (review4 N1 fix)', () {
    test(
      'idempotency holds for >=2000 generated strings (fixed seed 42), and '
      'no stored tag contains whitespace/-/_',
      () async {
        final rnd = Random(42);
        const alphabet = [
          'A', 'B', 'X', 'M', 'L', 'a', 'b', 'x', 'o', 's', 'e', 'n',
          '1', '4', '0',
          'Ä', 'ö', 'ß', 'Ü', 'ä', 'É', 'İ',
          ' ', '-', '_',
        ];
        final raws = <String>{};
        while (raws.length < 2000) {
          final len = 1 + rnd.nextInt(12);
          final s = List.generate(
            len,
            (_) => alphabet[rnd.nextInt(alphabet.length)],
          ).join();
          if (s.trim().replaceAll(RegExp(r'[\s\-_]'), '').isEmpty) continue;
          raws.add(s);
        }
        expect(raws.length, greaterThanOrEqualTo(2000));

        // Round 1: normalize every generated raw string via remember(),
        // batched well under the per-call tag cap (64) to keep the call
        // count down. The returned tag SET (not list) is what we check –
        // remember()'s own Step 1 already dedupes exact-normalized
        // collisions within one call, which is fine here.
        final rawList = raws.toList(growable: false);
        final n1 = <String>{};
        for (var i = 0; i < rawList.length; i += 60) {
          final end = (i + 60 < rawList.length) ? i + 60 : rawList.length;
          final batch = rawList.sublist(i, end);
          final r = await service.remember(
            text: 'N1 property round1 batch $i',
            project: 'fuzz',
            tags: batch,
          );
          n1.addAll(entries().get(r['id'] as int)!.tags.map((t) => t.name));
        }
        expect(n1, isNotEmpty);

        // No leftover separator in any normalized output.
        for (final tag in n1) {
          expect(
            RegExp(r'[\s\-_]').hasMatch(tag),
            isFalse,
            reason: 'normalized tag "$tag" still contains a separator',
          );
        }

        // Round 2: re-normalize every DISTINCT round-1 output. Since every
        // value in n1 is already normalized, an idempotent normalizer must
        // return the batch UNCHANGED (as a set) – any drift (a value that
        // moved, or two values that collapsed into one) fails the
        // assertion below and names the batch.
        final n1List = n1.toList(growable: false);
        for (var i = 0; i < n1List.length; i += 60) {
          final end = (i + 60 < n1List.length) ? i + 60 : n1List.length;
          final batch = n1List.sublist(i, end);
          final r = await service.remember(
            text: 'N1 property round2 batch $i',
            project: 'fuzz',
            tags: batch,
          );
          final n2 = entries()
              .get(r['id'] as int)!
              .tags
              .map((t) => t.name)
              .toSet();
          expect(
            n2,
            batch.toSet(),
            reason:
                'normalize(normalize(x)) != normalize(x) somewhere in batch '
                'starting at $i: got $n2, expected ${batch.toSet()}',
          );
        }
      },
    );
  });

  // -------------------------------------------------------------------
  // review4 N3: loose-key stem-length gate.
  //
  // The literal review4 fix ("strip a trailing suffix only if the
  // remaining stem is >= 3 characters") is what is implemented and tested
  // here. It is proven (see the worktree's implementation notes) to remove
  // the previously-empty-string key collision (en/es) and the open/ops
  // collision, while PRESERVING every correct grouping (idee/ideen,
  // test/tests, issue/issues, skill/skills, kontakt/kontakte,
  // apps-script/AppsScript). A uniform length threshold cannot ALSO split
  // every short unrelated pair that happens to end in the same letters
  // (e.g. rate/rat, date/daten, plan/plane, token/tok, new/news, code/cod)
  // without ALSO breaking idee/ideen-class correctness – those two classes
  // are numerically identical (same stem length, same suffix shape) but
  // require opposite outcomes, which is mathematically impossible for any
  // rule based only on generic string-length properties. This is a
  // WARNING-only signal (never a drop), so the residual collisions are a
  // cosmetic near-duplicate suggestion, not a correctness bug.
  // -------------------------------------------------------------------
  group('loose-key stem-length gate (review4 N3 fix)', () {
    Future<Set<String>?> variantGroupFor(String tagName) async {
      final l = await service.tagsList();
      final groups = (l['variantGroups'] as List).cast<Map<String, Object?>>();
      for (final g in groups) {
        final names = ((g['tags'] as List).cast<Map<String, Object?>>())
            .map((t) => t['name'] as String)
            .toSet();
        if (names.contains(tagName)) return names;
      }
      return null;
    }

    test('"en" and "es" are no longer grouped (empty-key collision removed)', () async {
      await service.remember(text: 'e1', project: 'home', tags: ['en']);
      await service.remember(text: 'e2', project: 'home', tags: ['es']);
      expect(await variantGroupFor('en'), isNull);
      expect(await variantGroupFor('es'), isNull);
    });

    test('"open" and "ops" are no longer grouped', () async {
      await service.remember(text: 'e1', project: 'home', tags: ['open']);
      await service.remember(text: 'e2', project: 'home', tags: ['ops']);
      expect(await variantGroupFor('open'), isNull);
      expect(await variantGroupFor('ops'), isNull);
    });

    test('"test" and "tests" are still grouped', () async {
      await service.remember(text: 'e1', project: 'home', tags: ['test']);
      await service.remember(text: 'e2', project: 'home', tags: ['tests']);
      expect(await variantGroupFor('test'), {'test', 'tests'});
    });

    test('"issue" and "issues" are still grouped', () async {
      await service.remember(text: 'e1', project: 'home', tags: ['issue']);
      await service.remember(text: 'e2', project: 'home', tags: ['issues']);
      expect(await variantGroupFor('issue'), {'issue', 'issues'});
    });

    test('"skill" and "skills" are still grouped', () async {
      await service.remember(text: 'e1', project: 'home', tags: ['skill']);
      await service.remember(text: 'e2', project: 'home', tags: ['skills']);
      expect(await variantGroupFor('skill'), {'skill', 'skills'});
    });

    test('"kontakt" and "kontakte" are still grouped', () async {
      await service.remember(text: 'e1', project: 'home', tags: ['kontakt']);
      await service.remember(text: 'e2', project: 'home', tags: ['kontakte']);
      expect(await variantGroupFor('kontakt'), {'kontakt', 'kontakte'});
    });

    test(
      '"apps-script" and "AppsScript" are grouped (both normalize to the '
      'identical string "appsScript" – trivially one group of one name, '
      'not a variantGroups entry, but tagsList reports a single row)',
      () async {
        final r = await service.remember(
          text: 'e1',
          project: 'home',
          tags: ['apps-script', 'AppsScript'],
        );
        expect(tagNamesOf(r), ['appsScript']);
      },
    );
  });

  // -------------------------------------------------------------------
  // review4 N4: duplicate literal names in tag_merge "from" / tag_remove
  // "tags" are deduped before counting, so a repeated name isn't
  // matched/removed/counted twice.
  // -------------------------------------------------------------------
  group('tag_merge dedupes literal "from" entries (review4 N4 fix)', () {
    test('a duplicated "from" name counts the row exactly once', () async {
      await service.remember(text: 'e1', project: 'home', tags: ['bob']);
      final r = await service.tagMerge(from: ['bob', 'bob'], into: 'robert');
      expect(r['tagsRemoved'], 1);
      expect(r['entriesChanged'], 1);
      expect(tags().count(), 1);
      expect(tags().getAll().single.name, 'robert');
    });

    test('dryRun also reports the deduped count', () async {
      await service.remember(text: 'e1', project: 'home', tags: ['bob']);
      final dry = await service.tagMerge(
        from: ['bob', 'bob', 'bob'],
        into: 'robert',
        dryRun: true,
      );
      expect(dry['tagsRemoved'], 1);
      expect(dry['entriesChanged'], 1);
    });
  });

  group('tag_remove dedupes literal "tags" entries (review4 N4 fix)', () {
    test('a duplicated name counts the row exactly once', () async {
      await service.remember(text: 'e1', project: 'home', tags: ['alice']);
      final r = await service.tagRemove(tags: ['alice', 'alice']);
      expect(r['tagsRemoved'], 1);
      expect(r['entriesChanged'], 1);
      expect(tags().count(), 0);
    });

    test('dryRun also reports the deduped count', () async {
      await service.remember(text: 'e1', project: 'home', tags: ['alice']);
      final dry = await service.tagRemove(
        tags: ['alice', 'alice'],
        dryRun: true,
      );
      expect(dry['tagsRemoved'], 1);
      expect(dry['entriesChanged'], 1);
    });
  });

  // -------------------------------------------------------------------
  // review4 m8: tag_merge's "into" now also gets the LOOSE-key kind
  // near-duplicate warning (_prepareTags Step 2b's counterpart), not only
  // the exact-match kind warning it already had.
  // -------------------------------------------------------------------
  group('tag_merge "into" loose-key kind warning (review4 m8 fix)', () {
    test(
      '"into: decisions" (loose key of kind "decision") warns as a '
      'near-duplicate, same wording _prepareTags Step 2b uses for an '
      'ordinary tag',
      () async {
        await service.remember(text: 'e1', project: 'home', tags: ['rules']);
        final r = await service.tagMerge(from: ['rules'], into: 'decisions');
        expect(
          (r['warning'] as String?) ?? '',
          contains('near-duplicate of the kind "decision"'),
        );
        // Still performs the merge – a warning, not a rejection.
        expect(tags().getAll().single.name, 'decisions');
      },
    );

    test(
      'an EXACT kind match still reports the exact-match wording, not the '
      'loose one (no double warning for the same target)',
      () async {
        await service.remember(text: 'e1', project: 'home', tags: ['rules']);
        final r = await service.tagMerge(from: ['rules'], into: 'decision');
        final warning = (r['warning'] as String?) ?? '';
        expect(warning, contains('matches a memory kind ("decision")'));
        expect(warning, isNot(contains('near-duplicate of the kind')));
      },
    );
  });

  // -------------------------------------------------------------------
  // review4: tagsList reports `total` alongside `truncated`, not only the
  // pre-existing `totalMatching`.
  // -------------------------------------------------------------------
  group('tagsList "total" field (review4 fix)', () {
    test('total equals totalMatching and reflects filters, not limit', () async {
      await service.remember(text: 'e1', project: 'home', tags: ['alice']);
      await service.remember(text: 'e2', project: 'home', tags: ['bob']);

      final r = await service.tagsList(limit: 1);
      expect(r['total'], 2);
      expect(r['total'], r['totalMatching']);
      expect(r['truncated'], true);
    });
  });

  // -------------------------------------------------------------------
  // tagsNormalize – 2026-09-21, tag discipline (0.3.0) final package.
  // -------------------------------------------------------------------
  group('tagsNormalize', () {
    // Simulates a pre-0.3.0 store: raw Tag rows written directly via the
    // box (bypassing _prepareTags entirely), exactly like the legacy-row
    // simulation tagMerge's own tests use.
    Tag putTag(String name) {
      final t = Tag(name: name);
      t.id = tags().put(t);
      return t;
    }

    void link(Map<String, Object?> r, Tag t) {
      final e = entries().get(r['id'] as int)!..tags.add(t);
      e.tags.applyToDb();
    }

    test(
      'the full legacy-store scenario: multiple spellings collapse, an '
      'already-normalized row is a merge target not a rename, links are '
      'preserved with no duplicates, vector index/contentHash untouched',
      () async {
        final e1 = await service.remember(text: 'e1', project: 'home');
        final e2 = await service.remember(text: 'e2', project: 'home');
        final e3 = await service.remember(text: 'e3', project: 'home');
        final e4 = await service.remember(text: 'e4', project: 'home');
        final e5 = await service.remember(text: 'e5', project: 'home');

        final rowAlice = putTag('Alice');
        final rowALICE = putTag('ALICE');
        final rowAppsScript1 = putTag('apps-script');
        final rowAppsScript2 = putTag('AppsScript');
        final rowKPI = putTag('KPI');
        final rowKpi = putTag('kpi'); // already normalized – pre-existing
        putTag('2026 Q3'); // deliberately left unlinked to any entry
        putTag('APIs'); // deliberately left unlinked to any entry

        link(e1, rowAlice);
        link(e1, rowALICE); // same entry carries BOTH Alice spellings
        link(e2, rowALICE);
        link(e3, rowAppsScript1);
        link(e4, rowAppsScript2);
        link(e5, rowKPI);
        link(e5, rowKpi); // same entry carries BOTH kpi spellings
        // row2026Q3 and rowAPIs deliberately left unlinked to any entry.

        final beforeHash = entries().get(e1['id'] as int)!.contentHash;
        final beforeIndexCount = index().count();

        final r = await service.tagsNormalize();

        final renamed = (r['renamed'] as List).cast<Map<String, Object?>>();
        final renamedFrom = renamed.map((e) => e['from']).toSet();
        expect(renamedFrom, {
          'Alice',
          'ALICE',
          'apps-script',
          'AppsScript',
          'KPI',
          '2026 Q3',
          'APIs',
        });
        expect(renamed.length, 7);
        for (final row in renamed) {
          final into = row['into'];
          if (row['from'] == 'Alice' || row['from'] == 'ALICE') {
            expect(into, 'alice');
          } else if (row['from'] == 'apps-script' ||
              row['from'] == 'AppsScript') {
            expect(into, 'appsScript');
          } else if (row['from'] == 'KPI') {
            expect(into, 'kpi');
          } else if (row['from'] == '2026 Q3') {
            expect(into, '2026q3');
          } else if (row['from'] == 'APIs') {
            expect(into, 'apis');
          }
        }
        // entries: Alice used on e1 only (1), ALICE used on e1+e2 (2),
        // apps-script on e3 (1), AppsScript on e4 (1), KPI on e5 (1),
        // 2026 Q3/APIs unused (0).
        final entriesByFrom = {
          for (final row in renamed) row['from']: row['entries'],
        };
        expect(entriesByFrom['Alice'], 1);
        expect(entriesByFrom['ALICE'], 2);
        expect(entriesByFrom['apps-script'], 1);
        expect(entriesByFrom['AppsScript'], 1);
        expect(entriesByFrom['KPI'], 1);
        expect(entriesByFrom['2026 Q3'], 0);
        expect(entriesByFrom['APIs'], 0);

        // "KPI" folded into the ALREADY-EXISTING "kpi" row -> counts
        // toward `merged`. "Alice"/"ALICE" and "apps-script"/"AppsScript"
        // both collapse into BRAND-NEW targets -> do not count.
        expect(r['merged'], 1);
        expect(r['skipped'], isEmpty);
        expect(r['tagsRemoved'], 7);
        expect(r['dryRun'], false);

        // Exactly the normalized rows remain.
        expect(
          tags().getAll().map((t) => t.name).toSet(),
          {'alice', 'appsScript', 'kpi', '2026q3', 'apis'},
        );

        // Links preserved, no duplicates: e1 had BOTH Alice+ALICE (now
        // both -> 'alice') and must end up with 'alice' exactly ONCE.
        expect(
          entries().get(e1['id'] as int)!.tags.map((t) => t.name).toList(),
          ['alice'],
        );
        expect(
          entries().get(e2['id'] as int)!.tags.map((t) => t.name).toList(),
          ['alice'],
        );
        expect(
          entries().get(e3['id'] as int)!.tags.map((t) => t.name).toList(),
          ['appsScript'],
        );
        expect(
          entries().get(e4['id'] as int)!.tags.map((t) => t.name).toList(),
          ['appsScript'],
        );
        // e5 had BOTH KPI+kpi (now both -> 'kpi') -> exactly once.
        expect(
          entries().get(e5['id'] as int)!.tags.map((t) => t.name).toList(),
          ['kpi'],
        );

        // Vector index and contentHash untouched.
        expect(entries().get(e1['id'] as int)!.contentHash, beforeHash);
        expect(index().count(), beforeIndexCount);
      },
    );

    test('dryRun reports the same result but writes nothing', () async {
      final e1 = await service.remember(text: 'e1', project: 'home');
      final legacy = putTag('Alice');
      link(e1, legacy);

      final dry = await service.tagsNormalize(dryRun: true);
      expect(dry['dryRun'], true);
      final dryRenamed = (dry['renamed'] as List).single as Map<String, Object?>;
      expect(dryRenamed['from'], 'Alice');
      expect(dryRenamed['into'], 'alice');
      expect(dryRenamed['entries'], 1);
      expect(dry['merged'], 0);
      expect(dry['tagsRemoved'], 1);

      // Nothing written.
      expect(tags().getAll().map((t) => t.name).toList(), ['Alice']);

      final real = await service.tagsNormalize();
      expect(real['renamed'], dry['renamed']);
      expect(real['merged'], dry['merged']);
      expect(real['tagsRemoved'], dry['tagsRemoved']);
    });

    test(
      'is idempotent: a second run changes nothing once every row is '
      'normalized',
      () async {
        final e1 = await service.remember(text: 'e1', project: 'home');
        link(e1, putTag('Alice'));
        await service.tagsNormalize();

        final again = await service.tagsNormalize();
        expect(again['renamed'], isEmpty);
        expect(again['merged'], 0);
        expect(again['skipped'], isEmpty);
        expect(again['tagsRemoved'], 0);
        expect(tags().getAll().map((t) => t.name).toList(), ['alice']);
      },
    );

    test(
      'a row whose normalized form is empty is skipped with a reason, not '
      'touched',
      () async {
        final e1 = await service.remember(text: 'e1', project: 'home');
        link(e1, putTag('---')); // normalizes to '' (all separators)

        final r = await service.tagsNormalize();
        expect(r['renamed'], isEmpty);
        final skipped = (r['skipped'] as List).cast<Map<String, Object?>>();
        expect(skipped, hasLength(1));
        expect(skipped.single['name'], '---');
        expect(skipped.single['reason'], contains('empty after normalization'));
        expect(tags().getAll().map((t) => t.name).toList(), ['---']);
        expect(
          entries().get(e1['id'] as int)!.tags.map((t) => t.name).toList(),
          ['---'],
        );
      },
    );

    test(
      'a row whose normalized form contains control characters is skipped '
      'with a reason, not touched',
      () async {
        final poisoned = 'bad${String.fromCharCode(27)}tag';
        final e1 = await service.remember(text: 'e1', project: 'home');
        link(e1, putTag(poisoned));

        final r = await service.tagsNormalize();
        expect(r['renamed'], isEmpty);
        final skipped = (r['skipped'] as List).cast<Map<String, Object?>>();
        expect(skipped, hasLength(1));
        expect(skipped.single['reason'], contains('control characters'));
        // The echoed name in the skip report is sanitized (no raw ESC byte).
        expect(
          (skipped.single['name'] as String).contains(String.fromCharCode(27)),
          isFalse,
        );
        expect(tags().getAll().map((t) => t.name).toList(), [poisoned]);
      },
    );

    test('a store with nothing to normalize reports all-empty/zero', () async {
      await service.remember(text: 'e1', project: 'home', tags: ['alice']);
      final r = await service.tagsNormalize();
      expect(r['renamed'], isEmpty);
      expect(r['merged'], 0);
      expect(r['skipped'], isEmpty);
      expect(r['tagsRemoved'], 0);
    });

    test('does not touch entry text, contentHash or the vector index', () async {
      final e1 = await service.remember(
        text: 'unaffected text 3',
        project: 'home',
      );
      link(e1, putTag('Alice'));
      final id = e1['id'] as int;
      final beforeHash = entries().get(id)!.contentHash;
      final beforeIndexCount = index().count();

      await service.tagsNormalize();

      final after = entries().get(id)!;
      expect(after.text, 'unaffected text 3');
      expect(after.contentHash, beforeHash);
      expect(index().count(), beforeIndexCount);
    });
  });

  // Pinned BEFORE the redundancy check in `_prepareTags` (steps 2/2b) was
  // extracted into a shared classifier for the strict registry mode: every
  // warning text, its order, the stored tag list and the log line must
  // stay byte-identical across that refactor (open mode must not change).
  group('_prepareTags warning snapshot', () {
    test(
      'every warning branch produces exactly today\'s text, in order',
      () async {
        await service.remember(
          text: 'contact seed for the snapshot',
          project: 'garden',
          tags: ['contact'],
        );
        await service.areaSet(name: 'work');
        await service.projectSet(name: 'acme-app', addAreas: ['work']);
        logLines.clear();

        final r = await service.remember(
          text: 'snapshot probe for every tag warning branch',
          project: 'acme-app',
          tags: [
            'bad\u0007tag',
            '---',
            'Apps Script',
            'apps-script',
            'acmeApp',
            'Decision',
            'Work',
            'acmeApps',
            'episodes',
            'works',
            'contacts',
            't42',
          ],
        );

        const expected = [
          'Tag "badtag" dropped: contains control characters.',
          'Tag "---" dropped: empty after normalization.',
          'Tag "Apps Script" stored as "appsScript".',
          'Tag "apps-script" stored as "appsScript".',
          'Tag "apps-script" is a duplicate of "Apps Script" (both '
              'normalize to "appsScript") – kept once.',
          'Tag "Decision" stored as "decision".',
          'Tag "Work" stored as "work".',
          'Tag "acmeApp" dropped: matches the project name "acme-app" – '
              'project is already filterable.',
          'Tag "decision" dropped: matches a memory kind ("decision") – '
              'kind is already filterable.',
          'Tag "work" dropped: matches an area this project belongs to – '
              'area is already filterable.',
          'Tag "acmeApps" looks like a near-duplicate of the project name '
              '"acme-app" – kept, but consider the project filter instead '
              'of a tag.',
          'Tag "episodes" looks like a near-duplicate of the kind '
              '"episode" – kept, but consider the kind filter instead of a '
              'tag.',
          'Tag "works" looks like a near-duplicate of an area this project '
              'belongs to – kept, but consider the area filter instead of a '
              'tag.',
          'New tag "contacts" – did you mean the existing "contact"?',
          '6 tags on one entry – more than 5 rarely help grouping.',
          'Tag "t42" looks like an identifier or version – identifiers and '
              'versions belong in the text, not in tags.',
        ];
        expect(warningOf(r), expected.join(' '));
        expect(tagNamesOf(r), [
          'acmeApps',
          'appsScript',
          'contacts',
          'episodes',
          't42',
          'works',
        ]);
        final id = r['id'] as int;
        expect(
          logLines,
          contains('[memory] entry $id tag preparation: ${expected.join(' | ')}'),
        );
      },
    );
  });
}
