/// Tests for the attribute value register (0.5.0): `attribute_define`,
/// `attributes_list` and the `fact_set` check in both registry modes.
///
/// Synthetic data only: project `garden`; attribute `state` with the
/// values backlog/planned/inProgress/waiting/paused/done/dropped, attribute
/// `colour`; subjects `Bed 1`, `Bed 2`, `Shed`.
library;

import 'dart:io';

import 'package:remembox/objectbox.g.dart';
import 'package:remembox/src/memory_service.dart';
import 'package:remembox/src/model.dart';
import 'package:remembox/src/store.dart' show RegistryMode;
import 'package:test/test.dart';

import 'helpers/test_server.dart';
import 'helpers/test_store_gate.dart';
import 'support/fake_embedder.dart';

const _states = [
  'backlog',
  'planned',
  'inProgress',
  'waiting',
  'paused',
  'done',
  'dropped',
];
const _allowed = 'backlog, planned, inProgress, waiting, paused, done, dropped';

void main() {
  late Directory tempDir;
  late TestGate testGate;
  late Store store;
  late MemoryService open;
  late MemoryService strict;
  late List<String> logLines;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('remembox_attributes_');
    logLines = [];
    testGate = await openTestGate(tempDir.path, log: logLines.add);
    store = testGate.store;
    final embedder = FakeEmbedder();
    open = MemoryService(
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
    await strict.projectSet(name: 'garden', description: 'Synthetic beds.');
  });

  tearDown(() async {
    await open.dispose();
    await strict.dispose();
    await testGate.close();
    tempDir.deleteSync(recursive: true);
  });

  Future<Map<String, Object?>> defineState() => open.attributeDefine(
    attribute: 'state',
    description: 'Where a thread stands.',
    values: _states,
  );

  Future<Map<String, Object?>> setState(
    MemoryService service,
    String subject, {
    String? text,
    double? number,
    String attribute = 'state',
  }) => service.factSet(
    subject: subject,
    attribute: attribute,
    project: 'garden',
    valueText: text,
    valueNumber: number,
  );

  Future<void> expectStrictRejection(
    Future<Object?> Function() call,
    String message,
  ) async {
    final facts = store.box<Fact>().count();
    final projects = store.box<ProjectScope>().count();
    logLines.clear();
    await expectLater(
      call(),
      throwsA(
        isA<ValidationException>().having((e) => e.message, 'message', message),
      ),
    );
    expect(store.box<Fact>().count(), facts);
    expect(store.box<ProjectScope>().count(), projects);
    expect(
      logLines.where(
        (l) => l.startsWith('[registry] strict: rejected fact_set – '),
      ),
      hasLength(1),
    );
  }

  group('fact_set in strict registry mode', () {
    setUp(defineState);

    test('accepts an allowed value', () async {
      final r = await setState(strict, 'Bed 1', text: 'inProgress');
      expect(r['action'], 'created');
      expect(r.containsKey('warning'), isFalse);
    });

    test('rejects a value that is not allowed, with "Did you mean"',
        () async {
      await expectStrictRejection(
        () => setState(strict, 'Bed 1', text: 'in progress'),
        'fact_set: "in progress" is not an allowed value of the attribute '
        '"state" (strict registry mode). Allowed: $_allowed. Did you mean '
        '"inProgress"? The allowed values are maintained with '
        'attribute_define. Nothing was written.',
      );
    });

    test('rejects a value with a different case (exact match only)',
        () async {
      await expectStrictRejection(
        () => setState(strict, 'Bed 1', text: 'Done'),
        'fact_set: "Done" is not an allowed value of the attribute "state" '
        '(strict registry mode). Allowed: $_allowed. Did you mean "done"? The '
        'allowed values are maintained with attribute_define. Nothing was '
        'written.',
      );
    });

    test('without a near value there is no "Did you mean"', () async {
      await expectStrictRejection(
        () => setState(strict, 'Bed 1', text: 'finished'),
        'fact_set: "finished" is not an allowed value of the attribute '
        '"state" (strict registry mode). Allowed: $_allowed. The allowed '
        'values are maintained with attribute_define. Nothing was written.',
      );
    });

    test('rejects a non-text value', () async {
      await expectStrictRejection(
        () => setState(strict, 'Bed 1', number: 3),
        'fact_set: the attribute "state" takes a text value (valueText), one '
        'of: $_allowed. Nothing was written.',
      );
    });

    test('rejects an attribute that is a case/space variant of a registered '
        'one', () async {
      await expectStrictRejection(
        () => setState(strict, 'Bed 1', text: 'done', attribute: 'State'),
        'fact_set: attribute "State" differs from the registered attribute '
        '"state" only by case/space/-/_ (strict registry mode) – use '
        '"state". Nothing was written.',
      );
    });

    test('an unrelated unregistered attribute is not restricted', () async {
      final r = await setState(strict, 'Shed', text: 'red', attribute: 'colour');
      expect(r['action'], 'created');
    });

    test('an identical re-set of a value that is no longer allowed is '
        'rejected', () async {
      await setState(strict, 'Bed 1', text: 'waiting');
      await open.attributeDefine(attribute: 'state', removeValues: ['waiting']);
      await expectStrictRejection(
        () => setState(strict, 'Bed 1', text: 'waiting'),
        'fact_set: "waiting" is not an allowed value of the attribute "state" '
        '(strict registry mode). Allowed: backlog, planned, inProgress, '
        'paused, done, dropped. The allowed values are maintained with '
        'attribute_define. Nothing was written.',
      );
    });
  });

  group('fact_set in open registry mode', () {
    setUp(defineState);

    test('stores a value that is not allowed, with a warning and a log line',
        () async {
      logLines.clear();
      final r = await setState(open, 'Bed 1', text: 'in progress');
      expect(r['action'], 'created');
      expect(r['value'], 'in progress');
      const warning =
          'fact_set: "in progress" is not an allowed value of the attribute '
          '"state". Allowed: $_allowed. Did you mean "inProgress"? The '
          'allowed values are maintained with attribute_define – stored '
          'anyway (open registry mode).';
      expect(r['warning'], warning);
      expect(logLines, contains('[memory] fact_set: $warning'));
    });

    test('warns about a non-text value and an attribute variant', () async {
      final number = await setState(open, 'Bed 1', number: 2);
      expect(
        number['warning'],
        'fact_set: the attribute "state" takes a text value (valueText), one '
        'of: $_allowed – stored anyway (open registry mode).',
      );
      final variant = await setState(
        open,
        'Bed 2',
        text: 'done',
        attribute: 'State',
      );
      expect(
        variant['warning'],
        'fact_set: attribute "State" differs from the registered attribute '
        '"state" only by case/space/-/_; use "state" – stored anyway (open '
        'registry mode).',
      );
    });
  });

  test('no definitions: fact_set results and logs are unchanged; a '
      'definition without values restricts nothing', () async {
    logLines.clear();
    final before = await setState(open, 'Bed 1', text: 'anything');
    final logsBefore = [...logLines];
    expect(before.containsKey('warning'), isFalse);
    expect(logsBefore.where((l) => l.contains('attribute')), isEmpty);

    await open.attributeDefine(
      attribute: 'colour',
      description: 'The colour of a thing.',
    );
    logLines.clear();
    final after = await setState(
      open,
      'Bed 2',
      text: 'anything',
      attribute: 'colour',
    );
    final strictAfter = await setState(
      strict,
      'Shed',
      text: 'whatever',
      attribute: 'colour',
    );
    Map<String, Object?> shape(Map<String, Object?> r) => {
      for (final e in r.entries)
        if (!{'id', 'subject', 'attribute', 'value', 'validFrom', 'createdAt'}
            .contains(e.key))
          e.key: e.value,
    };
    expect(shape(after), shape(before));
    expect(shape(strictAfter), shape(before));
    expect(logLines.where((l) => l.contains('allowed value')), isEmpty);
  });

  group('attribute_define', () {
    test('creates, replaces, adds and removes values', () async {
      final created = await defineState();
      expect(created['action'], 'created');
      expect(created['values'], _states);
      expect(created['valuesAdded'], _states);
      expect(created['valuesRemoved'], isEmpty);

      final added = await open.attributeDefine(
        attribute: 'state',
        addValues: ['archived', 'done'],
      );
      expect(added['action'], 'updated');
      expect(added['valuesAdded'], ['archived']);
      expect(added['values'], [..._states, 'archived']);
      expect(
        added['warning'],
        '"done" is already an allowed value of "state".',
      );

      final removed = await open.attributeDefine(
        attribute: 'state',
        removeValues: ['archived', 'unknown'],
      );
      expect(removed['valuesRemoved'], ['archived']);
      expect(
        removed['warning'],
        '"unknown" is not an allowed value of "state" – nothing removed.',
      );

      final replaced = await open.attributeDefine(
        attribute: 'state',
        values: ['done', 'backlog'],
      );
      expect(replaced['values'], ['done', 'backlog']);
      expect(replaced['valuesRemoved'], [
        'planned',
        'inProgress',
        'waiting',
        'paused',
        'dropped',
      ]);

      final reordered = await open.attributeDefine(
        attribute: 'state',
        values: ['backlog', 'done'],
      );
      expect(reordered['action'], 'updated');
      expect(reordered['values'], ['backlog', 'done']);
      final unchanged = await open.attributeDefine(
        attribute: 'state',
        values: ['backlog', 'done'],
      );
      expect(unchanged['action'], 'unchanged');

      final described = await open.attributeDefine(
        attribute: 'state',
        description: 'Where a thread stands now.',
      );
      expect(described['action'], 'updated');
      expect(described['description'], 'Where a thread stands now.');
      expect(described['values'], ['backlog', 'done']);
    });

    test('remove: true deletes the definition and its values, facts stay',
        () async {
      await defineState();
      await setState(open, 'Bed 1', text: 'done');
      final r = await open.attributeDefine(attribute: 'state', remove: true);
      expect(r['action'], 'removed');
      expect(r['valuesRemoved'], _states);
      expect(store.box<AttributeDefinition>().count(), 0);
      expect(store.box<AttributeValue>().count(), 0);
      expect(store.box<Fact>().count(), 1);
      final again = await open.attributeDefine(attribute: 'state', remove: true);
      expect(again['action'], 'unchanged');
      expect(again['warning'], '"state" is not registered – nothing removed.');
    });

    test('reports non-conforming current facts and never touches a fact',
        () async {
      await setState(open, 'Bed 1', text: 'in progress');
      await setState(open, 'Bed 2', text: 'done');
      await setState(open, 'Shed', number: 4);
      final factsBefore = [
        for (final f in store.box<Fact>().getAll())
          (f.id, f.valueText, f.valueNumber, f.validUntil),
      ];
      final r = await defineState();
      expect(r['nonConformingCurrent'], 2);
      expect(
        (r['nonConformingExamples'] as List).map((e) => (e as Map)['subject']),
        unorderedEquals(['Bed 1', 'Shed']),
      );
      expect(
        [
          for (final f in store.box<Fact>().getAll())
            (f.id, f.valueText, f.valueNumber, f.validUntil),
        ],
        factsBefore,
      );
    });

    test('removing a value still in use warns', () async {
      await defineState();
      await setState(open, 'Bed 1', text: 'waiting');
      await setState(open, 'Bed 2', text: 'waiting');
      final r = await open.attributeDefine(
        attribute: 'state',
        removeValues: ['waiting'],
      );
      expect(
        r['warning'],
        '"waiting" is still the current value of 2 fact(s) of "state" – they '
        'keep it; fact_set no longer accepts it in strict registry mode.',
      );
      expect(r['nonConformingCurrent'], 2);
    });

    test('no "no longer accepts" warning once the attribute is no longer '
        'restricted', () async {
      await defineState();
      await setState(open, 'Bed 1', text: 'waiting');
      final cleared = await open.attributeDefine(
        attribute: 'state',
        values: const [],
      );
      expect(cleared['valuesRemoved'], _states);
      expect(cleared.containsKey('warning'), isFalse);
      await defineState();
      await open.attributeDefine(attribute: 'state', values: _states);
      final removed = await open.attributeDefine(
        attribute: 'state',
        remove: true,
      );
      expect(removed['action'], 'removed');
      expect(removed.containsKey('warning'), isFalse);
    });

    test('collapses duplicates and warns about a variant name', () async {
      await defineState();
      final r = await open.attributeDefine(
        attribute: 'State',
        description: 'A different attribute.',
        values: ['a', 'a', 'b'],
      );
      expect(r['values'], ['a', 'b']);
      expect(
        r['warning'],
        allOf(
          contains('Value "a" is listed more than once – kept once.'),
          contains(
            '"State" differs from the registered attribute(s) "state" only '
            'by case/space/-/_ – registered anyway.',
          ),
        ),
      );
    });

    test('rejects bad input, nothing written', () async {
      final calls = <(Future<Object?> Function(), Object)>[
        (
          () => open.attributeDefine(attribute: 'state', values: ['a']),
          'attribute_define: "state" is not registered yet – a description '
              'is required (one sentence: what the attribute records).',
        ),
        (
          () => open.attributeDefine(
            attribute: 'state',
            description: 'x',
            values: ['a'],
            addValues: ['b'],
          ),
          'attribute_define: pass either "values" (replaces the whole set) or '
              '"addValues"/"removeValues" (change single values), not both.',
        ),
        (
          () => open.attributeDefine(
            attribute: 'state',
            remove: true,
            description: 'x',
          ),
          'attribute_define: "remove" deletes the whole definition – pass it '
              'without description or values.',
        ),
        (
          () => open.attributeDefine(
            attribute: 'state',
            description: 'x',
            values: [' '],
          ),
          'attribute_define: "values" contains a blank value.',
        ),
        (
          () => open.attributeDefine(
            attribute: 'state',
            description: 'x',
            values: ['a\u0007b'],
          ),
          'attribute_define: value "ab" contains control characters.',
        ),
        (
          () => open.attributeDefine(
            attribute: 'state',
            description: 'x',
            values: ['x' * 129],
          ),
          'values is too long: 129 characters exceeds the 128 character '
              'limit.',
        ),
        (
          () => open.attributeDefine(
            attribute: 'state',
            description: 'x',
            values: [for (var i = 0; i < 65; i++) 'v$i'],
          ),
          'attribute_define: "values" has 65 entries, exceeding the 64 value '
              'limit.',
        ),
        (
          () => open.attributeDefine(
            attribute: 'state',
            description: 'x',
            addValues: ['a'],
            removeValues: ['a'],
          ),
          'attribute_define: "a" appear in both "addValues" and '
              '"removeValues".',
        ),
        (
          () => open.attributeDefine(attribute: 'st\u001fate', description: 'x'),
          contains('attribute must not contain control characters'),
        ),
      ];
      for (final (call, message) in calls) {
        await expectLater(
          call(),
          throwsA(
            isA<ValidationException>().having(
              (e) => e.message,
              'message',
              message,
            ),
          ),
        );
      }
      expect(store.box<AttributeDefinition>().count(), 0);
      expect(store.box<AttributeValue>().count(), 0);
    });

    test('the total is capped at 64 values', () async {
      await open.attributeDefine(
        attribute: 'size',
        description: 'A size.',
        values: [for (var i = 0; i < 64; i++) 'v$i'],
      );
      await expectLater(
        open.attributeDefine(attribute: 'size', addValues: ['extra']),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            'attribute_define: "size" would have 65 values, exceeding the 64 '
                'value limit. Nothing was written.',
          ),
        ),
      );
      expect(store.box<AttributeValue>().count(), 64);
    });
  });

  group('attributes_list and stats', () {
    test('lists definitions with value usage and non-conforming counts',
        () async {
      await defineState();
      await open.attributeDefine(attribute: 'colour', description: 'Colour.');
      await setState(open, 'Bed 1', text: 'done');
      await setState(open, 'Bed 2', text: 'done');
      await setState(open, 'Shed', text: 'in progress');
      final r = await open.attributesList();
      expect(r['registryMode'], 'open');
      final rows = (r['attributes'] as List).cast<Map<String, Object?>>();
      expect(rows.map((a) => a['attribute']), ['colour', 'state']);
      expect(rows.first['values'], isEmpty);
      expect(rows.first['nonConformingCurrent'], 0);
      final state = rows.last;
      expect(state['description'], 'Where a thread stands.');
      expect(
        (state['values'] as List).firstWhere((v) => (v as Map)['value'] == 'done'),
        {'value': 'done', 'current': 2},
      );
      expect(state['nonConformingCurrent'], 1);

      final one = await open.attributesList(attribute: 'state');
      expect((one['attributes'] as List), hasLength(1));
      final missing = await open.attributesList(attribute: 'size');
      expect(missing['attributes'], isEmpty);
      expect(missing['warning'], 'attribute "size" is not registered.');
    });

    test('stats.registry counts attributeDefinitions', () async {
      expect(((await open.stats())['registry'] as Map)['attributeDefinitions'], 0);
      await defineState();
      expect(((await open.stats())['registry'] as Map)['attributeDefinitions'], 1);
    });
  });

  group('tools', () {
    late TestServer srv;
    setUp(() async => srv = await TestServer.open(
      registryMode: RegistryMode.strict,
    ));
    tearDown(() async => srv.close());

    test('attribute_define has a closed schema; attributes_list is listed',
        () async {
      final define = await srv.tool('attribute_define');
      expect(define.inputSchema.required, ['attribute']);
      expect(
        define.inputSchema.properties!.keys,
        unorderedEquals([
          'attribute',
          'description',
          'values',
          'addValues',
          'removeValues',
          'remove',
        ]),
      );
      expect(define.inputSchema.additionalProperties, isFalse);
      final list = await srv.tool('attributes_list');
      expect(list.inputSchema.properties!.keys, ['attribute']);
    });

    test('a strict rejection over the wire', () async {
      await srv.service.projectSet(name: 'garden', description: 'Beds.');
      await srv.callOk('attribute_define', {
        'attribute': 'state',
        'description': 'Where a thread stands.',
        'values': _states,
      });
      final bad = await srv.callInvalid('fact_set', {
        'subject': 'Bed 1',
        'attribute': 'state',
        'project': 'garden',
        'valueText': 'in progress',
      });
      expect(bad['message'], contains('Did you mean "inProgress"?'));
      final listed = await srv.callOk('attributes_list', {});
      expect((listed['attributes'] as List), hasLength(1));
    });
  });
}
