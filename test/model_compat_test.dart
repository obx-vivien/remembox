/// Model-diff regression test for the areas/facts (0.3.0) schema change —
/// plan §4 (T-M1), addendum M1/M4. Compares the CURRENT `lib/objectbox-
/// model.json` against a frozen copy of the 0.2.0 model (`test/fixtures/
/// objectbox-model-0.2.0.json`, copied from `lib/objectbox-model.json` at
/// commit c59dbb0, BEFORE `dart run build_runner build` added the areas/
/// facts entities) to prove the schema change is additive-only: every
/// existing entity/property/relation keeps its id/uid, and exactly the
/// four new entities were added.
///
/// This is the automated half of "reviewer eyeballs `git diff
/// lib/objectbox-model.json`: only additions, no `-` line except the
/// `last*Id` counters" (plan §4) — it runs that check every time, not just
/// once at review time.
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

typedef Json = Map<String, Object?>;

Json _loadModel(String path) =>
    (jsonDecode(File(path).readAsStringSync()) as Json);

List<Json> _entities(Json model) =>
    (model['entities'] as List).cast<Json>();

Json _entityById(List<Json> entities, String id) => entities.firstWhere(
  (e) => e['id'] == id,
  orElse: () => throw TestFailure('no entity with id "$id"'),
);

List<Json> _properties(Json entity) =>
    (entity['properties'] as List).cast<Json>();

List<Json> _relations(Json entity) =>
    (entity['relations'] as List).cast<Json>();

void _expectSameFields(
  Json actual,
  Json expected,
  List<String> fields,
  String context,
) {
  for (final field in fields) {
    expect(
      actual[field],
      expected[field],
      reason: '$context: field "$field" differs',
    );
  }
}

/// Numeric id prefix of an ObjectBox `"<id>:<uid>"` string, e.g.
/// `"9:8094921654310938506"` -> `9`.
int _numericId(String idString) => int.parse(idString.split(':').first);

/// OBXPropertyFlags bits relevant to the 0.3.1 fix (objectbox-5.3.2,
/// lib/src/modelinfo/enums.dart): `INDEXED` (8) marks a value index;
/// `INDEX_HASH` (2048) marks the old 32-bit hash index.
abstract final class _Flag {
  static const indexed = 8;
  static const indexHash = 2048;
}

/// `entity.property` keys for the four 0.2.0-baseline properties whose
/// flags deliberately changed by the 2026-09-23 (0.3.1) unique value index
/// fix – see "Unique value index" in lib/src/model.dart: ObjectBox indexed
/// unique String properties as a 32-bit HASH by default, and a put's
/// uniqueness check on a hash index has to load each hash-bucket candidate
/// by id, so a stale index entry fails the whole put with OBX 10502.
/// Switched to a value index instead, which never needs that load. The
/// ONLY change this test allows on these four properties is that exact bit
/// transition – `INDEX_HASH` cleared, `INDEXED` set; every other flag bit,
/// and every other field, still has to be byte-identical to 0.2.0. (The
/// other three 0.3.1-affected properties – `Area.name`, `AreaMembership
/// .key`, `ProjectScope.name` – were added by 0.3.0 and so are not in the
/// 0.2.0 baseline this test compares against; see
/// test/unique_index_type_test.dart for the full seven-property check.)
const _hashToValueIndexProperties031 = {
  'MemoryEntry.contentHash',
  'Tag.name',
  'SourceDocument.contentHash',
  'MemoryIndex.sourceKey',
};

