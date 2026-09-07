/// Pins `lib/src/http_transport.dart` (2026-07-18, the 2026-07-18
/// HTTP-daemon engineering log (internal)): the minimal MCP streamable-HTTP
/// bridge that lets ONE daemon process (the single ObjectBox writer) serve
/// MANY Claude Code sessions concurrently.
///
/// Drives a real [RememboxHttpDaemon] with a real `dart:io` [HttpClient]
/// over an ephemeral loopback port (`port: 0`) — no mocking of the HTTP
/// layer itself.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:remembox/objectbox.g.dart';
import 'package:remembox/src/http_transport.dart';
import 'package:remembox/src/memory_service.dart';
import 'package:remembox/src/store.dart' show localActivationSyncUrl;
import 'package:remembox/src/store_gate.dart';
import 'package:test/test.dart';

import 'support/fake_embedder.dart';

Map<String, Object?> _initializeBody(Object id) => {
  'jsonrpc': '2.0',
  'id': id,
  'method': 'initialize',
  'params': {
    'protocolVersion': '2025-06-18',
    'capabilities': <String, Object?>{},
    'clientInfo': {'name': 'http-transport-test', 'version': '0'},
  },
};

Map<String, Object?> _toolsListBody(Object id) => {
  'jsonrpc': '2.0',
  'id': id,
  'method': 'tools/list',
  'params': <String, Object?>{},
};

Map<String, Object?> _statsCallBody(Object id) => {
  'jsonrpc': '2.0',
  'id': id,
  'method': 'tools/call',
  'params': {'name': 'stats', 'arguments': <String, Object?>{}},
};

/// Fixed bearer token used by every daemon constructed in this file (Fix 1,
/// 2026-09-07, the 2026-09-07 daemon-auth engineering log (internal)) —
/// arbitrary but stable, so assertions can compare log lines/behavior
/// against it.
const String _testToken = 'test-only-daemon-token-do-not-use-in-prod';

class _Peer {
  final Process process;
  _Peer(this.process);

  static Future<_Peer> spawn(String storeDir, String helperScript) async {
    // Platform.resolvedExecutable: the VM running this test — no PATH
    // dependency, same SDK as the test.
    final proc = await Process.start(Platform.resolvedExecutable, [
      'run',
      helperScript,
      storeDir,
    ]);
    final firstLine =
        await proc.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first;
    if (firstLine != 'LOCK_HELD') {
      proc.kill();
      fail('peer did not report LOCK_HELD, got: $firstLine');
    }
    return _Peer(proc);
  }

  Future<void> stop() async {
    await process.stdin.close();
    final exited = await process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
    if (exited == -1) {
      stderr.writeln('WARNING: peer process did not exit cleanly, SIGKILLed');
    }
  }
}

