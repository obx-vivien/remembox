/// Tests for the facts tools (`memory_service_facts.dart`).
///
/// Synthetic data only: subjects `Flat B`, `Car`, `Account 1` (and `K0`/
/// `K1`/`K2` for the pseudo-random invariant property test at the bottom
/// of this file); attributes `rent`, `insurer`, `renewal`, `v`; projects
/// `home`, `garden`; areas `finance`, `family`.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:remembox/objectbox.g.dart';
import 'package:remembox/src/memory_service.dart';
import 'package:remembox/src/model.dart';
import 'package:remembox/src/store_gate.dart';
import 'package:test/test.dart';

import 'helpers/test_store_gate.dart';
import 'support/fake_embedder.dart';

void main() {
  late Directory tempDir;
  late TestGate testGate;
  late Store store;
  late StoreGate gate;
  late FakeEmbedder embedder;
  late MemoryService service;
  late List<String> logLines;

  void logCapture(String line) => logLines.add(line);

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('remembox_facts_test_');
    logLines = [];
    testGate = await openTestGate(tempDir.path, log: logCapture);
    store = testGate.store;
    gate = testGate.gate;
    embedder = FakeEmbedder();
    service = MemoryService(gate: gate, embedder: embedder, log: logCapture);
  });

  tearDown(() async {
    await service.dispose();
    await testGate.close();
    tempDir.deleteSync(recursive: true);
  });

  Box<Fact> facts() => store.box<Fact>();

  /// Directly inserts a Fact row bypassing factSet's write path — used to
  /// simulate a cross-device conflict (two current rows for one key), which
  /// `factSet`'s own single-writer serialization can never produce by
  /// itself (plan review "checks that pass": concurrent fact_set on the
  /// same key from two processes in gated mode is serialized by the
  /// store lock).
  int putRawFact({
    required String project,
    required String subject,
    required String attribute,
    String valueType = FactValueType.number,
    double? valueNumber,
    String valueText = '',
    DateTime? valueDate,
    String unit = '',
    DateTime? validFrom,
    DateTime? validUntil,
    DateTime? retractedAt,
    String sourceType = MemorySource.note,
  }) {
    final f = Fact(
      project: project,
      subject: subject,
      attribute: attribute,
      factKey: Fact.keyFor(project, subject, attribute),
      valueType: valueType,
      valueText: valueText,
      valueNumber: valueNumber,
      valueDate: valueDate,
      unit: unit,
      validFrom: validFrom,
      validUntil: validUntil,
      retractedAt: retractedAt,
      sourceType: sourceType,
    );
    return facts().put(f);
  }

  group('factSet: created / unchanged / replaced', () {
    test('creates a new fact for an unknown key', () async {
      final result = await service.factSet(
        subject: 'Flat B',
        attribute: 'rent',
        project: 'home',
        valueNumber: 1200,
        unit: 'EUR',
      );
      expect(result['action'], 'created');
      expect(result['project'], 'home');
      expect(result['subject'], 'Flat B');
      expect(result['attribute'], 'rent');
      expect(result['valueType'], FactValueType.number);
      expect(result['value'], 1200);
      expect(result['unit'], 'EUR');
      expect(result['current'], true);
      expect(result['retracted'], false);
      expect(facts().count(), 1);
    });

    test('identical value is a no-op returning the existing id', () async {
      final first = await service.factSet(
        subject: 'Flat B',
        attribute: 'rent',
        project: 'home',
        valueNumber: 1200,
        unit: 'EUR',
      );
      final second = await service.factSet(
        subject: 'Flat B',
        attribute: 'rent',
        project: 'home',
        valueNumber: 1200,
        unit: 'EUR',
      );
      expect(second['action'], 'unchanged');
      expect(second['id'], first['id']);
      expect(facts().count(), 1);
      // Review minor 1: neither call passed validFrom explicitly (both
      // default to "now", which almost never matches to the millisecond
      // across two separate calls) – no spurious "different validFrom"
      // warning belongs here.
      expect(second['warning'], isNull);
    });

    test('identical value with a different validFrom warns but keeps '
        'the existing validFrom', () async {
      final first = await service.factSet(
        subject: 'Flat B',
        attribute: 'rent',
        project: 'home',
        valueNumber: 1200,
        validFrom: DateTime.utc(2026, 1, 1),
      );
      final second = await service.factSet(
        subject: 'Flat B',
        attribute: 'rent',
        project: 'home',
        valueNumber: 1200,
        validFrom: DateTime.utc(2026, 2, 1),
      );
      expect(second['action'], 'unchanged');
      expect(second['id'], first['id']);
      expect(second['warning'], contains('different'));
      expect(second['validFrom'], first['validFrom']);
    });

    test(
      'review minor 1: identical value with a different sourceRef or '
      'explainedByEntryId warns instead of silently dropping the new one',
      () async {
        final entryA = await service.remember(text: 'note a', project: 'home');
        final entryB = await service.remember(text: 'note b', project: 'home');
        final first = await service.factSet(
          subject: 'Flat B',
          attribute: 'rent',
          project: 'home',
          valueNumber: 1200,
          sourceRef: 'r1',
          explainedByEntryId: entryA['id'] as int,
        );
        final second = await service.factSet(
          subject: 'Flat B',
          attribute: 'rent',
          project: 'home',
          valueNumber: 1200,
          sourceRef: 'r2',
          explainedByEntryId: entryB['id'] as int,
        );
        expect(second['action'], 'unchanged');
        expect(second['id'], first['id']);
        expect(second['warning'], contains('sourceRef'));
        expect(second['warning'], contains('explainedByEntryId'));
        // Never rewrites history: the stored row keeps its ORIGINAL
        // sourceRef/explainedBy, not the new ones.
        expect(second['sourceRef'], 'r1');
        expect(second['explainedByEntryId'], entryA['id']);
      },
    );

    test('a new value closes the old one and links forward', () async {
      final t0 = DateTime.utc(2026, 1, 1);
      final t1 = DateTime.utc(2026, 6, 1);
      final first = await service.factSet(
        subject: 'Flat B',
        attribute: 'rent',
        project: 'home',
        valueNumber: 1200,
        validFrom: t0,
      );
      final second = await service.factSet(
        subject: 'Flat B',
        attribute: 'rent',
        project: 'home',
        valueNumber: 1300,
        validFrom: t1,
      );
      expect(second['action'], 'replaced');
      expect(second['closedId'], first['id']);
      expect(second['value'], 1300);
      expect(second['current'], true);

      final oldRow = facts().get(first['id'] as int)!;
      expect(oldRow.validUntil, t1);
      expect(oldRow.supersededBy.targetId, second['id']);
      expect(facts().count(), 2);
    });

    test('rejects zero values', () async {
      expect(
        () => service.factSet(
          subject: 'Flat B',
          attribute: 'rent',
          project: 'home',
        ),
        throwsA(isA<ValidationException>()),
      );
    });

    test('rejects two or more values', () async {
      expect(
        () => service.factSet(
          subject: 'Flat B',
          attribute: 'rent',
          project: 'home',
          valueText: 'a lot',
          valueNumber: 1200,
        ),
        throwsA(isA<ValidationException>()),
      );
    });

    test('rejects a non-finite number (NaN / Infinity)', () async {
      expect(
        () => service.factSet(
          subject: 'Flat B',
          attribute: 'rent',
          project: 'home',
          valueNumber: double.nan,
        ),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => service.factSet(
          subject: 'Flat B',
          attribute: 'rent',
          project: 'home',
          valueNumber: double.infinity,
        ),
        throwsA(isA<ValidationException>()),
      );
    });

    test(
      'rejects over-long subject/attribute/valueText/unit/sourceRef',
      () async {
        expect(
          () => service.factSet(
            subject: 'x' * 201,
            attribute: 'rent',
            project: 'home',
            valueNumber: 1,
          ),
          throwsA(isA<ValidationException>()),
        );
        expect(
          () => service.factSet(
            subject: 'Flat B',
            attribute: 'x' * 129,
            project: 'home',
            valueNumber: 1,
          ),
          throwsA(isA<ValidationException>()),
        );
        expect(
          () => service.factSet(
            subject: 'Flat B',
            attribute: 'rent',
            project: 'home',
            valueText: 'x' * 4097,
          ),
          throwsA(isA<ValidationException>()),
        );
        expect(
          () => service.factSet(
            subject: 'Flat B',
            attribute: 'rent',
            project: 'home',
            valueNumber: 1,
            unit: 'x' * 33,
          ),
          throwsA(isA<ValidationException>()),
        );
        expect(
          () => service.factSet(
            subject: 'Flat B',
            attribute: 'rent',
            project: 'home',
            valueNumber: 1,
            sourceRef: 'x' * 4097,
          ),
          throwsA(isA<ValidationException>()),
        );
      },
    );

    test('rejects a control character in subject/attribute (incl. the key '
        'separator)', () async {
      expect(
        () => service.factSet(
          subject: 'Flat${kFactKeySep}B',
          attribute: 'rent',
          project: 'home',
          valueNumber: 1,
        ),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => service.factSet(
          subject: 'Flat B',
          attribute: 'rent',
          project: 'home',
          valueNumber: 1,
        ),
        throwsA(isA<ValidationException>()),
      );
    });

    test('rejects a blank project', () async {
      expect(
        () => service.factSet(
          subject: 'Flat B',
          attribute: 'rent',
          project: '',
          valueNumber: 1,
        ),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => service.factSet(
          subject: 'Flat B',
          attribute: 'rent',
          project: null,
          valueNumber: 1,
        ),
        throwsA(isA<ValidationException>()),
      );
    });

    test('rejects a validFrom before the current row\'s validFrom '
        '(back-dated insert)', () async {
      await service.factSet(
        subject: 'Flat B',
        attribute: 'rent',
        project: 'home',
        valueNumber: 1200,
        validFrom: DateTime.utc(2026, 6, 1),
      );
      expect(
        () => service.factSet(
          subject: 'Flat B',
          attribute: 'rent',
          project: 'home',
          valueNumber: 1300,
          validFrom: DateTime.utc(2026, 1, 1),
        ),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            contains('back-dated'),
          ),
        ),
      );
      // Nothing was written on the rejected call.
      expect(facts().count(), 1);
    });

    test('repairs two current rows for one key and warns', () async {
      final now = DateTime.now().toUtc();
      final id1 = putRawFact(
        project: 'home',
        subject: 'Flat B',
        attribute: 'rent',
        valueNumber: 1200,
        validFrom: now.subtract(const Duration(days: 10)),
      );
      final id2 = putRawFact(
        project: 'home',
        subject: 'Flat B',
        attribute: 'rent',
        valueNumber: 1250,
        validFrom: now.subtract(const Duration(days: 5)),
      );

      final result = await service.factSet(
        subject: 'Flat B',
        attribute: 'rent',
        project: 'home',
        valueNumber: 1300,
      );
      expect(result['action'], 'replaced');
      expect(result['closedIds'], containsAll([id1, id2]));
      expect(result['warning'], contains('overlapping values'));
      // The fact key in the warning is rendered human-readably
      // ("home / Flat B / rent"), not with its internal separator
      // stripped by log-sanitization ("homeFlat Brent").
      expect(result['warning'], contains('home / Flat B / rent'));

      final old1 = facts().get(id1)!;
      final old2 = facts().get(id2)!;
      expect(old1.validUntil, isNotNull);
      expect(old2.validUntil, isNotNull);
      expect(old1.supersededBy.targetId, result['id']);
      expect(old2.supersededBy.targetId, result['id']);

      // Exactly one current row remains for the key.
      final currentCount = facts()
          .query(
            Fact_.factKey.equals(Fact.keyFor('home', 'Flat B', 'rent')) &
                Fact_.validUntil.isNull() &
                Fact_.retractedAt.isNull(),
          )
          .build()
          .count();
      expect(currentCount, 1);
    });

    test(
      'a conflicting row that starts AFTER the new validFrom is a '
      'back-dated insert, same as any other – rejected, not silently '
      'closed at a zero-length interval',
      () async {
        final now = DateTime.now().toUtc();
        final earlyId = putRawFact(
          project: 'home',
          subject: 'Flat B',
          attribute: 'rent',
          valueNumber: 1200,
          validFrom: now.subtract(const Duration(days: 10)),
        );
        // Started LATER than the new write's validFrom (now) – inserting
        // there would have to close this row before it even started.
        final lateStart = now.add(const Duration(days: 3));
        final lateId = putRawFact(
          project: 'home',
          subject: 'Flat B',
          attribute: 'rent',
          valueNumber: 1250,
          validFrom: lateStart,
        );

        await expectLater(
          service.factSet(
            subject: 'Flat B',
            attribute: 'rent',
            project: 'home',
            valueNumber: 1300,
          ),
          throwsA(
            isA<ValidationException>().having(
              (e) => e.message,
              'message',
              contains('back-dated'),
            ),
          ),
        );

        // Nothing was written or closed by the rejected call.
        final early = facts().get(earlyId)!;
        final late = facts().get(lateId)!;
        expect(early.validUntil, isNull);
        expect(late.validUntil, isNull);
        expect(facts().count(), 2);
      },
    );

    test('rejects an unknown explainedByEntryId', () async {
      expect(
        () => service.factSet(
          subject: 'Flat B',
          attribute: 'rent',
          project: 'home',
          valueNumber: 1200,
          explainedByEntryId: 999999,
        ),
        throwsA(isA<ValidationException>()),
      );
    });

    test('a valid explainedByEntryId links the fact', () async {
      final entry = await service.remember(
        text:
            'The landlord raised the rent for Flat B in a synthetic '
            'test scenario.',
        project: 'home',
      );
      final entryId = entry['id'] as int;
      final result = await service.factSet(
        subject: 'Flat B',
        attribute: 'rent',
        project: 'home',
        valueNumber: 1200,
        explainedByEntryId: entryId,
      );
      expect(result['explainedByEntryId'], entryId);
    });
  });

  group('factSet: future-dated facts', () {
    test(
      'a future validFrom closes the old row at that future date; the '
      'new value does not leak into a bare (no-at) factGet before then',
      () async {
        final now = DateTime.now().toUtc();
        final future = now.add(const Duration(days: 30));
        final created = await service.factSet(
          subject: 'Car',
          attribute: 'insurer',
          project: 'home',
          valueText: 'Acme Insurance',
        );
        final scheduled = await service.factSet(
          subject: 'Car',
          attribute: 'insurer',
          project: 'home',
          valueText: 'Zenith Insurance',
          validFrom: future,
        );
        expect(scheduled['action'], 'replaced');
        expect(scheduled['closedId'], created['id']);

        final oldRow = facts().get(created['id'] as int)!;
        expect(oldRow.validUntil, isNotNull);
        expect(
          oldRow.validUntil!.difference(future).inMilliseconds.abs(),
          lessThan(1000),
        );

        // Bare factGet (no `at`, no includeFuture): the future value must
        // not appear, and – review finding B1 – the OLD value must still
        // be returned as current: closing A at a FUTURE date must not
        // make the key have no current value until that date arrives.
        final bare = await service.factGet(
          subject: 'Car',
          attribute: 'insurer',
        );
        final bareFacts = (bare['facts'] as List).cast<Map>();
        final bareValues = bareFacts.map((f) => f['value']).toSet();
        expect(bareValues, isNot(contains('Zenith Insurance')));
        expect(bareValues, contains('Acme Insurance'));
        final bareAcme = bareFacts.singleWhere(
          (f) => f['value'] == 'Acme Insurance',
        );
        expect(bareAcme['current'], isTrue);
        expect(bare['warning'], isNull);

        // With includeFuture: the scheduled value is visible.
        final futureIncluded = await service.factGet(
          subject: 'Car',
          attribute: 'insurer',
          includeFuture: true,
        );
        final futureValues = (futureIncluded['facts'] as List)
            .map((f) => (f as Map)['value'])
            .toSet();
        expect(futureValues, contains('Zenith Insurance'));

        // With `at` on/after the future validFrom: the scheduled value is
        // what applies.
        final atFuture = await service.factGet(
          subject: 'Car',
          attribute: 'insurer',
          at: future,
        );
        expect((atFuture['facts'] as List).single['value'], 'Zenith Insurance');
      },
    );

    test(
      'review B1: a second fact_set while a future row is scheduled never '
      'starts a parallel chain – it either supersedes the scheduled row '
      'or is rejected as back-dated',
      () async {
        final now = DateTime.now().toUtc();
        final future = now.add(const Duration(days: 30));
        final a = await service.factSet(
          subject: 'Car',
          attribute: 'insurer',
          project: 'home',
          valueText: 'A',
        );
        final b = await service.factSet(
          subject: 'Car',
          attribute: 'insurer',
          project: 'home',
          valueText: 'B',
          validFrom: future,
        );
        expect(b['closedId'], a['id']);

        // A new value dated NOW (before the scheduled future row) is
        // rejected as back-dated – never silently starts a second chain
        // next to the scheduled B (the pre-fix bug: current.isEmpty
        // because the write-path head lookup couldn't see the future row).
        await expectLater(
          service.factSet(
            subject: 'Car',
            attribute: 'insurer',
            project: 'home',
            valueText: 'C',
          ),
          throwsA(isA<ValidationException>()),
        );
        // Exactly two rows exist for this key: A (closed) and B (open) –
        // no third "C" chain.
        final rowsAfterReject = facts()
            .query(Fact_.factKey.equals(Fact.keyFor('home', 'Car', 'insurer')))
            .build()
            .find();
        expect(rowsAfterReject, hasLength(2));

        // A new value dated AT/AFTER the scheduled row's validFrom
        // supersedes it – the normal "replace" path, not a parallel
        // chain.
        final later = future.add(const Duration(days: 5));
        final d = await service.factSet(
          subject: 'Car',
          attribute: 'insurer',
          project: 'home',
          valueText: 'D',
          validFrom: later,
        );
        expect(d['action'], 'replaced');
        expect(d['closedId'], b['id']);
        final bRow = facts().get(b['id'] as int)!;
        expect(bRow.validUntil, isNotNull);
        expect(bRow.supersededBy.targetId, d['id']);

        // Re-sending the identical future value (still scheduled, not yet
        // superseded) is unchanged, not a duplicate.
        final future2 = now.add(const Duration(days: 60));
        final e = await service.factSet(
          subject: 'Account 1',
          attribute: 'renewal',
          project: 'home',
          valueText: 'X',
          validFrom: future2,
        );
        final repeat = await service.factSet(
          subject: 'Account 1',
          attribute: 'renewal',
          project: 'home',
          valueText: 'X',
          validFrom: future2,
        );
        expect(repeat['action'], 'unchanged');
        expect(repeat['id'], e['id']);
        final xRows = facts()
            .query(
              Fact_.factKey.equals(Fact.keyFor('home', 'Account 1', 'renewal')),
            )
            .build()
            .find();
        expect(xRows, hasLength(1));
      },
    );

    test(
      'review B1: stats().facts.current counts a fact closed at a future '
      'date as current (it has not stopped being true yet)',
      () async {
        final now = DateTime.now().toUtc();
        final future = now.add(const Duration(days: 30));
        await service.factSet(
          subject: 'Car',
          attribute: 'insurer',
          project: 'home',
          valueText: 'A',
        );
        await service.factSet(
          subject: 'Car',
          attribute: 'insurer',
          project: 'home',
          valueText: 'B',
          validFrom: future,
        );
        final stats = await service.stats();
        final factsBlock = stats['facts'] as Map;
        expect(factsBlock['total'], 2);
        expect(factsBlock['current'], 1);
      },
    );
  });

  group(
    'invariant: fact_set closes every row that would overlap the write, '
    'not only the open head',
    () {
      test(
        'ending the current fact with a FUTURE validUntil, then fact_set '
        'now, closes the ended row at now instead of creating an overlap',
        () async {
          final now = DateTime.now().toUtc();
          final future = now.add(const Duration(days: 30));
          final a = await service.factSet(
            subject: 'Car',
            attribute: 'insurer',
            project: 'home',
            valueText: 'A',
          );
          // A is still the open head, but its scheduled end (validUntil)
          // is in the future – A is neither retracted nor closed yet.
          await service.factForget(a['id'] as int, validUntil: future);

          final n = await service.factSet(
            subject: 'Car',
            attribute: 'insurer',
            project: 'home',
            valueText: 'N',
          );
          expect(n['action'], 'replaced');
          expect(n['closedId'], a['id']);

          final aRow = facts().get(a['id'] as int)!;
          // A's end date moved from the future down to now – it must not
          // stay open past the point N started (that would overlap N).
          expect(aRow.validUntil!.isAfter(future), isFalse);
          expect(
            aRow.validUntil!.difference(now).inMilliseconds.abs(),
            lessThan(1000),
          );

          // Exactly one row is valid now, and it is N.
          final bare = await service.factGet(
            subject: 'Car',
            attribute: 'insurer',
          );
          final bareFacts = (bare['facts'] as List).cast<Map>();
          expect(bareFacts, hasLength(1));
          expect(bareFacts.single['value'], 'N');
          expect(bare['warning'], isNull);
        },
      );

      test(
        'fact_set with a validFrom INSIDE an already-ended row\'s window '
        'shrinks that row instead of leaving it overlapping the new value',
        () async {
          final t0 = DateTime.utc(2026, 1, 1);
          final endedAt = DateTime.utc(2026, 6, 1);
          final insideWindow = DateTime.utc(2026, 4, 1);
          final a = await service.factSet(
            subject: 'Flat B',
            attribute: 'rent',
            project: 'home',
            valueNumber: 800,
            validFrom: t0,
          );
          await service.factForget(a['id'] as int, validUntil: endedAt);

          final c = await service.factSet(
            subject: 'Flat B',
            attribute: 'rent',
            project: 'home',
            valueNumber: 850,
            validFrom: insideWindow,
          );
          expect(c['action'], 'replaced');
          expect(c['closedId'], a['id']);

          final aRow = facts().get(a['id'] as int)!;
          expect(aRow.validUntil, insideWindow);

          // Exactly one row is valid inside the old window now.
          final atMay = await service.factGet(
            subject: 'Flat B',
            attribute: 'rent',
            at: DateTime.utc(2026, 5, 1),
          );
          final atMayFacts = (atMay['facts'] as List).cast<Map>();
          expect(atMayFacts, hasLength(1));
          expect(atMayFacts.single['value'], 850);
          expect(atMay['warning'], isNull);

          // Before insideWindow, the original (shrunk) 800 row still
          // applies.
          final atFeb = await service.factGet(
            subject: 'Flat B',
            attribute: 'rent',
            at: DateTime.utc(2026, 2, 1),
          );
          expect((atFeb['facts'] as List).single['value'], 800);
        },
      );
    },
  );

  group(
    'invariant: fact_forget(validUntil) must not overlap a successor',
    () {
      test(
        'ending an already-superseded row past its successor\'s start is '
        'rejected',
        () async {
          final t0 = DateTime.utc(2026, 1, 1);
          final t1 = DateTime.utc(2026, 3, 1);
          final a = await service.factSet(
            subject: 'Flat B',
            attribute: 'rent',
            project: 'home',
            valueNumber: 800,
            validFrom: t0,
          );
          await service.factSet(
            subject: 'Flat B',
            attribute: 'rent',
            project: 'home',
            valueNumber: 900,
            validFrom: t1,
          );

          // A's successor already starts in March – ending A in June
          // would overlap it.
          await expectLater(
            service.factForget(
              a['id'] as int,
              validUntil: DateTime.utc(2026, 6, 1),
            ),
            throwsA(isA<ValidationException>()),
          );

          // Nothing changed: A is still closed exactly at t1.
          final aRow = facts().get(a['id'] as int)!;
          expect(aRow.validUntil, t1);

          final atApr = await service.factGet(
            subject: 'Flat B',
            attribute: 'rent',
            at: DateTime.utc(2026, 4, 1),
          );
          final atAprFacts = (atApr['facts'] as List).cast<Map>();
          expect(atAprFacts, hasLength(1));
          expect(atAprFacts.single['value'], 900);
          expect(atApr['warning'], isNull);
        },
      );

      test(
        'ending an already-superseded row exactly at its successor\'s '
        'start is accepted (zero gap, not an overlap)',
        () async {
          final t0 = DateTime.utc(2026, 1, 1);
          final t1 = DateTime.utc(2026, 3, 1);
          final a = await service.factSet(
            subject: 'Flat B',
            attribute: 'rent',
            project: 'home',
            valueNumber: 800,
            validFrom: t0,
          );
          await service.factSet(
            subject: 'Flat B',
            attribute: 'rent',
            project: 'home',
            valueNumber: 900,
            validFrom: t1,
          );

          final result = await service.factForget(
            a['id'] as int,
            validUntil: t1,
          );
          expect(result['action'], 'ended');
        },
      );
    },
  );

  group(
    'invariant: fact_get(includeFuture) returns the value valid now PLUS '
    'every scheduled row, ordered by validFrom',
    () {
      test(
        'a currently-valid row and its scheduled successor are both '
        'returned, in validFrom order – not the scheduled row alone',
        () async {
          final now = DateTime.now().toUtc();
          final a = await service.factSet(
            subject: 'Car',
            attribute: 'insurer',
            project: 'home',
            valueText: 'A',
          );
          final b = await service.factSet(
            subject: 'Car',
            attribute: 'insurer',
            project: 'home',
            valueText: 'B',
            validFrom: now.add(const Duration(days: 5)),
          );
          final d = await service.factSet(
            subject: 'Car',
            attribute: 'insurer',
            project: 'home',
            valueText: 'D',
            validFrom: now.add(const Duration(days: 10)),
          );

          final result = await service.factGet(
            subject: 'Car',
            attribute: 'insurer',
            includeFuture: true,
          );
          final ids = (result['facts'] as List)
              .cast<Map>()
              .map((f) => f['id'])
              .toList();
          expect(ids, [a['id'], b['id'], d['id']]);
        },
      );
    },
  );

  group('factGet: at-boundaries, truncation, conflicts, provenance', () {
    test('at lookups: validFrom inclusive, validUntil exclusive', () async {
      final t0 = DateTime.utc(2026, 1, 1, 12);
      final t1 = DateTime.utc(2026, 6, 1, 12);
      final first = await service.factSet(
        subject: 'Flat B',
        attribute: 'rent',
        project: 'home',
        valueNumber: 1200,
        validFrom: t0,
      );
      await service.factSet(
        subject: 'Flat B',
        attribute: 'rent',
        project: 'home',
        valueNumber: 1300,
        validFrom: t1,
      );

      // Exactly at t0: the first row is included (validFrom inclusive).
      final atT0 = await service.factGet(
        subject: 'Flat B',
        attribute: 'rent',
        project: 'home',
        at: t0,
      );
      expect((atT0['facts'] as List).single['id'], first['id']);

      // Exactly at t1: validUntil is exclusive, so the first row is
      // excluded and the second (validFrom inclusive) is returned.
      final atT1 = await service.factGet(
        subject: 'Flat B',
        attribute: 'rent',
        project: 'home',
        at: t1,
      );
      expect((atT1['facts'] as List).single['value'], 1300);

      // Just before t1: still the first row.
      final justBefore = await service.factGet(
        subject: 'Flat B',
        attribute: 'rent',
        project: 'home',
        at: t1.subtract(const Duration(milliseconds: 1)),
      );
      expect((justBefore['facts'] as List).single['value'], 1200);
    });

    test('millisecond truncation: a validFrom/at carrying microseconds '
        'behaves like the truncated millisecond instant', () async {
      final withMicros = DateTime.utc(2026, 1, 1, 12, 0, 0, 0, 999);
      final result = await service.factSet(
        subject: 'Flat B',
        attribute: 'rent',
        project: 'home',
        valueNumber: 1200,
        validFrom: withMicros,
      );
      final storedValidFrom = DateTime.parse(result['validFrom'] as String);
      expect(storedValidFrom.microsecond, 0);

      // Querying `at` with the same microsecond-bearing instant still
      // resolves to the stored (truncated) row.
      final atMicro = await service.factGet(
        subject: 'Flat B',
        attribute: 'rent',
        project: 'home',
        at: withMicros,
      );
      expect((atMicro['facts'] as List).single['id'], result['id']);
    });

    test('excludes a retracted fact', () async {
      final created = await service.factSet(
        subject: 'Flat B',
        attribute: 'rent',
        project: 'home',
        valueNumber: 1200,
      );
      await service.factForget(created['id'] as int);
      final result = await service.factGet(
        subject: 'Flat B',
        attribute: 'rent',
        project: 'home',
      );
      expect(result['facts'], isEmpty);
    });

    test('warns on conflicting current rows for the same key', () async {
      final now = DateTime.now().toUtc();
      putRawFact(
        project: 'home',
        subject: 'Flat B',
        attribute: 'rent',
        valueNumber: 1200,
        validFrom: now.subtract(const Duration(days: 5)),
      );
      putRawFact(
        project: 'home',
        subject: 'Flat B',
        attribute: 'rent',
        valueNumber: 1250,
        validFrom: now.subtract(const Duration(days: 3)),
      );
      final result = await service.factGet(
        subject: 'Flat B',
        attribute: 'rent',
        project: 'home',
      );
      expect((result['facts'] as List), hasLength(2));
      expect(result['warning'], contains('overlapping values'));
      // The wording never promises a repair fact_set cannot guarantee –
      // it just says the write that fixes this.
      expect(result['warning'], contains('closes them'));
    });

    test('carries _provenance_note', () async {
      await service.factSet(
        subject: 'Flat B',
        attribute: 'rent',
        project: 'home',
        valueNumber: 1200,
      );
      final result = await service.factGet(
        subject: 'Flat B',
        attribute: 'rent',
        project: 'home',
      );
      expect(result['_provenance_note'], isNotNull);
      expect(result['_provenance_note'], contains('STORED MEMORIES'));
    });
  });

  group('factQuery', () {
    setUp(() async {
      await service.factSet(
        subject: 'Flat B',
        attribute: 'rent',
        project: 'home',
        valueNumber: 1200,
        unit: 'EUR',
      );
      await service.factSet(
        subject: 'Flat B',
        attribute: 'insurer',
        project: 'home',
        valueText: 'Acme Insurance',
      );
      await service.factSet(
        subject: 'Car',
        attribute: 'insurer',
        project: 'garden',
        valueText: 'Zenith Insurance',
      );
      await service.factSet(
        subject: 'Account 1',
        attribute: 'renewal',
        project: 'garden',
        valueNumber: 42.5,
      );
    });

    test('by attribute', () async {
      final result = await service.factQuery(attribute: 'insurer');
      expect((result['facts'] as List), hasLength(2));
    });

    test('by subjectPrefix is case-sensitive', () async {
      final result = await service.factQuery(subjectPrefix: 'Flat');
      expect((result['facts'] as List), hasLength(2));
      final lower = await service.factQuery(subjectPrefix: 'flat');
      expect((lower['facts'] as List), isEmpty);
    });

    test('by project', () async {
      final result = await service.factQuery(project: 'garden');
      expect((result['facts'] as List), hasLength(2));
    });

    test('by area (many-to-many via areaSet/projectSet)', () async {
      await service.areaSet(name: 'finance');
      await service.projectSet(name: 'home', addAreas: ['finance']);
      await service.projectSet(name: 'garden', addAreas: ['finance']);

      final result = await service.factQuery(area: 'finance');
      expect((result['facts'] as List), hasLength(4));
    });

    test('unknown area is rejected', () async {
      expect(
        () => service.factQuery(area: 'ghost'),
        throwsA(isA<ValidationException>()),
      );
    });

    test('an area with no projects returns count 0 with a warning', () async {
      await service.areaSet(name: 'family');
      final result = await service.factQuery(area: 'family');
      expect(result['count'], 0);
      expect(result['warning'], contains('no projects assigned'));
    });

    test('number range implies valueType == number', () async {
      final result = await service.factQuery(
        attribute: 'renewal',
        numberMin: 40,
        numberMax: 50,
      );
      expect((result['facts'] as List), hasLength(1));
      expect((result['facts'] as List).single['value'], 42.5);

      final outOfRange = await service.factQuery(
        attribute: 'renewal',
        numberMin: 100,
      );
      expect((outOfRange['facts'] as List), isEmpty);
    });

    test('includeHistory returns closed rows, flagged', () async {
      // No explicit validFrom: defaults to "now" at call time, strictly
      // later than the setUp row's own default validFrom (a moment
      // earlier) and still <= "now" when queried immediately after — so
      // this replaces the setUp row rather than tripping the back-dated
      // guard or scheduling a future row.
      await service.factSet(
        subject: 'Flat B',
        attribute: 'rent',
        project: 'home',
        valueNumber: 1300,
      );
      final currentOnly = await service.factQuery(attribute: 'rent');
      expect((currentOnly['facts'] as List), hasLength(1));

      final withHistory = await service.factQuery(
        attribute: 'rent',
        includeHistory: true,
      );
      final rows = withHistory['facts'] as List;
      expect(rows.length, greaterThanOrEqualTo(2));
      expect(rows.any((r) => (r as Map)['current'] == false), isTrue);
    });

    test('requires at least one filter', () async {
      expect(() => service.factQuery(), throwsA(isA<ValidationException>()));
    });

    test('limit truncates and reports the total count', () async {
      for (var i = 0; i < 10; i++) {
        await service.factSet(
          subject: 'Account 1',
          attribute: 'field$i',
          project: 'garden',
          valueNumber: i.toDouble(),
        );
      }
      final result = await service.factQuery(project: 'garden', limit: 3);
      expect((result['facts'] as List), hasLength(3));
      expect(result['truncated'], true);
      expect(result['count'], greaterThanOrEqualTo(12));
    });
  });

  group('factForget', () {
    test('soft retract (default): excludes from factGet, visible with '
        'includeHistory', () async {
      final created = await service.factSet(
        subject: 'Flat B',
        attribute: 'rent',
        project: 'home',
        valueNumber: 1200,
      );
      final result = await service.factForget(created['id'] as int);
      expect(result['action'], 'retracted');

      final plain = await service.factGet(
        subject: 'Flat B',
        attribute: 'rent',
        project: 'home',
      );
      expect(plain['facts'], isEmpty);

      final query = await service.factQuery(
        attribute: 'rent',
        includeHistory: true,
      );
      final rows = query['facts'] as List;
      expect(rows.single['retracted'], true);
    });

    test(
      'retracting an already-retracted fact is an idempotent no-op – it '
      'does not overwrite retractedAt',
      () async {
        final created = await service.factSet(
          subject: 'Flat B',
          attribute: 'rent',
          project: 'home',
          valueNumber: 1200,
        );
        final first = await service.factForget(created['id'] as int);
        await Future.delayed(const Duration(milliseconds: 20));
        final second = await service.factForget(created['id'] as int);
        expect(second['action'], 'unchanged');
        // Both [first]'s reported retractedAt and the stored value are
        // millisecond-truncated (same precision fact_set/fact_get already
        // use), so the second call names the exact SAME retraction, not a
        // fresh one.
        expect(second['retractedAt'], first['retractedAt']);
        expect(second['warning'], contains('already retracted'));
      },
    );

    test(
      'review minor 5: "ended" (validUntil) does not apply to an '
      'already-retracted fact',
      () async {
        final created = await service.factSet(
          subject: 'Flat B',
          attribute: 'rent',
          project: 'home',
          valueNumber: 1200,
          validFrom: DateTime.utc(2026, 1, 1),
        );
        await service.factForget(created['id'] as int);
        expect(
          () => service.factForget(
            created['id'] as int,
            validUntil: DateTime.utc(2026, 6, 1),
          ),
          throwsA(isA<ValidationException>()),
        );
      },
    );

    test('validUntil: ends the fact without a successor, stays valid up '
        'to that date', () async {
      final t0 = DateTime.utc(2026, 1, 1);
      final endDate = DateTime.utc(2026, 6, 1);
      final created = await service.factSet(
        subject: 'Car',
        attribute: 'insurer',
        project: 'home',
        valueText: 'Acme Insurance',
        validFrom: t0,
      );
      final result = await service.factForget(
        created['id'] as int,
        validUntil: endDate,
      );
      expect(result['action'], 'ended');

      final beforeEnd = await service.factGet(
        subject: 'Car',
        attribute: 'insurer',
        project: 'home',
        at: endDate.subtract(const Duration(days: 1)),
      );
      expect((beforeEnd['facts'] as List).single['id'], created['id']);

      final afterEnd = await service.factGet(
        subject: 'Car',
        attribute: 'insurer',
        project: 'home',
        at: endDate.add(const Duration(days: 1)),
      );
      expect(afterEnd['facts'], isEmpty);
    });

    test(
      'review B2: ending (validUntil) a fact that HAS a predecessor does '
      'NOT reopen it – only retract/hard-delete do',
      () async {
        final t0 = DateTime.utc(2026, 1, 1);
        final t1 = DateTime.utc(2026, 3, 1);
        final endDate = DateTime.utc(2026, 6, 1);
        final rent800 = await service.factSet(
          subject: 'Flat B',
          attribute: 'rent',
          project: 'home',
          valueNumber: 800,
          validFrom: t0,
        );
        final rent900 = await service.factSet(
          subject: 'Flat B',
          attribute: 'rent',
          project: 'home',
          valueNumber: 900,
          validFrom: t1,
        );
        final result = await service.factForget(
          rent900['id'] as int,
          validUntil: endDate,
        );
        expect(result['action'], 'ended');
        // The predecessor is NOT reopened for "ended" (review B2) – no
        // reopenedId, and no reopen warning either.
        expect(result['reopenedId'], isNull);

        // A bare fact_get (real "now", long after endDate) returns
        // nothing current – 900 ended, and 800 was already closed when
        // 900 replaced it, so neither is open-ended any more.
        final bare = await service.factGet(subject: 'Flat B', attribute: 'rent');
        expect(bare['facts'], isEmpty);

        // Inside the 900 period returns exactly 900.
        final inside = await service.factGet(
          subject: 'Flat B',
          attribute: 'rent',
          at: DateTime.utc(2026, 4, 1),
        );
        final insideFacts = (inside['facts'] as List).cast<Map>();
        expect(insideFacts, hasLength(1));
        expect(insideFacts.single['value'], 900);
        expect(inside['warning'], isNull);

        // Before the 900 period (inside the 800 period) returns exactly
        // 800.
        final before = await service.factGet(
          subject: 'Flat B',
          attribute: 'rent',
          at: DateTime.utc(2026, 2, 1),
        );
        final beforeFacts = (before['facts'] as List).cast<Map>();
        expect(beforeFacts, hasLength(1));
        expect(beforeFacts.single['value'], 800);

        // After the end date, nothing is current – the contract ended,
        // and no reopened predecessor lingers.
        final after = await service.factGet(
          subject: 'Flat B',
          attribute: 'rent',
          at: endDate.add(const Duration(days: 30)),
        );
        expect(after['facts'], isEmpty);

        // The predecessor row itself is untouched: still closed at t1,
        // still pointing forward.
        final rent800Row = facts().get(rent800['id'] as int)!;
        expect(rent800Row.validUntil, t1);
        expect(rent800Row.supersededBy.targetId, rent900['id']);
      },
    );

    test('validUntil before validFrom is rejected', () async {
      final created = await service.factSet(
        subject: 'Car',
        attribute: 'insurer',
        project: 'home',
        valueText: 'Acme Insurance',
        validFrom: DateTime.utc(2026, 6, 1),
      );
      expect(
        () => service.factForget(
          created['id'] as int,
          validUntil: DateTime.utc(2026, 1, 1),
        ),
        throwsA(isA<ValidationException>()),
      );
    });

    test('hard deletes and clears supersededBy pointers', () async {
      final first = await service.factSet(
        subject: 'Flat B',
        attribute: 'rent',
        project: 'home',
        valueNumber: 1200,
        validFrom: DateTime.utc(2026, 1, 1),
      );
      final second = await service.factSet(
        subject: 'Flat B',
        attribute: 'rent',
        project: 'home',
        valueNumber: 1300,
        validFrom: DateTime.utc(2026, 6, 1),
      );

      final result = await service.factForget(second['id'] as int, hard: true);
      expect(result['action'], 'hard-deleted');
      expect(facts().get(second['id'] as int), isNull);

      // The predecessor's dangling supersededBy pointer was cleared (and,
      // since `second` was the current row, `first` is reopened — see the
      // M3 group below for a dedicated assertion of the reopening itself).
      final firstRow = facts().get(first['id'] as int)!;
      expect(firstRow.supersededBy.targetId, 0);
    });

    test('unknown id is rejected', () async {
      expect(
        () => service.factForget(999999),
        throwsA(isA<ValidationException>()),
      );
    });

    group('M3: reopening the predecessor', () {
      test('retracting the current fact reopens its predecessor', () async {
        final first = await service.factSet(
          subject: 'Flat B',
          attribute: 'rent',
          project: 'home',
          valueNumber: 1200,
          validFrom: DateTime.utc(2026, 1, 1),
        );
        final second = await service.factSet(
          subject: 'Flat B',
          attribute: 'rent',
          project: 'home',
          valueNumber: 1300,
          validFrom: DateTime.utc(2026, 6, 1),
        );

        final result = await service.factForget(second['id'] as int);
        expect(result['reopenedId'], first['id']);
        expect(result.containsKey('warning'), isFalse);

        final firstRow = facts().get(first['id'] as int)!;
        expect(firstRow.validUntil, isNull);
        expect(firstRow.supersededBy.targetId, 0);

        final plain = await service.factGet(
          subject: 'Flat B',
          attribute: 'rent',
          project: 'home',
        );
        expect((plain['facts'] as List).single['value'], 1200);
      });

      test('hard-deleting the current fact reopens its predecessor', () async {
        final first = await service.factSet(
          subject: 'Flat B',
          attribute: 'rent',
          project: 'home',
          valueNumber: 1200,
          validFrom: DateTime.utc(2026, 1, 1),
        );
        final second = await service.factSet(
          subject: 'Flat B',
          attribute: 'rent',
          project: 'home',
          valueNumber: 1300,
          validFrom: DateTime.utc(2026, 6, 1),
        );

        final result = await service.factForget(
          second['id'] as int,
          hard: true,
        );
        expect(result['reopenedId'], first['id']);

        final firstRow = facts().get(first['id'] as int)!;
        expect(firstRow.validUntil, isNull);
        expect(firstRow.supersededBy.targetId, 0);
      });

      test('no current value remains: predecessor already retracted', () async {
        final first = await service.factSet(
          subject: 'Flat B',
          attribute: 'rent',
          project: 'home',
          valueNumber: 1200,
          validFrom: DateTime.utc(2026, 1, 1),
        );
        final second = await service.factSet(
          subject: 'Flat B',
          attribute: 'rent',
          project: 'home',
          valueNumber: 1300,
          validFrom: DateTime.utc(2026, 6, 1),
        );
        // Retract the predecessor directly (simulating an out-of-order
        // history edit) so it is a closed AND retracted row.
        final predecessor = facts().get(first['id'] as int)!;
        predecessor.retractedAt = DateTime.now().toUtc();
        facts().put(predecessor);

        final result = await service.factForget(second['id'] as int);
        expect(result.containsKey('reopenedId'), isFalse);
        expect(result['warning'], contains('no current value remains'));
      });

      test(
        'no current value remains: forgotten fact had no predecessor',
        () async {
          final only = await service.factSet(
            subject: 'Flat B',
            attribute: 'rent',
            project: 'home',
            valueNumber: 1200,
          );
          final result = await service.factForget(only['id'] as int);
          expect(result.containsKey('reopenedId'), isFalse);
          expect(result['warning'], contains('no current value remains'));
        },
      );
    });
  });

  group('invariant: pseudo-random operation sequence', () {
    test(
      'a fixed-seed sequence of fact_set/fact_forget calls across 3 keys '
      'never leaves two non-retracted rows of a key overlapping, and at '
      'most one row is valid at any sampled instant – rejected operations '
      'are allowed as long as they throw ValidationException and nothing '
      'else',
      () async {
        final random = math.Random(1234567);
        final baseNow = DateTime.now().toUtc();
        const subjects = ['K0', 'K1', 'K2'];
        final createdIds = {for (final s in subjects) s: <int>[]};
        final lastValue = <String, String>{};

        bool intervalsOverlap(
          DateTime s1,
          DateTime? e1,
          DateTime s2,
          DateTime? e2,
        ) {
          final farFuture = DateTime.utc(9999);
          return s1.isBefore(e2 ?? farFuture) && s2.isBefore(e1 ?? farFuture);
        }

        // Every non-retracted row for [subject]'s key, straight from the
        // box – independent of any service-side filtering, so this is a
        // check ON the write path, not a restatement of it.
        List<Fact> nonRetractedRows(String subject) => facts()
            .query(
              Fact_.factKey.equals(Fact.keyFor('home', subject, 'v')) &
                  Fact_.retractedAt.isNull(),
            )
            .build()
            .find();

        Future<void> checkInvariant(String subject) async {
          final rows = nonRetractedRows(subject);
          for (var i = 0; i < rows.length; i++) {
            for (var j = i + 1; j < rows.length; j++) {
              final overlap = intervalsOverlap(
                rows[i].validFrom,
                rows[i].validUntil,
                rows[j].validFrom,
                rows[j].validUntil,
              );
              expect(
                overlap,
                isFalse,
                reason:
                    'rows ${rows[i].id} and ${rows[j].id} for "$subject" '
                    'overlap: [${rows[i].validFrom}, ${rows[i].validUntil}) '
                    'vs [${rows[j].validFrom}, ${rows[j].validUntil})',
              );
            }
          }
          // At most one row valid at "now" and at each row's own
          // validFrom (the natural boundary instants) – cross-checked
          // through the public factGet(at: ...) surface, not just the
          // raw rows, so this also pins the shared read-side predicate.
          final sampleInstants = <DateTime>{
            DateTime.now().toUtc(),
            for (final r in rows) r.validFrom,
          };
          for (final instant in sampleInstants) {
            final atResult = await service.factGet(
              subject: subject,
              attribute: 'v',
              project: 'home',
              at: instant,
            );
            expect(
              (atResult['facts'] as List).length,
              lessThanOrEqualTo(1),
              reason:
                  'more than one row valid at $instant for "$subject": '
                  '${atResult['facts']}',
            );
          }
        }

        int pickId(String subject) {
          final ids = createdIds[subject]!;
          // One in five picks an id unlikely to exist (already
          // hard-deleted, or never created) – exercising the "unknown
          // id" rejection path too, not only operations on real rows.
          if (ids.isEmpty || random.nextInt(5) == 0) {
            return 900000000 + random.nextInt(1000);
          }
          return ids[random.nextInt(ids.length)];
        }

        for (var op = 0; op < 300; op++) {
          final subject = subjects[random.nextInt(subjects.length)];
          final kind = random.nextInt(4); // 0=set 1=retract 2=end 3=hard
          try {
            switch (kind) {
              case 0:
                DateTime? validFrom;
                switch (random.nextInt(3)) {
                  case 1:
                    validFrom = baseNow.subtract(
                      Duration(days: random.nextInt(60) + 1),
                    );
                  case 2:
                    validFrom = baseNow.add(
                      Duration(days: random.nextInt(60) + 1),
                    );
                }
                // One in ten re-sends the last value used for this
                // subject – exercising the "unchanged" no-op path too.
                final reuse =
                    random.nextInt(10) == 0 && lastValue.containsKey(subject);
                final value = reuse ? lastValue[subject]! : 'v$op';
                final result = await service.factSet(
                  subject: subject,
                  attribute: 'v',
                  project: 'home',
                  valueText: value,
                  validFrom: validFrom,
                );
                lastValue[subject] = value;
                createdIds[subject]!.add(result['id'] as int);
              case 1:
                await service.factForget(pickId(subject));
              case 2:
                final DateTime until;
                switch (random.nextInt(3)) {
                  case 0:
                    until = baseNow.subtract(
                      Duration(days: random.nextInt(90)),
                    );
                  case 1:
                    until = baseNow;
                  default:
                    until = baseNow.add(Duration(days: random.nextInt(90)));
                }
                await service.factForget(pickId(subject), validUntil: until);
              default:
                await service.factForget(pickId(subject), hard: true);
            }
          } on ValidationException {
            // Rejected operations are allowed by design – the invariant
            // check below still runs, confirming the rejection left
            // nothing inconsistent behind.
          }
          await checkInvariant(subject);
        }
      },
    );
  });

  group('perf', () {
    test(
      'fact_get on 10k facts stays fast (median of 20 calls, recorded)',
      () async {
        const total = 10000;
        final now = DateTime.now().toUtc();
        for (var i = 0; i < total; i++) {
          putRawFact(
            project: 'garden',
            subject: 'Bulk $i',
            attribute: 'value',
            valueNumber: i.toDouble(),
            validFrom: now.subtract(const Duration(days: 1)),
          );
        }
        // One real row via factSet, exercised by the timed factGet calls
        // below (also has an explicit fact_query-by-area timing, recorded
        // not asserted, per plan §5).
        await service.factSet(
          subject: 'Bulk timed',
          attribute: 'value',
          project: 'garden',
          valueNumber: 1,
        );

        final samples = <int>[];
        for (var i = 0; i < 20; i++) {
          final sw = Stopwatch()..start();
          await service.factGet(
            subject: 'Bulk timed',
            attribute: 'value',
            project: 'garden',
          );
          sw.stop();
          samples.add(sw.elapsedMicroseconds);
        }
        samples.sort();
        final medianUs = samples[samples.length ~/ 2];
        stderr.writeln(
          '[perf] fact_get median over ${samples.length} calls on '
          '$total facts: ${medianUs / 1000} ms',
        );
        // Generous bound — this asserts "not pathologically slow", not a
        // tight performance target (plan review m11: a flaky timing
        // assertion collides with "never weaken a test").
        expect(medianUs, lessThan(50 * 1000));

        final areaSw = Stopwatch()..start();
        await service.factQuery(project: 'garden', limit: 50);
        areaSw.stop();
        stderr.writeln(
          '[perf] fact_query by project over $total facts: '
          '${areaSw.elapsedMilliseconds} ms (recorded, not asserted)',
        );
      },
      tags: ['perf'],
    );
  });
}
