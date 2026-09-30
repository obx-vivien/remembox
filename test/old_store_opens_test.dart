/// Old-store-compatibility test — plan §4 (T-M2), addendum "minor
/// changes" (avoid a binary fixture: build the old-schema store at test
/// time instead, per plan review m1).
///
/// Builds a store containing ONLY the 0.2.0 entities (MemoryEntry, Tag,
/// SourceDocument, MemoryLink, MemoryIndex) via a [ModelDefinition]
/// filtered from the SAME generated `getObjectBoxModel()` the production
/// binary uses (never hand-duplicated), writes synthetic rows, closes it,
/// then reopens the SAME store directory with the FULL 0.3.0 model and
/// asserts every 0.2.0 row survived untouched and the new areas/facts
/// boxes are immediately usable. This is the automated version of U2
/// ("opening an existing store with additional entities is a silent
/// additive schema update") — pinned instead of assumed.
library;

import 'dart:convert';
import 'dart:io';

import 'package:objectbox/internal.dart' as obx_int;
import 'package:remembox/objectbox.g.dart';
import 'package:remembox/src/model.dart';
import 'package:remembox/src/store.dart';
import 'package:test/test.dart';

/// The 5 entity names that existed in the 0.2.0 model
/// (test/fixtures/objectbox-model-0.2.0.json) — matched by NAME rather
/// than assuming a particular id ordering, so this test does not silently
/// start passing for the wrong reason if entity ids ever get reordered.
const _oldEntityNames = {
  'MemoryEntry',
  'MemoryIndex',
  'MemoryLink',
  'SourceDocument',
  'Tag',
};

/// Reads the exact 0.2.0 `last*Id` counters from the frozen fixture
/// (single source of truth shared with test/model_compat_test.dart — no
/// hand-duplicated uid literals here).
Map<String, obx_int.IdUid> _oldCounters() {
  final json =
      jsonDecode(
            File(
              'test/fixtures/objectbox-model-0.2.0.json',
            ).readAsStringSync(),
          )
          as Map<String, Object?>;
  return {
    for (final key in ['lastEntityId', 'lastIndexId', 'lastRelationId'])
      key: obx_int.IdUid.fromString(json[key] as String),
  };
}

