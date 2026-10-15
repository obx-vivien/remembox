/// Threads (0.5.0): `thread_update`, `thread_list`, `thread_get` and the
/// thread side of `remember`/`supersede`/`forget`/`project_merge`/`stats`/
/// `areas_list` – service level, persistent test gate, fake embedder.
///
/// Every branch of the state-history rule (amendment A1) has its own test,
/// including the two review scenarios: B1 (a seeded thread with an
/// unknown date, then a dated change today becomes current) and B2
/// (inProgress → waiting → inProgress without eventAt: three rows).
///
/// Synthetic data only: projects `company1`, `client3`, `home`; threads
/// "Website relaunch", "Studio rent renewal", "Brand guide offer".
library;

import 'dart:io';

import 'package:remembox/objectbox.g.dart';
import 'package:remembox/src/embedder.dart';
import 'package:remembox/src/memory_service.dart';
import 'package:remembox/src/model.dart';
import 'package:remembox/src/store.dart' show RegistryMode;
import 'package:test/test.dart';

import 'helpers/test_store_gate.dart';
import 'support/fake_embedder.dart';

const _project = 'company1';

DateTime _truncMs(DateTime d) =>
    DateTime.fromMillisecondsSinceEpoch(d.millisecondsSinceEpoch, isUtc: true);

