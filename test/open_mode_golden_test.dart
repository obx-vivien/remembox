/// Golden test: open registry mode (the default) must behave exactly like
/// the code before strict registry mode existed.
///
/// A scripted sequence of write and read calls runs against a fresh store
/// with the default (open) service. Every result, every rejection message
/// and every `[memory]`/`[registry]` log line is normalized (see
/// [_normalizeStep]) and compared with `test/fixtures/open_mode_golden.json`.
/// That fixture was captured by running THIS file against `main`'s code –
/// not against this branch – so a regression in open mode shows up here
/// instead of being compared against itself.
///
/// Capture procedure (only ever from main's code, never from a branch):
///
/// ```bash
/// repo=$PWD                                      # this checkout
/// tmp=$(mktemp -d)
/// git archive main | tar -x -C "$tmp"            # main's tree, no worktree
/// cp lib/libobjectbox.dylib "$tmp/lib/"           # native library
/// cp test/open_mode_golden_test.dart "$tmp/test/"
/// (cd "$tmp" && dart pub get && \
///   REMEMBOX_GOLDEN_WRITE="$repo/test/fixtures/open_mode_golden.json" \
///   dart test test/open_mode_golden_test.dart)
/// rm -rf "$tmp"
/// ```
///
/// With `REMEMBOX_GOLDEN_WRITE` set the test writes the fixture instead of
/// comparing. This file therefore only uses API that exists on main too
/// (no registry mode parameter). Normalization removes what legitimately
/// differs between two runs (wall-clock timestamps, the temp directory)
/// and the keys added to results on purpose since (listed in the
/// CHANGELOG): `tags_list` `registered`/`description`/`registryMode`/
/// `unregisteredInUse`/`aliases`/`aliasesInUse`, `areas_list`
/// `projects`/`mergedProjects`/`registryMode`, `stats.registry`
/// `mode`/`tagDefinitions`/`tagAliases`,
/// the merge and remove tools' `definitionsRemoved`/`intoDefinition`/
/// `carriedFrom`/`aliasesAdded`/`aliasesRemoved`, and `reindex`'s
/// `nearDuplicates`. The fixture itself is never edited: a key is only
/// ever added to this drop list, so everything main produced is still
/// compared.
///
/// Synthetic data only: projects `acme-app`, `garden`, `family`; area
/// `work`; tags as in the warning snapshot of test/tags_test.dart.
library;

import 'dart:convert';
import 'dart:io';

import 'package:remembox/objectbox.g.dart';
import 'package:remembox/src/memory_service.dart';
import 'package:remembox/src/model.dart';
import 'package:test/test.dart';

import 'helpers/test_store_gate.dart';
import 'support/fake_embedder.dart';

const _fixturePath = 'test/fixtures/open_mode_golden.json';

/// Keys that hold wall-clock values – removed everywhere.
const _clockKeys = {'createdAt', 'lastAccessedAt', 'indexedAt', 'updatedAt'};

/// Additive keys introduced with strict registry mode, per step kind.
const _addedKeysByTool = <String, Set<String>>{
  'tags_list': {
    'registryMode',
    'registered',
    'unregisteredInUse',
    'aliases',
    'aliasesInUse',
  },
  'areas_list': {'projects', 'mergedProjects', 'registryMode'},
  'tag_merge': {
    'definitionsRemoved',
    'intoDefinition',
    'carriedFrom',
    'aliasesAdded',
    'aliasesRemoved',
  },
  'tag_remove': {'definitionsRemoved', 'aliasesRemoved'},
  'tags_normalize': {'definitionsRemoved', 'aliasesAdded', 'aliasesRemoved'},
};

Object? _withoutClock(Object? v) => switch (v) {
  Map() => {
    for (final e in v.entries)
      if (!_clockKeys.contains(e.key)) e.key as String: _withoutClock(e.value),
  },
  List() => [for (final x in v) _withoutClock(x)],
  _ => v,
};

/// Normalizes one step's output for comparison (see the library doc).
Object? _normalizeStep(String tool, Object? output) {
  final out = _withoutClock(jsonDecode(jsonEncode(output)));
  if (out is! Map<String, Object?>) return out;
  for (final key in _addedKeysByTool[tool] ?? const <String>{}) {
    out.remove(key);
  }
  if (tool == 'tags_list') {
    for (final row in (out['tags'] as List).cast<Map<String, Object?>>()) {
      row
        ..remove('registered')
        ..remove('description');
    }
    for (final group
        in (out['variantGroups'] as List).cast<Map<String, Object?>>()) {
      for (final row in (group['tags'] as List).cast<Map<String, Object?>>()) {
        row.remove('registered');
      }
    }
  }
  if (tool == 'stats') {
    (out['store'] as Map<String, Object?>).remove('directory');
    (out['registry'] as Map<String, Object?>)
      ..remove('mode')
      ..remove('tagDefinitions')
      ..remove('tagAliases');
  }
  if (tool == 'reindex') {
    (out['registry'] as Map<String, Object?>).remove('nearDuplicates');
  }
  return out;
}

