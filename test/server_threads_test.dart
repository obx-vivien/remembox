/// Thread tools through the MCP layer (0.5.0): schemas
/// (`additionalProperties: false`), argument parsing (dates, ids,
/// expectedVersion without threadId), the `version_conflict` error shape,
/// an idempotent replay and `thread_get` by title.
///
/// Synthetic data only: project `company1`, thread "Website relaunch".
library;

import 'package:dart_mcp/client.dart';
import 'package:remembox/src/model.dart';
import 'package:test/test.dart';

import 'helpers/test_server.dart';

void main() {
  late TestServer srv;

  setUp(() async {
    srv = await TestServer.open();
  });

  tearDown(() => srv.close());

  Future<Map<String, Object?>> create() => srv.callOk('thread_update', {
    'title': 'Website relaunch',
    'project': 'company1',
    'state': 'inProgress',
  });

  test('the three thread tools are listed with closed schemas; remember '
      'and supersede take threadId; the instructions name thread_update',
      () async {
    for (final name in ['thread_update', 'thread_list', 'thread_get']) {
      final tool = await srv.tool(name);
      expect(tool.inputSchema.additionalProperties, isFalse, reason: name);
    }
    final update = await srv.tool('thread_update');
    expect(
      update.inputSchema.properties!.keys,
      containsAll([
        'threadId',
        'title',
        'project',
        'state',
        'eventAt',
        'note',
        'attachEntryIds',
        'pausedUntil',
        'clearPausedUntil',
        'expectedVersion',
        'idempotencyKey',
      ]),
    );
    expect(
      (await srv.tool('remember')).inputSchema.properties!.keys,
      contains('threadId'),
    );
    expect(
      (await srv.tool('supersede')).inputSchema.properties!.keys,
      contains('threadId'),
    );
    expect(srv.instructions, contains('thread_update'));
    expect(
      update.description,
      allOf(
        contains('before the latest known state date'),
        contains('eventAt needs state'),
      ),
    );
  });

  test('an unknown argument is rejected before the handler runs', () async {
    final result = await srv.call('thread_update', {
      'title': 'Website relaunch',
      'project': 'company1',
      'state': 'inProgress',
      'evntAt': '2026-10-01',
    });
    expect(result.isError, isTrue);
    expect((result.content.single as TextContent).text, contains('"evntAt"'));
    expect(srv.store.box<Thread>().count(), 0);
  });

  test('bad dates, expectedVersion without threadId and a bad id list are '
      'invalid_input', () async {
    final noOffset = await srv.callInvalid('thread_update', {
      'title': 'Website relaunch',
      'project': 'company1',
      'state': 'inProgress',
      'eventAt': '2026-10-01T10:00:00',
    });
    expect(noOffset['message'], contains('explicit UTC offset'));
    final rolled = await srv.callInvalid('thread_update', {
      'title': 'Website relaunch',
      'project': 'company1',
      'state': 'inProgress',
      'eventAt': '2026-02-30',
    });
    expect(rolled['message'], contains('not a valid calendar date'));
    final version = await srv.callInvalid('thread_update', {
      'title': 'Website relaunch',
      'project': 'company1',
      'state': 'inProgress',
      'expectedVersion': 1,
    });
    expect(version['message'], contains('expectedVersion needs threadId'));
    final ids = await srv.callInvalid('thread_update', {
      'threadId': 1,
      'attachEntryIds': [0],
    });
    expect(ids['message'], contains('positive integers'));
    expect(srv.store.box<Thread>().count(), 0);
  });

  test('a date-only eventAt of today is accepted', () async {
    final now = DateTime.now();
    final today =
        '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
    final r = await srv.callOk('thread_update', {
      'title': 'Website relaunch',
      'project': 'company1',
      'state': 'inProgress',
      'eventAt': today,
    });
    expect(r['since'], '${today}T00:00:00.000Z');
  });

  test('a stale expectedVersion is a version_conflict error with the '
      'current thread; nothing written', () async {
    final id = (await create())['threadId'] as int;
    await srv.callOk('thread_update', {'threadId': id, 'state': 'waiting'});
    final result = await srv.call('thread_update', {
      'threadId': id,
      'state': 'done',
      'expectedVersion': 1,
    });
    expect(result.isError, isTrue);
    final json = decodeToolJson(result);
    expect(json['error'], 'version_conflict');
    expect(json['message'], contains('is at version 2, you expected 1'));
    final current = json['current'] as Map<String, Object?>;
    expect(current['threadId'], id);
    expect(current['version'], 2);
    expect(current['state'], 'waiting');
    expect(srv.store.box<ThreadState>().count(), 2);
    expect(
      srv.logLines.where((l) => l.startsWith('[server] thread_update version '
          'conflict')),
      hasLength(1),
    );
  });

  test('a retry with the same idempotencyKey is replayed', () async {
    final args = {
      'title': 'Website relaunch',
      'project': 'company1',
      'state': 'inProgress',
      'idempotencyKey': 'retry-1',
    };
    final first = await srv.callOk('thread_update', args);
    final again = await srv.callOk('thread_update', args);
    expect(again['replayed'], isTrue);
    expect(again['threadId'], first['threadId']);
    expect(again['version'], first['version']);
    expect(srv.store.box<ThreadState>().count(), 1);
  });

  test('thread_get by title, thread_list, remember with threadId', () async {
    final id = (await create())['threadId'] as int;
    final mem = await srv.callOk('remember', {
      'text': 'Status: design approved.',
      'project': 'company1',
      'kind': 'snapshot',
      'threadId': id,
    });
    expect((mem['thread'] as Map)['attached'], isTrue);
    final got = await srv.callOk('thread_get', {
      'title': 'website relaunch',
      'project': 'company1',
    });
    expect(got['id'], id);
    expect((got['entries'] as List).single['id'], mem['id']);
    final list = await srv.callOk('thread_list', {'project': 'company1'});
    expect(list['count'], 1);
    expect((list['threads'] as List).single['entryCount'], 1);
    final none = await srv.callInvalid('thread_get', {'title': 'Website'});
    expect(none['message'], contains('pass threadId, or title and project'));
  });
}
