/// Pinning test for the unique value index fix – 2026-09-23, unique value
/// index (0.3.1). See "Unique value index" in lib/src/model.dart for the
/// full rationale; short version: ObjectBox indexes every indexed String
/// property as a 32-bit HASH (flag `INDEX_HASH`, 2048) by default, from
/// `@Index` and `@Unique` alike – `@Unique` is what makes that default
/// dangerous, not what selects it.
/// A put's uniqueness check on a hash index must load each hash-bucket
/// candidate by id to resolve possible collisions – if a candidate is gone
/// (a stale index entry), that load fails and the whole put fails hard
/// with "Entity unavailable for indexed ID `<n>`" (OBX_ERROR 10502),
/// permanently blocking that value (objectbox-java issue #1150).
///
/// This test parses the generated `lib/objectbox-model.json` directly
/// (not the Dart annotations in lib/src/model.dart), so it catches a
/// future change the moment it reintroduces a hash-indexed unique String
/// property – on any entity, not just the seven known today.
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

typedef Json = Map<String, Object?>;

/// Relevant bits of OBXPropertyFlags (objectbox-5.3.2, lib/src/modelinfo/
/// enums.dart): a value index sets INDEXED; @Unique sets UNIQUE; the two
/// hash-index variants set INDEX_HASH or INDEX_HASH64 instead of INDEXED.
abstract final class _Flag {
  static const indexed = 8;
  static const unique = 32;
  static const indexHash = 2048;
  static const indexHash64 = 4096;
}

/// The seven `@Unique` String properties switched from a hash index to a
/// value index by the 0.3.1 fix – kept in sync with lib/src/model.dart by
/// hand; the second test below fails loudly if this list and the model
/// ever drift apart.
const _valueIndexedUniqueProperties = {
  'MemoryEntry.contentHash',
  'MemoryIndex.sourceKey',
  'SourceDocument.contentHash',
  'Tag.name',
  'Area.name',
  'AreaMembership.key',
  'ProjectScope.name',
};

void main() {
  final model =
      jsonDecode(File('lib/objectbox-model.json').readAsStringSync()) as Json;
  final entities = (model['entities'] as List).cast<Json>();

  group('unique_index_type (0.3.1 hash-index regression guard)', () {
    test('no @Unique property is hash-indexed', () {
      for (final entity in entities) {
        final entityName = entity['name'] as String;
        final properties = (entity['properties'] as List).cast<Json>();
        for (final prop in properties) {
          final flags = prop['flags'] as int? ?? 0;
          if (flags & _Flag.unique == 0) continue;
          final propName = prop['name'] as String;
          expect(
            flags & _Flag.indexHash,
            0,
            reason:
                '$entityName.$propName is @Unique and hash-indexed – a '
                "put's uniqueness check on a hash index dereferences the "
                'candidate object by id, and a stale index entry then '
                'fails the put with OBX 10502, permanently blocking that '
                'value (objectbox-java #1150). Add '
                '@Index(type: IndexType.value) instead.',
          );
          expect(
            flags & _Flag.indexHash64,
            0,
            reason:
                '$entityName.$propName is @Unique and 64-bit hash-indexed '
                '– same OBX 10502 failure mode as INDEX_HASH.',
          );
        }
      }
    });

    test('the seven known unique string properties are value-indexed', () {
      final seen = <String>{};
      for (final entity in entities) {
        final entityName = entity['name'] as String;
        final properties = (entity['properties'] as List).cast<Json>();
        for (final prop in properties) {
          final propName = prop['name'] as String;
          final key = '$entityName.$propName';
          if (!_valueIndexedUniqueProperties.contains(key)) continue;
          seen.add(key);
          final flags = prop['flags'] as int? ?? 0;
          expect(
            flags & _Flag.unique,
            _Flag.unique,
            reason: '$key must stay @Unique',
          );
          expect(
            flags & _Flag.indexed,
            _Flag.indexed,
            reason: '$key must carry @Index(type: IndexType.value)',
          );
        }
      }
      expect(
        seen,
        _valueIndexedUniqueProperties,
        reason:
            'expected to find exactly these seven properties in the model '
            '– update this list and lib/src/model.dart together if the '
            'schema changes',
      );
    });
  });
}