/// Builds a [obx_int.ModelDefinition] containing ONLY the 5 pre-existing
/// entities, reusing the exact [obx_int.ModelEntity]/[obx_int.
/// EntityDefinition] objects the FULL generated model
/// ([getObjectBoxModel]) already built — filtered, never re-declared by
/// hand, so this can never drift from the real schema.
obx_int.ModelDefinition _oldModelDefinition() {
  final full = getObjectBoxModel();
  final oldEntities = full.model.entities
      .where((e) => _oldEntityNames.contains(e.name))
      .toList(growable: false);
  if (oldEntities.length != _oldEntityNames.length) {
    throw StateError(
      'expected exactly the 5 pre-existing entities '
      '($_oldEntityNames), found '
      '${oldEntities.map((e) => e.name).toList()} — the areas/facts '
      'entities must be named exactly Area/AreaMembership/Fact/'
      'ProjectScope for this filter to work.',
    );
  }
  final oldBindings = <Type, obx_int.EntityDefinition>{
    for (final entry in full.bindings.entries)
      if (_oldEntityNames.contains(entry.key.toString())) entry.key: entry.value,
  };
  final counters = _oldCounters();
  final oldModel = obx_int.ModelInfo(
    generatorVersion: full.model.generatorVersion,
    entities: oldEntities,
    lastEntityId: counters['lastEntityId']!,
    lastIndexId: counters['lastIndexId']!,
    lastRelationId: counters['lastRelationId']!,
    lastSequenceId: const obx_int.IdUid.empty(),
    retiredEntityUids: const [],
    retiredIndexUids: const [],
    retiredPropertyUids: const [],
    retiredRelationUids: const [],
    modelVersion: full.model.modelVersion,
    modelVersionParserMinimum: full.model.modelVersionParserMinimum,
    version: full.model.version,
  );
  return obx_int.ModelDefinition(oldModel, oldBindings);
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('remembox_old_store_');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test(
    'a store built with the 0.2.0 (5-entity) model opens with the full '
    '0.3.0 model and keeps every row; the new areas/facts boxes are '
    'immediately usable',
    () {
      // --- Phase 1: build the OLD store, write synthetic 0.2.0 rows. ---
      ensureNativeLibraryLoaded();
      final oldStore = Store(_oldModelDefinition(), directory: tempDir.path);
      final oldSyncClient = startLocalActivationSyncClient(oldStore);

      final tagBox = oldStore.box<Tag>();
      final docBox = oldStore.box<SourceDocument>();
      final entryBox = oldStore.box<MemoryEntry>();
      final linkBox = oldStore.box<MemoryLink>();
      final indexBox = oldStore.box<MemoryIndex>();

      late int entry1Id;
      late int entry2Id;
      oldStore.runInTransaction(TxMode.write, () {
        final tag = Tag(name: 'synthetic-old-tag');
        final doc = SourceDocument(
          name: 'synthetic-old-doc',
          contentHash: 'old-store-doc-hash',
        );
        docBox.put(doc);
        final entry1 = MemoryEntry(
          title: 'old-store entry one',
          text: 'synthetic body one, written under the 0.2.0 model',
          kind: MemoryKind.fact,
          sourceType: MemorySource.note,
          project: 'acme-app',
          contentHash: 'old-store-entry-hash-1',
        );
        entry1.tags.add(tag);
        entry1.source.target = doc;
        entry1Id = entryBox.put(entry1);
        final entry2 = MemoryEntry(
          title: 'old-store entry two',
          text: 'synthetic body two, written under the 0.2.0 model',
          kind: MemoryKind.decision,
          sourceType: MemorySource.note,
          project: 'garden',
          contentHash: 'old-store-entry-hash-2',
        );
        entry2Id = entryBox.put(entry2);
        final link = MemoryLink(
          linkType: LinkType.related,
          note: 'synthetic link written under the 0.2.0 model',
        );
        link.from.targetId = entry1Id;
        link.to.targetId = entry2Id;
        linkBox.put(link);
        indexBox.put(
          MemoryIndex(
            sourceKey: MemoryIndex.sourceKeyFor(entry1Id),
            entryId: entry1Id,
            embedding: List<double>.filled(MemoryIndex.hnswDimensions, 0.0),
            embedModel: 'synthetic-old-model',
            dims: MemoryIndex.hnswDimensions,
            textHash: 'old-store-entry-hash-1',
          ),
        );
      });

      expect(tagBox.count(), 1);
      expect(docBox.count(), 1);
      expect(entryBox.count(), 2);
      expect(linkBox.count(), 1);
      expect(indexBox.count(), 1);

      oldSyncClient.close();
      oldStore.close();

      // --- Phase 2: reopen the SAME directory with the FULL 0.3.0 model
      // — the real upgrade path (openMemoryStore, same as production). ---
      final newStore = openMemoryStore(tempDir.path);
      final newSyncClient = startLocalActivationSyncClient(newStore);
      addTearDown(() {
        newSyncClient.close();
        newStore.close();
      });

      // Every 0.2.0 row survived, untouched.
      expect(newStore.box<Tag>().count(), 1);
      expect(newStore.box<SourceDocument>().count(), 1);
      expect(newStore.box<MemoryEntry>().count(), 2);
      expect(newStore.box<MemoryLink>().count(), 1);
      expect(newStore.box<MemoryIndex>().count(), 1);

      final survivingEntry1 = newStore.box<MemoryEntry>().get(entry1Id)!;
      expect(survivingEntry1.contentHash, 'old-store-entry-hash-1');
      expect(survivingEntry1.project, 'acme-app');
      expect(survivingEntry1.tags.map((t) => t.name), [
        'synthetic-old-tag',
      ]);
      expect(survivingEntry1.source.target?.contentHash, 'old-store-doc-hash');

      final survivingLink = newStore.box<MemoryLink>().query().build().findFirst()!;
      expect(survivingLink.from.targetId, entry1Id);
      expect(survivingLink.to.targetId, entry2Id);

      // The new areas/facts boxes are immediately usable — additive
      // schema change, not a migration that needs to run first.
      expect(newStore.box<ProjectScope>().count(), 0);
      expect(newStore.box<Area>().count(), 0);
      expect(newStore.box<AreaMembership>().count(), 0);
      expect(newStore.box<Fact>().count(), 0);

      newStore.runInTransaction(TxMode.write, () {
        final area = Area(name: 'work', nameKey: ScopeKey.of('work'));
        newStore.box<Area>().put(area);
      });
      expect(newStore.box<Area>().count(), 1);
    },
  );

  test(
    'a store whose Tag.name still carries the pre-0.3.1 hash-indexed '
    'unique flags opens with the current value-indexed model, keeps '
    'every row, and accepts a brand-new tag name',
    () {
      // Sanity check: the CURRENT model must actually differ from
      // _oldTagNameFlags below, or this test would pass for the wrong
      // reason if the 0.3.1 fix were ever silently reverted.
      final currentTagNameProp = getObjectBoxModel().model.entities
          .firstWhere((e) => e.name == 'Tag')
          .findPropertyByName('name')!;
      expect(
        currentTagNameProp.flags,
        32808,
        reason:
            'Tag.name is expected to carry the 0.3.1 value-index flags '
            '(INDEXED + UNIQUE, no INDEX_HASH) – see "Unique value index" '
            'in lib/src/model.dart. If this genuinely changed, update '
            'both this literal and _oldTagNameFlags in this file.',
      );

      // --- Phase 1: build a store with Tag.name still HASH-indexed
      // (34848), exactly as every store created before the 2026-09-23
      // (0.3.1) fix has it on disk. Write several tags and a MemoryEntry
      // linking one of them. ---
      ensureNativeLibraryLoaded();
      final oldStore = Store(
        _modelWithOldTagNameFlags(),
        directory: tempDir.path,
      );
      final oldSyncClient = startLocalActivationSyncClient(oldStore);

      final tagBox = oldStore.box<Tag>();
      final entryBox = oldStore.box<MemoryEntry>();

      late int keptTagId;
      oldStore.runInTransaction(TxMode.write, () {
        final tagAlice = Tag(name: 'alice');
        final tagGarden = Tag(name: 'garden');
        final tagAcme = Tag(name: 'acme-app');
        keptTagId = tagBox.put(tagAlice);
        tagBox.put(tagGarden);
        tagBox.put(tagAcme);

        final entry = MemoryEntry(
          title: 'hash-index era entry',
          text: 'written while Tag.name was still hash-indexed',
          kind: MemoryKind.fact,
          sourceType: MemorySource.note,
          project: 'acme-app',
          contentHash: 'hash-index-era-entry-hash',
        );
        entry.tags.add(tagAlice);
        entryBox.put(entry);
      });

      expect(tagBox.count(), 3);
      expect(entryBox.count(), 1);

      oldSyncClient.close();
      oldStore.close();

      // --- Phase 2: reopen the SAME directory with the CURRENT
      // (value-indexed) model – the real 0.3.1 upgrade path
      // (openMemoryStore, same as production). ObjectBox rebuilds
      // Tag's index on open because the index type changed underneath
      // the same indexId. ---
      final newStore = openMemoryStore(tempDir.path);
      final newSyncClient = startLocalActivationSyncClient(newStore);
      addTearDown(() {
        newSyncClient.close();
        newStore.close();
      });

      // Every row written under the old hash index survived, untouched.
      expect(newStore.box<Tag>().count(), 3);
      expect(newStore.box<MemoryEntry>().count(), 1);
      final survivingTag = newStore.box<Tag>().get(keptTagId)!;
      expect(survivingTag.name, 'alice');
      final survivingEntries = newStore.box<MemoryEntry>().getAll();
      expect(survivingEntries.single.tags.map((t) => t.name), ['alice']);

      // The upgrade path this test pins: after reopening with the
      // value-indexed model, writing a brand-new tag name – the write
      // that used to fail permanently with "Entity unavailable for
      // indexed ID <n>" (OBX 10502) once a hash bucket held a stale
      // entry – succeeds normally.
      final newTagId = newStore.box<Tag>().put(
        Tag(name: 'brand-new-tag-name'),
      );
      expect(newStore.box<Tag>().get(newTagId)?.name, 'brand-new-tag-name');
      expect(newStore.box<Tag>().count(), 4);
    },
  );
}

