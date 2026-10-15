/// Pins the sync-activation pitfall (OBX_ERROR 10001, see
/// test/sync_annotation_test.dart's doc comment) for the 0.5.0 thread
/// entities: `Thread`, `ThreadState` and `ThreadEntry` are `@Sync()` and
/// refuse `put()` until a local-activation sync client is started;
/// `ThreadOp` is deliberately local-only and writes without any client.
library;

import 'dart:io';

import 'package:remembox/objectbox.g.dart';
import 'package:remembox/src/model.dart';
import 'package:remembox/src/store.dart' show localActivationSyncUrl;
import 'package:test/test.dart';

Thread _thread(DateTime now) => Thread(
  title: 'Website relaunch',
  titleKey: ScopeKey.of('Website relaunch'),
  project: 'company1',
  state: ThreadStates.inProgress,
  stateRecordedAt: now,
);

void main() {
  late Directory tempDir;
  late Store store;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('remembox_sync_threads_');
    store = openStore(directory: tempDir.path);
  });

  tearDown(() {
    store.close();
    tempDir.deleteSync(recursive: true);
  });

  test('KNOWN PITFALL: put() on Thread/ThreadState/ThreadEntry WITHOUT any '
      'sync client fails with OBX 10001', () {
    final now = DateTime.now().toUtc();
    expect(
      () => store.box<Thread>().put(_thread(now)),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(contains('sync-enabled type'), contains('10001')),
        ),
      ),
    );
    expect(
      () => store.box<ThreadState>().put(
        ThreadState(state: ThreadStates.waiting, recordedAt: now),
      ),
      throwsA(isA<StateError>()),
    );
    expect(
      () => store.box<ThreadEntry>().put(ThreadEntry(via: ThreadVia.attach)),
      throwsA(isA<StateError>()),
    );
  });

  test('ThreadOp is local-only: put() succeeds WITHOUT any sync client', () {
    final id = store.box<ThreadOp>().put(
      ThreadOp(
        key: 'retry-1',
        threadId: 7,
        version: 2,
        argsHash: 'hash',
        resultJson: '{"threadId":7}',
      ),
    );
    expect(store.box<ThreadOp>().get(id)!.key, 'retry-1');
  });

  test('a STARTED local-activation client makes Thread/ThreadState/'
      'ThreadEntry writes work, including the three ToOnes', () {
    final client = SyncClient(
      store,
      [localActivationSyncUrl],
      [SyncCredentials.none()],
    )..start();
    addTearDown(client.close);
    final now = DateTime.now().toUtc();

    final threadId = store.box<Thread>().put(_thread(now));
    final entryId = store.box<MemoryEntry>().put(
      MemoryEntry(
        title: 'status report',
        text: 'synthetic status report',
        kind: MemoryKind.snapshot,
        sourceType: MemorySource.note,
        project: 'company1',
        contentHash: 'sync-threads-entry-hash',
      ),
    );
    final stateId = store.box<ThreadState>().put(
      ThreadState(state: ThreadStates.waiting, recordedAt: now)
        ..thread.targetId = threadId,
    );
    final linkId = store.box<ThreadEntry>().put(
      ThreadEntry(via: ThreadVia.note)
        ..thread.targetId = threadId
        ..entry.targetId = entryId,
    );

    expect(store.box<ThreadState>().get(stateId)!.thread.targetId, threadId);
    final link = store.box<ThreadEntry>().get(linkId)!;
    expect(link.thread.targetId, threadId);
    expect(link.entry.targetId, entryId);
  });
}
