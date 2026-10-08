/// Tests for the tag discipline MCP tool layer (`lib/src/server.dart`) –
/// 2026-09-21, tag discipline (0.3.0).
///
/// Drives a real [RememboxServer] over an in-memory duplex [StreamChannel]
/// pair with a real [MCPClient], exactly like test/server_areas_facts_test.dart
/// – this file only asserts that server.dart wires `tags_list`/`tag_merge`/
/// `tag_remove` arguments through correctly and that bad input surfaces as
/// an `invalid_input` tool result; the underlying service logic has its own
/// dedicated tests (test/tags_test.dart).
///
/// Also covers `tag_define` (2026-10-06, tag registry) and one strict
/// registry mode rejection over the wire.
///
/// Synthetic data only: project `home`, tags `alice`, `bob`, `lesson`,
/// `appsScript`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp/client.dart';
import 'package:remembox/src/memory_service.dart';
import 'package:remembox/src/model.dart';
import 'package:remembox/src/server.dart';
import 'package:remembox/src/store.dart' show RegistryMode;
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
    tempDir = Directory.systemTemp.createTempSync('remembox_server_tags_test_');
    testGate = await openTestGate(tempDir.path);
    embedder = FakeEmbedder();
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

  Future<CallToolResult> call(String name, Map<String, Object?> args) =>
      connection.callTool(CallToolRequest(name: name, arguments: args));

  Future<Map<String, Object?>> callOk(
    String name,
    Map<String, Object?> args,
  ) async {
    final result = await call(name, args);
    expect(
      result.isError ?? false,
      isFalse,
      reason: 'expected $name to succeed, got: ${_decodeToolJson(result)}',
    );
    return _decodeToolJson(result);
  }

  Future<Map<String, Object?>> callInvalid(
    String name,
    Map<String, Object?> args,
  ) async {
    final result = await call(name, args);
    expect(result.isError, isTrue, reason: 'expected $name to fail on $args');
    final json = _decodeToolJson(result);
    expect(json['error'], 'invalid_input');
    return json;
  }

  group('remember/supersede tag warnings surface over the wire', () {
    test('a camelCase-changing tag produces a warning in the tool result', () async {
      final r = await callOk('remember', {
        'text': 'server-layer tag probe',
        'project': 'home',
        'tags': ['apps-script'],
      });
      expect(r['warning'], contains('Tag "apps-script" stored as "appsScript"'));
    });
  });

  group('tags_list', () {
    test('lists tags with usage counts', () async {
      await callOk('remember', {
        'text': 'e1',
        'project': 'home',
        'tags': ['alice'],
      });
      await callOk('remember', {
        'text': 'e2',
        'project': 'home',
        'tags': ['alice'],
      });

      final r = await callOk('tags_list', {});
      final list = (r['tags']! as List).cast<Map<String, Object?>>();
      // `registered`/`description` (tag registry, 2026-10-06) are part
      // of every row; nothing is registered here.
      expect(list, [
        {'name': 'alice', 'count': 2, 'registered': false, 'description': null},
      ]);
      expect(r['_provenance_note'], isNotNull);
    });

    test('prefix/minCount/limit are wired through', () async {
      await callOk('remember', {
        'text': 'e1',
        'project': 'home',
        'tags': ['alice'],
      });
      await callOk('remember', {
        'text': 'e2',
        'project': 'home',
        'tags': ['bob'],
      });

      final r = await callOk('tags_list', {'prefix': 'al', 'limit': 1});
      final list = (r['tags']! as List).cast<Map<String, Object?>>();
      expect(list.map((t) => t['name']), ['alice']);
    });
  });

  group('tag_merge', () {
    test('merges from into into and reports counts', () async {
      await callOk('remember', {
        'text': 'e1',
        'project': 'home',
        'tags': ['contact'],
      });
      await callOk('remember', {
        'text': 'e2',
        'project': 'home',
        'tags': ['contacts'],
      });

      final r = await callOk('tag_merge', {
        'from': ['contacts'],
        'into': 'contact',
      });
      expect(r['entriesChanged'], 1);
      expect(r['linksReplaced'], 1);
      expect(r['tagsRemoved'], 1);
      expect(r['dryRun'], false);
    });

    test('dryRun is wired through and writes nothing', () async {
      await callOk('remember', {
        'text': 'e1',
        'project': 'home',
        'tags': ['contact'],
      });
      await callOk('remember', {
        'text': 'e2',
        'project': 'home',
        'tags': ['contacts'],
      });

      final dry = await callOk('tag_merge', {
        'from': ['contacts'],
        'into': 'contact',
        'dryRun': true,
      });
      expect(dry['dryRun'], true);

      final list = (await callOk('tags_list', {}))['tags']! as List;
      expect(list, hasLength(2), reason: 'dryRun must not have written anything');
    });

    test('missing "into" is rejected client-side-bypass-safe (server-side '
        'invalid_input)', () async {
      final result = await call('tag_merge', {
        'from': ['x'],
      });
      // dart_mcp validates `required` client-side for a genuinely missing
      // argument, same caveat server_areas_facts_test.dart documents for
      // project_merge's own required arguments – this just asserts the
      // call does not silently succeed.
      expect(result.isError, isTrue);
    });

    test('"into" equal to a "from" entry is rejected', () async {
      await callOk('remember', {
        'text': 'e1',
        'project': 'home',
        'tags': ['contact'],
      });
      await callInvalid('tag_merge', {
        'from': ['contact'],
        'into': 'contact',
      });
    });
  });

  group('tag_remove', () {
    test('removes tags and reports counts', () async {
      await callOk('remember', {
        'text': 'e1',
        'project': 'home',
        'tags': ['alice'],
      });

      final r = await callOk('tag_remove', {
        'tags': ['alice'],
      });
      expect(r['entriesChanged'], 1);
      expect(r['linksRemoved'], 1);
      expect(r['tagsRemoved'], 1);
      expect(r['dryRun'], false);
    });

    test('dryRun is wired through and writes nothing', () async {
      await callOk('remember', {
        'text': 'e1',
        'project': 'home',
        'tags': ['alice'],
      });

      final dry = await callOk('tag_remove', {
        'tags': ['alice'],
        'dryRun': true,
      });
      expect(dry['dryRun'], true);

      final list = (await callOk('tags_list', {}))['tags']! as List;
      expect(list, hasLength(1), reason: 'dryRun must not have written anything');
    });

    test('unknown tag names are reported, not fatal', () async {
      final r = await callOk('tag_remove', {
        'tags': ['doesNotExist'],
      });
      expect(r['notFound'], ['doesNotExist']);
    });
  });

  group('tags_normalize', () {
    test('merges a legacy row into its normalized form and reports counts', () async {
      final r0 = await callOk('remember', {'text': 'e1', 'project': 'home'});
      final store = testGate.store;
      final legacy = Tag(name: 'Alice');
      legacy.id = store.box<Tag>().put(legacy);
      final entry = store.box<MemoryEntry>().get(r0['id'] as int)!
        ..tags.add(legacy);
      entry.tags.applyToDb();

      final r = await callOk('tags_normalize', {});
      expect(r['dryRun'], false);
      final renamed = (r['renamed']! as List).cast<Map<String, Object?>>();
      expect(renamed, [
        {'from': 'Alice', 'into': 'alice', 'entries': 1},
      ]);
      expect(r['merged'], 0);
      expect(r['skipped'], isEmpty);
      expect(r['tagsRemoved'], 1);
    });

    test('dryRun is wired through and writes nothing', () async {
      final r0 = await callOk('remember', {'text': 'e1', 'project': 'home'});
      final store = testGate.store;
      final legacy = Tag(name: 'Alice');
      legacy.id = store.box<Tag>().put(legacy);
      final entry = store.box<MemoryEntry>().get(r0['id'] as int)!
        ..tags.add(legacy);
      entry.tags.applyToDb();

      final dry = await callOk('tags_normalize', {'dryRun': true});
      expect(dry['dryRun'], true);
      expect(store.box<Tag>().getAll().map((t) => t.name).toList(), ['Alice']);
    });
  });

  group('tag_define', () {
    test('is listed by tools/list with a closed schema', () async {
      final listed = await connection.listTools();
      final tool = listed.tools.singleWhere((t) => t.name == 'tag_define');
      final schema = tool.inputSchema;
      expect(schema.required, ['name']);
      expect(
        schema.properties!.keys,
        unorderedEquals([
          'name',
          'description',
          'allowSimilar',
          'aliases',
          'addAliases',
          'removeAliases',
        ]),
      );
      expect(schema.additionalProperties, isFalse);
    });

    test('registers a tag and reports it', () async {
      final r = await callOk('tag_define', {
        'name': 'apps-script',
        'description': 'Automation scripts.',
      });
      expect(r['name'], 'appsScript');
      expect(r['action'], 'created');
      expect(r['normalizedFrom'], 'apps-script');
    });

    test('aliases are wired through; omitted leaves them, [] clears them',
        () async {
      final r = await callOk('tag_define', {
        'name': 'cooking',
        'description': 'Meals and how to make them.',
        'aliases': ['recipe', 'kitchen'],
      });
      expect(r['aliases'], ['kitchen', 'recipe']);
      final kept = await callOk('tag_define', {'name': 'cooking'});
      expect(kept['aliases'], ['kitchen', 'recipe']);
      final cleared = await callOk('tag_define', {
        'name': 'cooking',
        'aliases': <String>[],
      });
      expect(cleared['aliases'], isEmpty);
      expect(cleared['aliasesRemoved'], ['kitchen', 'recipe']);
    });

    test('bad input surfaces as invalid_input', () async {
      final r = await callInvalid('tag_define', {'name': 'lesson'});
      expect(r['message'], contains('a description is required'));
    });

    test('an unknown argument is rejected, nothing registered', () async {
      // The typed client sends the arguments as given; the server's schema
      // validation (additionalProperties: false) rejects the call before
      // the handler runs.
      final result = await call('tag_define', {
        'name': 'lesson',
        'descripton': 'Misspelled key.',
      });
      expect(result.isError, isTrue);
      final text = (result.content.single as TextContent).text;
      expect(text, contains('"descripton"'));
      expect(testGate.store.box<TagDefinition>().count(), 0);
    });
  });

  test('strict registry mode: remember with an unregistered tag is an '
      'invalid_input error naming the tag', () async {
    final strictService = MemoryService(
      gate: testGate.gate,
      embedder: embedder,
      registryMode: RegistryMode.strict,
    );
    final clientToServer = StreamController<String>();
    final serverToClient = StreamController<String>();
    final strictServer = RememboxServer(
      StreamChannel<String>.withCloseGuarantee(
        clientToServer.stream,
        serverToClient.sink,
      ),
      service: strictService,
    );
    final strictClient = _TestClient();
    final strictConnection = strictClient.connectServer(
      StreamChannel<String>.withCloseGuarantee(
        serverToClient.stream,
        clientToServer.sink,
      ),
    );
    addTearDown(() async {
      await strictClient.shutdown();
      await strictServer.shutdown();
      await strictService.dispose();
    });
    await strictConnection.initialize(
      InitializeRequest(
        protocolVersion: ProtocolVersion.latestSupported,
        capabilities: strictClient.capabilities,
        clientInfo: strictClient.implementation,
      ),
    );
    strictConnection.notifyInitialized(InitializedNotification());
    await strictServer.initialized;

    await strictService.projectSet(
      name: 'home',
      description: 'Synthetic household project.',
    );
    final result = await strictConnection.callTool(
      CallToolRequest(
        name: 'remember',
        arguments: {
          'text': 'strict probe',
          'project': 'home',
          'tags': ['lesson'],
        },
      ),
    );
    expect(result.isError, isTrue);
    final json = _decodeToolJson(result);
    expect(json['error'], 'invalid_input');
    expect(
      json['message'],
      contains('tag(s) not registered (strict registry mode): "lesson"'),
    );
    expect(testGate.store.box<MemoryEntry>().count(), 0);
  });
}
