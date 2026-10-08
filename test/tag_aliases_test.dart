/// Tests for tag aliases (`TagAlias`): alternative names of a registered
/// tag – set by `tag_define` (`aliases`, `addAliases`, `removeAliases`),
/// recorded by `tag_merge`, resolved by `_prepareTags` on every write
/// (both registry modes) and by `tag_merge`/`tags_normalize` targets,
/// cleaned up by `tag_remove`, listed by `tags_list`.
///
/// Synthetic data only: projects `garden`, `family`; tags `housework`
/// (alias `chores`), `cooking` (aliases `recipe`, `kitchen`, `dish`),
/// `cleaning`, `dishes`, `alice`, `status`.
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

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('remembox_tag_aliases_');
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
    await strict.projectSet(name: 'garden', description: 'Garden things.');
    await strict.projectSet(name: 'family', description: 'Family things.');
  });

  tearDown(() async {
    await open.dispose();
    await strict.dispose();
    await testGate.close();
    tempDir.deleteSync(recursive: true);
  });

  Box<TagAlias> aliases() => store.box<TagAlias>();
  Box<TagDefinition> defs() => store.box<TagDefinition>();
  Box<Tag> tags() => store.box<Tag>();
  Box<MemoryEntry> entries() => store.box<MemoryEntry>();

  Map<String, String> aliasRows() => {
    for (final a in aliases().getAll()) a.name: a.tag,
  };

  Map<String, int> counts() => {
    'entries': entries().count(),
    'tags': tags().count(),
    'defs': defs().count(),
    'aliases': aliases().count(),
    'projects': store.box<ProjectScope>().count(),
    'index': store.box<MemoryIndex>().count(),
  };

  List<String> tagsOf(Map<String, Object?> result) => entries()
      .get(result['id'] as int)!
      .tags
      .map((t) => t.name)
      .toList();

  Future<Map<String, Object?>> define(
    String name, {
    List<String>? aliasNames,
    bool allowSimilar = false,
  }) => strict.tagDefine(
    name: name,
    description: 'Synthetic tag $name.',
    aliases: aliasNames,
    allowSimilar: allowSimilar,
  );

  /// Puts a legacy (not normalized) Tag row named [name] on a new entry.
  Future<void> legacyTag(String name) async {
    final e = await open.remember(text: 'legacy $name', project: 'family');
    store.runInTransaction(TxMode.write, () {
      final entry = entries().get(e['id'] as int)!;
      entry.tags.add(Tag(name: name));
      entries().put(entry);
    });
  }

  /// Expects [call] to throw a ValidationException containing [expected]
  /// and to write nothing.
  Future<String> expectRejected(
    Future<Object?> Function() call,
    String expected,
  ) async {
    final before = counts();
    String? message;
    try {
      await call();
    } on ValidationException catch (e) {
      message = e.message;
    }
    expect(message, isNotNull, reason: 'expected a ValidationException');
    expect(message, contains(expected));
    expect(counts(), before, reason: 'a rejection must write nothing');
    return message!;
  }

  group('tag_define aliases', () {
    test('creates aliases, normalized and sorted, and logs each', () async {
      logLines.clear();
      final r = await define('cooking', aliasNames: ['Recipe', 'kitchen']);
      expect(r['action'], 'created');
      expect(r['aliases'], ['kitchen', 'recipe']);
      expect(r['aliasesAdded'], ['kitchen', 'recipe']);
      expect(r['aliasesRemoved'], isEmpty);
      expect(r['aliasesNormalizedFrom'], {'Recipe': 'recipe'});
      expect(aliasRows(), {'kitchen': 'cooking', 'recipe': 'cooking'});
      expect(
        logLines.where((l) => l.startsWith('[memory] tag_define: added alias')),
        hasLength(2),
      );
    });

    test('duplicate aliases collapse with a warning', () async {
      final r = await define('cooking', aliasNames: ['Recipe', 'recipe']);
      expect(r['aliases'], ['recipe']);
      expect(
        r['warning'],
        contains('Alias "recipe" is a duplicate of "Recipe" (both normalize '
            'to "recipe") – kept once.'),
      );
    });

    test('an alias listed twice verbatim is also warned about', () async {
      final r = await define('cooking', aliasNames: ['dish', 'dish']);
      expect(r['aliases'], ['dish']);
      expect(
        r['warning'],
        contains('Alias "dish" is listed more than once – kept once.'),
      );
    });

    test('aliases replaces the set and names what it removed; an empty '
        'list clears it', () async {
      await define('cooking', aliasNames: ['recipe', 'kitchen']);
      final r = await strict.tagDefine(
        name: 'cooking',
        aliases: ['recipe', 'dish'],
      );
      expect(r['action'], 'updated');
      expect(r['aliases'], ['dish', 'recipe']);
      expect(r['aliasesAdded'], ['dish']);
      expect(r['aliasesRemoved'], ['kitchen']);
      expect(r['warning'], contains('Alias(es) removed from "cooking": '
          '"kitchen".'));
      final same = await strict.tagDefine(name: 'cooking');
      expect(same['action'], 'unchanged');
      expect(same['aliases'], ['dish', 'recipe']);
      logLines.clear();
      final cleared = await strict.tagDefine(name: 'cooking', aliases: []);
      expect(cleared['aliasesRemoved'], ['dish', 'recipe']);
      expect(aliases().count(), 0);
      expect(
        logLines.where(
          (l) => l.startsWith('[memory] tag_define: removed alias'),
        ),
        hasLength(2),
      );
    });

    test('addAliases keeps the existing ones; removeAliases removes single '
        'ones', () async {
      await define('cooking', aliasNames: ['recipe']);
      final added = await strict.tagDefine(
        name: 'cooking',
        addAliases: ['kitchen'],
      );
      expect(added['aliases'], ['kitchen', 'recipe']);
      expect(added['aliasesRemoved'], isEmpty);
      expect(added['warning'], isNull);
      final removed = await strict.tagDefine(
        name: 'cooking',
        removeAliases: ['recipe', 'nope'],
      );
      expect(removed['aliases'], ['kitchen']);
      expect(removed['aliasesRemoved'], ['recipe']);
      expect(
        removed['warning'],
        allOf(
          contains('"nope" is not an alias of "cooking" – nothing removed.'),
          contains('Alias(es) removed from "cooking": "recipe".'),
        ),
      );
    });

    test('aliases cannot be combined with addAliases/removeAliases, and '
        'one name cannot be added and removed at once', () async {
      await define('cooking');
      await expectRejected(
        () => strict.tagDefine(
          name: 'cooking',
          aliases: ['recipe'],
          addAliases: ['kitchen'],
        ),
        'pass either "aliases"',
      );
      await expectRejected(
        () => strict.tagDefine(
          name: 'cooking',
          addAliases: ['recipe'],
          removeAliases: ['Recipe'],
        ),
        '"recipe" appear in both "addAliases" and "removeAliases"',
      );
    });

    group('conflicts reject the whole call, nothing written', () {
      test('the tag itself', () async {
        await expectRejected(
          () => define('cooking', aliasNames: ['Cooking']),
          '"cooking" is the tag itself',
        );
      });

      test('another registered tag', () async {
        await define('cleaning');
        await expectRejected(
          () => define('housework', aliasNames: ['cleaning']),
          '"cleaning" is a registered tag of its own',
        );
      });

      test('an alias of another tag, naming the owner', () async {
        await define('cleaning', aliasNames: ['chores']);
        await expectRejected(
          () => define('housework', aliasNames: ['chores']),
          '"chores" is already an alias of "cleaning"',
        );
      });

      test('a project, area or kind name', () async {
        await strict.areaSet(name: 'work');
        await expectRejected(
          () => define('housework', aliasNames: ['garden']),
          '"garden" repeats the registered project "garden"',
        );
        await expectRejected(
          () => define('housework', aliasNames: ['work']),
          '"work" repeats the area "work"',
        );
        await expectRejected(
          () => define('housework', aliasNames: ['decision']),
          '"decision" repeats the memory kind "decision"',
        );
      });

      test('control characters or an empty alias', () async {
        await expectRejected(
          () => define('housework', aliasNames: ['bad\u0007alias']),
          'contains control characters',
        );
        await expectRejected(
          () => define('housework', aliasNames: ['---']),
          'is empty after normalization',
        );
      });

      test('a spelling variant of a registered tag, unless allowSimilar',
          () async {
        await define('dish');
        await expectRejected(
          () => define('cooking', aliasNames: ['dishes']),
          '"dishes" looks like a variant of "dish" (same word apart from '
              'case, plural or separators) – pass allowSimilar: true if it '
              'is genuinely another name of "cooking"',
        );
        final r = await define(
          'cooking',
          aliasNames: ['dishes'],
          allowSimilar: true,
        );
        expect(r['aliases'], ['dishes']);
      });

      test('a spelling variant of another tag\'s alias, unless allowSimilar',
          () async {
        await define('housework', aliasNames: ['chores']);
        await expectRejected(
          () => define('cleaning', aliasNames: ['chore']),
          '"chore" looks like a variant of "chores" (alias of "housework")',
        );
      });

      test('an existing alias cannot be registered as a tag', () async {
        await define('cooking', aliasNames: ['recipe']);
        await expectRejected(
          () => define('recipe'),
          'tag_define: "recipe" is an alias of "cooking" – use "cooking"',
        );
      });

      test('a variant of an existing alias cannot be registered as a tag, '
          'unless allowSimilar', () async {
        await define('cooking', aliasNames: ['recipe']);
        await expectRejected(
          () => define('recipes'),
          'tag_define: "recipes" looks like a variant of "recipe" (alias of '
              '"cooking")',
        );
        final r = await define('recipes', allowSimilar: true);
        expect(r['action'], 'created');
      });
    });

    test('an alias that is a tag in use is allowed, with a tag_merge hint',
        () async {
      await open.remember(text: 'old', project: 'garden', tags: ['chores']);
      final r = await define('housework', aliasNames: ['chores']);
      expect(r['aliases'], ['chores']);
      expect(
        r['warning'],
        contains('entries still carry "chores" – tag_merge(from: '
            '["chores"], into: "housework") moves them.'),
      );
    });

    test('a new tag never gets a tag_merge hint for another tag\'s alias',
        () async {
      await open.remember(text: 'old', project: 'garden', tags: ['chores']);
      await define('housework', aliasNames: ['chores']);
      final r = await define('chore', allowSimilar: true);
      expect(r['warning'] ?? '', isNot(contains('tag_merge')));
    });
  });

  group('aliases resolve on write', () {
    test('open mode: an alias is stored as its tag, with warning and log',
        () async {
      await define('housework', aliasNames: ['chores']);
      logLines.clear();
      final r = await open.remember(
        text: 'swept the floor',
        project: 'family',
        tags: ['chores'],
      );
      expect(tagsOf(r), ['housework']);
      expect(
        r['warning'],
        contains('Tag "chores" is an alias of "housework" – stored as '
            '"housework".'),
      );
      expect(
        logLines,
        contains('[memory] tag alias resolved: "chores" -> "housework"'),
      );
      expect(tags().getAll().map((t) => t.name), isNot(contains('chores')));
    });

    test('strict end-to-end: a normalized alias resolves and is accepted',
        () async {
      await define('cooking', aliasNames: ['recipe', 'kitchen']);
      final r = await strict.remember(
        text: 'a soup for cold days',
        project: 'family',
        tags: ['Recipe'],
      );
      expect(tagsOf(r), ['cooking']);
      expect(
        r['warning'],
        contains('Tag "recipe" is an alias of "cooking" – stored as '
            '"cooking".'),
      );
    });

    test('no substitution when the name is itself a registered tag',
        () async {
      await define('cooking');
      await define('status');
      // Not reachable through tag_define (it rejects this alias) – a row
      // written directly, e.g. arriving by Sync.
      aliases().put(TagAlias(name: 'status', tag: 'cooking'));
      final r = await strict.remember(
        text: 'weekly status',
        project: 'garden',
        tags: ['status'],
      );
      expect(tagsOf(r), ['status']);
      expect(r['warning'] ?? '', isNot(contains('is an alias of')));
    });

    test('a dangling alias (its tag is not registered) is not resolved',
        () async {
      aliases().put(TagAlias(name: 'chores', tag: 'housework'));
      logLines.clear();
      final r = await open.remember(
        text: 'dusted',
        project: 'family',
        tags: ['chores'],
      );
      expect(tagsOf(r), ['chores']);
      expect(
        r['warning'],
        contains('Tag "chores" is an alias of "housework", but "housework" '
            'is not a registered tag – kept as "chores".'),
      );
      expect(
        logLines,
        contains(startsWith('[memory] tag alias not resolved: "chores"')),
      );
    });

    test('duplicates created by the substitution collapse to the first '
        'occurrence', () async {
      await define('housework', aliasNames: ['chores']);
      await define('alice');
      final r = await strict.remember(
        text: 'chores with alice',
        project: 'family',
        tags: ['alice', 'chores', 'housework'],
      );
      expect(tagsOf(r), ['alice', 'housework']);
    });

    test('strict suggestions name the tag behind a similar alias', () async {
      await define('cooking', aliasNames: ['recipes']);
      await expectRejected(
        () => strict.remember(
          text: 'probe',
          project: 'garden',
          tags: ['recipe'],
        ),
        '"recipe" (similar registered tag: "cooking" (alias "recipes"); '
            'tag_define accepts it only with allowSimilar: true)',
      );
    });
  });

  group('merge targets that are aliases resolve to their tag', () {
    setUp(() async {
      await define('housework', aliasNames: ['chores']);
      await open.remember(text: 'old', project: 'family', tags: ['oldThing']);
    });

    for (final mode in ['open', 'strict']) {
      test('$mode tag_merge into an alias merges into its tag (dry run '
          'alike)', () async {
        final service = mode == 'open' ? open : strict;
        final dry = await service.tagMerge(
          from: ['oldThing'],
          into: 'chores',
          dryRun: true,
        );
        logLines.clear();
        final r = await service.tagMerge(from: ['oldThing'], into: 'chores');
        for (final result in [dry, r]) {
          expect(result['into'], 'housework');
          expect(result['aliasesAdded'], ['oldThing']);
          expect(
            result['warning'],
            contains('Tag "chores" is an alias of "housework" – merged into '
                '"housework".'),
          );
        }
        expect(
          logLines,
          contains(startsWith('[memory] tag_merge: target "chores" is an '
              'alias of "housework"')),
        );
        expect(tags().getAll().map((t) => t.name), isNot(contains('chores')));
        expect(aliasRows()['oldThing'], 'housework');
      });
    }

    test('merging a tag into its own alias is rejected', () async {
      await expectRejected(
        () => open.tagMerge(from: ['housework'], into: 'chores'),
        'is an alias of "housework", which also appears in "from" – '
            'nothing to merge.',
      );
    });

    for (final mode in ['open', 'strict']) {
      test('$mode tags_normalize onto an alias normalizes into its tag (dry '
          'run alike)', () async {
        final service = mode == 'open' ? open : strict;
        await legacyTag('Chores');
        final dry = await service.tagsNormalize(dryRun: true);
        final r = await service.tagsNormalize();
        for (final result in [dry, r]) {
          final renamed = (result['renamed'] as List)
              .cast<Map<String, Object?>>();
          expect(renamed.single['from'], 'Chores');
          expect(renamed.single['into'], 'housework');
          expect(
            result['warning'],
            contains('Tag "chores" is an alias of "housework" – merged into '
                '"housework".'),
          );
        }
        final names = tags().getAll().map((t) => t.name);
        expect(names, contains('housework'));
        expect(names, isNot(contains('chores')));
        expect(names, isNot(contains('Chores')));
      });
    }
  });

  group('tag_merge records aliases', () {
    test('merged-away names become aliases of a registered target',
        () async {
      await define('housework');
      await open.remember(text: 'old', project: 'family', tags: ['chores']);
      logLines.clear();
      final r = await open.tagMerge(from: ['chores'], into: 'housework');
      expect(r['aliasesAdded'], ['chores']);
      expect(aliasRows(), {'chores': 'housework'});
      expect(
        logLines,
        contains(startsWith('[memory] tag_merge: added alias "chores" of '
            '"housework"')),
      );
      final later = await strict.remember(
        text: 'later',
        project: 'family',
        tags: ['chores'],
      );
      expect(tagsOf(later), ['housework']);
    });

    test('dry run reports the aliases and writes none', () async {
      await define('housework');
      await open.remember(text: 'old', project: 'family', tags: ['chores']);
      final r = await open.tagMerge(
        from: ['chores'],
        into: 'housework',
        dryRun: true,
      );
      expect(r['aliasesAdded'], ['chores']);
      expect(aliases().count(), 0);
    });

    test('a conflicting alias is skipped with a warning', () async {
      await open.remember(text: 'old', project: 'family', tags: ['chores']);
      await define('cleaning', aliasNames: ['chores']);
      await define('housework');
      final r = await open.tagMerge(from: ['chores'], into: 'housework');
      expect(r['aliasesAdded'], isEmpty);
      expect(
        r['warning'],
        contains('alias "chores" not recorded for "housework": "chores" is '
            'already an alias of "cleaning".'),
      );
      expect(aliasRows(), {'chores': 'cleaning'});
    });

    test('the aliases of a merged-away definition move to the target',
        () async {
      await define('dishes', aliasNames: ['plates']);
      await define('cooking');
      final r = await strict.tagMerge(from: ['dishes'], into: 'cooking');
      expect(r['aliasesAdded'], ['dishes', 'plates']);
      expect(r['aliasesRemoved'], isEmpty);
      expect(aliasRows(), {'dishes': 'cooking', 'plates': 'cooking'});
    });

    test('an unregistered target records no aliases and says so', () async {
      await define('housework');
      await open.remember(text: 'old', project: 'family', tags: ['chores']);
      logLines.clear();
      final r = await open.tagMerge(from: ['chores'], into: 'tidyUp');
      expect(r['intoDefinition'], 'none');
      expect(r['aliasesAdded'], isEmpty);
      expect(
        r['warning'],
        contains('No aliases recorded for "chores" – "tidyUp" is not a '
            'registered tag; register it with tag_define first (or add '
            'them later with tag_define addAliases).'),
      );
      expect(
        logLines,
        contains(startsWith('[memory] tag_merge: no aliases recorded for '
            '"chores"')),
      );
    });

    test('without a registered target the merged-away aliases are removed',
        () async {
      await define('cleaning', aliasNames: ['chores']);
      // Open mode, into a project name: the definition cannot be carried,
      // so the target stays unregistered.
      final r = await open.tagMerge(from: ['cleaning'], into: 'garden');
      expect(r['intoDefinition'], 'none');
      expect(r['aliasesAdded'], isEmpty);
      expect(r['aliasesRemoved'], ['chores']);
      expect(aliases().count(), 0);
    });

    test('tags_normalize records no alias for a spelling the normalization '
        'resolves anyway', () async {
      await define('housework');
      await legacyTag('Housework');
      logLines.clear();
      final r = await strict.tagsNormalize();
      expect(r['aliasesAdded'], isEmpty);
      expect(aliases().count(), 0);
      expect(
        logLines,
        contains(startsWith('[memory] tags_normalize: no alias needed for '
            '"Housework"')),
      );
    });
  });

  group('merge edge cases', () {
    test('the no-aliases warning is the same in a dry run and a real run, '
        'and does not send a project name to tag_define', () async {
      // "cleaning" holds the store's only definition; the real run removes
      // it, the dry run does not.
      await define('cleaning');
      await open.remember(text: 'a', project: 'family', tags: ['cleaning']);
      const expected =
          'No aliases recorded for "cleaning" – "garden" is not a '
          'registered tag, and "garden" cannot be registered: it repeats '
          'the registered project "garden".';
      final dry = await open.tagMerge(
        from: ['cleaning'],
        into: 'garden',
        dryRun: true,
      );
      final real = await open.tagMerge(from: ['cleaning'], into: 'garden');
      expect(dry['warning'], contains(expected));
      expect(real['warning'], contains(expected));
      expect(real['warning'], isNot(contains('register it with tag_define')));
    });

    test('a merged-away name that is a spelling variant is skipped with the '
        'tag_define call that records it anyway', () async {
      await define('housework');
      await define('dish');
      await open.remember(text: 'a', project: 'family', tags: ['dishes']);
      final r = await open.tagMerge(from: ['dishes'], into: 'housework');
      expect(r['aliasesAdded'], isEmpty);
      expect(
        r['warning'],
        contains('alias "dishes" not recorded for "housework": "dishes" '
            'looks like a variant of "dish" (same word apart from case, '
            'plural or separators) – tag_define("housework", addAliases: '
            '["dishes"], allowSimilar: true) records it anyway.'),
      );
      expect(r['warning'], isNot(contains('pass allowSimilar')));
    });

    test('a definition is never carried onto a variant of an alias: strict '
        'rejects, open merges without the carry', () async {
      await define('cooking', aliasNames: ['recipe']);
      await define('foo');
      await open.remember(text: 'a', project: 'family', tags: ['foo']);
      await expectRejected(
        () => strict.tagMerge(from: ['foo'], into: 'recipes'),
        'tag_merge: the definition of "foo" cannot be carried over to '
            '"recipes" (strict registry mode): "recipes" looks like a '
            'variant of "recipe" (alias of "cooking") (same word apart from '
            'case, plural or separators). Merge into the tag that alias '
            'belongs to instead',
      );
      final r = await open.tagMerge(from: ['foo'], into: 'recipes');
      expect(r['intoDefinition'], 'none');
      expect(r['warning'], contains('was not carried over to "recipes"'));
      expect(defs().getAll().map((d) => d.name), isNot(contains('recipes')));
    });
  });

  group('advice for an alias whose tag is not registered', () {
    setUp(() {
      aliases().put(TagAlias(name: 'chores', tag: 'housework'));
    });

    const ways =
        'the alias "chores" points at "housework", which is not registered '
        '– tag_define "housework" first (then "chores" resolves to it); to '
        'drop the alias instead, tag_define("housework", removeAliases: '
        '["chores"]) after registering "housework", or tag_remove "chores"';

    test('strict tag_merge lists the ways out', () async {
      await open.remember(text: 'b', project: 'family', tags: ['bar']);
      final message = await expectRejected(
        () => strict.tagMerge(from: ['bar'], into: 'chores'),
        'definition to carry over (strict registry mode). '
            '${ways[0].toUpperCase()}${ways.substring(1)}. Nothing was '
            'changed.',
      );
      expect(message, isNot(contains('Register it first')));
      expect(message, isNot(contains('merge into "housework" instead')));
    });

    test('strict tags_normalize says writes are rejected and lists the '
        'ways out', () async {
      await legacyTag('Chores');
      final r = await strict.tagsNormalize();
      expect(
        r['warning'],
        contains('"chores" is not a registered tag (strict registry mode) – '
            'writes using it are rejected; $ways.'),
      );
    });

    test('strict remember with the alias is rejected, and the message says '
        'the name was kept and what to do', () async {
      await expectRejected(
        () => strict.remember(text: 'p', project: 'family', tags: ['chores']),
        'tag(s) not registered (strict registry mode): "chores" (kept as '
            '"chores": $ways). Use a registered tag or drop it. tags_list '
            'shows every registered tag. Nothing was written.',
      );
    });
  });

  group('tag_remove', () {
    test('a defined tag takes its aliases along (dry run writes nothing)',
        () async {
      await define('cooking', aliasNames: ['recipe', 'kitchen']);
      final dry = await open.tagRemove(tags: ['cooking'], dryRun: true);
      expect(dry['aliasesRemoved'], ['kitchen', 'recipe']);
      expect(aliases().count(), 2);
      logLines.clear();
      final r = await open.tagRemove(tags: ['cooking']);
      expect(r['aliasesRemoved'], ['kitchen', 'recipe']);
      expect(aliases().count(), 0);
      expect(
        logLines.where(
          (l) => l.startsWith('[memory] tag_remove: removed alias'),
        ),
        hasLength(2),
      );
    });

    test('a name that is only an alias points at removeAliases', () async {
      await define('housework', aliasNames: ['chores']);
      final r = await open.tagRemove(tags: ['chores']);
      expect(r['notFound'], ['chores']);
      expect(
        r['warning'],
        contains('"chores" is an alias of "housework" and stays one – '
            'tag_define(name: "housework", removeAliases: ["chores"]) '
            'removes it.'),
      );
      expect(aliasRows(), {'chores': 'housework'});
    });
  });

  group('tags_list', () {
    test('shows aliases, marks aliases in use, counts them, and matches a '
        'prefix on aliases', () async {
      await open.remember(text: 'old', project: 'family', tags: ['chores']);
      await define('housework', aliasNames: ['chores', 'cleanup']);
      final all = await open.tagsList();
      final rows = (all['tags'] as List).cast<Map<String, Object?>>();
      final house = rows.singleWhere((r) => r['name'] == 'housework');
      expect(house['aliases'], ['chores', 'cleanup']);
      final chores = rows.singleWhere((r) => r['name'] == 'chores');
      expect(chores['aliasOf'], 'housework');
      expect(chores.containsKey('aliases'), isFalse);
      expect(chores.containsKey('aliasTargetMissing'), isFalse);
      expect(all['aliases'], 2);
      expect(all['aliasesInUse'], 1);
      expect(all['unregisteredInUse'], 0, reason: 'an alias in use resolves');

      final byAlias = await open.tagsList(prefix: 'clean');
      final matched = (byAlias['tags'] as List).cast<Map<String, Object?>>();
      expect(matched, hasLength(1));
      expect(matched.single['name'], 'housework');
      expect(matched.single['matchedAlias'], 'cleanup');
      expect(matched.single.containsKey('aliasTargetMissing'), isFalse);
    });

    test('a dangling alias is flagged and counts as unregistered', () async {
      await open.remember(text: 'old', project: 'family', tags: ['chores']);
      await open.remember(text: 'stew', project: 'family', tags: ['cooking']);
      aliases()
        ..put(TagAlias(name: 'chores', tag: 'housework'))
        ..put(TagAlias(name: 'kitchenware', tag: 'cooking'));
      final all = await open.tagsList();
      final rows = (all['tags'] as List).cast<Map<String, Object?>>();
      final chores = rows.singleWhere((r) => r['name'] == 'chores');
      expect(chores['aliasTargetMissing'], isTrue);
      expect(all['aliasesInUse'], 0);
      expect(all['unregisteredInUse'], 2);
      final byAlias = await open.tagsList(prefix: 'kitchen');
      final matched = (byAlias['tags'] as List).cast<Map<String, Object?>>();
      expect(matched.single['name'], 'cooking');
      expect(matched.single['matchedAlias'], 'kitchenware');
      expect(matched.single['aliasTargetMissing'], isTrue);
    });

    test('a name that is both a registered tag and an alias row is listed '
        'as a tag only, and logged', () async {
      await define('status');
      await define('cooking');
      aliases().put(TagAlias(name: 'status', tag: 'cooking'));
      logLines.clear();
      final all = await open.tagsList();
      final rows = (all['tags'] as List).cast<Map<String, Object?>>();
      expect(rows.singleWhere((r) => r['name'] == 'cooking')['aliases'], []);
      expect(
        logLines,
        contains(startsWith('[memory] tags_list: "status" is both a '
            'registered tag and an alias of "cooking"')),
      );
    });
  });
}