void main() {
  late Directory tempDir;
  late TestGate testGate;
  late Store store;
  late FakeEmbedder embedder;
  late MemoryService service;
  late MemoryService strict;
  late List<String> logLines;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('remembox_threads_');
    logLines = [];
    testGate = await openTestGate(tempDir.path, log: logLines.add);
    store = testGate.store;
    embedder = FakeEmbedder();
    service = MemoryService(
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
  });

  tearDown(() async {
    await service.dispose();
    await strict.dispose();
    await testGate.close();
    tempDir.deleteSync(recursive: true);
  });

  DateTime day(int d) => DateTime.utc(2026, 10, d);
  String iso(DateTime d) => d.toIso8601String();

  Future<Map<String, Object?>> create({
    String title = 'Website relaunch',
    String state = ThreadStates.inProgress,
    DateTime? eventAt,
    String project = _project,
  }) => service.threadUpdate(
    title: title,
    project: project,
    state: state,
    eventAt: eventAt,
    eventAtIsDate: eventAt != null,
  );

  Future<Map<String, Object?>> setState(
    int id,
    String state, {
    DateTime? eventAt,
  }) => service.threadUpdate(
    threadId: id,
    state: state,
    eventAt: eventAt,
    eventAtIsDate: eventAt != null,
  );

  Thread threadRow(int id) => store.box<Thread>().get(id)!;
  int stateRows() => store.box<ThreadState>().count();

  Future<void> expectRejected(
    Future<Object?> Function() call,
    Object messageMatcher,
  ) async {
    final threads = store.box<Thread>().count();
    final rows = stateRows();
    final links = store.box<ThreadEntry>().count();
    final entries = store.box<MemoryEntry>().count();
    await expectLater(
      call(),
      throwsA(
        isA<ValidationException>().having(
          (e) => e.message,
          'message',
          messageMatcher,
        ),
      ),
    );
    expect(store.box<Thread>().count(), threads, reason: 'no thread written');
    expect(stateRows(), rows, reason: 'no state row written');
    expect(store.box<ThreadEntry>().count(), links, reason: 'no attachment');
    expect(store.box<MemoryEntry>().count(), entries, reason: 'no entry');
  }

  group('create and resolve', () {
    test('create: one thread, one state row, version 1, project '
        'registered, since unknown', () async {
      final r = await create();
      expect(r['action'], 'created');
      expect(r['state'], ThreadStates.inProgress);
      expect(r['since'], isNull);
      expect(r['sinceRecordedAt'], isNotNull);
      expect(r['version'], 1);
      expect(r.containsKey('previousVersion'), isFalse);
      expect((r['stateRow'] as Map)['appliedAsHistory'], isFalse);
      expect(store.box<Thread>().count(), 1);
      expect(stateRows(), 1);
      expect(store.box<ProjectScope>().count(), 1);
      expect(
        logLines.where(
          (l) => l.startsWith('[memory] thread_update thread ') &&
              l.contains('action=created'),
        ),
        hasLength(1),
      );
    });

    test('title + project resolve an existing live thread across '
        'case/space variants – updated, not created twice', () async {
      final id = (await create())['threadId'] as int;
      final r = await service.threadUpdate(
        title: 'website  Relaunch',
        project: _project,
        state: ThreadStates.waiting,
      );
      expect(r['threadId'], id);
      expect(r['action'], 'updated');
      expect(r['title'], 'Website relaunch', reason: 'no rename by title');
      expect(store.box<Thread>().count(), 1);
    });

    test('state is required to create; title + project without anything '
        'else on an existing thread is "nothing to do"', () async {
      await expectRejected(
        () => service.threadUpdate(title: 'Website relaunch', project: _project),
        contains('state is required to create a thread'),
      );
      await create();
      await expectRejected(
        () => service.threadUpdate(title: 'Website relaunch', project: _project),
        contains('nothing to do'),
      );
      await expectRejected(
        () => service.threadUpdate(threadId: 1),
        contains('nothing to do'),
      );
    });

    test('missing identification, unknown thread, bad title', () async {
      await expectRejected(
        () => service.threadUpdate(state: ThreadStates.waiting),
        contains('pass threadId (to update) or title and project'),
      );
      await expectRejected(
        () => service.threadUpdate(threadId: 12, state: ThreadStates.waiting),
        'thread_update: thread 12 does not exist.',
      );
      await expectRejected(
        () => create(title: ' padded'),
        contains('leading/trailing whitespace'),
      );
      await expectRejected(
        () => create(title: 'x' * 201),
        contains('201'),
      );
      await expectRejected(
        () => create(title: 'tab\there'),
        contains('control characters'),
      );
    });

    test('an unknown state is rejected in BOTH registry modes with the '
        'near-match suggestion; no attribute register is involved', () async {
      for (final s in [service, strict]) {
        await expectRejected(
          () => s.threadUpdate(
            title: 'Website relaunch',
            project: _project,
            state: 'In Progress',
          ),
          allOf(
            contains('"In Progress" is not a thread state'),
            contains('Did you mean "inProgress"?'),
            contains('Nothing was written.'),
          ),
        );
      }
      await expectRejected(
        () => create(state: 'läuft'),
        allOf(contains('not a thread state'), isNot(contains('Did you mean'))),
      );
      // An attribute "state" with other values does not restrict threads
      // (amendment A2: no coupling to the attribute register).
      await service.attributeDefine(
        attribute: 'state',
        description: 'Something else.',
        values: ['open', 'closed'],
      );
      expect((await create())['action'], 'created');
    });

    test('a future eventAt is rejected: a timestamp beyond the 5-minute '
        'skew, a date-only value after today; today and a timestamp within '
        'the skew are accepted', () async {
      final now = DateTime.now();
      await expectRejected(
        () => service.threadUpdate(
          title: 'Website relaunch',
          project: _project,
          state: ThreadStates.inProgress,
          eventAt: now.toUtc().add(const Duration(hours: 1)),
        ),
        contains('is in the future'),
      );
      final tomorrow = now.add(const Duration(days: 1));
      await expectRejected(
        () => service.threadUpdate(
          title: 'Website relaunch',
          project: _project,
          state: ThreadStates.inProgress,
          eventAt: DateTime.utc(tomorrow.year, tomorrow.month, tomorrow.day),
          eventAtIsDate: true,
        ),
        contains('is in the future'),
      );
      final today = await service.threadUpdate(
        title: 'Website relaunch',
        project: _project,
        state: ThreadStates.inProgress,
        eventAt: DateTime.utc(now.year, now.month, now.day),
        eventAtIsDate: true,
      );
      expect(today['action'], 'created');
      final skew = await service.threadUpdate(
        title: 'Brand guide offer',
        project: _project,
        state: ThreadStates.waiting,
        eventAt: now.toUtc().add(const Duration(minutes: 2)),
      );
      expect(skew['action'], 'created');
    });
  });

  group('state history (amendment A1)', () {
    test('same state without eventAt: unchanged, no row, no version bump',
        () async {
      final id = (await create())['threadId'] as int;
      final r = await setState(id, ThreadStates.inProgress);
      expect(r['action'], 'unchanged');
      expect(r['version'], 1);
      expect(r.containsKey('stateRow'), isFalse);
      expect(stateRows(), 1);
    });

    test('same state, unknown date, earlier eventAt: dated in place '
        '(no new row, version +1)', () async {
      final id = (await create())['threadId'] as int;
      final r = await setState(id, ThreadStates.inProgress, eventAt: day(7));
      expect(r['action'], 'dated');
      expect(r['since'], iso(day(7)));
      expect(r['version'], 2);
      expect(stateRows(), 1);
      expect(threadRow(id).stateEventAt, day(7));
      // The same date again: unchanged.
      final again = await setState(id, ThreadStates.inProgress, eventAt: day(7));
      expect(again['action'], 'unchanged');
      expect(again['version'], 2);
    });

    test('dating is refused when eventAt is after the row was recorded',
        () async {
      final id = (await create())['threadId'] as int;
      // A timestamp (not a date): compared as an instant.
      final r = await service.threadUpdate(
        threadId: id,
        state: ThreadStates.inProgress,
        eventAt: DateTime.now().toUtc().add(const Duration(minutes: 1)),
      );
      expect(r['action'], 'unchanged');
      expect(r['warning'], contains('can only be filled in with an earlier'));
      expect(threadRow(id).stateEventAt, isNull);
      expect(r['version'], 1);
    });

    test('dating is refused when an earlier state is dated after eventAt',
        () async {
      final id = (await create(eventAt: day(5)))['threadId'] as int;
      await setState(id, ThreadStates.waiting);
      final r = await setState(id, ThreadStates.waiting, eventAt: day(1));
      expect(r['action'], 'unchanged');
      expect(r['warning'], contains('before the earlier state inProgress'));
      expect(threadRow(id).stateEventAt, isNull);
    });

    test('a known date is never corrected', () async {
      final id = (await create(eventAt: day(5)))['threadId'] as int;
      final r = await setState(id, ThreadStates.inProgress, eventAt: day(6));
      expect(r['action'], 'unchanged');
      expect(r['warning'], contains('dates are not corrected in 0.5.0'));
      expect(threadRow(id).stateEventAt, day(5));
    });

    test('a new state with a later date becomes current (updated)', () async {
      final id = (await create(eventAt: day(1)))['threadId'] as int;
      final r = await setState(id, ThreadStates.waiting, eventAt: day(5));
      expect(r['action'], 'updated');
      expect(r['state'], ThreadStates.waiting);
      expect(r['since'], iso(day(5)));
      expect(r['version'], 2);
      expect(r['previousVersion'], 1);
      expect(stateRows(), 2);
    });

    test('a new state dated exactly at the current date becomes current',
        () async {
      final id = (await create(eventAt: day(5)))['threadId'] as int;
      final r = await setState(id, ThreadStates.waiting, eventAt: day(5));
      expect(r['action'], 'updated');
      expect(r['state'], ThreadStates.waiting);
    });

    test('late information dated before the current state is stored as '
        'history only (historyAdded, logged); repeating it changes nothing',
        () async {
      final id = (await create(eventAt: day(1)))['threadId'] as int;
      await setState(id, ThreadStates.waiting, eventAt: day(5));
      logLines.clear();
      final r = await setState(id, ThreadStates.paused, eventAt: day(3));
      expect(r['action'], 'historyAdded');
      expect(r['state'], ThreadStates.waiting, reason: 'current unchanged');
      expect(r['since'], iso(day(5)));
      expect((r['stateRow'] as Map)['appliedAsHistory'], isTrue);
      expect(r['warning'], contains('stored as history only'));
      expect(r['version'], 3);
      expect(logLines.where((l) => l.contains('late info')), hasLength(1));
      final rows = store.box<ThreadState>().getAll();
      expect(rows.where((r) => r.asHistory), hasLength(1));

      final again = await setState(id, ThreadStates.paused, eventAt: day(3));
      expect(again['action'], 'unchanged');
      expect(again['warning'], contains('repeated late information'));
      expect(stateRows(), 3);
      expect(again['version'], 3);
    });

    test('B1: a thread with an unknown date, then a dated change today – '
        'the change becomes current (with a "previous state had no date" '
        'warning)', () async {
      final id = (await create())['threadId'] as int;
      final now = DateTime.now();
      final today = DateTime.utc(now.year, now.month, now.day);
      final r = await setState(id, ThreadStates.waiting, eventAt: today);
      expect(r['action'], 'updated');
      expect(r['state'], ThreadStates.waiting);
      expect(r['since'], iso(today));
      expect(r['warning'], contains('had no date'));
    });

    test('B2: inProgress → waiting → inProgress without eventAt – three '
        'rows, current inProgress, version 3', () async {
      final id = (await create())['threadId'] as int;
      await setState(id, ThreadStates.waiting);
      final r = await setState(id, ThreadStates.inProgress);
      expect(r['action'], 'updated');
      expect(r['state'], ThreadStates.inProgress);
      expect(r['version'], 3);
      expect(stateRows(), 3);
    });

    test('closing and reopening: a later live state on a done thread '
        'becomes current', () async {
      final id = (await create())['threadId'] as int;
      await setState(id, ThreadStates.done);
      final r = await setState(id, ThreadStates.inProgress);
      expect(r['action'], 'updated');
      expect(r['state'], ThreadStates.inProgress);
    });
  });

  group('titles', () {
    test('rename onto another live title is rejected, nothing changed',
        () async {
      await create();
      final b = (await create(title: 'Brand guide offer'))['threadId'] as int;
      await expectRejected(
        () => service.threadUpdate(threadId: b, title: 'website relaunch'),
        allOf(
          contains('a live thread titled "Website relaunch" already exists'),
          contains('(id 1, state inProgress)'),
          contains('Nothing was written.'),
        ),
      );
      expect(threadRow(b).title, 'Brand guide offer');
      expect(threadRow(b).version, 1);
      final ok = await service.threadUpdate(threadId: b, title: 'Brand guide');
      expect(ok['renamedFrom'], 'Brand guide offer');
      expect(ok['title'], 'Brand guide');
      expect(ok['version'], 2);
      expect(ok['action'], 'updated');
    });

    test('a closed thread with the same title: a new thread is created, '
        'with a warning naming the old id', () async {
      final old = (await create())['threadId'] as int;
      await setState(old, ThreadStates.done, eventAt: day(2));
      final r = await create();
      expect(r['action'], 'created');
      expect(r['threadId'], isNot(old));
      expect(
        r['warning'],
        contains('a closed thread with the same title exists (id $old, done '
            'since 2026-10-02)'),
      );
    });

    test('reopening is blocked while another live thread has the title',
        () async {
      final old = (await create())['threadId'] as int;
      await setState(old, ThreadStates.done);
      final fresh = (await create())['threadId'] as int;
      await expectRejected(
        () => setState(old, ThreadStates.inProgress),
        allOf(contains('(id $fresh, state inProgress)'), contains('rename')),
      );
      expect(threadRow(old).state, ThreadStates.done);
    });

    test('two live threads with one title (as after a sync): by-title '
        'calls are rejected with both ids', () async {
      final now = DateTime.now().toUtc();
      for (var i = 0; i < 2; i++) {
        store.box<Thread>().put(
          Thread(
            title: 'Website relaunch',
            titleKey: ScopeKey.of('Website relaunch'),
            project: _project,
            state: ThreadStates.inProgress,
            stateRecordedAt: now,
          ),
        );
      }
      await expectRejected(
        () => create(state: ThreadStates.waiting),
        contains('2 live threads match the title "Website relaunch" in '
            'project "company1" (ids 1, 2) – pass threadId'),
      );
    });
  });

  group('project move', () {
    test('move: projectFrom, version +1, target registered', () async {
      final id = (await create())['threadId'] as int;
      final r = await service.threadUpdate(threadId: id, project: 'client3');
      expect(r['projectFrom'], _project);
      expect(r['project'], 'client3');
      expect(r['version'], 2);
      expect(
        store
            .box<ProjectScope>()
            .getAll()
            .map((p) => p.name),
        containsAll([_project, 'client3']),
      );
    });

    test('strict registry mode: create and move need a registered project',
        () async {
      await expectRejected(
        () => strict.threadUpdate(
          title: 'Website relaunch',
          project: _project,
          state: ThreadStates.inProgress,
        ),
        contains('is not registered (strict registry mode)'),
      );
      await strict.projectSet(name: _project, description: 'Company one.');
      final id =
          (await strict.threadUpdate(
                title: 'Website relaunch',
                project: _project,
                state: ThreadStates.inProgress,
              ))['threadId']
              as int;
      await expectRejected(
        () => strict.threadUpdate(threadId: id, project: 'client3'),
        contains('project "client3" is not registered'),
      );
      expect(threadRow(id).project, _project);
    });
  });

  group('pausedUntil', () {
    test('set with paused; leaving paused clears it (logged); a pausedUntil '
        'with another state warns; clearPausedUntil clears it', () async {
      final id = (await create())['threadId'] as int;
      final p = await service.threadUpdate(
        threadId: id,
        state: ThreadStates.paused,
        pausedUntil: day(30),
      );
      expect(p['pausedUntil'], iso(day(30)));
      expect(p.containsKey('warning'), isFalse);
      expect(
        store.box<ThreadState>().getAll().last.pausedUntil,
        day(30),
        reason: 'audit copy on the state row',
      );
      logLines.clear();
      final left = await setState(id, ThreadStates.inProgress);
      expect(left['pausedUntilCleared'], isTrue);
      expect(left['pausedUntil'], isNull);
      expect(logLines.where((l) => l.contains('pausedUntil cleared')), hasLength(1));

      final warned = await service.threadUpdate(
        threadId: id,
        pausedUntil: day(29),
      );
      expect(warned['warning'], contains('not paused'));
      expect(warned['pausedUntil'], iso(day(29)));
      final versionBefore = warned['version'] as int;
      final cleared = await service.threadUpdate(
        threadId: id,
        clearPausedUntil: true,
      );
      expect(cleared['pausedUntilCleared'], isTrue);
      expect(cleared['version'], versionBefore + 1);
      await expectRejected(
        () => service.threadUpdate(
          threadId: id,
          pausedUntil: day(29),
          clearPausedUntil: true,
        ),
        contains('not both'),
      );
    });
  });

  group('note and attachments', () {
    test('note: stored as snapshot in the thread project, attached, '
        'indexed (reindex re-embeds nothing); version unchanged by the '
        'attachment', () async {
      final id = (await create())['threadId'] as int;
      final r = await service.threadUpdate(
        threadId: id,
        note: 'Waiting for the copy from the client.',
        sourceRef: 'chat:session-1',
      );
      final note = r['note'] as Map<String, Object?>;
      expect(note['duplicate'], isFalse);
      expect(note['indexed'], isTrue);
      expect(r['attached'], [note['id']]);
      expect(r['version'], 1, reason: 'attachments do not bump the version');
      expect(r['action'], 'updated');
      final entry = store.box<MemoryEntry>().get(note['id'] as int)!;
      expect(entry.kind, MemoryKind.snapshot);
      expect(entry.project, _project);
      expect(entry.sourceRef, 'chat:session-1');
      expect(entry.tags, isEmpty);
      expect(store.box<MemoryIndex>().count(), 1);
      final link = store.box<ThreadEntry>().getAll().single;
      expect(link.via, ThreadVia.note);
      final reindex = await service.reindex();
      expect(reindex['reembedded'], 0);
      expect(reindex['created'], 0);
    });

    test('note text already stored: the existing entry is attached, with a '
        'warning', () async {
      final id = (await create())['threadId'] as int;
      final existing =
          (await service.remember(
                text: 'Copy arrived on Monday.',
                project: 'client3',
              ))['id']
              as int;
      final r = await service.threadUpdate(
        threadId: id,
        note: 'Copy  arrived on Monday.',
      );
      expect(r['note'], {'id': existing, 'duplicate': true});
      expect(r['attached'], [existing]);
      expect(r['attachedFromOtherProject'], [existing]);
      expect(r['warning'], contains('already stored as entry $existing'));
      expect(store.box<MemoryEntry>().count(), 1);
    });

    test('embedding down: the note is stored and attached, indexed: false, '
        'with a warning', () async {
      final id = (await create())['threadId'] as int;
      embedder.failWith = EmbedderException('Ollama is down.');
      final r = await service.threadUpdate(threadId: id, note: 'Offer sent.');
      final note = r['note'] as Map<String, Object?>;
      expect(note['indexed'], isFalse);
      expect(r['warning'], contains('NOT indexed yet'));
      expect(store.box<MemoryIndex>().count(), 0);
      expect(store.box<ThreadEntry>().count(), 1);
    });

    test('attachEntryIds: attached, already attached, other project; a '
        'missing id or 51 ids reject the whole call', () async {
      final id = (await create())['threadId'] as int;
      final a = (await service.remember(text: 'one', project: _project))['id']
          as int;
      final b = (await service.remember(text: 'two', project: 'client3'))['id']
          as int;
      final r = await service.threadUpdate(threadId: id, attachEntryIds: [a, b]);
      expect(r['attached'], [a, b]);
      expect(r['attachedFromOtherProject'], [b]);
      expect(r['warning'], contains('belongs to another project than the thread'));
      expect(r['version'], 1);
      final again = await service.threadUpdate(threadId: id, attachEntryIds: [a]);
      expect(again['alreadyAttached'], [a]);
      expect(again['action'], 'unchanged');

      await expectRejected(
        () => service.threadUpdate(
          threadId: id,
          state: ThreadStates.waiting,
          attachEntryIds: [a, 999],
        ),
        'thread_update: id(s) do not exist, nothing written: 999.',
      );
      expect(threadRow(id).state, ThreadStates.inProgress);
      await expectRejected(
        () => service.threadUpdate(
          threadId: id,
          attachEntryIds: [for (var i = 1; i <= 51; i++) i],
        ),
        contains('"attachEntryIds" has 51 entries, exceeding the 50 id limit'),
      );
    });
  });

  group('version and idempotency', () {
    test('a stale expectedVersion is a ThreadVersionConflict with the '
        'current thread; nothing written', () async {
      final id = (await create())['threadId'] as int;
      await setState(id, ThreadStates.waiting);
      final rows = stateRows();
      await expectLater(
        service.threadUpdate(
          threadId: id,
          state: ThreadStates.done,
          expectedVersion: 1,
        ),
        throwsA(
          isA<ThreadVersionConflict>()
              .having(
                (e) => e.message,
                'message',
                'thread_update: thread $id is at version 2, you expected 1 – '
                    're-read it (thread_get) and retry. Nothing was written.',
              )
              .having((e) => e.current['version'], 'current.version', 2)
              .having(
                (e) => e.current['state'],
                'current.state',
                ThreadStates.waiting,
              ),
        ),
      );
      expect(stateRows(), rows);
      expect(logLines.where((l) => l.contains('version conflict')), hasLength(1));
      final ok = await service.threadUpdate(
        threadId: id,
        state: ThreadStates.done,
        expectedVersion: 2,
      );
      expect(ok['version'], 3);
      await expectRejected(
        () => service.threadUpdate(
          title: 'Brand guide offer',
          project: _project,
          state: ThreadStates.waiting,
          expectedVersion: 1,
        ),
        contains('expectedVersion needs threadId'),
      );
    });

    test('idempotencyKey: a retry with the same arguments replays the '
        'first result without writing; other arguments are rejected',
        () async {
      final first = await service.threadUpdate(
        title: 'Website relaunch',
        project: _project,
        state: ThreadStates.inProgress,
        note: 'Kick-off done.',
        idempotencyKey: 'seed-1',
      );
      embedder.calls.clear();
      final replay = await service.threadUpdate(
        title: 'Website relaunch',
        project: _project,
        state: ThreadStates.inProgress,
        note: 'Kick-off  done.',
        idempotencyKey: 'seed-1',
      );
      expect(replay['replayed'], isTrue);
      expect(Map.of(replay)..remove('replayed'), first);
      expect(embedder.calls, isEmpty, reason: 'a replay embeds nothing');
      expect(store.box<Thread>().count(), 1);
      expect(stateRows(), 1);
      expect(store.box<MemoryEntry>().count(), 1);
      expect(store.box<ThreadOp>().count(), 1);
      expect(logLines.where((l) => l.contains('replayed key "seed-1"')), hasLength(1));

      await expectRejected(
        () => service.threadUpdate(
          title: 'Website relaunch',
          project: _project,
          state: ThreadStates.waiting,
          idempotencyKey: 'seed-1',
        ),
        contains('idempotencyKey "seed-1" was already used for a different '
            'request (thread ${first['threadId']})'),
      );
    });

    test('idempotency rows older than 30 days are pruned by the next call '
        '(logged)', () async {
      store.box<ThreadOp>().put(
        ThreadOp(
          key: 'old',
          threadId: 99,
          version: 1,
          argsHash: 'h',
          resultJson: '{}',
          createdAt: DateTime.now().toUtc().subtract(const Duration(days: 31)),
        ),
      );
      store.box<ThreadOp>().put(
        ThreadOp(
          key: 'recent',
          threadId: 99,
          version: 1,
          argsHash: 'h',
          resultJson: '{}',
          createdAt: DateTime.now().toUtc().subtract(const Duration(days: 29)),
        ),
      );
      await create();
      expect(store.box<ThreadOp>().getAll().map((o) => o.key), ['recent']);
      expect(
        logLines.where((l) => l.contains('pruned 1 idempotency row(s)')),
        hasLength(1),
      );
    });

    test('a bad idempotencyKey is rejected', () async {
      await expectRejected(
        () => service.threadUpdate(
          title: 'Website relaunch',
          project: _project,
          state: ThreadStates.inProgress,
          idempotencyKey: 'k' * 129,
        ),
        contains('idempotencyKey must be 1-128 characters'),
      );
    });
  });

  group('thread_list', () {
    test('filters, closed threads, entry counts, pauseElapsed, limit',
        () async {
      final a = (await create())['threadId'] as int;
      final b = (await create(title: 'Brand guide offer', project: 'client3'))[
              'threadId']
          as int;
      final c = (await create(title: 'Studio rent renewal'))['threadId'] as int;
      await service.threadUpdate(
        threadId: c,
        state: ThreadStates.paused,
        pausedUntil: day(1),
      );
      final d = (await create(title: 'Old offer'))['threadId'] as int;
      await setState(d, ThreadStates.dropped);
      await service.threadUpdate(threadId: a, note: 'Draft reviewed.');

      final all = await service.threadList();
      expect(all['count'], 3);
      expect(all['total'], 3);
      expect(all['truncated'], isFalse);
      final rows = (all['threads'] as List).cast<Map<String, Object?>>();
      expect(rows.map((r) => r['id']), [b, c, a], reason: 'project, title');
      expect(rows.firstWhere((r) => r['id'] == a)['entryCount'], 1);
      final paused = rows.firstWhere((r) => r['id'] == c);
      expect(paused['pauseElapsed'], isTrue);

      final withClosed = await service.threadList(includeClosed: true);
      expect(withClosed['count'], 4);
      final dropped = await service.threadList(states: [ThreadStates.dropped]);
      expect((dropped['threads'] as List).single['id'], d);
      final company = await service.threadList(project: _project);
      expect(company['count'], 2);
      final limited = await service.threadList(limit: 1);
      expect(limited['count'], 1);
      expect(limited['total'], 3);
      expect(limited['truncated'], isTrue);
      expect(limited['warning'], contains('raise limit'));
      expect(
        () => service.threadList(limit: 501),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => service.threadList(states: ['open']),
        throwsA(isA<ValidationException>()),
      );
    });

    test('area filter resolves to its projects', () async {
      await service.areaSet(name: 'work');
      await service.projectSet(name: 'client3', addAreas: ['work']);
      await create();
      await create(title: 'Brand guide offer', project: 'client3');
      final r = await service.threadList(area: 'work');
      expect(
        (r['threads'] as List).map((t) => (t as Map)['project']),
        ['client3'],
      );
      final none = await service.threadList(area: 'work', project: _project);
      expect(none['count'], 0);
      expect(none['warning'], contains('is not a member of area'));
    });
  });

  group('thread_get', () {
    test('history order and current flag, entries newest first with '
        'superseded/expired flags, by id and by title', () async {
      final id = (await create(eventAt: day(1)))['threadId'] as int;
      await setState(id, ThreadStates.waiting, eventAt: day(5));
      await setState(id, ThreadStates.paused, eventAt: day(3));
      final first =
          (await service.remember(text: 'first note', project: _project))['id']
              as int;
      await service.threadUpdate(threadId: id, attachEntryIds: [first]);
      await service.supersede(first, text: 'first note, corrected');
      final second =
          (await service.remember(text: 'second note', project: _project))['id']
              as int;
      await service.threadUpdate(threadId: id, attachEntryIds: [second]);
      await service.forget(second);

      final r = await service.threadGet(threadId: id, includeText: true);
      expect(r['state'], ThreadStates.waiting);
      final history = (r['history'] as List).cast<Map<String, Object?>>();
      expect(history.map((h) => h['state']), [
        ThreadStates.inProgress,
        ThreadStates.paused,
        ThreadStates.waiting,
      ]);
      expect(history.map((h) => h['current']), [false, false, true]);
      expect(history.map((h) => h['asHistory']), [false, true, false]);
      final entries = (r['entries'] as List).cast<Map<String, Object?>>();
      // second, then the supersede-carried replacement and first.
      expect(entries.first['id'], second);
      expect(entries.first['expired'], isTrue);
      expect(entries.first['text'], 'second note');
      final firstRow = entries.firstWhere((e) => e['id'] == first);
      expect(firstRow['supersededBy'], isNotNull);
      expect(firstRow['via'], ThreadVia.attach);
      expect(r['entryCount'], 3);
      expect(r['_provenance_note'], isNotNull);

      final byTitle = await service.threadGet(
        title: 'website relaunch',
        project: _project,
      );
      expect(byTitle['id'], id);
      expect((byTitle['entries'] as List).first, isNot(contains('text')));
    });

    test('a dangling attachment is reported in missingEntryIds', () async {
      final id = (await create())['threadId'] as int;
      final e = (await service.remember(text: 'gone', project: _project))['id']
          as int;
      await service.threadUpdate(threadId: id, attachEntryIds: [e]);
      // Bypass forget (as a cross-device replace would).
      store.box<MemoryEntry>().remove(e);
      final r = await service.threadGet(threadId: id);
      // objectbox-dart 5.3.2 reads the ToOne of a removed target back as
      // id 0 (measured), so the attachment row is reported by its own id.
      final link = store.box<ThreadEntry>().getAll().single;
      expect(link.entry.targetId, 0);
      expect(r['danglingAttachmentIds'], [link.id]);
      expect(r.containsKey('missingEntryIds'), isFalse);
      expect(r['warning'], contains('no longer exists'));
      expect(r['entries'], isEmpty);
      expect(r['entryCount'], 1);
    });

    test('a tampered denormalized state is reported (read-only, logged) and '
        'repaired by the next thread_update', () async {
      final id = (await create())['threadId'] as int;
      final t = threadRow(id)..state = ThreadStates.done;
      store.box<Thread>().put(t);
      logLines.clear();
      final r = await service.threadGet(threadId: id);
      expect(r['warning'], contains('disagrees with its history'));
      expect(logLines.where((l) => l.contains('disagrees')), hasLength(1));
      expect(threadRow(id).state, ThreadStates.done, reason: 'read-only');
      await service.threadUpdate(threadId: id, note: 'Status checked.');
      expect(threadRow(id).state, ThreadStates.inProgress);
    });

    test('by title: a closed thread is found when no live one exists; an '
        'unknown title is rejected', () async {
      final id = (await create())['threadId'] as int;
      await setState(id, ThreadStates.done);
      final r = await service.threadGet(
        title: 'Website relaunch',
        project: _project,
      );
      expect(r['id'], id);
      expect(r['closed'], isTrue);
      await expectLater(
        service.threadGet(title: 'Nope', project: _project),
        throwsA(isA<ValidationException>()),
      );
    });
  });

  group('remember / supersede / forget / project_merge / stats', () {
    test('remember(threadId) attaches the entry – also on the duplicate '
        'path; an unknown thread rejects the call', () async {
      final id = (await create())['threadId'] as int;
      final r = await service.remember(
        text: 'Status: copy received.',
        project: _project,
        kind: MemoryKind.snapshot,
        threadId: id,
      );
      expect(r['thread'], {'id': id, 'attached': true, 'version': 1});
      final dup = await service.remember(
        text: 'Status: copy received.',
        project: _project,
        threadId: id,
      );
      expect(dup['duplicate'], isTrue);
      expect(dup['thread'], {'id': id, 'attached': false, 'version': 1});
      expect(store.box<ThreadEntry>().count(), 1);
      expect(store.box<ThreadEntry>().getAll().single.via, ThreadVia.remember);
      await expectLater(
        service.remember(text: 'never', project: _project, threadId: 77),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            'remember: thread 77 does not exist.',
          ),
        ),
      );
      expect(store.box<MemoryEntry>().count(), 1);
    });

    test('supersede carries the old entry\'s thread attachments to the new '
        'entry (the old one stays attached)', () async {
      final id = (await create())['threadId'] as int;
      final old =
          (await service.remember(
                text: 'Offer: 3 days.',
                project: _project,
                threadId: id,
              ))['id']
              as int;
      final r = await service.supersede(old, text: 'Offer: 4 days.');
      expect(r['threadsCarried'], [id]);
      final links = store.box<ThreadEntry>().getAll();
      expect(links.map((l) => l.entry.targetId), containsAll([old, r['newId']]));
      expect(
        links.firstWhere((l) => l.entry.targetId == r['newId']).via,
        ThreadVia.supersede,
      );
      expect(logLines.where((l) => l.contains('supersede carried 1')), hasLength(1));
      final plain = await service.supersede(
        (await service.remember(text: 'free', project: _project))['id'] as int,
        text: 'free, corrected',
      );
      expect(plain.containsKey('threadsCarried'), isFalse);
    });

    test('forget(hard) removes the thread attachments (counted); a soft '
        'forget keeps them', () async {
      final id = (await create())['threadId'] as int;
      final e =
          (await service.remember(
                text: 'to delete',
                project: _project,
                threadId: id,
              ))['id']
              as int;
      final soft = await service.forget(e);
      expect(soft.containsKey('threadEntriesRemoved'), isFalse);
      expect(store.box<ThreadEntry>().count(), 1);
      final hard = await service.forget(e, hard: true);
      expect(hard['threadEntriesRemoved'], 1);
      expect(store.box<ThreadEntry>().count(), 0);
      expect(threadRow(id).version, 1);
    });

    test('project_merge moves threads (version +1) and reports live title '
        'conflicts; the dry run reports the same and moves nothing',
        () async {
      final keep = (await create(project: 'client3'))['threadId'] as int;
      final moved = (await create())['threadId'] as int;
      final other = (await create(title: 'Brand guide offer'))['threadId'] as int;
      final dry = await service.projectMerge(
        from: _project,
        into: 'client3',
        dryRun: true,
      );
      expect(dry['threadsMoved'], 2);
      expect(dry['threadTitleConflicts'], [
        {
          'threadId': moved,
          'title': 'Website relaunch',
          'conflictsWithThreadId': keep,
        },
      ]);
      expect(threadRow(moved).project, _project);
      final real = await service.projectMerge(from: _project, into: 'client3');
      expect(real['threadsMoved'], 2);
      expect(real['threadTitleConflicts'], dry['threadTitleConflicts']);
      expect(real['warning'], contains('resolve with thread_update'));
      expect(threadRow(moved).project, 'client3');
      expect(threadRow(moved).version, 2);
      expect(threadRow(other).project, 'client3');
      await expectRejected(
        () => service.threadUpdate(
          title: 'Website relaunch',
          project: 'client3',
          state: ThreadStates.waiting,
        ),
        contains('2 live threads match'),
      );
    });

    test('stats.threads counts threads, states, attachments and '
        'idempotency rows', () async {
      final id = (await create())['threadId'] as int;
      await create(title: 'Old offer', state: ThreadStates.done);
      await service.threadUpdate(
        threadId: id,
        note: 'A report.',
        idempotencyKey: 'k1',
      );
      final s = (await service.stats())['threads'] as Map<String, Object?>;
      expect(s['total'], 2);
      expect(s['live'], 1);
      expect((s['byState'] as Map)['inProgress'], 1);
      expect((s['byState'] as Map)['done'], 1);
      expect((s['byState'] as Map).keys, ThreadStates.all);
      expect(s['threadEntries'], 1);
      expect(s['idempotencyRows'], 1);
    });

    test('a project used only by a thread counts as used: areas_list lists '
        'it as unregistered and the registry backfill registers it',
        () async {
      store.box<Thread>().put(
        Thread(
          title: 'Synced in',
          titleKey: ScopeKey.of('Synced in'),
          project: 'home',
          state: ThreadStates.planned,
          stateRecordedAt: DateTime.now().toUtc(),
        ),
      );
      final areas = await service.areasList();
      expect(areas['unregisteredProjects'], ['home']);
      final backfill = await service.backfillProjectRegistry();
      expect(backfill['registered'], 1);
      expect(
        store.box<ProjectScope>().getAll().map((p) => p.name),
        ['home'],
      );
    });
  });

  group('review fixes', () {
    test('a call that waited for the lock records its time under the lock: '
        'the call that commits last wins and reports its own state',
        () async {
      final slow = MemoryService(
        gate: testGate.gate,
        embedder: FakeEmbedder(embedDelay: const Duration(milliseconds: 300)),
        log: logLines.add,
      );
      addTearDown(slow.dispose);
      final id = (await create())['threadId'] as int;
      // A starts first and embeds its note for 300 ms; B starts later and
      // commits first.
      final a = slow.threadUpdate(
        threadId: id,
        state: ThreadStates.waiting,
        note: 'Status from the slow call.',
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final b = await setState(id, ThreadStates.paused);
      expect(b['state'], ThreadStates.paused);
      final ra = await a;
      expect(ra['action'], 'updated');
      expect(ra['state'], ThreadStates.waiting);
      expect(threadRow(id).state, ThreadStates.waiting);
      expect(ra['version'], 3);
    });

    test('a stale stored state is repaired and persisted even when the call '
        'changes nothing else (logged, version unchanged)', () async {
      final id = (await create())['threadId'] as int;
      store.box<Thread>().put(threadRow(id)..state = ThreadStates.waiting);
      logLines.clear();
      final r = await setState(id, ThreadStates.inProgress);
      expect(threadRow(id).state, ThreadStates.inProgress);
      expect(r['state'], ThreadStates.inProgress);
      expect(r['version'], 1);
      expect(r['warning'], contains('was repaired'));
      expect(
        logLines.where(
          (l) => l.contains('repaired thread $id: stored state waiting'),
        ),
        hasLength(1),
      );
    });

    test('supersede with identical text and threadId is rejected before '
        'anything is attached', () async {
      final id = (await create())['threadId'] as int;
      final old = (await service.remember(text: 'same', project: _project))[
          'id'] as int;
      await expectLater(
        service.supersede(old, text: 'same', threadId: id),
        throwsA(isA<ValidationException>()),
      );
      expect(store.box<ThreadEntry>().count(), 0);
    });

    test('eventAt without state is rejected', () async {
      final id = (await create())['threadId'] as int;
      await expectRejected(
        () => service.threadUpdate(
          threadId: id,
          eventAt: day(1),
          eventAtIsDate: true,
          note: 'started on the 1st',
        ),
        contains('eventAt needs state'),
      );
    });

    test('pausedUntil with late information stays on the history row; with '
        'refused information it is not applied; a note in the same call is '
        'not reported as "nothing changed"', () async {
      final id = (await service.threadUpdate(
        title: 'Studio rent renewal',
        project: _project,
        state: ThreadStates.paused,
        eventAt: day(5),
        eventAtIsDate: true,
        pausedUntil: day(30),
      ))['threadId'] as int;
      final late = await service.threadUpdate(
        threadId: id,
        state: ThreadStates.waiting,
        eventAt: day(1),
        eventAtIsDate: true,
        pausedUntil: day(20),
      );
      expect(late['action'], 'historyAdded');
      expect(threadRow(id).pausedUntil, day(30));
      expect(late['warning'], contains('kept on the history row only'));
      final historyRow = store
          .box<ThreadState>()
          .getAll()
          .singleWhere((r) => r.asHistory);
      expect(historyRow.pausedUntil, day(20));

      final refused = await service.threadUpdate(
        threadId: id,
        state: ThreadStates.paused,
        eventAt: day(4),
        eventAtIsDate: true,
        pausedUntil: day(25),
        note: 'Landlord answered.',
      );
      expect(threadRow(id).pausedUntil, day(30));
      expect(refused['warning'], contains('pausedUntil was not applied'));
      expect(refused['warning'], isNot(contains('nothing changed')));
      expect(refused['action'], 'updated', reason: 'the note was attached');
    });

    test('a dated state before the LATEST known date (not only the current '
        "row's) goes to history", () async {
      final id = (await create(state: ThreadStates.waiting, eventAt: day(5)))[
          'threadId'] as int;
      await setState(id, ThreadStates.inProgress);
      final r = await setState(id, ThreadStates.paused, eventAt: day(1));
      expect(r['action'], 'historyAdded');
      expect(r['state'], ThreadStates.inProgress);
      expect(r['warning'], contains('before the latest known state date'));
    });

    test('a date-only eventAt is compared with the recording time by the '
        'LOCAL calendar day – in every time zone', () async {
      // D: a past local day (never "in the future").
      final ago = DateTime.now().subtract(const Duration(days: 10));
      final d = DateTime.utc(ago.year, ago.month, ago.day);
      Future<Map<String, Object?>> dateUnknownRowRecordedAt(
        DateTime recordedAt,
      ) async {
        final id = (await create(title: 'Thread ${recordedAt.millisecond}'))[
            'threadId'] as int;
        final row = store
            .box<ThreadState>()
            .getAll()
            .singleWhere((r) => r.thread.targetId == id)
          ..recordedAt = recordedAt.toUtc();
        store.box<ThreadState>().put(row);
        store.box<Thread>().put(
          threadRow(id)..stateRecordedAt = recordedAt.toUtc(),
        );
        return setState(id, ThreadStates.inProgress, eventAt: d);
      }

      // Recorded early on local day D (east of UTC that is still the UTC
      // day before): D is the same day – dated.
      final sameDay = await dateUnknownRowRecordedAt(
        DateTime(ago.year, ago.month, ago.day, 0, 1, 0, 1),
      );
      expect(sameDay['action'], 'dated');
      expect(sameDay['since'], iso(d));
      // Recorded late on local day D-1 (west of UTC that is already UTC
      // day D): D is a later day – refused.
      final dayBefore = await dateUnknownRowRecordedAt(
        DateTime(ago.year, ago.month, ago.day - 1, 20, 0, 0, 2),
      );
      expect(dayBefore['action'], 'unchanged');
      expect(dayBefore['warning'], contains('can only be filled in'));
    });

    test('a date-only eventAt on the local day of a timestamped state is '
        'not "before" it (history rule and dating guard)', () async {
      final noon = DateTime(2026, 10, 5, 12).toUtc();
      final day = DateTime.utc(2026, 10, 5);
      final id = (await service.threadUpdate(
        title: 'Website relaunch',
        project: _project,
        state: ThreadStates.waiting,
        eventAt: noon,
      ))['threadId'] as int;
      final r = await setState(id, ThreadStates.done, eventAt: day);
      expect(r['action'], 'updated');
      expect(r['state'], ThreadStates.done);

      // Dating guard: an earlier state dated by a timestamp on day D does
      // not block filling in D for the current state.
      final other = (await service.threadUpdate(
        title: 'Brand guide offer',
        project: _project,
        state: ThreadStates.waiting,
        eventAt: noon,
      ))['threadId'] as int;
      await setState(other, ThreadStates.inProgress);
      final dated = await setState(other, ThreadStates.inProgress, eventAt: day);
      expect(dated['action'], 'dated');
    });

    test('a new current row is recorded after a current row whose '
        'recordedAt lies ahead (another clock): it still becomes current',
        () async {
      final id = (await create())['threadId'] as int;
      final ahead = DateTime.now().toUtc().add(const Duration(days: 1));
      final row = store.box<ThreadState>().getAll().single
        ..recordedAt = ahead;
      store.box<ThreadState>().put(row);
      store.box<Thread>().put(threadRow(id)..stateRecordedAt = ahead);
      final r = await setState(id, ThreadStates.waiting);
      expect(r['action'], 'updated');
      expect(r['state'], ThreadStates.waiting);
      expect(
        DateTime.parse(r['sinceRecordedAt'] as String),
        _truncMs(ahead).add(const Duration(milliseconds: 1)),
      );
    });

    test('a hard forget with an attachment that has no thread logs and '
        'skips it', () async {
      final e = (await service.remember(text: 'orphaned', project: _project))[
          'id'] as int;
      store.box<ThreadEntry>().put(
        ThreadEntry(via: ThreadVia.attach)..entry.targetId = e,
      );
      final r = await service.forget(e, hard: true);
      expect(r['threadEntriesRemoved'], 1);
      expect(
        logLines.where(
          (l) => l.contains('thread 0 of an attachment does not exist'),
        ),
        hasLength(1),
      );
    });

    test('by-title resolution goes by the history, not a stale stored '
        'state: no duplicate thread, the copy is repaired', () async {
      final id = (await create())['threadId'] as int;
      store.box<Thread>().put(threadRow(id)..state = ThreadStates.done);
      logLines.clear();
      final r = await create(state: ThreadStates.waiting);
      expect(r['threadId'], id);
      expect(r['action'], 'updated');
      expect(store.box<Thread>().count(), 1);
      expect(threadRow(id).state, ThreadStates.waiting);
      expect(
        logLines.where((l) => l.contains('disagrees with its history')),
        isNotEmpty,
      );
    });

    test('remember(threadId) into a thread of another project warns and '
        'reports it', () async {
      final id = (await create())['threadId'] as int;
      final r = await service.remember(
        text: 'Note filed under client3.',
        project: 'client3',
        threadId: id,
      );
      expect((r['thread'] as Map)['attachedFromOtherProject'], [r['id']]);
      expect(r['warning'], contains('belongs to another project'));
      final dup = await service.remember(
        text: 'Note filed under client3.',
        project: 'client3',
        threadId: id,
      );
      expect(dup['warning'], contains('belongs to another project'));
    });

    test('supersede skips (and logs) an attachment without a thread',
        () async {
      final old = (await service.remember(text: 'orphan', project: _project))[
          'id'] as int;
      store.box<ThreadEntry>().put(
        ThreadEntry(via: ThreadVia.attach)..entry.targetId = old,
      );
      final r = await service.supersede(old, text: 'orphan, corrected');
      expect(r.containsKey('threadsCarried'), isFalse);
      expect(
        logLines.where((l) => l.contains('points at no thread')),
        hasLength(1),
      );
    });
  });
}
