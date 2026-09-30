/// Tests for WP5's MCP tool layer (`lib/src/server.dart`) over areas and
/// facts — 2026-09-21, areas and facts (0.3.0), plan §3/§5. Also covers
/// `entries_move` (2026-09-21, entries move (0.3.0)) – a later, closely
/// related registry tool, added to this same file rather than a new one
/// since it shares the exact harness/coverage-scope every group here
/// already uses.
///
/// Drives a real [RememboxServer] over an in-memory duplex [StreamChannel]
/// pair with a real [MCPClient], exactly like test/server_test.dart — this
/// file only adds coverage for the NEW tools (`area_set`, `project_set`,
/// `areas_list`, `project_merge`, `entries_move`, `fact_set`, `fact_get`,
/// `fact_query`, `fact_forget`) and the `area` argument on
/// `recall`/`list_recent`. The underlying service behavior
/// (memory_service_registry/areas/facts.dart) has its own dedicated tests
/// (registry_test.dart, areas_test.dart, facts_test.dart,
/// areas_integration_test.dart, entries_move_test.dart) — this file
/// asserts only that server.dart wires arguments through correctly and
/// that bad input surfaces as an `invalid_input` tool result, not that the
/// service logic itself is correct.
///
/// Synthetic data only (addendum cross-cutting rule): projects `acme-app`,
/// `home`, `garden`; areas `work`, `family`; subjects `Flat B`, `Car`,
/// `Account 1`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp/client.dart';
import 'package:remembox/src/memory_service.dart';
import 'package:remembox/src/model.dart';
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
    tempDir = Directory.systemTemp.createTempSync(
      'remembox_server_areas_facts_test_',
    );
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
    expect(
      result.isError,
      isTrue,
      reason: 'expected $name to fail on $args',
    );
    final json = _decodeToolJson(result);
    expect(json['error'], 'invalid_input');
    return json;
  }

  group('server metadata', () {
    test('serverVersion is 0.3.1', () {
      expect(serverVersion, '0.3.1');
    });

    test('the MCP initialize handshake reports serverInfo.version 0.3.1', () async {
      // Re-verifies via the protocol itself (not just the Dart constant):
      // a second connection over a fresh channel pair, same server.
      final toServer = StreamController<String>();
      final toClient = StreamController<String>();
      final freshServer = RememboxServer(
        StreamChannel<String>.withCloseGuarantee(
          toServer.stream,
          toClient.sink,
        ),
        service: service,
      );
      addTearDown(freshServer.shutdown);
      final freshClient = _TestClient();
      final freshConnection = freshClient.connectServer(
        StreamChannel<String>.withCloseGuarantee(
          toClient.stream,
          toServer.sink,
        ),
      );
      final initResult = await freshConnection.initialize(
        InitializeRequest(
          protocolVersion: ProtocolVersion.latestSupported,
          capabilities: freshClient.capabilities,
          clientInfo: freshClient.implementation,
        ),
      );
      expect(initResult.serverInfo.version, '0.3.1');
      await freshClient.shutdown();
    });
  });

  group('tool listing', () {
    test(
      'tools/list carries every new areas/facts tool with its schema',
      () async {
        final listed = await connection.listTools();
        final byName = {for (final t in listed.tools) t.name: t};

        const newToolNames = [
          'area_set',
          'project_set',
          'areas_list',
          'project_merge',
          'entries_move',
          'fact_set',
          'fact_get',
          'fact_query',
          'fact_forget',
        ];
        for (final name in newToolNames) {
          expect(byName.containsKey(name), isTrue, reason: '$name missing');
        }

        expect(byName['area_set']!.inputSchema.required, contains('name'));
        expect(
          byName['project_set']!.inputSchema.properties?.keys,
          containsAll(['name', 'addAreas', 'removeAreas', 'status']),
        );
        expect(byName['areas_list']!.inputSchema.properties, isEmpty);
        expect(
          byName['project_merge']!.inputSchema.required,
          containsAll(['from', 'into']),
        );
        expect(
          byName['entries_move']!.inputSchema.required,
          containsAll(['ids', 'toProject']),
        );
        expect(
          byName['entries_move']!.inputSchema.properties?.keys,
          containsAll(['ids', 'toProject', 'dryRun', 'includeChain']),
        );
        final factSetProps = byName['fact_set']!.inputSchema.properties!;
        expect(
          factSetProps.keys,
          containsAll([
            'subject',
            'attribute',
            'project',
            'valueText',
            'valueNumber',
            'valueDate',
          ]),
        );
        // project is deliberately NOT client-side required (same
        // client-bypass reasoning as remember's tool schema) — asserts the
        // convention was actually followed, not just documented.
        expect(
          byName['fact_set']!.inputSchema.required,
          isNot(contains('project')),
        );
        expect(byName['fact_get']!.inputSchema.required, contains('subject'));
        expect(byName['fact_forget']!.inputSchema.required, contains('id'));

        // area is now on recall and list_recent too.
        expect(
          byName['recall']!.inputSchema.properties?.keys,
          contains('area'),
        );
        expect(
          byName['list_recent']!.inputSchema.properties?.keys,
          contains('area'),
        );
      },
    );

    test(
      'review privacy/presentation: no tool description or property '
      'description leaks internal planning references or the '
      '"objectbox" company/maintainer-area example',
      () async {
        final listed = await connection.listTools();
        for (final tool in listed.tools) {
          final toolText = tool.description ?? '';
          expect(
            toolText,
            isNot(contains('objectbox')),
            reason: '${tool.name} description mentions "objectbox"',
          );
          for (final pattern in ['plan §', 'addendum ', 'WP1', 'WP2', 'WP3',
              'WP4', 'WP5', '2026-09-21']) {
            expect(
              toolText,
              isNot(contains(pattern)),
              reason: '${tool.name} description leaks "$pattern"',
            );
          }
          final props = tool.inputSchema.properties;
          if (props == null) continue;
          for (final entry in props.entries) {
            final propText = jsonEncode(entry.value);
            expect(
              propText,
              isNot(contains('objectbox')),
              reason: '${tool.name}.${entry.key} mentions "objectbox"',
            );
          }
        }
      },
    );

    test(
      'review B2: the fact_forget tool description does not claim that '
      '"ended" reopens the predecessor',
      () async {
        final listed = await connection.listTools();
        final factForget = listed.tools.singleWhere(
          (t) => t.name == 'fact_forget',
        );
        final text = factForget.description ?? '';
        expect(text, contains('does not apply to'));
        // The old wording ("If the forgotten fact was the current value
        // ... becomes current again", applied to ALL three actions
        // including "ended") is gone.
        expect(
          text,
          isNot(
            contains(
              'If the forgotten fact was the current value for its key',
            ),
          ),
        );
      },
    );
  });

  group('area_set', () {
    test('creates, then updates the description, then is unchanged', () async {
      final created = await callOk('area_set', {'name': 'work'});
      expect(created['action'], 'created');
      expect(created['name'], 'work');
      final id = created['id'];

      final updated = await callOk('area_set', {
        'name': 'work',
        'description': 'Day job stuff',
      });
      expect(updated['action'], 'updated');
      expect(updated['id'], id);

      final unchanged = await callOk('area_set', {
        'name': 'work',
        'description': 'Day job stuff',
      });
      expect(unchanged['action'], 'unchanged');
    });

    test('a blank name is rejected as invalid_input', () async {
      // 'name' is in the tool schema's client-side `required` list (unlike
      // remember's/fact_set's `project` — see fact_set's tool definition
      // comment), so omitting the key entirely never reaches the server;
      // an empty/whitespace value is what exercises MemoryService's own
      // server-side "required" rejection.
      await callInvalid('area_set', {'name': '   '});
    });

    test('a name over areaNameMaxLen is rejected as invalid_input', () async {
      await callInvalid('area_set', {
        'name': 'x' * (MemoryService.areaNameMaxLen + 1),
      });
    });
  });

  group('project_set', () {
    test('creates a project and assigns/removes areas', () async {
      await callOk('area_set', {'name': 'work'});
      await callOk('area_set', {'name': 'family'});

      final created = await callOk('project_set', {
        'name': 'acme-app',
        'addAreas': ['work', 'family'],
      });
      expect(created['action'], 'created');
      expect((created['areas'] as List).toSet(), {'work', 'family'});

      final removed = await callOk('project_set', {
        'name': 'acme-app',
        'removeAreas': ['family'],
      });
      expect(removed['removed'], ['family']);
      expect((removed['areas'] as List).toSet(), {'work'});
    });

    test('setting status to archived succeeds; merged is rejected', () async {
      final archived = await callOk('project_set', {
        'name': 'acme-app',
        'status': ProjectStatus.archived,
      });
      expect(archived['status'], ProjectStatus.archived);

      await callInvalid('project_set', {
        'name': 'acme-app',
        'status': ProjectStatus.merged,
      });
    });

    test('an unknown area in addAreas is rejected as invalid_input', () async {
      await callInvalid('project_set', {
        'name': 'acme-app',
        'addAreas': ['no-such-area'],
      });
    });

    test('a blank name is rejected as invalid_input', () async {
      // Same client-side-required-list caveat as area_set's test above.
      await callInvalid('project_set', {'name': ''});
    });
  });

  group('areas_list', () {
    test('reports areas with member projects and registry warnings', () async {
      await callOk('area_set', {'name': 'work'});
      await callOk('project_set', {
        'name': 'acme-app',
        'addAreas': ['work'],
      });
      // Registered (remember() auto-registers) but never assigned to an
      // area — projectsWithoutArea, not unregisteredProjects (which is
      // for a project string with NO registry row at all; remember()'s
      // own auto-registration means that never happens through the
      // public tool surface — registry_test.dart covers the raw-store
      // case directly).
      await callOk('remember', {
        'text': 'garden note, no area assigned',
        'project': 'garden',
      });

      final result = await callOk('areas_list', {});
      final areas = result['areas'] as List;
      final work = areas.cast<Map<String, Object?>>().firstWhere(
        (a) => a['name'] == 'work',
      );
      final projectNames = (work['projects'] as List)
          .cast<Map<String, Object?>>()
          .map((p) => p['name'])
          .toSet();
      expect(projectNames, contains('acme-app'));

      expect(result['projectsWithoutArea'], contains('garden'));
    });
  });

  group('project_merge', () {
    test('dryRun reports without writing; the real call moves data', () async {
      await callOk('remember', {
        'text': 'note in old-name',
        'project': 'old-name',
      });

      final dry = await callOk('project_merge', {
        'from': 'old-name',
        'into': 'acme-app',
        'dryRun': true,
      });
      expect(dry['dryRun'], isTrue);
      expect(dry['entriesMoved'], 1);

      // dryRun must not have actually moved anything.
      final stillOld = await callOk('list_recent', {'project': 'old-name'});
      expect(stillOld['count'], 1);

      final real = await callOk('project_merge', {
        'from': 'old-name',
        'into': 'acme-app',
      });
      expect(real['dryRun'], isFalse);
      expect(real['entriesMoved'], 1);

      final movedAway = await callOk('list_recent', {'project': 'old-name'});
      expect(movedAway['count'], 0);
      final movedInto = await callOk('list_recent', {'project': 'acme-app'});
      expect(movedInto['count'], greaterThanOrEqualTo(1));
    });

    test('a blank "from" or "into" is rejected as invalid_input', () async {
      // Same client-side-required-list caveat as area_set's test above —
      // both keys are present but blank, so the client sends the request
      // and MemoryService's own project-required check fires.
      await callInvalid('project_merge', {'from': '', 'into': 'b'});
      await callInvalid('project_merge', {'from': 'a', 'into': ''});
    });

    test('"from" equal to "into" is rejected as invalid_input', () async {
      await callInvalid('project_merge', {'from': 'x', 'into': 'x'});
    });
  });

  group('entries_move', () {
    test('dryRun reports without writing; the real call moves the ids',
        () async {
      final e1 = await callOk('remember', {
        'text': 'note about watering',
        'project': 'general',
      });
      await callOk('remember', {
        'text': 'unrelated note',
        'project': 'general',
      });

      final dry = await callOk('entries_move', {
        'ids': [e1['id']],
        'toProject': 'garden',
        'dryRun': true,
      });
      expect(dry['dryRun'], isTrue);
      expect(dry['moved'], 1);

      // dryRun must not have actually moved anything.
      final stillGeneral = await callOk('list_recent', {'project': 'general'});
      expect(stillGeneral['count'], 2);

      final real = await callOk('entries_move', {
        'ids': [e1['id']],
        'toProject': 'garden',
      });
      expect(real['dryRun'], isFalse);
      expect(real['moved'], 1);
      expect(real['factsUnaffected'], isTrue);

      final movedAway = await callOk('list_recent', {'project': 'general'});
      expect(movedAway['count'], 1);
      final movedInto = await callOk('list_recent', {'project': 'garden'});
      expect(movedInto['count'], 1);
    });

    test('includeChain defaults to true: a superseded chain moves whole',
        () async {
      final old = await callOk('remember', {
        'text': 'car insurer v1',
        'project': 'general',
      });
      final sup = await callOk('supersede', {
        'oldId': old['id'],
        'text': 'car insurer v2',
        'project': 'general',
      });

      final result = await callOk('entries_move', {
        'ids': [sup['newId']],
        'toProject': 'car',
      });
      expect(result['moved'], 2);
      expect(result['chainEntriesAdded'], 1);
    });

    test('an empty "ids" list is rejected as invalid_input', () async {
      await callInvalid('entries_move', {'ids': [], 'toProject': 'garden'});
    });

    test('a non-list "ids" is rejected (schema validation, not JSON '
        'decodable as our own invalid_input shape)', () async {
      // A wrong TOP-LEVEL type against the declared list schema is
      // rejected by dart_mcp's own schema validator before the request
      // ever reaches our handler/_guard – the result is still isError, but
      // its content is a raw validator message, not our
      // {error: invalid_input, message: ...} JSON shape (see
      // callInvalid/_decodeToolJson's doc), so this asserts isError only.
      final result = await call('entries_move', {
        'ids': 'x',
        'toProject': 'garden',
      });
      expect(result.isError, isTrue);
    });

    test('an id of 0 is rejected as invalid_input', () async {
      await callInvalid('entries_move', {'ids': [0], 'toProject': 'garden'});
    });

    test('a non-integer id (1.5) is rejected as invalid_input', () async {
      await callInvalid('entries_move', {
        'ids': [1.5],
        'toProject': 'garden',
      });
    });

    test('a blank "toProject" is rejected as invalid_input', () async {
      final e1 = await callOk('remember', {
        'text': 'note',
        'project': 'general',
      });
      await callInvalid('entries_move', {
        'ids': [e1['id']],
        'toProject': '',
      });
    });

    test('a missing id is rejected as invalid_input', () async {
      await callInvalid('entries_move', {
        'ids': [999999],
        'toProject': 'garden',
      });
    });
  });

  group('fact_set', () {
    test('creates a text fact, then replaces it with a new value', () async {
      final created = await callOk('fact_set', {
        'subject': 'Flat B',
        'attribute': 'insurer',
        'project': 'home',
        'valueText': 'Acme Insurance',
      });
      expect(created['action'], 'created');
      expect(created['value'], 'Acme Insurance');
      expect(created['current'], isTrue);

      final replaced = await callOk('fact_set', {
        'subject': 'Flat B',
        'attribute': 'insurer',
        'project': 'home',
        'valueText': 'Other Insurance',
      });
      expect(replaced['action'], 'replaced');
      expect(replaced['closedId'], created['id']);
    });

    test('a numeric fact round-trips as a number', () async {
      final result = await callOk('fact_set', {
        'subject': 'Flat B',
        'attribute': 'rent',
        'project': 'home',
        'valueNumber': 950.5,
        'unit': 'EUR',
      });
      expect(result['value'], 950.5);
      expect(result['unit'], 'EUR');
      expect(result['valueType'], FactValueType.number);
    });

    test('project is required (missing entirely, server-side)', () async {
      final json = await callInvalid('fact_set', {
        'subject': 'Flat B',
        'attribute': 'rent',
        'valueText': 'x',
      });
      expect(json['message'], contains('project is required'));
    });

    test('a blank subject is rejected as invalid_input', () async {
      // Same client-side-required-list caveat as area_set's test above.
      await callInvalid('fact_set', {
        'subject': '',
        'attribute': 'rent',
        'project': 'home',
        'valueText': 'x',
      });
    });

    test('a blank attribute is rejected as invalid_input', () async {
      await callInvalid('fact_set', {
        'subject': 'Flat B',
        'attribute': '',
        'project': 'home',
        'valueText': 'x',
      });
    });

    test(
      'giving two of valueText/valueNumber/valueDate is rejected as '
      'invalid_input',
      () async {
        await callInvalid('fact_set', {
          'subject': 'Flat B',
          'attribute': 'rent',
          'project': 'home',
          'valueText': 'x',
          'valueNumber': 1,
        });
      },
    );

    test('giving none of the three values is rejected as invalid_input', () async {
      await callInvalid('fact_set', {
        'subject': 'Flat B',
        'attribute': 'rent',
        'project': 'home',
      });
    });

    test('a malformed validFrom date is rejected as invalid_input', () async {
      await callInvalid('fact_set', {
        'subject': 'Flat B',
        'attribute': 'rent',
        'project': 'home',
        'valueNumber': 1,
        'validFrom': 'not-a-date',
      });
    });

    test(
      'review M2: a date-only valueDate is exact UTC midnight for that '
      'calendar date, independent of the server\'s own time zone',
      () async {
        final result = await callOk('fact_set', {
          'subject': 'Account 1',
          'attribute': 'renewal',
          'project': 'home',
          'valueDate': '2026-03-01',
        });
        expect(result['value'], '2026-03-01T00:00:00.000Z');
      },
    );

    test(
      'review M2: a date-time value with NO explicit UTC offset/Z is '
      'rejected as invalid_input (ambiguous – depends on server TZ)',
      () async {
        final json = await callInvalid('fact_set', {
          'subject': 'Account 1',
          'attribute': 'renewal',
          'project': 'home',
          'valueDate': '2026-03-01T10:00:00',
        });
        expect(json['message'], contains('offset'));
      },
    );

    test(
      'review M2: a date-time value WITH an explicit offset or Z is '
      'accepted and normalized to UTC',
      () async {
        final withZ = await callOk('fact_set', {
          'subject': 'Account 1',
          'attribute': 'renewal',
          'project': 'home',
          'valueDate': '2026-03-01T10:00:00Z',
        });
        expect(withZ['value'], '2026-03-01T10:00:00.000Z');

        final withOffset = await callOk('fact_set', {
          'subject': 'Car',
          'attribute': 'insurer',
          'project': 'home',
          'valueDate': '2026-03-01T10:00:00+02:00',
        });
        expect(withOffset['value'], '2026-03-01T08:00:00.000Z');
      },
    );

    test(
      'a date-only value that is not a real calendar date is rejected '
      '(DateTime.tryParse would otherwise silently roll it over)',
      () async {
        final json = await callInvalid('fact_set', {
          'subject': 'Account 1',
          'attribute': 'renewal',
          'project': 'home',
          'valueDate': '2030-02-30',
        });
        expect(json['message'], contains('not a valid calendar date'));
      },
    );

    test(
      'every date-argument schema description states the accepted format',
      () async {
        final listed = await connection.listTools();
        final byName = {for (final t in listed.tools) t.name: t};
        const dateArgsByTool = {
          'remember': ['expiresAt', 'docCreatedAt'],
          'supersede': ['expiresAt'],
          'fact_set': ['valueDate', 'validFrom'],
          'fact_get': ['at'],
          'fact_forget': ['validUntil'],
        };
        for (final entry in dateArgsByTool.entries) {
          final props = byName[entry.key]!.inputSchema.properties!;
          for (final argName in entry.value) {
            final description = props[argName]!.description ?? '';
            expect(
              description,
              contains('YYYY-MM-DD'),
              reason: '${entry.key}.$argName description: "$description"',
            );
            expect(
              description,
              contains('offset'),
              reason: '${entry.key}.$argName description: "$description"',
            );
          }
        }
      },
    );

    test('a subject over subjectMaxLen is rejected as invalid_input', () async {
      await callInvalid('fact_set', {
        'subject': 'x' * (MemoryService.subjectMaxLen + 1),
        'attribute': 'rent',
        'project': 'home',
        'valueNumber': 1,
      });
    });

    test(
      'a valueText over factTextMaxLen is rejected as invalid_input',
      () async {
        await callInvalid('fact_set', {
          'subject': 'Flat B',
          'attribute': 'rent',
          'project': 'home',
          'valueText': 'x' * (MemoryService.factTextMaxLen + 1),
        });
      },
    );

    test(
      'a non-finite valueNumber (JSON 1e999 overflows to Infinity) is '
      'rejected as invalid_input, never an uncaught crash — same L-4 '
      'discipline as get\'s id argument (server_test.dart)',
      () async {
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
              onTimeout: () => fail('server never responded'),
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

        // Written directly into the request text (never round-tripped
        // through jsonEncode, which throws on double.infinity) so it
        // reaches the server exactly as a real client's bytes would.
        toServer.add(
          '{"jsonrpc":"2.0","id":2,"method":"tools/call",'
          '"params":{"name":"fact_set","arguments":{"subject":"Flat B",'
          '"attribute":"rent","project":"home","valueNumber":1e999}}}',
        );
        final response = await nextResponse();
        final decoded = jsonDecode(response) as Map<String, Object?>;
        expect(decoded.containsKey('error'), isFalse);
        final result = decoded['result'] as Map<String, Object?>;
        expect(result['isError'], isTrue);
        final text =
            ((result['content'] as List).single as Map<String, Object?>)['text']
                as String;
        final payload = jsonDecode(text) as Map<String, Object?>;
        expect(payload['error'], 'invalid_input');
      },
    );
  });

  group('fact_get', () {
    test('round trips the current value, and "at" a past instant', () async {
      final first = await callOk('fact_set', {
        'subject': 'Car',
        'attribute': 'insurer',
        'project': 'home',
        'valueText': 'First Insurer',
      });
      final firstValidFrom = DateTime.parse(first['validFrom'] as String);

      // No explicit validFrom: defaults to real "now" at write time, which
      // is guaranteed to be at/after firstValidFrom (real elapsed time) —
      // an artificial future offset would make the second row invisible
      // to a plain fact_get (validFrom <= now) until that instant arrives.
      await callOk('fact_set', {
        'subject': 'Car',
        'attribute': 'insurer',
        'project': 'home',
        'valueText': 'Second Insurer',
      });

      final current = await callOk('fact_get', {
        'subject': 'Car',
        'attribute': 'insurer',
        'project': 'home',
      });
      final currentFacts = current['facts'] as List;
      expect(currentFacts, hasLength(1));
      expect(
        (currentFacts.single as Map<String, Object?>)['value'],
        'Second Insurer',
      );

      final past = await callOk('fact_get', {
        'subject': 'Car',
        'attribute': 'insurer',
        'project': 'home',
        'at': firstValidFrom.toIso8601String(),
      });
      final pastFacts = past['facts'] as List;
      expect(pastFacts, hasLength(1));
      expect(
        (pastFacts.single as Map<String, Object?>)['value'],
        'First Insurer',
      );
    });

    test('an unknown subject returns an empty list, not an error', () async {
      final result = await callOk('fact_get', {'subject': 'No Such Subject'});
      expect(result['facts'], isEmpty);
    });

    test('a blank subject is rejected as invalid_input', () async {
      // Same client-side-required-list caveat as area_set's test above.
      await callInvalid('fact_get', {'subject': ''});
    });
  });

  group('fact_query', () {
    test('finds facts by attribute and by project', () async {
      await callOk('fact_set', {
        'subject': 'Flat B',
        'attribute': 'rent',
        'project': 'home',
        'valueNumber': 950,
      });
      await callOk('fact_set', {
        'subject': 'Account 1',
        'attribute': 'rent',
        'project': 'garden',
        'valueNumber': 40,
      });

      final byAttribute = await callOk('fact_query', {'attribute': 'rent'});
      expect(byAttribute['count'], 2);

      final byProject = await callOk('fact_query', {'project': 'home'});
      expect(byProject['count'], 1);
    });

    test(
      'requires at least one of attribute/subjectPrefix/project/area',
      () async {
        await callInvalid('fact_query', {});
      },
    );

    test('an unknown area filter is rejected as invalid_input', () async {
      await callInvalid('fact_query', {'area': 'no-such-area'});
    });

    test(
      'review minor 3: an oversized area filter is rejected as '
      'invalid_input via the shared cap, same as recall/list_recent',
      () async {
        final hugeArea = 'a' * (1024 * 1024);
        final json = await callInvalid('fact_query', {
          'attribute': 'rent',
          'area': hugeArea,
        });
        expect(json['message'], contains('too long'));
      },
    );

    test('a number range filter only matches numeric facts', () async {
      await callOk('fact_set', {
        'subject': 'Flat B',
        'attribute': 'rent',
        'project': 'home',
        'valueNumber': 950,
      });
      final result = await callOk('fact_query', {
        'attribute': 'rent',
        'numberMin': 900,
        'numberMax': 1000,
      });
      expect(result['count'], greaterThanOrEqualTo(1));
    });
  });

  group('fact_forget', () {
    test('retract (default) marks the fact retracted, not current', () async {
      final created = await callOk('fact_set', {
        'subject': 'Flat B',
        'attribute': 'rent',
        'project': 'home',
        'valueNumber': 950,
      });
      final forgotten = await callOk('fact_forget', {'id': created['id']});
      expect(forgotten['action'], 'retracted');

      final lookup = await callOk('fact_get', {
        'subject': 'Flat B',
        'attribute': 'rent',
        'project': 'home',
      });
      expect(lookup['facts'], isEmpty);
    });

    test(
      'retracting the current fact reopens its predecessor (addendum M3)',
      () async {
        final first = await callOk('fact_set', {
          'subject': 'Car',
          'attribute': 'rent',
          'project': 'home',
          'valueNumber': 10,
        });
        final firstValidFrom = DateTime.parse(first['validFrom'] as String);
        final second = await callOk('fact_set', {
          'subject': 'Car',
          'attribute': 'rent',
          'project': 'home',
          'valueNumber': 20,
          'validFrom': firstValidFrom
              .add(const Duration(seconds: 1))
              .toIso8601String(),
        });

        final forgotten = await callOk('fact_forget', {'id': second['id']});
        expect(forgotten['reopenedId'], first['id']);

        final lookup = await callOk('fact_get', {
          'subject': 'Car',
          'attribute': 'rent',
          'project': 'home',
        });
        final facts = lookup['facts'] as List;
        expect(facts, hasLength(1));
        expect((facts.single as Map<String, Object?>)['id'], first['id']);
      },
    );

    test('hard=true permanently deletes the row', () async {
      final created = await callOk('fact_set', {
        'subject': 'Flat B',
        'attribute': 'rent',
        'project': 'home',
        'valueNumber': 950,
      });
      final forgotten = await callOk('fact_forget', {
        'id': created['id'],
        'hard': true,
      });
      expect(forgotten['action'], 'hard-deleted');
    });

    test('id=0 is rejected as invalid_input', () async {
      await callInvalid('fact_forget', {'id': 0});
    });
  });

  group('recall with area', () {
    test('filters hits to entries whose project belongs to the area', () async {
      await callOk('area_set', {'name': 'work'});
      await callOk('project_set', {
        'name': 'acme-app',
        'addAreas': ['work'],
      });
      embedder.register('area-filtered text', embedder.planeVector(0));

      await callOk('remember', {
        'text': 'area-filtered text',
        'project': 'acme-app',
      });
      await callOk('remember', {
        'text': 'area-filtered text',
        'project': 'garden',
      });

      final result = await callOk('recall', {
        'query': 'area-filtered text',
        'area': 'work',
      });
      final hits = (result['hits'] as List).cast<Map<String, Object?>>();
      expect(hits, isNotEmpty);
      for (final hit in hits) {
        expect(hit['project'], 'acme-app');
      }
    });

    test('an unknown area is rejected as invalid_input', () async {
      await callInvalid('recall', {
        'query': 'anything',
        'area': 'no-such-area',
      });
    });

    test(
      'review minor 3: an oversized area filter is rejected as '
      'invalid_input, not forwarded whole to the store query',
      () async {
        final hugeArea = 'a' * (1024 * 1024);
        final json = await callInvalid('recall', {
          'query': 'anything',
          'area': hugeArea,
        });
        expect(json['message'], contains('too long'));
      },
    );
  });

  group('list_recent with area', () {
    test('filters entries to the area\'s member projects', () async {
      await callOk('area_set', {'name': 'family'});
      await callOk('project_set', {
        'name': 'garden',
        'addAreas': ['family'],
      });
      await callOk('remember', {'text': 'garden note', 'project': 'garden'});
      await callOk('remember', {'text': 'acme note', 'project': 'acme-app'});

      final result = await callOk('list_recent', {'area': 'family'});
      final entries = (result['entries'] as List).cast<Map<String, Object?>>();
      expect(entries, isNotEmpty);
      for (final entry in entries) {
        expect(entry['project'], 'garden');
      }
    });

    test('an unknown area is rejected as invalid_input', () async {
      await callInvalid('list_recent', {'area': 'no-such-area'});
    });

    test(
      'review minor 4: an area plus a project outside that area returns '
      'count 0 with a warning, mirroring recall/fact_query',
      () async {
        await callOk('area_set', {'name': 'family'});
        await callOk('project_set', {
          'name': 'garden',
          'addAreas': ['family'],
        });
        await callOk('remember', {'text': 'garden note', 'project': 'garden'});
        await callOk('remember', {'text': 'acme note', 'project': 'acme-app'});

        final result = await callOk('list_recent', {
          'area': 'family',
          'project': 'acme-app',
        });
        expect(result['count'], 0);
        expect(result['warning'], isNotNull);
        expect(result['warning'], contains('acme-app'));
        expect(result['warning'], contains('family'));
      },
    );

    test(
      'review minor 3: an oversized area filter is rejected as '
      'invalid_input, not forwarded whole to the store query',
      () async {
        final hugeArea = 'a' * (1024 * 1024);
        final json = await callInvalid('list_recent', {'area': hugeArea});
        expect(json['message'], contains('too long'));
      },
    );
  });
}
