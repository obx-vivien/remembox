/// Pins the same sync-activation pitfall `test/sync_annotation_test.dart`
/// pins for the original 5 entities (OBX_ERROR 10001 — see that file's doc
/// comment for the full explanation), for the 4 new areas/facts entities —
/// 2026-09-21, areas and facts (0.3.0). New file rather than an edit to
/// the existing one (plan §5 / this work package's own instructions):
/// `test/sync_annotation_test.dart` is left untouched.
library;

import 'dart:io';

import 'package:remembox/objectbox.g.dart';
import 'package:remembox/src/model.dart';
import 'package:remembox/src/store.dart' show localActivationSyncUrl;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late Store store;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('remembox_sync_areas_');
    store = openStore(directory: tempDir.path);
  });

  tearDown(() {
    store.close();
    tempDir.deleteSync(recursive: true);
  });

  test(
    'KNOWN PITFALL: put() on ProjectScope/Area/AreaMembership/Fact '
    'WITHOUT any sync client fails with OBX 10001',
    () {
      expect(
        () => store.box<ProjectScope>().put(
          ProjectScope(name: 'acme-app', nameKey: 'acmeapp'),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('sync-enabled type'), contains('10001')),
          ),
        ),
      );
      expect(
        () => store.box<Area>().put(Area(name: 'work', nameKey: 'work')),
        throwsA(isA<StateError>()),
      );
      expect(
        () => store.box<AreaMembership>().put(
          AreaMembership(
            key: AreaMembership.keyFor('work', 'acme-app'),
            area: 'work',
            project: 'acme-app',
          ),
        ),
        throwsA(isA<StateError>()),
      );
      expect(
        () => store.box<Fact>().put(
          Fact(
            project: 'acme-app',
            subject: 'Flat B',
            attribute: 'rent',
            factKey: Fact.keyFor('acme-app', 'Flat B', 'rent'),
            valueType: FactValueType.number,
            valueNumber: 950,
            sourceType: MemorySource.note,
          ),
        ),
        throwsA(isA<StateError>()),
      );
    },
  );

  test(
    'a STARTED local-activation client makes ProjectScope/Area/'
    'AreaMembership/Fact writes work, including their relations '
    '(Fact.supersededBy, Fact.explainedBy)',
    () {
      final client = SyncClient(
        store,
        [localActivationSyncUrl],
        [SyncCredentials.none()],
      )..start();
      addTearDown(client.close);

      final scopeId = store.box<ProjectScope>().put(
        ProjectScope(name: 'acme-app', nameKey: 'acmeapp'),
      );
      expect(scopeId, greaterThan(0));

      final areaId = store.box<Area>().put(
        Area(name: 'work', nameKey: 'work'),
      );
      expect(areaId, greaterThan(0));

      final membershipId = store.box<AreaMembership>().put(
        AreaMembership(
          key: AreaMembership.keyFor('work', 'acme-app'),
          area: 'work',
          project: 'acme-app',
        ),
      );
      expect(membershipId, greaterThan(0));

      final entry = MemoryEntry(
        title: 'explains the rent fact',
        text: 'synthetic explanatory memory',
        kind: MemoryKind.fact,
        sourceType: MemorySource.note,
        project: 'acme-app',
        contentHash: 'sync-areas-facts-entry-hash',
      );
      final entryId = store.box<MemoryEntry>().put(entry);

      final oldFact = Fact(
        project: 'acme-app',
        subject: 'Flat B',
        attribute: 'rent',
        factKey: Fact.keyFor('acme-app', 'Flat B', 'rent'),
        valueType: FactValueType.number,
        valueNumber: 900,
        sourceType: MemorySource.note,
      );
      final oldFactId = store.box<Fact>().put(oldFact);

      final newFact = Fact(
        project: 'acme-app',
        subject: 'Flat B',
        attribute: 'rent',
        factKey: Fact.keyFor('acme-app', 'Flat B', 'rent'),
        valueType: FactValueType.number,
        valueNumber: 950,
        sourceType: MemorySource.note,
      );
      newFact.explainedBy.targetId = entryId;
      final newFactId = store.box<Fact>().put(newFact);

      oldFact.supersededBy.targetId = newFactId;
      store.box<Fact>().put(oldFact);

      final reread = store.box<Fact>().get(oldFactId)!;
      expect(reread.supersededBy.targetId, newFactId);
      final rereadNew = store.box<Fact>().get(newFactId)!;
      expect(rereadNew.explainedBy.targetId, entryId);
    },
  );
}