void main() {
  test('open mode matches the golden output captured from main', () async {
    final tempDir = Directory.systemTemp.createTempSync('remembox_golden_');
    final logLines = <String>[];
    final testGate = await openTestGate(tempDir.path, log: logLines.add);
    final store = testGate.store;
    final service = MemoryService(
      gate: testGate.gate,
      embedder: FakeEmbedder(),
      log: logLines.add,
    );
    addTearDown(() async {
      await service.dispose();
      await testGate.close();
      tempDir.deleteSync(recursive: true);
    });

    final steps = <Map<String, Object?>>[];
    Future<Object?> step(
      String tool,
      String label,
      Future<Object?> Function() call,
    ) async {
      logLines.clear();
      Object? output;
      try {
        output = await call();
      } on ValidationException catch (e) {
        output = {'error': e.message};
      }
      steps.add({
        'tool': tool,
        'label': label,
        'output': _normalizeStep(tool, output),
        'log': [
          for (final l in logLines)
            if (l.startsWith('[memory]') || l.startsWith('[registry]'))
              l.replaceAll(tempDir.path, '<dir>'),
        ],
      });
      return output;
    }

    int idOf(Object? result) => (result! as Map<String, Object?>)['id'] as int;
    final t0 = DateTime.utc(2026, 1, 1);

    await step('area_set', 'area work', () => service.areaSet(name: 'work'));
    await step(
      'project_set',
      'register acme-app in work',
      () => service.projectSet(
        name: 'acme-app',
        description: 'Synthetic app project.',
        addAreas: ['work'],
      ),
    );
    final seed = await step(
      'remember',
      'seed tag contact',
      () => service.remember(
        text: 'contact seed for the golden run',
        project: 'garden',
        tags: ['contact'],
      ),
    );
    final first = await step(
      'remember',
      'every tag warning branch',
      () => service.remember(
        text: 'golden probe for every tag warning branch',
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
      ),
    );
    await step(
      'remember',
      'duplicate text',
      () => service.remember(
        text: 'golden probe for every tag warning branch',
        project: 'acme-app',
      ),
    );
    await step(
      'remember',
      'duplicate text with links',
      () => service.remember(
        text: 'contact seed for the golden run',
        project: 'garden',
        links: [LinkSpec(toId: idOf(first), type: LinkType.related)],
      ),
    );
    await step(
      'remember',
      'bad link target',
      () => service.remember(
        text: 'never stored',
        project: 'garden',
        links: [LinkSpec(toId: 999, type: LinkType.related)],
      ),
    );
    await step(
      'remember',
      'with a link',
      () => service.remember(
        text: 'garden beds are planned for spring',
        project: 'garden',
        tags: ['status'],
        links: [LinkSpec(toId: idOf(seed), type: LinkType.derivedFrom)],
      ),
    );
    final superseded = await step(
      'supersede',
      'explicit project and tags',
      () => service.supersede(
        idOf(seed),
        text: 'contact seed for the golden run, corrected',
        project: 'garden',
        tags: ['contact', 'lesson'],
      ),
    );
    await step(
      'supersede',
      'inherited project',
      () => service.supersede(
        (superseded! as Map<String, Object?>)['newId'] as int,
        text: 'contact seed for the golden run, corrected twice',
      ),
    );
    await step(
      'remember',
      'near-duplicate project name',
      () => service.remember(text: 'variant spelling', project: 'Acme_App'),
    );
    for (final (label, value) in [
      ('fact created', 'blue'),
      ('fact unchanged', 'blue'),
      ('fact replaced', 'green'),
    ]) {
      await step(
        'fact_set',
        label,
        () => service.factSet(
          subject: 'Car',
          attribute: 'colour',
          project: 'family',
          valueText: value,
          validFrom: label == 'fact replaced'
              ? t0.add(const Duration(days: 1))
              : t0,
        ),
      );
    }
    await step(
      'project_merge',
      'dry run',
      () => service.projectMerge(
        from: 'Acme_App',
        into: 'acme-app',
        dryRun: true,
      ),
    );
    await step(
      'project_merge',
      'real',
      () => service.projectMerge(from: 'Acme_App', into: 'acme-app'),
    );
    await step(
      'fact_set',
      'under a merged project',
      () => service.factSet(
        subject: 'Car',
        attribute: 'colour',
        project: 'Acme_App',
        valueText: 'red',
        validFrom: t0,
      ),
    );
    final afterMerge = await step(
      'remember',
      'under a merged project',
      () => service.remember(
        text: 'written after the merge',
        project: 'Acme_App',
      ),
    );
    await step(
      'project_set',
      'describe and archive garden',
      () => service.projectSet(
        name: 'garden',
        description: 'Synthetic garden project.',
        status: ProjectStatus.archived,
      ),
    );
    await step(
      'project_set',
      'unknown area',
      () => service.projectSet(name: 'garden', addAreas: ['nowhere']),
    );
    await step(
      'entries_move',
      'merged target, dry run',
      () => service.entriesMove(
        ids: [idOf(afterMerge)],
        toProject: 'Acme_App',
        dryRun: true,
      ),
    );
    await step(
      'entries_move',
      'into garden',
      () => service.entriesMove(ids: [idOf(afterMerge)], toProject: 'garden'),
    );
    await step(
      'tag_merge',
      'dry run',
      () => service.tagMerge(from: ['contacts'], into: 'contact', dryRun: true),
    );
    await step(
      'tag_merge',
      'real',
      () => service.tagMerge(from: ['contacts', 'nope'], into: 'contact'),
    );
    await step(
      'tag_merge',
      'into a kind name',
      () => service.tagMerge(from: ['works'], into: 'decisions'),
    );
    await step(
      'tag_remove',
      'dry run',
      () => service.tagRemove(tags: ['t42'], dryRun: true),
    );
    await step(
      'tag_remove',
      'real',
      () => service.tagRemove(tags: ['t42', 'nope']),
    );
    // A legacy, pre-normalization spelling attached directly.
    store.runInTransaction(TxMode.write, () {
      final entry = store.box<MemoryEntry>().get(idOf(first))!;
      entry.tags.add(Tag(name: 'Alice'));
      store.box<MemoryEntry>().put(entry);
    });
    await step(
      'tags_normalize',
      'dry run',
      () => service.tagsNormalize(dryRun: true),
    );
    await step('tags_normalize', 'real', () => service.tagsNormalize());
    await step('tags_list', 'all', () => service.tagsList());
    await step('areas_list', 'all', () => service.areasList());
    await step('reindex', 'full', () => service.reindex());
    await step('stats', 'all', () => service.stats());
    // The stored rows themselves, not only the tool results.
    await step('rows', 'store content', () async {
      final entries = store.box<MemoryEntry>().getAll()
        ..sort((a, b) => a.id.compareTo(b.id));
      final facts = store.box<Fact>().getAll()
        ..sort((a, b) => a.id.compareTo(b.id));
      return {
        'entries': [
          for (final e in entries)
            {
              'id': e.id,
              'title': e.title,
              'kind': e.kind,
              'project': e.project,
              'tags': e.tags.map((t) => t.name).toList()..sort(),
              'supersededBy': e.supersededBy.targetId,
              'source': e.source.targetId,
            },
        ],
        'tags': store.box<Tag>().getAll().map((t) => t.name).toList()..sort(),
        'projects': [
          for (final p in store.box<ProjectScope>().getAll()
            ..sort((a, b) => a.name.compareTo(b.name)))
            {
              'name': p.name,
              'nameKey': p.nameKey,
              'status': p.status,
              'mergedInto': p.mergedInto,
              'description': p.description,
            },
        ],
        'areas': store.box<Area>().getAll().map((a) => a.name).toList(),
        'memberships': store
            .box<AreaMembership>()
            .getAll()
            .map((m) => '${m.area}/${m.project}')
            .toList()
          ..sort(),
        'facts': [
          for (final f in facts)
            {
              'id': f.id,
              'project': f.project,
              'subject': f.subject,
              'attribute': f.attribute,
              'valueText': f.valueText,
              'validFrom': f.validFrom.toIso8601String(),
              'validUntil': f.validUntil?.toIso8601String(),
              'supersededBy': f.supersededBy.targetId,
            },
        ],
        'links': [
          for (final l in store.box<MemoryLink>().getAll())
            '${l.from.targetId}-${l.linkType}->${l.to.targetId}',
        ]..sort(),
      };
    });

    final encoded = const JsonEncoder.withIndent('  ').convert(steps);
    final writeTo = Platform.environment['REMEMBOX_GOLDEN_WRITE'];
    if (writeTo != null && writeTo.isNotEmpty) {
      File(writeTo).writeAsStringSync('$encoded\n');
      return;
    }
    final expected = jsonDecode(File(_fixturePath).readAsStringSync()) as List;
    final actual = jsonDecode(encoded) as List;
    expect(actual.length, expected.length, reason: 'number of steps');
    for (var i = 0; i < expected.length; i++) {
      expect(
        actual[i],
        expected[i],
        reason: 'step $i (${(expected[i] as Map)['tool']}: '
            '${(expected[i] as Map)['label']}) differs from main',
      );
    }
  });
}