void main() {
  final oldModel = _loadModel('test/fixtures/objectbox-model-0.2.0.json');
  final newModel = _loadModel('lib/objectbox-model.json');
  final oldEntities = _entities(oldModel);
  final newEntities = _entities(newModel);

  group('model_compat (0.2.0 -> 0.3.0, areas and facts)', () {
    test('every 0.2.0 entity is present with identical id/name/flags/'
        'lastPropertyId', () {
      for (final old in oldEntities) {
        final id = old['id'] as String;
        final current = _entityById(newEntities, id);
        _expectSameFields(current, old, [
          'id',
          'name',
          'flags',
          'lastPropertyId',
        ], 'entity $id (${old['name']})');
      }
    });

    test('every 0.2.0 property is present, unchanged, on its 0.2.0 '
        'entity', () {
      for (final old in oldEntities) {
        final id = old['id'] as String;
        final current = _entityById(newEntities, id);
        final oldProps = _properties(old);
        final newProps = _properties(current);
        for (final oldProp in oldProps) {
          final propId = oldProp['id'] as String;
          final newProp = newProps.firstWhere(
            (p) => p['id'] == propId,
            orElse: () => throw TestFailure(
              'property $propId (${oldProp['name']}) missing from entity '
              '${old['name']} in the current model',
            ),
          );
          final context =
              'entity ${old['name']}, property $propId '
              '(${oldProp['name']})';
          _expectSameFields(newProp, oldProp, [
            'id',
            'name',
            'type',
            'indexId',
            'relationTarget',
          ], context);

          final flagKey = '${old['name']}.${oldProp['name']}';
          // A property with flags == 0 omits the "flags" key entirely
          // (ModelProperty.toMap: `if (flags != 0) ret[...] = flags`).
          final oldFlags = oldProp['flags'] as int? ?? 0;
          final newFlags = newProp['flags'] as int? ?? 0;
          if (_hashToValueIndexProperties031.contains(flagKey)) {
            expect(
              oldFlags & _Flag.indexHash,
              _Flag.indexHash,
              reason:
                  '$context: expected to be hash-indexed (INDEX_HASH set) '
                  'in the 0.2.0 baseline – if not, this property does not '
                  'belong in _hashToValueIndexProperties031',
            );
            expect(
              oldFlags & _Flag.indexed,
              0,
              reason:
                  '$context: expected NOT to already carry INDEXED in the '
                  '0.2.0 baseline',
            );
            final expectedNewFlags =
                (oldFlags & ~_Flag.indexHash) | _Flag.indexed;
            expect(
              newFlags,
              expectedNewFlags,
              reason:
                  '$context: flags must change by EXACTLY the 0.3.1 '
                  'hash-index -> value-index transition (clear INDEX_HASH '
                  '2048, set INDEXED 8); every other bit must stay '
                  'identical to 0.2.0 ($oldFlags) – expected '
                  '$expectedNewFlags, got $newFlags',
            );
          } else {
            expect(newFlags, oldFlags, reason: '$context: flags changed unexpectedly');
          }
        }
        // Property COUNT must also match (lastPropertyId alone would miss
        // a property being both removed and a new one added at a reused
        // slot id).
        expect(
          newProps.length,
          oldProps.length,
          reason: 'entity ${old['name']}: property count changed',
        );
      }
    });

    test('MemoryEntry.tags relation (1:7448594369450009005) is identical', () {
      const memoryEntryId = '1:2753922093019415356';
      final oldEntry = _entityById(oldEntities, memoryEntryId);
      final newEntry = _entityById(newEntities, memoryEntryId);
      final oldRelations = _relations(oldEntry);
      final newRelations = _relations(newEntry);
      expect(
        newRelations.length,
        oldRelations.length,
        reason: 'MemoryEntry relation count changed',
      );
      for (final oldRel in oldRelations) {
        final relId = oldRel['id'] as String;
        final newRel = newRelations.firstWhere(
          (r) => r['id'] == relId,
          orElse: () => throw TestFailure('relation $relId missing'),
        );
        _expectSameFields(newRel, oldRel, [
          'id',
          'name',
          'targetId',
        ], 'MemoryEntry relation $relId');
      }
      expect(oldRelations.single['id'], '1:7448594369450009005');
    });

    test('retiredEntityUids/IndexUids/PropertyUids/RelationUids are still '
        'empty', () {
      // Also covers the 2026-09-23 (0.3.1) unique value index fix: it
      // changes property `flags` in place (hash index -> value index) at
      // the SAME `indexId` – confirmed by the flags-transition check
      // above, which also asserts `indexId` is unchanged for the four
      // affected 0.2.0-baseline properties. A generator that instead
      // retired the old hash index's uid and minted a new one would leave
      // a trace in retiredIndexUids; this stayed empty when the 0.3.1
      // model was regenerated, so no retirement happened.
      for (final key in [
        'retiredEntityUids',
        'retiredIndexUids',
        'retiredPropertyUids',
        'retiredRelationUids',
      ]) {
        expect(newModel[key], isEmpty, reason: key);
      }
    });

    test('counters: lastEntityId.id == 9, lastRelationId unchanged, '
        'lastIndexId grew, modelVersion unchanged', () {
      expect(
        _numericId(newModel['lastEntityId'] as String),
        9,
        reason:
            'addendum M1: 4 new entities (Area, AreaMembership, Fact, '
            'ProjectScope) on top of the 5 existing ones -> lastEntityId 9',
      );
      expect(
        newModel['lastRelationId'],
        oldModel['lastRelationId'],
        reason:
            'addendum M1: area membership is a synced link ENTITY keyed '
            'by names, not a ToMany/@Backlink relation pair -> no new '
            'relation, lastRelationId must be byte-identical to 0.2.0',
      );
      expect(
        _numericId(newModel['lastIndexId'] as String),
        greaterThan(_numericId(oldModel['lastIndexId'] as String)),
        reason: 'the new entities add indexed properties',
      );
      expect(newModel['modelVersion'], oldModel['modelVersion']);
    });

    test('exactly the 4 new entities (Area, AreaMembership, Fact, '
        'ProjectScope) were added, nothing else', () {
      final oldIds = oldEntities.map((e) => e['id'] as String).toSet();
      final addedEntities = newEntities.where((e) => !oldIds.contains(e['id']));
      final addedNames = addedEntities.map((e) => e['name']).toSet();
      expect(
        addedNames,
        {'Area', 'AreaMembership', 'Fact', 'ProjectScope'},
      );
      expect(addedEntities.length, 4);
      // Every added entity's numeric id must be one of the 4 new slots
      // (6-9) — never a reused old slot.
      for (final e in addedEntities) {
        expect(_numericId(e['id'] as String), inInclusiveRange(6, 9));
      }
    });
  });
}