/// Flags [Tag.name] carried before the 2026-09-23 (0.3.1) unique-value-index
/// fix: `@Unique` on a `@Sync()` entity, hash-indexed. Frozen in
/// test/fixtures/objectbox-model-0.2.0.json (same value, same property) –
/// not re-derived here so a typo can't silently produce a no-op test.
const _oldTagNameFlags = 34848;

/// Builds a [obx_int.ModelDefinition] equal to the CURRENT full model
/// except [Tag.name]'s flags are reverted to [_oldTagNameFlags]. This
/// reproduces the exact upgrade path a real existing store takes: every
/// other property is already on the current schema, only Tag.name's index
/// type is stale, the way it is for any store that predates 0.3.1.
obx_int.ModelDefinition _modelWithOldTagNameFlags() {
  final full = getObjectBoxModel();
  final currentTag = full.model.entities.firstWhere((e) => e.name == 'Tag');
  // forModelJson: true – same shape as lib/objectbox-model.json itself;
  // notably it skips ModelEntity.constructorParams, which is a
  // late-initialized field that is never set on entities built at runtime
  // by getObjectBoxModel() (only the build-time generator sets it), so
  // reading it via the default toMap() throws LateInitializationError.
  final tagMap = currentTag.toMap(forModelJson: true);
  final nameProp = (tagMap['properties'] as List)
      .cast<Map<String, dynamic>>()
      .firstWhere((p) => p['name'] == 'name');
  nameProp['flags'] = _oldTagNameFlags;
  final patchedTag = obx_int.ModelEntity.fromMap(tagMap, model: full.model);

  final entities = [
    for (final e in full.model.entities)
      if (e.name == 'Tag') patchedTag else e,
  ];

  final model = obx_int.ModelInfo(
    generatorVersion: full.model.generatorVersion,
    entities: entities,
    lastEntityId: full.model.lastEntityId,
    lastIndexId: full.model.lastIndexId,
    lastRelationId: full.model.lastRelationId,
    lastSequenceId: full.model.lastSequenceId,
    retiredEntityUids: full.model.retiredEntityUids,
    retiredIndexUids: full.model.retiredIndexUids,
    retiredPropertyUids: full.model.retiredPropertyUids,
    retiredRelationUids: full.model.retiredRelationUids,
    modelVersion: full.model.modelVersion,
    modelVersionParserMinimum: full.model.modelVersionParserMinimum,
    version: full.model.version,
  );
  return obx_int.ModelDefinition(model, full.bindings);
}
