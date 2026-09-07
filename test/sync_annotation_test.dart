/// Pins a platform behavior that shaped RememBox's bootstrap: with the
/// Sync-enabled ObjectBox C library, `box.put()` on `@Sync()`-annotated
/// entity types FAILS with OBX_ERROR 10001 ("Can not modify object of
/// sync-enabled type ... because sync has not been activated for this
/// store") until a SyncClient exists for the store.
///
/// This reproduced a pitfall previously reported by another local project.
/// The official docs do not describe a client-free local-only mode for
/// sync-enabled types, so RememBox always creates a client:
/// a real one when OBX_MEMORY_SYNC_URL is set, otherwise an UNSTARTED
/// client on ws://127.0.0.1:0 (reserved port — can never connect or
/// replicate) purely to activate local writes. See
/// `startSyncClient`/`localActivationSyncUrl` in lib/src/store.dart.
///
/// If the second test ever starts failing, ObjectBox changed the
/// activation semantics — re-check the official docs/changelog, do not
/// paper over it.
library;

import 'dart:io';

import 'package:remembox/objectbox.g.dart';
import 'package:remembox/src/model.dart';
import 'package:remembox/src/store.dart' show localActivationSyncUrl;
import 'package:test/test.dart';

MemoryEntry _entry(String hash) => MemoryEntry(
  title: 'sync pitfall',
  text: 'sync pitfall body',
  kind: MemoryKind.fact,
  sourceType: MemorySource.note,
  contentHash: hash,
);

void main() {
  late Directory tempDir;
  late Store store;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('remembox_sync_');
    store = openStore(directory: tempDir.path);
  });

  tearDown(() {
    store.close();
    tempDir.deleteSync(recursive: true);
  });

  test('the Sync-enabled C library is what tool/setup.sh installed', () {
    expect(
      Sync.isAvailable(),
      isTrue,
      reason:
          'tool/setup.sh installs the Sync variant (install.sh --sync); '
          'if this fails the wrong library variant is in lib/',
    );
  });

  test('KNOWN PITFALL: put() on @Sync entities WITHOUT any sync client '
      'fails with OBX 10001', () {
    expect(
      () => store.box<MemoryEntry>().put(_entry('pitfall-hash-1')),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(contains('sync-enabled type'), contains('10001')),
        ),
      ),
    );
  });

  test('a STARTED local-activation client (reserved port 0 — can never '
      'connect) makes local writes and queries work with zero replication; '
      'an unstarted client is NOT enough', () {
    final client = SyncClient(
      store,
      [localActivationSyncUrl],
      [SyncCredentials.none()],
    );
    addTearDown(client.close);

    // Constructing alone does not activate sync — still OBX 10001:
    expect(
      () => store.box<MemoryEntry>().put(_entry('pitfall-hash-2')),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('10001'),
        ),
      ),
      reason: 'an unstarted client must not be treated as activation',
    );

    client.start();

    final box = store.box<MemoryEntry>();
    final id = box.put(_entry('pitfall-hash-2'));
    expect(id, greaterThan(0));

    final found =
        box
            .query(MemoryEntry_.contentHash.equals('pitfall-hash-2'))
            .build()
            .findFirst();
    expect(found, isNotNull);

    // Relations too: ToMany tag links behave normally.
    found!.tags.add(Tag(name: 'sync-pitfall-tag'));
    box.put(found);
    expect(box.get(id)!.tags.map((t) => t.name), contains('sync-pitfall-tag'));
  });
}
