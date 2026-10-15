/// Test-only harness for tool-level tests: a [RememboxServer] on a fresh
/// temp store, connected to an in-memory MCP client, with `callOk`/
/// `callInvalid` helpers. Used by the 0.5.0 server tests (kinds, link
/// directions, retired tags, attribute values, in-place edits) so each of
/// them does not repeat the same channel plumbing.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp/client.dart';
import 'package:remembox/objectbox.g.dart';
import 'package:remembox/src/memory_service.dart';
import 'package:remembox/src/server.dart';
import 'package:remembox/src/store.dart' show RegistryMode;
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

import '../support/fake_embedder.dart';
import 'test_store_gate.dart';

base class _TestClient extends MCPClient {
  _TestClient() : super(Implementation(name: 'test client', version: '0.1'));
}

/// The tool result's JSON payload (success and error results alike).
Map<String, Object?> decodeToolJson(CallToolResult result) {
  final text = (result.content.single as TextContent).text;
  return jsonDecode(text) as Map<String, Object?>;
}

class TestServer {
  final Directory tempDir;
  final TestGate testGate;
  final MemoryService service;
  final RememboxServer server;
  final ServerConnection connection;
  final _TestClient _client;

  /// Every log line the service and server wrote.
  final List<String> logLines;

  /// The server instructions from the `initialize` result.
  final String? instructions;

  TestServer._(
    this.tempDir,
    this.testGate,
    this.service,
    this.server,
    this.connection,
    this._client,
    this.logLines,
    this.instructions,
  );

  Store get store => testGate.store;

  /// Opens a fresh store, a service in [registryMode] and a connected
  /// client. Call [close] in `tearDown`.
  static Future<TestServer> open({
    RegistryMode registryMode = RegistryMode.open,
  }) async {
    final tempDir = Directory.systemTemp.createTempSync('remembox_test_srv_');
    final logLines = <String>[];
    final testGate = await openTestGate(tempDir.path, log: logLines.add);
    final service = MemoryService(
      gate: testGate.gate,
      embedder: FakeEmbedder(),
      log: logLines.add,
      registryMode: registryMode,
    );
    final clientToServer = StreamController<String>();
    final serverToClient = StreamController<String>();
    final server = RememboxServer(
      StreamChannel<String>.withCloseGuarantee(
        clientToServer.stream,
        serverToClient.sink,
      ),
      service: service,
      log: logLines.add,
    );
    final client = _TestClient();
    final connection = client.connectServer(
      StreamChannel<String>.withCloseGuarantee(
        serverToClient.stream,
        clientToServer.sink,
      ),
    );
    final init = await connection.initialize(
      InitializeRequest(
        protocolVersion: ProtocolVersion.latestSupported,
        capabilities: client.capabilities,
        clientInfo: client.implementation,
      ),
    );
    connection.notifyInitialized(InitializedNotification());
    await server.initialized;
    return TestServer._(
      tempDir,
      testGate,
      service,
      server,
      connection,
      client,
      logLines,
      init.instructions,
    );
  }

  Future<void> close() async {
    await _client.shutdown();
    await server.shutdown();
    await service.dispose();
    await testGate.close();
    tempDir.deleteSync(recursive: true);
  }

  Future<CallToolResult> call(String name, Map<String, Object?> args) =>
      connection.callTool(CallToolRequest(name: name, arguments: args));

  /// Calls [name] and expects success; returns the JSON payload.
  Future<Map<String, Object?>> callOk(
    String name,
    Map<String, Object?> args,
  ) async {
    final result = await call(name, args);
    expect(
      result.isError ?? false,
      isFalse,
      reason: 'expected $name to succeed, got: ${decodeToolJson(result)}',
    );
    return decodeToolJson(result);
  }

  /// Calls [name] and expects an `invalid_input` error; returns the JSON
  /// payload (`error`, `message`).
  Future<Map<String, Object?>> callInvalid(
    String name,
    Map<String, Object?> args,
  ) async {
    final result = await call(name, args);
    expect(result.isError, isTrue, reason: 'expected $name to fail on $args');
    final json = decodeToolJson(result);
    expect(json['error'], 'invalid_input');
    return json;
  }

  /// The tool [name] as `tools/list` reports it.
  Future<Tool> tool(String name) async {
    final listed = await connection.listTools();
    return listed.tools.singleWhere((t) => t.name == name);
  }
}
