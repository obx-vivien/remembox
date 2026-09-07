/// Pins FIX-1 (the 2026-07-06 engineering log (internal), F-1): tool-handler
/// executions must be serialized so a client that pipes `remember` then
/// `recall` WITHOUT
/// awaiting the first response cannot have `recall` observe a half-finished
/// `remember` (verified before the fix: candidatesFetched=0 immediately
/// after an indexed remember, because recall's query ran before remember's
/// write transaction committed).
///
/// This drives a real [RememboxServer] over an in-memory duplex
/// [StreamChannel] pair with a real [MCPClient], firing both `tools/call`
/// requests back-to-back without awaiting the first — exactly the race
/// condition the finding describes — and asserts remember's write is fully
/// visible to recall's candidates.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp/client.dart';
import 'package:remembox/src/memory_service.dart';
import 'package:remembox/src/server.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

import 'helpers/test_store_gate.dart';
import 'support/fake_embedder.dart';

base class _TestClient extends MCPClient {
  _TestClient() : super(Implementation(name: 'test client', version: '0.1'));
}

Map<String, Object?> _decodeToolJson(CallToolResult result) {
  final text = (result.content.single as TextContent).text;
  return jsonDecode(text) as Map<String, Object?>;
}

void main() {
  late Directory tempDir;
  late TestGate testGate;
  late FakeEmbedder embedder;
  late MemoryService service;
  late RememboxServer server;
  late ServerConnection connection;
  late _TestClient client;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('remembox_server_test_');
    // 2026-09-01 (Store-Gate): persistent-mode StoreGate wrapping a fresh
    // temp store — see test/helpers/test_store_gate.dart.
    testGate = await openTestGate(tempDir.path);
    // A real (non-zero) embed delay is required to reproduce the race: it
    // forces remember()'s _indexEntry await to actually yield the event
    // loop, matching production's real HTTP round trip to Ollama — see
    // FakeEmbedder.embedDelay docs.
    embedder = FakeEmbedder(embedDelay: const Duration(milliseconds: 20));
    service = MemoryService(gate: testGate.gate, embedder: embedder);

    final clientToServer = StreamController<String>();
    final serverToClient = StreamController<String>();
    final serverChannel = StreamChannel<String>.withCloseGuarantee(
      clientToServer.stream,
      serverToClient.sink,
    );
    final clientChannel = StreamChannel<String>.withCloseGuarantee(
      serverToClient.stream,
      clientToServer.sink,
    );

    server = RememboxServer(serverChannel, service: service);
    client = _TestClient();
    connection = client.connectServer(clientChannel);

    final initResult = await connection.initialize(
      InitializeRequest(
        protocolVersion: ProtocolVersion.latestSupported,
        capabilities: client.capabilities,
        clientInfo: client.implementation,
      ),
    );
    expect(initResult.protocolVersion?.isSupported, isTrue);
    connection.notifyInitialized(InitializedNotification());
    await server.initialized;
  });

  tearDown(() async {
    await client.shutdown();
    await server.shutdown();
    await service.dispose();
    await testGate.close();
    tempDir.deleteSync(recursive: true);
  });

  test(
    'recall fired without awaiting a prior remember still sees the '
    'remembered entry as an indexed candidate (no interleaving)',
    () async {
      embedder.register('race text', embedder.planeVector(0));

      // Deliberately do NOT await the remember call before firing recall —
      // this is the exact client behavior that exposed F-1.
      final rememberFuture = connection.callTool(
        CallToolRequest(
          name: 'remember',
          arguments: {
            'text': 'race text',
            'sourceType': 'note',
            'project': 'test',
          },
        ),
      );
      final recallFuture = connection.callTool(
        CallToolRequest(name: 'recall', arguments: {'query': 'race text'}),
      );

      final rememberResult = await rememberFuture;
      final recallResult = await recallFuture;

      expect(rememberResult.isError ?? false, isFalse);
      expect(recallResult.isError ?? false, isFalse);

      // If the calls were NOT serialized, recall could run before remember's
      // write transaction committed and see zero candidates. With
      // serialization, remember (queued first) always finishes first and
      // recall must see exactly the one indexed candidate.
      final recallJson = _decodeToolJson(recallResult);
      expect(
        recallJson['candidatesFetched'],
        greaterThanOrEqualTo(1),
        reason:
            "recall must observe the prior remember's committed index row "
            '— tool calls must be serialized, not interleaved',
      );
      final hits = recallJson['hits'] as List;
      expect(hits, isNotEmpty);
      expect((hits.single as Map)['text'], 'race text');
    },
  );

  test(
    'a failing tool call does not poison the chain for the next queued call',
    () async {
      // An invalid kind is rejected by the _guard (ValidationException ->
      // isError result, not a crash) — fire it followed immediately by a
      // valid call, unawaited, and confirm the valid call still completes
      // normally afterwards.
      final failingFuture = connection.callTool(
        CallToolRequest(
          name: 'remember',
          arguments: {
            'text': 'bad kind',
            'kind': 'not-a-real-kind',
            'project': 'test',
          },
        ),
      );
      final okFuture = connection.callTool(
        CallToolRequest(
          name: 'remember',
          arguments: {
            'text': 'good after bad',
            'sourceType': 'note',
            'project': 'test',
          },
        ),
      );

      final failingResult = await failingFuture;
      final okResult = await okFuture;

      expect(failingResult.isError, isTrue);
      expect(okResult.isError ?? false, isFalse);
      final okJson = _decodeToolJson(okResult);
      expect(okJson['duplicate'], isFalse);
    },
  );

  test(
    'a remember call without project is rejected server-side with an '
    'actionable error (2026-09-06, Fix 1: project is required, enforced '
    'in MemoryService, not left to prompt-level convention)',
    () async {
      final result = await connection.callTool(
        CallToolRequest(
          name: 'remember',
          arguments: {'text': 'missing project'},
        ),
      );
      expect(result.isError, isTrue);
      final json = _decodeToolJson(result);
      expect(json['error'], 'invalid_input');
      expect(json['message'], contains('project is required'));
    },
  );

  test(
    'L-4 (2026-09-07 security review): tools/call get id=1e999 — a JSON '
    "numeral Dart's own jsonDecode silently overflows to double.infinity "
    "— is rejected as invalid_input, never an uncaught multi-frame stack "
    "trace escaping from dart_mcp's schema validator",
    () async {
      // Sanity-checks the premise this test reproduces: 1e999 overflows
      // double precision to Infinity once JSON-decoded. jsonEncode(
      // double.infinity) itself throws (JSON has no Infinity literal), so
      // the typed `connection.callTool(...)` client used by every other
      // test in this file can NEVER reproduce this — it would refuse to
      // even serialize the request. Only a raw wire message (built here as
      // literal JSON text, exactly like a real client's bytes) can put
      // double.infinity in front of the server's schema validator.
      expect(jsonDecode('1e999'), double.infinity);

      final toServer = StreamController<String>();
      final toClient = StreamController<String>();
      final rawServer = RememboxServer(
        StreamChannel<String>.withCloseGuarantee(
          toServer.stream,
          toClient.sink,
        ),
        service: service,
      );
      addTearDown(rawServer.shutdown);

      // toClient.stream is single-subscription (dart:async streams from a
      // plain StreamController may be listened to at most ONCE ever, even
      // after cancellation) — a persistent listener feeding a tiny pull
      // queue is required to await "the next response" more than once.
      final pendingResponses = <String>[];
      final responseWaiters = <Completer<void>>[];
      toClient.stream.listen((line) {
        pendingResponses.add(line);
        if (responseWaiters.isNotEmpty) {
          responseWaiters.removeAt(0).complete();
        }
      });
      Future<String> nextResponse() async {
        if (pendingResponses.isEmpty) {
          final waiter = Completer<void>();
          responseWaiters.add(waiter);
          await waiter.future.timeout(
            const Duration(seconds: 5),
            onTimeout: () => fail(
              'server never responded — it may have crashed the '
              'connection instead of returning an error result',
            ),
          );
        }
        return pendingResponses.removeAt(0);
      }

      toServer.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'initialize',
          'params': {
            'protocolVersion': '2025-06-18',
            'capabilities': <String, Object?>{},
            'clientInfo': {'name': 'raw-test-client', 'version': '0'},
          },
        }),
      );
      await nextResponse();
      toServer.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'notifications/initialized',
          'params': <String, Object?>{},
        }),
      );
      await rawServer.initialized;

      // The literal `1e999` below is written directly into the request
      // text — never round-tripped through jsonEncode — so it reaches the
      // server exactly as a real client's bytes would.
      toServer.add(
        '{"jsonrpc":"2.0","id":2,"method":"tools/call",'
        '"params":{"name":"get","arguments":{"id":1e999}}}',
      );
      final response = await nextResponse();

      expect(
        response,
        isNot(contains('#0 ')),
        reason: 'no raw Dart stack frame marker must reach the wire',
      );
      final decoded = jsonDecode(response) as Map<String, Object?>;
      expect(decoded['id'], 2);
      expect(
        decoded.containsKey('error'),
        isFalse,
        reason:
            'must be a normal CallToolResult (isError:true), not a '
            'JSON-RPC-level error — that would mean the crash still '
            'escaped past the tool guard: ${decoded['error']}',
      );
      final result = decoded['result'] as Map<String, Object?>;
      expect(result['isError'], isTrue);
      final text =
          ((result['content'] as List).single as Map<String, Object?>)['text']
              as String;
      expect(text.length, lessThan(500));
      final payload = jsonDecode(text) as Map<String, Object?>;
      expect(payload['error'], 'invalid_input');
    },
  );

  test(
    'N-6 (2026-09-07 security-review re-verification): tools/call get '
    'id=0 is rejected as invalid_input naming "ids start at 1", never an '
    'internal_error with a native stack trace (ObjectBox ids start at 1; '
    'id=0 previously reached the native layer and threw "Illegal ID '
    'value: 0 (OBX_ERROR code 10002)")',
    () async {
      final logLines = <String>[];
      final toServer = StreamController<String>();
      final toClient = StreamController<String>();
      final idServer = RememboxServer(
        StreamChannel<String>.withCloseGuarantee(
          toServer.stream,
          toClient.sink,
        ),
        service: service,
        log: logLines.add,
      );
      addTearDown(idServer.shutdown);
      final idClient = _TestClient();
      final idConnection = idClient.connectServer(
        StreamChannel<String>.withCloseGuarantee(
          toClient.stream,
          toServer.sink,
        ),
      );
      await idConnection.initialize(
        InitializeRequest(
          protocolVersion: ProtocolVersion.latestSupported,
          capabilities: idClient.capabilities,
          clientInfo: idClient.implementation,
        ),
      );
      idConnection.notifyInitialized(InitializedNotification());
      await idServer.initialized;

      final result = await idConnection.callTool(
        CallToolRequest(name: 'get', arguments: {'id': 0}),
      );
      expect(result.isError, isTrue);
      final json = _decodeToolJson(result);
      expect(json['error'], 'invalid_input');
      expect(json['message'], contains('positive integer'));
      expect(json['message'], contains('ids start at 1'));
      expect(
        logLines.any(
          (l) => l.contains('OBX_ERROR') || l.contains('Illegal ID'),
        ),
        isFalse,
        reason: 'must never reach the native layer: $logLines',
      );

      await idClient.shutdown();
    },
  );

  test(
    'N-7 (2026-09-07 security-review re-verification): tools/call get '
    'id=1e19 is rejected as invalid_input naming the out-of-range value, '
    'not silently clamped to int64 max (previously: "id '
    '9223372036854775807 does not exist")',
    () async {
      final result = await connection.callTool(
        CallToolRequest(name: 'get', arguments: {'id': 1e19}),
      );
      expect(result.isError, isTrue);
      final json = _decodeToolJson(result);
      expect(json['error'], 'invalid_input');
      expect(json['message'], contains('out of the 64-bit integer range'));
      expect(
        json['message'],
        isNot(contains('9223372036854775807')),
        reason: 'must not silently clamp to int64 max',
      );
    },
  );

  test(
    'M-4 residual (2026-09-07 security-review re-verification): remember '
    'with a 1 MiB expiresAt is rejected as invalid_input with a bounded '
    'message, never a ~1 MB error echoing the whole value back',
    () async {
      final hugeDate = '9' * (1024 * 1024);
      final result = await connection.callTool(
        CallToolRequest(
          name: 'remember',
          arguments: {
            'text': 'bad expiresAt',
            'project': 'test',
            'expiresAt': hugeDate,
          },
        ),
      );
      expect(result.isError, isTrue);
      final json = _decodeToolJson(result);
      expect(json['error'], 'invalid_input');
      expect(json['message'], contains('too long'));
      final text = (result.content.single as TextContent).text;
      expect(
        text.length,
        lessThan(300),
        reason: 'the whole 1 MiB value must never be echoed back',
      );
    },
  );

  test(
    'M-4 residual (2026-09-07 security-review re-verification): recall '
    'with a 1 MiB project filter is rejected as invalid_input, not '
    'forwarded whole to the store query',
    () async {
      final hugeProject = 'p' * (1024 * 1024);
      final result = await connection.callTool(
        CallToolRequest(
          name: 'recall',
          arguments: {'query': 'anything', 'project': hugeProject},
        ),
      );
      expect(result.isError, isTrue);
      final json = _decodeToolJson(result);
      expect(json['error'], 'invalid_input');
      expect(json['message'], contains('too long'));
      final text = (result.content.single as TextContent).text;
      expect(text.length, lessThan(300));
    },
  );

  test('a shared ToolCallSerializer keeps tool calls serialized across TWO '
      'RememboxServer instances (2026-07-18, the 2026-07-18 HTTP-daemon '
      'engineering log, internal: HTTP daemon mode gives each session its '
      'OWN RememboxServer '
      'instance over one MemoryService — this is the cross-instance version '
      'of the FIX-1 race the test above pins for a single instance).\n\n'
      'Strengthened 2026-08-14 ("Review round 1 fixes" finding 6): the '
      'candidatesFetched assertion below is an indirect side effect that '
      'could in principle still pass under a scheduling accident even without '
      'the fix. The overlapDetected assertion is the direct, timing-'
      'independent pin — it fails the instant ToolCallSerializer EVER runs '
      'two handlers concurrently, via the onHandlerStart/onHandlerEnd '
      'test-only seam on ToolCallSerializer (lib/src/server.dart). The '
      'counterpart demonstration (that a PRIVATE per-instance serializer '
      'WOULD show overlap/observe zero candidates) is not forced here — '
      'reliably forcing that interleaving without the shared serializer would '
      'itself be a race, so it is left un-asserted; the single-instance test '
      'above already pins the non-serialized failure mode directly.', () async {
    // Second "session": an independent RememboxServer + client + channel
    // pair, but explicitly sharing `server`'s serializer AND `service` —
    // exactly what RememboxHttpDaemon does across HTTP sessions
    // (lib/src/http_transport.dart _Session.create).
    final clientToServer2 = StreamController<String>();
    final serverToClient2 = StreamController<String>();
    final serverChannel2 = StreamChannel<String>.withCloseGuarantee(
      clientToServer2.stream,
      serverToClient2.sink,
    );
    final clientChannel2 = StreamChannel<String>.withCloseGuarantee(
      serverToClient2.stream,
      clientToServer2.sink,
    );
    final server2 = RememboxServer(
      serverChannel2,
      service: service,
      serializer: server.serializer,
    );
    final client2 = _TestClient();
    final connection2 = client2.connectServer(clientChannel2);
    final initResult2 = await connection2.initialize(
      InitializeRequest(
        protocolVersion: ProtocolVersion.latestSupported,
        capabilities: client2.capabilities,
        clientInfo: client2.implementation,
      ),
    );
    expect(initResult2.protocolVersion?.isSupported, isTrue);
    connection2.notifyInitialized(InitializedNotification());
    await server2.initialized;
    addTearDown(() async {
      await client2.shutdown();
      await server2.shutdown();
    });

    // Timing-independent overlap detector (finding 6): wired onto the
    // SHARED serializer instance, so it observes every handler execution
    // regardless of which RememboxServer instance queued it.
    var handlerRunning = false;
    var overlapDetected = false;
    final sharedSerializer = server.serializer;
    sharedSerializer.onHandlerStart = (tool) {
      if (handlerRunning) overlapDetected = true;
      handlerRunning = true;
    };
    sharedSerializer.onHandlerEnd = (tool) {
      handlerRunning = false;
    };
    addTearDown(() {
      sharedSerializer.onHandlerStart = null;
      sharedSerializer.onHandlerEnd = null;
    });

    embedder.register('cross-session race text', embedder.planeVector(0));

    // Session 1 fires remember, session 2 fires recall for the SAME text,
    // and session 1 also fires a third call (stats) — all WITHOUT
    // awaiting an earlier one first, widening the window in which an
    // unserialized implementation would show overlap.
    final rememberFuture = connection.callTool(
      CallToolRequest(
        name: 'remember',
        arguments: {
          'text': 'cross-session race text',
          'sourceType': 'note',
          'project': 'test',
        },
      ),
    );
    final recallFuture = connection2.callTool(
      CallToolRequest(
        name: 'recall',
        arguments: {'query': 'cross-session race text'},
      ),
    );
    final statsFuture = connection.callTool(
      CallToolRequest(name: 'stats', arguments: const {}),
    );

    final rememberResult = await rememberFuture;
    final recallResult = await recallFuture;
    final statsResult = await statsFuture;

    expect(rememberResult.isError ?? false, isFalse);
    expect(recallResult.isError ?? false, isFalse);
    expect(statsResult.isError ?? false, isFalse);

    expect(
      overlapDetected,
      isFalse,
      reason:
          'ToolCallSerializer must never run two handlers concurrently, '
          'even across two RememboxServer instances sharing it — this is '
          'the timing-independent pin for the cross-instance invariant '
          '(finding 6)',
    );

    // Original side-effect assertion retained as a second, independent
    // confirmation of the same invariant.
    final recallJson = _decodeToolJson(recallResult);
    expect(
      recallJson['candidatesFetched'],
      greaterThanOrEqualTo(1),
      reason:
          "session 2 (an independent RememboxServer instance) must still "
          "observe session 1's committed remember() when both share ONE "
          'ToolCallSerializer — the HTTP-daemon cross-session invariant. '
          'If each instance had its own private serializer (the bug this '
          'sharing fixes), this could be 0.',
    );
    final hits = recallJson['hits'] as List;
    expect(hits, isNotEmpty);
    expect((hits.single as Map)['text'], 'cross-session race text');
  });
}