void main() {
  group('RememboxHttpDaemon HTTP round trip', () {
    late Directory tempDir;
    late Store store;
    late SyncClient syncClient;
    late StoreGate gate;
    late FakeEmbedder embedder;
    late MemoryService service;
    late RememboxHttpDaemon daemon;
    late HttpClient client;
    late int port;
    late List<String> logLines;

    void logCapture(String line) => logLines.add(line);

    Future<HttpClientResponse> send(
      String method, {
      Map<String, Object?>? body,
      String? sessionId,
      String path = '/mcp',
      // Fix 1 (2026-09-07): every request needs a bearer token now; tests
      // that specifically exercise auth pass `authToken: null` (omit the
      // header) or a wrong value.
      String? authToken = _testToken,
    }) async {
      final request = await client.openUrl(
        method,
        Uri.parse('http://127.0.0.1:$port$path'),
      );
      if (authToken != null) {
        request.headers.set('Authorization', 'Bearer $authToken');
      }
      if (sessionId != null) request.headers.set('Mcp-Session-Id', sessionId);
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      return request.close();
    }

    Future<Map<String, Object?>?> readJson(HttpClientResponse response) async {
      final text = await utf8.decoder.bind(response).join();
      if (text.isEmpty) return null;
      return jsonDecode(text) as Map<String, Object?>;
    }

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('remembox_http_test_');
      logLines = [];
      store = openStore(directory: tempDir.path);
      syncClient = SyncClient(
        store,
        [localActivationSyncUrl],
        [SyncCredentials.none()],
      )..start();
      embedder = FakeEmbedder();
      gate = await StoreGate.persistent(
        store: store,
        syncClient: syncClient,
        storeDirectory: tempDir.path,
        log: logCapture,
      );
      service = MemoryService(
        gate: gate,
        embedder: embedder,
        log: logCapture,
      );
      daemon = RememboxHttpDaemon(
        service: service,
        log: logCapture,
        token: _testToken,
        sessionTtl: const Duration(minutes: 30),
      );
      port = await daemon.start(port: 0);
      client = HttpClient();
    });

    tearDown(() async {
      client.close(force: true);
      await daemon.stop();
      await service.dispose();
      await gate.close();
      tempDir.deleteSync(recursive: true);
    });

    test('initialize creates a session and returns Mcp-Session-Id', () async {
      final resp = await send('POST', body: _initializeBody(1));
      expect(resp.statusCode, HttpStatus.ok);
      final sessionId = resp.headers.value('Mcp-Session-Id');
      expect(sessionId, isNotNull);
      expect(sessionId, isNotEmpty);
      final json = await readJson(resp);
      expect(json!['id'], 1);
      expect(json['result'], isA<Map>());
      expect((json['result'] as Map)['protocolVersion'], isNotNull);
      expect(daemon.sessionCount, 1);
    });

    test('tools/list and tools/call stats work with the session id', () async {
      final initResp = await send('POST', body: _initializeBody(1));
      final sessionId = initResp.headers.value('Mcp-Session-Id')!;
      await readJson(initResp);

      final listResp = await send(
        'POST',
        sessionId: sessionId,
        body: _toolsListBody(2),
      );
      expect(listResp.statusCode, HttpStatus.ok);
      final listJson = await readJson(listResp);
      expect(listJson!['id'], 2);
      final tools = (listJson['result'] as Map)['tools'] as List;
      expect(
        tools.map((t) => (t as Map)['name']),
        containsAll(['remember', 'recall', 'stats']),
      );

      final statsResp = await send(
        'POST',
        sessionId: sessionId,
        body: _statsCallBody(3),
      );
      expect(statsResp.statusCode, HttpStatus.ok);
      final statsJson = await readJson(statsResp);
      expect(statsJson!['id'], 3);
      expect(statsJson['result'], isA<Map>());
    });

    test('a notification is accepted with 202 and no body', () async {
      final initResp = await send('POST', body: _initializeBody(1));
      final sessionId = initResp.headers.value('Mcp-Session-Id')!;
      await readJson(initResp);

      final notifResp = await send(
        'POST',
        sessionId: sessionId,
        body: {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
      );
      expect(notifResp.statusCode, HttpStatus.accepted);
      final text = await utf8.decoder.bind(notifResp).join();
      expect(text, isEmpty);
    });

    test(
      'a non-initialize request without Mcp-Session-Id returns 400',
      () async {
        final resp = await send('POST', body: _toolsListBody(5));
        expect(resp.statusCode, HttpStatus.badRequest);
      },
    );

    test('an unknown session id returns 404', () async {
      final resp = await send(
        'POST',
        sessionId: 'this-session-does-not-exist',
        body: _toolsListBody(5),
      );
      expect(resp.statusCode, HttpStatus.notFound);
    });

    test('DELETE disposes the session; a later request 404s', () async {
      final initResp = await send('POST', body: _initializeBody(1));
      final sessionId = initResp.headers.value('Mcp-Session-Id')!;
      await readJson(initResp);
      expect(daemon.sessionCount, 1);

      final delResp = await send('DELETE', sessionId: sessionId);
      expect(delResp.statusCode, HttpStatus.ok);
      expect(daemon.sessionCount, 0);

      final afterResp = await send(
        'POST',
        sessionId: sessionId,
        body: _toolsListBody(2),
      );
      expect(afterResp.statusCode, HttpStatus.notFound);
    });

    test('DELETE without Mcp-Session-Id returns 400', () async {
      final resp = await send('DELETE');
      expect(resp.statusCode, HttpStatus.badRequest);
    });

    test('a second initialize creates an independent session', () async {
      final r1 = await send('POST', body: _initializeBody(1));
      final s1 = r1.headers.value('Mcp-Session-Id')!;
      await readJson(r1);
      final r2 = await send('POST', body: _initializeBody(1));
      final s2 = r2.headers.value('Mcp-Session-Id')!;
      await readJson(r2);

      expect(s1, isNot(equals(s2)));
      expect(daemon.sessionCount, 2);

      // Both sessions independently usable.
      final list1 = await readJson(
        await send('POST', sessionId: s1, body: _toolsListBody(2)),
      );
      final list2 = await readJson(
        await send('POST', sessionId: s2, body: _toolsListBody(2)),
      );
      expect(list1!['id'], 2);
      expect(list2!['id'], 2);
    });

    test('GET returns 405 Method Not Allowed', () async {
      final resp = await send('GET');
      expect(resp.statusCode, HttpStatus.methodNotAllowed);
      await resp.drain<void>();
    });

    test('malformed JSON body returns 400 with a parse-error body', () async {
      final request = await client.openUrl(
        'POST',
        Uri.parse('http://127.0.0.1:$port/mcp'),
      );
      request.headers.set('Authorization', 'Bearer $_testToken');
      request.headers.contentType = ContentType.json;
      request.write('{not valid json');
      final resp = await request.close();
      expect(resp.statusCode, HttpStatus.badRequest);
      final json = await readJson(resp);
      expect((json!['error'] as Map)['code'], -32700);
    });

    test('an unknown path returns 404', () async {
      final resp = await send(
        'POST',
        path: '/not-mcp',
        body: _initializeBody(1),
      );
      expect(resp.statusCode, HttpStatus.notFound);
    });

    test('concurrent requests with distinct ids on ONE session are both '
        'answered correctly (no id mix-up, order not assumed)', () async {
      final initResp = await send('POST', body: _initializeBody(1));
      final sessionId = initResp.headers.value('Mcp-Session-Id')!;
      await readJson(initResp);

      final future1 = send(
        'POST',
        sessionId: sessionId,
        body: _toolsListBody(100),
      ).then(readJson);
      final future2 = send(
        'POST',
        sessionId: sessionId,
        body: _statsCallBody(101),
      ).then(readJson);

      final results = await Future.wait([future1, future2]);
      final byId = {for (final r in results) r!['id']: r};
      expect(byId.keys, containsAll([100, 101]));
      expect(
        (byId[100]!['result'] as Map)['tools'],
        isA<List>(),
        reason:
            'id=100 (tools/list) must get the tools/list result even '
            'though both requests were fired concurrently',
      );
      expect(
        byId[101]!['result'],
        isA<Map>(),
        reason: 'id=101 (tools/call stats) must get the stats result',
      );
    });
  });

  group('duplicate in-flight request id (2026-08-14 "Review round 1 fixes" '
      'finding 4)', () {
    // A pure-HTTP-timing version of this test (fire two requests with the
    // same id and hope they race) is NOT reliable: real loopback sockets
    // usually let the first request's whole round trip finish before the
    // second's socket-level send even lands, so no collision ever
    // happens. Forcing a deterministic collision needs the FIRST request
    // to still be genuinely in flight when the second's `sendRequest`
    // call runs — achieved here with a real (non-zero) FakeEmbedder delay
    // on a `remember` call, exactly the technique test/server_test.dart
    // uses to force the FIX-1 race.
    late Directory tempDir;
    late Store store;
    late SyncClient syncClient;
    late StoreGate gate;
    late FakeEmbedder embedder;
    late MemoryService service;
    late RememboxHttpDaemon daemon;
    late HttpClient client;
    late int port;
    late List<String> logLines;

    void logCapture(String line) => logLines.add(line);

    Future<HttpClientResponse> send(
      String method, {
      Map<String, Object?>? body,
      String? sessionId,
    }) async {
      final request = await client.openUrl(
        method,
        Uri.parse('http://127.0.0.1:$port/mcp'),
      );
      request.headers.set('Authorization', 'Bearer $_testToken');
      if (sessionId != null) {
        request.headers.set('Mcp-Session-Id', sessionId);
      }
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      return request.close();
    }

    Future<Map<String, Object?>?> readJson(HttpClientResponse response) async {
      final text = await utf8.decoder.bind(response).join();
      if (text.isEmpty) return null;
      return jsonDecode(text) as Map<String, Object?>;
    }

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync(
        'remembox_http_dupid_test_',
      );
      logLines = [];
      store = openStore(directory: tempDir.path);
      syncClient = SyncClient(
        store,
        [localActivationSyncUrl],
        [SyncCredentials.none()],
      )..start();
      embedder = FakeEmbedder(embedDelay: const Duration(milliseconds: 150));
      gate = await StoreGate.persistent(
        store: store,
        syncClient: syncClient,
        storeDirectory: tempDir.path,
        log: logCapture,
      );
      service = MemoryService(
        gate: gate,
        embedder: embedder,
        log: logCapture,
      );
      daemon = RememboxHttpDaemon(
        service: service,
        log: logCapture,
        token: _testToken,
      );
      port = await daemon.start(port: 0);
      client = HttpClient();
    });

    tearDown(() async {
      client.close(force: true);
      await daemon.stop();
      await service.dispose();
      await gate.close();
      tempDir.deleteSync(recursive: true);
    });

    test('a slow first request superseded by a fast second request with the '
        'same id gets an error response (logged), the second gets the '
        'real response', () async {
      embedder.register('dup-id race text', embedder.planeVector(0));

      final initResp = await send('POST', body: _initializeBody(1));
      final sessionId = initResp.headers.value('Mcp-Session-Id')!;
      await readJson(initResp);

      // Call 1: slow (embedder delay), id=42 — must still be in flight
      // (no JSON-RPC response received yet) when call 2 registers the
      // same id.
      final slowFuture = send(
        'POST',
        sessionId: sessionId,
        body: {
          'jsonrpc': '2.0',
          'id': 42,
          'method': 'tools/call',
          'params': {
            'name': 'remember',
            'arguments': {
              'text': 'dup-id race text',
              'sourceType': 'note',
              'project': 'test',
            },
          },
        },
      ).then(readJson);

      // Call 2: fast (tools/list, no embedder involved), SAME id=42.
      final fastFuture = send(
        'POST',
        sessionId: sessionId,
        body: _toolsListBody(42),
      ).then(readJson);

      final slowJson = await slowFuture;
      final fastJson = await fastFuture;

      expect(
        slowJson,
        isNotNull,
        reason:
            'the superseded waiter must still get an HTTP response '
            '(the error), never a hung connection',
      );
      expect(
        (slowJson!['error'] as Map)['message'],
        contains('superseded'),
        reason:
            'call 1 (slow, registered first) must be the superseded '
            'waiter — got: $slowJson',
      );

      expect(fastJson!['id'], 42);
      expect(
        (fastJson['result'] as Map)['tools'],
        isA<List>(),
        reason:
            'call 2 (fast, registered second) must get the real '
            'tools/list result',
      );

      expect(
        logLines.any(
          (l) =>
              l.contains(sessionLogHandle(sessionId)) &&
              l.contains('duplicate in-flight'),
        ),
        isTrue,
        reason: 'the duplicate id must be logged (by handle): $logLines',
      );
      expect(
        logLines.any((l) => l.contains(sessionId)),
        isFalse,
        reason:
            'no log line may contain the raw session id (Fix 3, 2026-09-07, '
            'the 2026-09-07 daemon-auth engineering log (internal)): $logLines',
      );
    });

    test('a DELETE that disposes a session with an in-flight request '
        'completes the pending request via a handle, never the raw '
        'session id (S2, 2026-09-08 audit)', () async {
      embedder.register('s2-dispose-race text', embedder.planeVector(0));

      final initResp = await send('POST', body: _initializeBody(1));
      final sessionId = initResp.headers.value('Mcp-Session-Id')!;
      await readJson(initResp);

      // Slow request (embedder delay, 150ms — see setUp) — still in
      // flight when the DELETE below disposes the session out from
      // under it.
      final slowFuture = send(
        'POST',
        sessionId: sessionId,
        body: {
          'jsonrpc': '2.0',
          'id': 99,
          'method': 'tools/call',
          'params': {
            'name': 'remember',
            'arguments': {
              'text': 's2-dispose-race text',
              'sourceType': 'note',
              'project': 'test',
            },
          },
        },
      ).then(readJson);

      // Give the slow request time to reach session.sendRequest and
      // register its completer in _pending before the DELETE disposes
      // the session (embedDelay is 150ms; 30ms is comfortably before
      // that but after the request has been dispatched).
      await Future.delayed(const Duration(milliseconds: 30));

      final deleteResp = await send('DELETE', sessionId: sessionId);
      expect(deleteResp.statusCode, HttpStatus.ok);

      final slowJson = await slowFuture;
      expect(
        slowJson,
        isNotNull,
        reason:
            'the request disposed out from under it must still get an '
            'HTTP response (the error), never a hung connection',
      );
      // Whichever of dispose()'s two completeError sites wins the race
      // (the stream's onDone handler closing first, or the explicit
      // fallback loop at the end of dispose() — see _Session.dispose in
      // lib/src/http_transport.dart), both must use the session handle,
      // never the raw id (S2, 2026-09-08 audit).
      final errorMessage = (slowJson!['error'] as Map)['message'] as String;
      expect(
        errorMessage,
        anyOf(contains('disposed'), contains('closed before a response')),
      );
      expect(
        errorMessage.contains(sessionId),
        isFalse,
        reason: 'the error message itself must not contain the raw '
            'session id: $errorMessage',
      );

      final handle = sessionLogHandle(sessionId);
      expect(
        errorMessage.contains(handle),
        isTrue,
        reason: 'the error message must identify the session by its '
            'handle: $errorMessage',
      );
      expect(
        logLines.any((l) => l.contains(sessionId)),
        isFalse,
        reason:
            'no log line may contain the raw session id — including the '
            'dispose()-time StateError relayed through _handlePost\'s '
            '"on StateError" branch (S2, lib/src/http_transport.dart '
            '_Session.dispose): $logLines',
      );
    });
  });

  group('session TTL sweep', () {
    late Directory tempDir;
    late Store store;
    late SyncClient syncClient;
    late StoreGate gate;
    late FakeEmbedder embedder;
    late MemoryService service;
    late RememboxHttpDaemon daemon;
    late HttpClient client;
    late int port;
    late List<String> logLines;

    void logCapture(String line) => logLines.add(line);

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('remembox_http_ttl_test_');
      logLines = [];
      store = openStore(directory: tempDir.path);
      syncClient = SyncClient(
        store,
        [localActivationSyncUrl],
        [SyncCredentials.none()],
      )..start();
      embedder = FakeEmbedder();
      gate = await StoreGate.persistent(
        store: store,
        syncClient: syncClient,
        storeDirectory: tempDir.path,
        log: logCapture,
      );
      service = MemoryService(
        gate: gate,
        embedder: embedder,
        log: logCapture,
      );
      // Tiny TTL and tiny sweep interval so the test runs fast and
      // deterministically.
      daemon = RememboxHttpDaemon(
        service: service,
        log: logCapture,
        token: _testToken,
        sessionTtl: const Duration(milliseconds: 100),
        sweepInterval: const Duration(milliseconds: 50),
      );
      port = await daemon.start(port: 0);
      client = HttpClient();
    });

    tearDown(() async {
      client.close(force: true);
      await daemon.stop();
      await service.dispose();
      await gate.close();
      tempDir.deleteSync(recursive: true);
    });

    test('an idle session is disposed by the GC sweep and logged', () async {
      final request = await client.openUrl(
        'POST',
        Uri.parse('http://127.0.0.1:$port/mcp'),
      );
      request.headers.set('Authorization', 'Bearer $_testToken');
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(_initializeBody(1)));
      final resp = await request.close();
      final sessionId = resp.headers.value('Mcp-Session-Id')!;
      await resp.drain<void>();
      expect(daemon.sessionCount, 1);

      var cleared = false;
      for (var i = 0; i < 40; i++) {
        if (daemon.sessionCount == 0) {
          cleared = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(cleared, isTrue, reason: 'sweep must eventually GC the session');
      expect(
        logLines.any(
          (l) =>
              l.contains(sessionLogHandle(sessionId)) &&
              l.contains('idle timeout'),
        ),
        isTrue,
        reason:
            'session disposal by the sweep must be logged (by handle): '
            '$logLines',
      );
      expect(
        logLines.any((l) => l.contains(sessionId)),
        isFalse,
        reason:
            'no log line may contain the raw session id (Fix 3, 2026-09-07, '
            'the 2026-09-07 daemon-auth engineering log (internal)): $logLines',
      );
    });
  });

  group('session TTL sweep does not GC a session with an in-flight request '
      '(M3, 2026-08-14 review round 2)', () {
    // Pins the mid-flight GC fix: lastActivity is set at request START, so
    // without the fix a request running longer than sessionTtl (only
    // reachable with a misconfigured tiny
    // OBX_MEMORY_HTTP_SESSION_TTL_SECONDS) would look idle to the sweep
    // even while a real HTTP caller is still waiting on its response. A
    // slow (delayed FakeEmbedder) `remember` call forces a deterministic
    // in-flight window that outlasts sessionTtl, the same technique the
    // "duplicate in-flight request id" group above uses.
    late Directory tempDir;
    late Store store;
    late SyncClient syncClient;
    late StoreGate gate;
    late FakeEmbedder embedder;
    late MemoryService service;
    late RememboxHttpDaemon daemon;
    late HttpClient client;
    late int port;
    late List<String> logLines;

    void logCapture(String line) => logLines.add(line);

    Future<HttpClientResponse> send(
      String method, {
      Map<String, Object?>? body,
      String? sessionId,
    }) async {
      final request = await client.openUrl(
        method,
        Uri.parse('http://127.0.0.1:$port/mcp'),
      );
      request.headers.set('Authorization', 'Bearer $_testToken');
      if (sessionId != null) {
        request.headers.set('Mcp-Session-Id', sessionId);
      }
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      return request.close();
    }

    Future<Map<String, Object?>?> readJson(HttpClientResponse response) async {
      final text = await utf8.decoder.bind(response).join();
      if (text.isEmpty) return null;
      return jsonDecode(text) as Map<String, Object?>;
    }

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync(
        'remembox_http_midflight_gc_test_',
      );
      logLines = [];
      store = openStore(directory: tempDir.path);
      syncClient = SyncClient(
        store,
        [localActivationSyncUrl],
        [SyncCredentials.none()],
      )..start();
      // Delay comfortably longer than sessionTtl below, so the request is
      // still in flight for multiple sweep ticks past its TTL.
      embedder = FakeEmbedder(embedDelay: const Duration(milliseconds: 400));
      gate = await StoreGate.persistent(
        store: store,
        syncClient: syncClient,
        storeDirectory: tempDir.path,
        log: logCapture,
      );
      service = MemoryService(
        gate: gate,
        embedder: embedder,
        log: logCapture,
      );
      daemon = RememboxHttpDaemon(
        service: service,
        log: logCapture,
        token: _testToken,
        sessionTtl: const Duration(milliseconds: 150),
        sweepInterval: const Duration(milliseconds: 40),
      );
      port = await daemon.start(port: 0);
      client = HttpClient();
    });

    tearDown(() async {
      client.close(force: true);
      await daemon.stop();
      await service.dispose();
      await gate.close();
      tempDir.deleteSync(recursive: true);
    });

    test(
      'a session survives past its idle TTL while a slow request is in '
      'flight, then is garbage-collected once the response has landed and '
      'it goes truly idle',
      () async {
        embedder.register('mid-flight gc text', embedder.planeVector(0));

        final initResp = await send('POST', body: _initializeBody(1));
        final sessionId = initResp.headers.value('Mcp-Session-Id')!;
        await readJson(initResp);

        final rememberFuture = send(
          'POST',
          sessionId: sessionId,
          body: {
            'jsonrpc': '2.0',
            'id': 7,
            'method': 'tools/call',
            'params': {
              'name': 'remember',
              'arguments': {
                'text': 'mid-flight gc text',
                'sourceType': 'note',
                'project': 'test',
              },
            },
          },
        ).then(readJson);

        // Poll while the remember call is still in flight (well past the
        // 150ms TTL, well before the 400ms embed delay finishes) —
        // the session must NOT be GC'd during this window.
        await Future<void>.delayed(const Duration(milliseconds: 250));
        expect(
          daemon.sessionCount,
          1,
          reason:
              'a session with a request still in flight must survive past '
              'its idle TTL',
        );
        expect(
          logLines.any(
            (l) =>
                l.contains(sessionLogHandle(sessionId)) &&
                l.contains('in flight') &&
                l.contains('idle TTL'),
          ),
          isTrue,
          reason:
              'the sweep keeping a mid-flight session alive must be '
              'logged (by handle), not silent: $logLines',
        );

        final rememberJson = await rememberFuture;
        expect(
          rememberJson,
          isNotNull,
          reason: 'the in-flight request must still get its real response',
        );
        expect(rememberJson!['error'], isNull, reason: '$rememberJson');

        // Now the session has gone genuinely idle (lastActivity refreshed
        // on response completion) — it must eventually be GC'd once
        // another full TTL has elapsed with no further activity.
        var cleared = false;
        for (var i = 0; i < 40; i++) {
          if (daemon.sessionCount == 0) {
            cleared = true;
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(
          cleared,
          isTrue,
          reason: 'sweep must eventually GC the session once it goes idle',
        );
        expect(
          logLines.any(
            (l) =>
                l.contains(sessionLogHandle(sessionId)) &&
                l.contains('idle timeout'),
          ),
          isTrue,
          reason:
              'final disposal by the sweep must be logged (by handle): '
              '$logLines',
        );
        expect(
          logLines.any((l) => l.contains(sessionId)),
          isFalse,
          reason:
              'no log line may contain the raw session id (Fix 3, '
              '2026-09-07, the 2026-09-07 daemon-auth engineering log '
              '(internal)): '
              '$logLines',
        );
      },
    );
  });

  group('serve mode guard', () {
    late Directory tempDir;
    late List<String> logLines;

    void logCapture(String line) => logLines.add(line);

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync(
        'remembox_serve_guard_test_',
      );
      logLines = [];
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('serve mode refuses to start when another process already holds the '
        'store lock (peer holds a shared lock — daemon still insists on '
        'exclusive)', () async {
      final peer = await _Peer.spawn(
        tempDir.path,
        'test/helpers/hold_shared_lock.dart',
      );
      addTearDown(peer.stop);

      expect(
        () => acquireServeModeGuard(tempDir.path, log: logCapture),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('EXCLUSIVE'),
          ),
        ),
      );
    });

    test('serve mode acquires exclusively when no peer is present', () async {
      final guard = acquireServeModeGuard(tempDir.path, log: logCapture);
      expect(guard.peersPresent(), isFalse);
      guard.release(log: logCapture);
    });
  });

  group('DoS hygiene caps (2026-08-14 "Review round 1 fixes" finding 5)', () {
    late Directory tempDir;
    late Store store;
    late SyncClient syncClient;
    late StoreGate gate;
    late FakeEmbedder embedder;
    late MemoryService service;
    late RememboxHttpDaemon daemon;
    late HttpClient client;
    late int port;
    late List<String> logLines;

    void logCapture(String line) => logLines.add(line);

    Future<HttpClientResponse> send(
      String method, {
      Map<String, Object?>? body,
      String? rawBody,
      String? sessionId,
    }) async {
      final request = await client.openUrl(
        method,
        Uri.parse('http://127.0.0.1:$port/mcp'),
      );
      request.headers.set('Authorization', 'Bearer $_testToken');
      if (sessionId != null) request.headers.set('Mcp-Session-Id', sessionId);
      request.headers.contentType = ContentType.json;
      if (body != null) {
        request.write(jsonEncode(body));
      } else if (rawBody != null) {
        request.write(rawBody);
      }
      return request.close();
    }

    Future<Map<String, Object?>?> readJson(HttpClientResponse response) async {
      final text = await utf8.decoder.bind(response).join();
      if (text.isEmpty) return null;
      return jsonDecode(text) as Map<String, Object?>;
    }

    Future<void> startEnv(Directory dir) async {
      store = openStore(directory: dir.path);
      syncClient = SyncClient(
        store,
        [localActivationSyncUrl],
        [SyncCredentials.none()],
      )..start();
      embedder = FakeEmbedder();
      gate = await StoreGate.persistent(
        store: store,
        syncClient: syncClient,
        storeDirectory: dir.path,
        log: logCapture,
      );
      service = MemoryService(
        gate: gate,
        embedder: embedder,
        log: logCapture,
      );
    }

    Future<void> stopEnv() async {
      await service.dispose();
      await gate.close();
    }

    group('session cap', () {
      setUp(() async {
        tempDir = Directory.systemTemp.createTempSync(
          'remembox_http_maxsessions_test_',
        );
        logLines = [];
        await startEnv(tempDir);
        daemon = RememboxHttpDaemon(
          service: service,
          log: logCapture,
          token: _testToken,
          maxSessions: 2,
        );
        port = await daemon.start(port: 0);
        client = HttpClient();
      });

      tearDown(() async {
        client.close(force: true);
        await daemon.stop();
        await stopEnv();
        tempDir.deleteSync(recursive: true);
      });

      test(
        'initialize beyond the session cap evicts the oldest never-used '
        'session (Fix 3, 2026-09-07, the 2026-09-07 daemon-auth engineering '
        'log (internal)) '
        'instead of rejecting, logged with its handle',
        () async {
          final r1 = await send('POST', body: _initializeBody(1));
          final s1 = r1.headers.value('Mcp-Session-Id')!;
          expect(r1.statusCode, HttpStatus.ok);
          await readJson(r1);
          // s1 gets real post-init traffic, so it is NOT evictable.
          await readJson(
            await send('POST', sessionId: s1, body: _toolsListBody(2)),
          );

          final r2 = await send('POST', body: _initializeBody(1));
          final s2 = r2.headers.value('Mcp-Session-Id')!;
          expect(r2.statusCode, HttpStatus.ok);
          await readJson(r2);
          // s2 stays never-used since its own initialize — the only
          // eviction candidate at the cap.
          expect(daemon.sessionCount, 2);

          final r3 = await send('POST', body: _initializeBody(1));
          expect(
            r3.statusCode,
            HttpStatus.ok,
            reason:
                's2 (never used) must be evicted to admit this initialize, '
                'not rejected with 503',
          );
          final s3 = r3.headers.value('Mcp-Session-Id')!;
          await readJson(r3);
          expect(
            daemon.sessionCount,
            2,
            reason: 's2 evicted, s1 kept, s3 admitted — cap stays at 2',
          );
          expect(
            logLines.any(
              (l) =>
                  l.contains('evicted') &&
                  l.contains(sessionLogHandle(s2)),
            ),
            isTrue,
            reason: 'the eviction must be logged with s2\'s handle: $logLines',
          );
          expect(
            logLines.any((l) => l.contains(s2)),
            isFalse,
            reason: 'the eviction log must not contain the raw id: $logLines',
          );

          // s2 is really gone.
          final afterResp = await send(
            'POST',
            sessionId: s2,
            body: _toolsListBody(9),
          );
          expect(afterResp.statusCode, HttpStatus.notFound);

          // Now give s3 real traffic too, so BOTH remaining sessions are
          // non-evictable — only then must the cap finally fall back to 503.
          await readJson(
            await send('POST', sessionId: s3, body: _toolsListBody(2)),
          );
          final r4 = await send('POST', body: _initializeBody(1));
          expect(r4.statusCode, HttpStatus.serviceUnavailable);
          final json4 = await readJson(r4);
          expect(json4, isNotNull);
          expect((json4!['error'] as Map)['message'], contains('max'));
          expect(
            daemon.sessionCount,
            2,
            reason: 'the final rejected initialize must not create a session',
          );
          expect(
            logLines.any(
              (l) => l.contains('session cap') && l.contains('none evictable'),
            ),
            isTrue,
            reason: 'the final 503 must be logged: $logLines',
          );
        },
      );
    });

    group('request body cap', () {
      setUp(() async {
        tempDir = Directory.systemTemp.createTempSync(
          'remembox_http_maxbody_test_',
        );
        logLines = [];
        await startEnv(tempDir);
        daemon = RememboxHttpDaemon(
          service: service,
          log: logCapture,
          token: _testToken,
          maxBodyBytes: 200,
        );
        port = await daemon.start(port: 0);
        client = HttpClient();
      });

      tearDown(() async {
        client.close(force: true);
        await daemon.stop();
        await stopEnv();
        tempDir.deleteSync(recursive: true);
      });

      test(
        'an oversized POST body gets 413 with a JSON error body and a '
        'logged line naming the cap; the daemon stays usable afterwards',
        () async {
          // 'x' * 1000 comfortably exceeds the 200-byte test cap once
          // wrapped in the JSON-RPC envelope.
          final oversizedText = 'x' * 1000;
          final rawBody = jsonEncode({
            'jsonrpc': '2.0',
            'id': 1,
            'method': 'initialize',
            'params': {
              'protocolVersion': '2025-06-18',
              'capabilities': <String, Object?>{},
              'clientInfo': {'name': oversizedText, 'version': '0'},
            },
          });
          expect(rawBody.length, greaterThan(200));

          final resp = await send('POST', rawBody: rawBody);
          expect(resp.statusCode, HttpStatus.requestEntityTooLarge);
          final json = await readJson(resp);
          expect(json, isNotNull);
          expect((json!['error'] as Map)['message'], contains('200'));
          expect(
            logLines.any((l) => l.contains('exceeded') && l.contains('200')),
            isTrue,
            reason: 'the body-size rejection must be logged: $logLines',
          );

          // Daemon must still be usable — one oversized request does not
          // wedge it.
          final okResp = await send('POST', body: _initializeBody(2));
          expect(okResp.statusCode, HttpStatus.ok);
          expect(daemon.sessionCount, 1);
        },
      );
    });
  });

  group('constant-time bearer-token comparison (Fix 1, 2026-09-07, '
      'the 2026-09-07 daemon-auth engineering log (internal), review '
      'finding H-1)', () {
    test('equal strings compare equal', () {
      expect(constantTimeEquals('abc123', 'abc123'), isTrue);
      expect(constantTimeEquals('', ''), isTrue);
    });

    test('unequal strings of the same length compare unequal', () {
      expect(constantTimeEquals('abc123', 'abc124'), isFalse);
      expect(constantTimeEquals('aaaaaa', 'baaaaa'), isFalse);
    });

    test('strings of different lengths compare unequal (and do not throw '
        'or short-circuit on the shorter one)', () {
      expect(constantTimeEquals('short', 'a-much-longer-string'), isFalse);
      expect(constantTimeEquals('a-much-longer-string', 'short'), isFalse);
      expect(constantTimeEquals('', 'nonempty'), isFalse);
    });
  });

  group('auth, Host, Origin, Content-Type hardening (Fix 1/2, 2026-09-07, '
      'the 2026-09-07 daemon-auth engineering log (internal))', () {
    late Directory tempDir;
    late Store store;
    late SyncClient syncClient;
    late StoreGate gate;
    late FakeEmbedder embedder;
    late MemoryService service;
    late RememboxHttpDaemon daemon;
    late HttpClient client;
    late int port;
    late List<String> logLines;

    void logCapture(String line) => logLines.add(line);

    Future<HttpClientResponse> send(
      String method, {
      Map<String, Object?>? body,
      String? sessionId,
      String? authToken = _testToken,
      // N-10 (2026-09-07 security-review re-verification): raw override for
      // the whole Authorization header, for tests that need a specific
      // auth-scheme casing (e.g. "bearer" lowercase) that "Bearer $authToken"
      // can't express. Takes precedence over [authToken] when non-null.
      String? authHeader,
      String? host,
      String? origin,
      String? contentType = 'application/json',
    }) async {
      final request = await client.openUrl(
        method,
        Uri.parse('http://127.0.0.1:$port/mcp'),
      );
      if (host != null) request.headers.set(HttpHeaders.hostHeader, host);
      if (origin != null) request.headers.set('Origin', origin);
      if (authHeader != null) {
        request.headers.set('Authorization', authHeader);
      } else if (authToken != null) {
        request.headers.set('Authorization', 'Bearer $authToken');
      }
      if (sessionId != null) request.headers.set('Mcp-Session-Id', sessionId);
      if (body != null) {
        if (contentType != null) {
          request.headers.set(HttpHeaders.contentTypeHeader, contentType);
        }
        request.write(jsonEncode(body));
      }
      return request.close();
    }

    Future<Map<String, Object?>?> readJson(HttpClientResponse response) async {
      final text = await utf8.decoder.bind(response).join();
      if (text.isEmpty) return null;
      return jsonDecode(text) as Map<String, Object?>;
    }

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync(
        'remembox_http_auth_test_',
      );
      logLines = [];
      store = openStore(directory: tempDir.path);
      syncClient = SyncClient(
        store,
        [localActivationSyncUrl],
        [SyncCredentials.none()],
      )..start();
      embedder = FakeEmbedder();
      gate = await StoreGate.persistent(
        store: store,
        syncClient: syncClient,
        storeDirectory: tempDir.path,
        log: logCapture,
      );
      service = MemoryService(
        gate: gate,
        embedder: embedder,
        log: logCapture,
      );
      daemon = RememboxHttpDaemon(
        service: service,
        log: logCapture,
        token: _testToken,
      );
      port = await daemon.start(port: 0);
      client = HttpClient();
    });

    tearDown(() async {
      client.close(force: true);
      await daemon.stop();
      await service.dispose();
      await gate.close();
      tempDir.deleteSync(recursive: true);
    });

    test('a request with the right token, loopback host, no Origin, and '
        'application/json is served normally', () async {
      final resp = await send('POST', body: _initializeBody(1));
      expect(resp.statusCode, HttpStatus.ok);
      expect(daemon.sessionCount, 1);
    });

    test('a missing Authorization header returns 401 with a JSON-RPC error '
        'body, logged, and creates no session', () async {
      final resp = await send(
        'POST',
        body: _initializeBody(1),
        authToken: null,
      );
      expect(resp.statusCode, HttpStatus.unauthorized);
      final json = await readJson(resp);
      expect(json, isNotNull);
      expect((json!['error'] as Map)['message'], isNotEmpty);
      expect(daemon.sessionCount, 0);
      expect(
        logLines.any((l) => l.contains('401') && l.contains('bearer')),
        isTrue,
        reason: 'the rejection must be logged: $logLines',
      );
    });

    test('a wrong Authorization token returns 401 and creates no session', () async {
      final resp = await send(
        'POST',
        body: _initializeBody(1),
        authToken: 'definitely-the-wrong-token',
      );
      expect(resp.statusCode, HttpStatus.unauthorized);
      expect(daemon.sessionCount, 0);
    });

    test(
      'N-10 (2026-09-07 security-review re-verification): a lowercase '
      '"bearer" auth-scheme is accepted (RFC 7235 §2.1: the scheme token '
      'is case-insensitive)',
      () async {
        final resp = await send(
          'POST',
          body: _initializeBody(1),
          authHeader: 'bearer $_testToken',
        );
        expect(resp.statusCode, HttpStatus.ok);
        await readJson(resp);
      },
    );

    test('a non-loopback Host header returns 403, logged, and creates no '
        'session (DNS-rebinding defense)', () async {
      final resp = await send(
        'POST',
        body: _initializeBody(1),
        host: 'attacker.example:1234',
      );
      expect(resp.statusCode, HttpStatus.forbidden);
      expect(daemon.sessionCount, 0);
      expect(
        logLines.any((l) => l.contains('403') && l.contains('Host')),
        isTrue,
        reason: 'the rejection must be logged: $logLines',
      );
    });

    test('loopback Host headers (with and without a port, and IPv6, '
        'bracketed and bare) are all allowed', () async {
      for (final host in [
        '127.0.0.1',
        '127.0.0.1:9999',
        'localhost',
        '[::1]',
        // N-9 (2026-09-07 security-review re-verification): a BARE
        // (unbracketed) IPv6 literal was previously dead code —
        // `lastIndexOf(':')` split "::1" into host "::" + bogus port "1",
        // which never matched the loopback switch below.
        '::1',
      ]) {
        final resp = await send(
          'POST',
          body: _initializeBody(1),
          host: host,
        );
        expect(
          resp.statusCode,
          HttpStatus.ok,
          reason: 'Host "$host" must be treated as loopback',
        );
        await readJson(resp);
      }
    });

    test(
      'N-9 (2026-09-07 security-review re-verification): a userinfo-shaped '
      'Host header naming a different host after "@" is rejected as '
      'non-loopback, not treated as "localhost"',
      () async {
        final resp = await send(
          'POST',
          body: _initializeBody(1),
          host: 'localhost:1@evil.com',
        );
        expect(
          resp.statusCode,
          HttpStatus.forbidden,
          reason:
              '"localhost:1@evil.com" must not parse as loopback host '
              '"localhost" with bogus port "1@evil.com"',
        );
        expect(daemon.sessionCount, 0);
      },
    );

    test('a present non-loopback Origin returns 403, logged with the '
        'rejected origin, and creates no session', () async {
      final resp = await send(
        'POST',
        body: _initializeBody(1),
        origin: 'https://evil.example',
      );
      expect(resp.statusCode, HttpStatus.forbidden);
      expect(daemon.sessionCount, 0);
      expect(
        logLines.any(
          (l) =>
              l.contains('403') &&
              l.contains('Origin') &&
              l.contains('evil.example'),
        ),
        isTrue,
        reason: 'the rejection must name the rejected origin: $logLines',
      );
    });

    test(
      'N-5 (2026-09-07 security-review re-verification): 50 rapid '
      '(pre-auth) 403 Host rejections from one connection produce far '
      'fewer than 50 log lines, and a later rejection folds in the '
      'suppressed count instead of dropping it',
      () async {
        // Burst: 50 rejected requests within (well under) the 1-second
        // rate-limit window — before N-5, EVERY one of these logged its
        // own line unconditionally, pre-auth (78,900 bytes for 300 such
        // requests with a 400-char Origin, per the finding).
        for (var i = 0; i < 50; i++) {
          final resp = await send(
            'POST',
            body: _initializeBody(1),
            host: 'attacker.example:1234',
          );
          expect(resp.statusCode, HttpStatus.forbidden);
          await readJson(resp);
        }
        final burstLines =
            logLines
                .where((l) => l.contains('403') && l.contains('Host'))
                .toList();
        expect(
          burstLines.length,
          lessThan(50),
          reason:
              '50 rapid rejections from one port must not produce 50 log '
              'lines: got ${burstLines.length}',
        );

        // Cross the 1-second rate-limit window, then send one more —
        // this one must be logged, folding in whatever the burst above
        // suppressed (no-silent-drop: the count is never just discarded).
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        final finalResp = await send(
          'POST',
          body: _initializeBody(1),
          host: 'attacker.example:1234',
        );
        expect(finalResp.statusCode, HttpStatus.forbidden);
        await readJson(finalResp);

        final allHostLines =
            logLines
                .where((l) => l.contains('403') && l.contains('Host'))
                .toList();
        expect(
          allHostLines.last,
          contains('suppressed'),
          reason:
              'the rejection logged after the rate-limit window must '
              'carry the suppressed count: $allHostLines',
        );
      },
    );

    test('a loopback Origin is allowed', () async {
      final resp = await send(
        'POST',
        body: _initializeBody(1),
        origin: 'http://localhost:3927',
      );
      expect(resp.statusCode, HttpStatus.ok);
    });

    test('a POST with Content-Type text/plain returns 415, logged, and '
        'creates no session (kills the non-preflighted cross-origin '
        'vector the 2026-09-07 review used)', () async {
      final resp = await send(
        'POST',
        body: _initializeBody(1),
        contentType: 'text/plain',
      );
      expect(resp.statusCode, HttpStatus.unsupportedMediaType);
      expect(daemon.sessionCount, 0);
      expect(
        logLines.any((l) => l.contains('415') && l.contains('Content-Type')),
        isTrue,
        reason: 'the rejection must be logged: $logLines',
      );
    });

    test('application/json with a charset suffix is accepted', () async {
      final resp = await send(
        'POST',
        body: _initializeBody(1),
        contentType: 'application/json; charset=utf-8',
      );
      expect(resp.statusCode, HttpStatus.ok);
    });

    test('log lines identify sessions by an 8-char handle and never '
        'contain the raw session id anywhere', () async {
      final resp = await send('POST', body: _initializeBody(1));
      final sessionId = resp.headers.value('Mcp-Session-Id')!;
      await readJson(resp);
      final handle = sessionLogHandle(sessionId);
      expect(handle.length, 8);

      expect(
        logLines.any((l) => l.contains('session $handle created')),
        isTrue,
        reason:
            'a log line must identify the session by its handle: $logLines',
      );
      expect(
        logLines.any((l) => l.contains(sessionId)),
        isFalse,
        reason: 'no log line may contain the raw session id: $logLines',
      );
    });
  });
}
