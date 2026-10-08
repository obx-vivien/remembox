/// Facts tools `fact_set`/`fact_get`/`fact_query`/`fact_forget` –
/// 2026-09-21, areas and facts (0.3.0).
///
/// The primitives these are built on (`_ensureProjectScope`,
/// `_nearDuplicateProjects`, `_resolveAreaProjects`,
/// `_nonRetractedFactsForKey`, `_requireNoControlChars`,
/// `_requireRegistryProjectName`) live in memory_service_registry.dart –
/// reused below, never duplicated.
part of 'memory_service.dart';

// ---------------------------------------------------------------------------
// Caps (`subjectMaxLen`/`attributeMaxLen`/`factTextMaxLen`/
// `unitMaxLen` are also exposed as public names on MemoryService for
// server.dart's tool-schema layer; this file does not touch server.dart,
// so the write path here enforces the SAME numbers under its own private
// names – server.dart is free to
// reuse these values verbatim when it defines its public constants, the
// same way memory_service_registry.dart's `_areaNameMaxLen` predates
// server.dart's `areaNameMaxLen`). `sourceRef`'s cap is NOT redefined here:
// it reuses [MemoryService._sourceRefMaxLen] (the same cap `remember`
// already enforces) – one number, not two.
// ---------------------------------------------------------------------------

const int _subjectMaxLen = 200;
const int _attributeMaxLen = 128;
const int _factTextMaxLen = 4096;
const int _unitMaxLen = 32;

/// Upper bound `factQuery`'s `limit` is clamped to, regardless of what the
/// caller asks for ("cap 500 ... never silent truncation" – the
/// clamp itself is silent-safe only because `truncated`/`count` in the
/// result always say so).
const int _factQueryLimitCap = 500;

/// Truncates [dt] to millisecond precision (UTC) – `dateUtc` storage only
/// keeps milliseconds (how-to-use-objectbox.md), so comparing/storing an
/// un-truncated value (e.g. one carrying microseconds from `DateTime.now()`
/// on a platform that provides them) would make an otherwise-identical
/// value compare as "different" (spurious `replaced`) and could fail the
/// `validFrom >=` back-dated check by a sub-millisecond margin. Applied
/// to every incoming/derived
/// [DateTime] on the facts write and read paths before it is compared or
/// persisted.
DateTime _truncToMs(DateTime dt) => DateTime.fromMillisecondsSinceEpoch(
  dt.toUtc().millisecondsSinceEpoch,
  isUtc: true,
);

/// The ONE "is this fact valid at instant [t]" rule, used by every reader
/// that needs it: [MemoryServiceFacts.factGet] (no `at`, and with `at`
/// given), [MemoryServiceFacts.factQuery] (unless `includeHistory`),
/// [_factSummary]'s `current` field (via [_factValidAt]) and
/// `stats().facts.current`. A condition built by hand at each call site
/// instead risks disagreement (e.g. `validUntil == null` only, ignoring a
/// `validUntil` that lies in the future – a fact closed at a FUTURE date,
/// a scheduled replacement, or a `fact_forget` given a future
/// `validUntil`, would then vanish from every "current" read immediately,
/// well before that future date arrived). One builder means there is
/// only one place left to get this wrong.
///
/// Distinct from "is this fact the open HEAD of its key's history"
/// ([Fact.isCurrent], `validUntil == null`, no time bound at all): the
/// write path (`factSet`) uses this predicate to find the row valid at
/// the instant it is writing to, but still checks `validUntil == null`
/// directly wherever it specifically needs the open head – e.g. to decide
/// which closed row(s) should be linked forward via `supersededBy`.
Condition<Fact> _factValidAtCondition(DateTime t) =>
    Fact_.validFrom.lessOrEqualDate(t) &
    (Fact_.validUntil.isNull() | Fact_.validUntil.greaterThanDate(t)) &
    Fact_.retractedAt.isNull();

/// In-memory twin of [_factValidAtCondition] for an already-loaded [Fact]
/// (used by [_factSummary]'s `current` field) – must encode exactly the
/// same rule as the query version; kept next to it, not reimplemented
/// elsewhere.
bool _factValidAt(Fact f, DateTime t) =>
    !f.validFrom.isAfter(t) &&
    (f.validUntil == null || f.validUntil!.isAfter(t)) &&
    f.retractedAt == null;

/// Human-readable rendering of a [Fact.factKey] for a warning/log line:
/// [MemoryService.sanitizeForLog] strips control characters for
/// log-injection safety, which silently swallows
/// [kFactKeySep] too and reads as e.g. `"homeCarinsurer"`. Splitting on the
/// separator first and rejoining with `" / "` keeps the log-safety
/// stripping (each segment still goes through [MemoryService.sanitizeForLog])
/// while staying legible: `"home / Car / insurer"`.
String _renderFactKey(String key) =>
    key.split(kFactKeySep).map(MemoryService.sanitizeForLog).join(' / ');

void _requireFiniteFactNumber(double value) {
  if (!value.isFinite) {
    throw ValidationException(
      'valueNumber must be a finite number (NaN/Infinity are rejected).',
    );
  }
}

/// The one slot [f] actually uses, serialized per the fact result
/// shape (`value (string | number | ISO-8601)`).
Object? _factValue(Fact f) {
  switch (f.valueType) {
    case FactValueType.text:
      return f.valueText;
    case FactValueType.number:
      return f.valueNumber;
    case FactValueType.date:
      return f.valueDate?.toIso8601String();
    default:
      // Unreachable in practice (valueType is always one of the three
      // above on any row this service wrote), but never silently returns
      // null-as-if-valid for an unexpected value – surfaces the actual
      // stored string so a caller inspecting a cross-device/future-schema
      // row sees what is really there.
      return f.valueType;
  }
}

/// `true` iff [old] already holds exactly the value/unit [factSet] was
/// asked to set – the "no write, return existing id" branch.
/// [old.valueType] must be compared by the caller BEFORE calling this (a
/// text row is never "the same value" as a number row, whatever the
/// number).
bool _sameFactValue(
  Fact old,
  String valueType,
  String? valueText,
  double? valueNumber,
  DateTime? valueDate,
) {
  switch (valueType) {
    case FactValueType.text:
      return old.valueText == (valueText ?? '');
    case FactValueType.number:
      return old.valueNumber == valueNumber;
    case FactValueType.date:
      return old.valueDate == valueDate;
    default:
      return false;
  }
}

/// Fact result shape shared by every fact tool. [now] decides `current`
/// per the shared
/// definition (`validUntil == null && retractedAt == null &&
/// validFrom <= now`) – passed in rather than read fresh here so every row
/// in the same tool call is judged against the exact same instant.
Map<String, Object?> _factSummary(Fact f, {required DateTime now}) => {
  'id': f.id,
  'project': f.project,
  'subject': f.subject,
  'attribute': f.attribute,
  'valueType': f.valueType,
  'value': _factValue(f),
  'unit': f.unit,
  'validFrom': f.validFrom.toIso8601String(),
  'validUntil': f.validUntil?.toIso8601String(),
  'current': _factValidAt(f, now),
  'retracted': f.retractedAt != null,
  'sourceType': f.sourceType,
  'sourceRef': f.sourceRef,
  'explainedByEntryId': f.explainedBy.targetId != 0
      ? f.explainedBy.targetId
      : null,
  'supersededBy': f.supersededBy.targetId != 0 ? f.supersededBy.targetId : null,
  'createdAt': f.createdAt.toIso8601String(),
};

extension MemoryServiceFacts on MemoryService {
  Fact _requireFact(int id) {
    final fact = _facts.get(id);
    if (fact == null) {
      throw ValidationException('Fact with id $id does not exist.');
    }
    return fact;
  }

  /// Exactly one of `valueText`/`valueNumber`/`valueDate`
  /// required. Retracting/hard-forgetting the CURRENT fact
  /// for a key reopens its predecessor in the same write tx – the same
  /// invariant `factForget` below must honor.
  Future<Map<String, Object?>> factSet({
    required String subject,
    required String attribute,
    required String? project,
    String? valueText,
    double? valueNumber,
    DateTime? valueDate,
    String unit = '',
    DateTime? validFrom,
    String sourceType = MemorySource.note,
    String sourceRef = '',
    int? explainedByEntryId,
  }) async {
    // -- validation before the lending (mirrors remember()'s shape) --
    final valuesGiven = [
      valueText != null,
      valueNumber != null,
      valueDate != null,
    ].where((b) => b).length;
    if (valuesGiven != 1) {
      throw ValidationException(
        'fact_set requires exactly one of valueText/valueNumber/valueDate '
        '(got $valuesGiven).',
      );
    }
    final String valueType;
    if (valueText != null) {
      valueType = FactValueType.text;
    } else if (valueNumber != null) {
      valueType = FactValueType.number;
    } else {
      valueType = FactValueType.date;
    }
    if (valueNumber != null) _requireFiniteFactNumber(valueNumber);

    MemoryService._requireSourceType(sourceType);
    // Project rule identical to `remember`'s: byte-exact,
    // length-capped, never trimmed, no control-char rejection beyond what
    // `remember` already accepts.
    final validatedProject = _requireRegistryProjectName(project);

    if (subject.trim().isEmpty) {
      throw ValidationException('subject is required.');
    }
    if (attribute.trim().isEmpty) {
      throw ValidationException('attribute is required.');
    }
    MemoryService._requireLen('subject', subject, _subjectMaxLen);
    MemoryService._requireLen('attribute', attribute, _attributeMaxLen);
    // Reuse the registry's control-char guard (also blocks kFactKeySep) –
    // the key separator must never be forgeable via subject/attribute.
    _requireNoControlChars('subject', subject);
    _requireNoControlChars('attribute', attribute);
    if (valueText != null) {
      MemoryService._requireLen('valueText', valueText, _factTextMaxLen);
    }
    MemoryService._requireLen('unit', unit, _unitMaxLen);
    MemoryService._requireLen(
      'sourceRef',
      sourceRef,
      MemoryService._sourceRefMaxLen,
    );

    final resolvedValidFrom = _truncToMs(validFrom ?? DateTime.now().toUtc());
    final resolvedValueDate = valueDate == null ? null : _truncToMs(valueDate);

    return _withSession('fact_set', () {
      return store.runInTransaction(TxMode.write, () {
        // Strict registry mode: registered, non-merged project only –
        // before _ensureProjectScope (which would register it). No-op in
        // open mode.
        _requireWritableProject(validatedProject, tool: 'fact_set');
        final ensured = _ensureProjectScope(
          validatedProject,
          reason: 'fact_set',
        );
        final warnings = <String>[...ensured.warnings];
        final dupeProjects = _nearDuplicateProjects(validatedProject);
        if (dupeProjects.isNotEmpty) {
          warnings.add(
            'project "${MemoryService.sanitizeForLog(validatedProject)}" '
            'differs from existing '
            '${dupeProjects.map((n) => '"${MemoryService.sanitizeForLog(n)}"').join(', ')} '
            'only by case/space/-/_; use the existing name or run '
            'project_merge.',
          );
        }

        if (explainedByEntryId != null) {
          _requireEntry(explainedByEntryId, what: 'explainedBy entry');
        }

        final key = Fact.keyFor(validatedProject, subject, attribute);

        Fact buildNew() {
          final f = Fact(
            project: validatedProject,
            subject: subject,
            attribute: attribute,
            factKey: key,
            valueType: valueType,
            valueText: valueText ?? '',
            valueNumber: valueNumber,
            valueDate: resolvedValueDate,
            unit: unit,
            validFrom: resolvedValidFrom,
            sourceType: sourceType,
            sourceRef: sourceRef,
          );
          if (explainedByEntryId != null) {
            f.explainedBy.targetId = explainedByEntryId;
          }
          return f;
        }

        // The invariant this write path owns: for this key, the
        // non-retracted rows' `[validFrom, validUntil)` intervals never
        // overlap. `rows` is every non-retracted row for the key, not
        // only the open head – a row already closed at a FUTURE date
        // (a scheduled replacement, or a `fact_forget` given a future
        // `validUntil`) can still overlap [resolvedValidFrom, ...) and
        // has to be considered too.
        final rows = _nonRetractedFactsForKey(key);
        final validAtNewFrom = rows
            .where((r) => _factValidAt(r, resolvedValidFrom))
            .toList();

        final Fact resultFact;
        final String action;
        int? closedId;
        List<int>? closedIds;

        final singleValidNow = validAtNewFrom.length == 1
            ? validAtNewFrom.single
            : null;
        final sameAsSingleValidNow =
            singleValidNow != null &&
            singleValidNow.validUntil == null &&
            singleValidNow.valueType == valueType &&
            singleValidNow.unit == unit &&
            _sameFactValue(
              singleValidNow,
              valueType,
              valueText,
              valueNumber,
              resolvedValueDate,
            );

        if (sameAsSingleValidNow) {
          final old = singleValidNow;
          resultFact = old;
          action = 'unchanged';
          // Only warn about a differing validFrom when the caller
          // actually passed one. `validFrom == null` means "now" was
          // only ever the default – every idempotent re-set that simply
          // omits validFrom (the common case) would otherwise fire this
          // warning too, since "now" almost never equals the stored
          // row's validFrom to the millisecond.
          if (validFrom != null && old.validFrom != resolvedValidFrom) {
            warnings.add(
              'fact_set: identical value for key '
              '"${_renderFactKey(key)}" with a different '
              'validFrom (${resolvedValidFrom.toIso8601String()}); kept '
              'the existing row\'s validFrom '
              '(${old.validFrom.toIso8601String()}).',
            );
          }
          // An unchanged value never rewrites history – sourceRef/
          // explainedBy on the existing row are left as they are – but a
          // caller who supplied a DIFFERENT sourceRef or
          // explainedByEntryId than what is stored deserves to know it
          // was not applied, rather than it being silently dropped.
          if (sourceRef.isNotEmpty && sourceRef != old.sourceRef) {
            warnings.add(
              'fact_set: identical value for key "${_renderFactKey(key)}"'
              ' – the new sourceRef '
              '"${MemoryService.sanitizeForLog(sourceRef)}" was not '
              'stored (an unchanged value keeps its existing sourceRef); '
              'forget and re-set the fact to replace it.',
            );
          }
          final oldExplainedBy = old.explainedBy.targetId == 0
              ? null
              : old.explainedBy.targetId;
          if (explainedByEntryId != null &&
              explainedByEntryId != oldExplainedBy) {
            warnings.add(
              'fact_set: identical value for key "${_renderFactKey(key)}"'
              ' – the new explainedByEntryId ($explainedByEntryId) was not '
              'stored (an unchanged value keeps its existing link); '
              'forget and re-set the fact to replace it.',
            );
          }
        } else {
          // Not a same-value no-op. `resolvedValidFrom` may only extend
          // the key's history at or after every row already on record –
          // otherwise the new row would have to overlap one that starts
          // later, which the invariant forbids. The row with the latest
          // `validFrom` is exactly the one such an insert would violate,
          // so it is also the row named in the rejection.
          if (rows.isNotEmpty) {
            final latest = rows.reduce(
              (a, b) => a.validFrom.isAfter(b.validFrom) ? a : b,
            );
            if (resolvedValidFrom.isBefore(latest.validFrom)) {
              final now = DateTime.now().toUtc();
              final scheduled = latest.validFrom.isAfter(now);
              throw ValidationException(
                'fact_set: validFrom (${resolvedValidFrom.toIso8601String()}) '
                'is before fact ${latest.id}\'s validFrom '
                '(${latest.validFrom.toIso8601String()}) for key '
                '"${_renderFactKey(key)}" – back-dated insert into history '
                'not supported in v1.'
                '${scheduled ? ' Fact ${latest.id} (value '
                    '${_factValue(latest)}) is scheduled to take effect '
                    'then; run fact_forget(id: ${latest.id}) first if you '
                    'meant to cancel or replace it.' : ''}',
              );
            }
          }

          final created = buildNew();
          created.id = _facts.put(created);
          // Every row that would otherwise still cover
          // [resolvedValidFrom, ...) – open, or closed later than this
          // write – is closed exactly at resolvedValidFrom (never
          // before it started: the rejection above already ruled that
          // out). Only a row that was open before this write is also
          // linked forward via supersededBy – a row that already had its
          // own validUntil (e.g. from `fact_forget(validUntil: ...)`)
          // keeps whatever forward link it already had, since this write
          // is trimming its end, not replacing the row that was meant to
          // follow it.
          final ids = <int>[];
          for (final old in rows) {
            final overlaps =
                old.validUntil == null ||
                old.validUntil!.isAfter(resolvedValidFrom);
            if (!overlaps) continue;
            final wasOpen = old.validUntil == null;
            old.validUntil = resolvedValidFrom;
            if (wasOpen) old.supersededBy.targetId = created.id;
            _facts.put(old);
            ids.add(old.id);
          }
          resultFact = created;
          if (ids.isEmpty) {
            action = 'created';
            log(
              '[memory] fact_set created fact ${created.id} for key '
              '"${_renderFactKey(key)}"',
            );
          } else if (ids.length == 1) {
            action = 'replaced';
            closedId = ids.single;
            log(
              '[memory] fact_set replaced fact ${ids.single} with '
              '${created.id} for key "${_renderFactKey(key)}"',
            );
          } else {
            // More than one row overlapped the same write – a
            // cross-device conflict (typically Sync writing on two
            // devices), not something a single-writer serialized
            // fact_set can produce on its own. Close ALL of them and
            // warn instead of silently picking a winner.
            action = 'replaced';
            closedIds = ids;
            log(
              '[memory] WARN fact key "${_renderFactKey(key)}" had '
              '${ids.length} overlapping rows – closed all (repair), new '
              'current is fact ${created.id}',
            );
            warnings.add(
              'fact key "${_renderFactKey(key)}" had overlapping values '
              '(${ids.length} rows, typically from Sync writing on two '
              'devices); all were closed at '
              '${resolvedValidFrom.toIso8601String()} and replaced by '
              'this write.',
            );
          }
        }

        final result = <String, Object?>{
          ..._factSummary(resultFact, now: DateTime.now().toUtc()),
          'action': action,
          'closedId': ?closedId,
          'closedIds': ?closedIds,
        };
        if (warnings.isNotEmpty) result['warning'] = warnings.join(' ');
        return _applyGuardPeerWarning(result);
      });
    });
  }

  /// `includeFuture`: without `at`, a future-dated row (whose
  /// [Fact.isCurrent] is true but `validFrom > now`) is excluded unless
  /// [includeFuture] is set, so "current" and "valid right now" don't
  /// silently disagree. When set, the row valid right now (if any) AND
  /// every row still ahead of it are returned together, ordered by
  /// `validFrom` – not the future row alone, which would silently drop
  /// the value that actually applies today.
  Future<Map<String, Object?>> factGet({
    required String subject,
    String? attribute,
    String? project,
    DateTime? at,
    bool includeFuture = false,
  }) {
    if (subject.trim().isEmpty) {
      throw ValidationException('subject is required.');
    }
    MemoryService._requireLen('subject', subject, _subjectMaxLen);
    if (attribute != null) {
      MemoryService._requireLen('attribute', attribute, _attributeMaxLen);
    }
    if (project != null) {
      MemoryService._requireLen(
        'project',
        project,
        MemoryService.projectMaxLen,
      );
    }
    final resolvedAt = at == null ? null : _truncToMs(at);

    return _withSession('fact_get', () {
      return store.runInTransaction(TxMode.read, () {
        var condition = Fact_.subject.equals(subject, caseSensitive: true);
        if (attribute != null) {
          condition =
              condition &
              Fact_.attribute.equals(attribute, caseSensitive: true);
        }
        if (project != null) {
          condition =
              condition & Fact_.project.equals(project, caseSensitive: true);
        }
        final now = DateTime.now().toUtc();
        // `includeFuture` without an explicit `at` is the one place a
        // caller asks to see more than "the value right now": the row
        // valid at this instant (if any) PLUS every row still ahead of
        // it (a scheduled replacement not yet in effect) – deliberately
        // NOT just the open head, which would show a future row but
        // drop the value that actually applies today.
        final unionFutureView = resolvedAt == null && includeFuture;
        if (resolvedAt != null) {
          condition = condition & _factValidAtCondition(resolvedAt);
        } else if (unionFutureView) {
          condition =
              condition &
              (_factValidAtCondition(now) |
                  (Fact_.validFrom.greaterThanDate(now) &
                      Fact_.retractedAt.isNull()));
        } else {
          condition = condition & _factValidAtCondition(now);
        }

        var builder = _facts.query(condition);
        if (unionFutureView) {
          builder = builder.order(Fact_.validFrom);
        }
        final rows = _useQuery(builder, (q) => q.find());

        // Overlapping non-retracted rows sharing one factKey violate the
        // facts invariant – always a cross-device conflict (typically
        // Sync writing on two devices), surfaced rather than silently
        // picked-first. Skipped for `unionFutureView`: that view returns
        // more than one row per key BY DESIGN (the current value plus
        // whatever is scheduled after it), which is not an overlap.
        final warnings = <String>[];
        if (!unionFutureView) {
          final byKey = <String, int>{};
          for (final r in rows) {
            byKey[r.factKey] = (byKey[r.factKey] ?? 0) + 1;
          }
          for (final e in byKey.entries) {
            if (e.value > 1) {
              warnings.add(
                'overlapping values (${e.value} rows) exist for key '
                '"${_renderFactKey(e.key)}" (typically from Sync writing '
                'on two devices); setting the value again with fact_set '
                'closes them.',
              );
            }
          }
        }

        final result = <String, Object?>{
          'facts': [for (final r in rows) _factSummary(r, now: now)],
          '_provenance_note': MemoryService._provenanceNote,
        };
        if (warnings.isNotEmpty) result['warning'] = warnings.join(' ');
        return result;
      });
    });
  }

  /// At least one of `attribute`/`subjectPrefix`/`project`/
  /// `area` required (no unbounded dump).
  Future<Map<String, Object?>> factQuery({
    String? attribute,
    String? subjectPrefix,
    String? project,
    String? area,
    double? numberMin,
    double? numberMax,
    bool includeHistory = false,
    int limit = 50,
  }) {
    if (attribute == null &&
        subjectPrefix == null &&
        project == null &&
        area == null) {
      throw ValidationException(
        'fact_query requires at least one of attribute, subjectPrefix, '
        'project, area – no unbounded dump.',
      );
    }
    if (limit <= 0) {
      throw ValidationException('limit must be >= 1.');
    }
    if (attribute != null) {
      MemoryService._requireLen('attribute', attribute, _attributeMaxLen);
    }
    if (subjectPrefix != null) {
      MemoryService._requireLen('subjectPrefix', subjectPrefix, _subjectMaxLen);
    }
    if (project != null) {
      MemoryService._requireLen(
        'project',
        project,
        MemoryService.projectMaxLen,
      );
    }
    if (area != null) {
      MemoryService._requireLen('area', area, _areaNameMaxLen);
    }
    if (numberMin != null) _requireFiniteFactNumber(numberMin);
    if (numberMax != null) _requireFiniteFactNumber(numberMax);
    final effectiveLimit = math.min(limit, _factQueryLimitCap);

    return _withSession('fact_query', () {
      return store.runInTransaction(TxMode.read, () {
        List<String>? areaProjects;
        if (area != null) {
          // Throws ValidationException if the area does not exist.
          areaProjects = _resolveAreaProjects(area);
          if (areaProjects.isEmpty) {
            // Never build oneOf([]) – early return.
            return {
              'facts': const <Object?>[],
              'count': 0,
              'truncated': false,
              'warning':
                  'area "${MemoryService.sanitizeForLog(area)}" has no '
                  'projects assigned.',
              '_provenance_note': MemoryService._provenanceNote,
            };
          }
        }
        if (project != null &&
            areaProjects != null &&
            !areaProjects.contains(project)) {
          return {
            'facts': const <Object?>[],
            'count': 0,
            'truncated': false,
            'warning':
                'project "${MemoryService.sanitizeForLog(project)}" is not '
                'in area "${MemoryService.sanitizeForLog(area!)}".',
            '_provenance_note': MemoryService._provenanceNote,
          };
        }

        Condition<Fact>? condition;
        void add(Condition<Fact> c) {
          condition = condition == null ? c : condition! & c;
        }

        if (attribute != null) {
          add(Fact_.attribute.equals(attribute, caseSensitive: true));
        }
        if (subjectPrefix != null) {
          add(Fact_.subject.startsWith(subjectPrefix, caseSensitive: true));
        }
        if (project != null) {
          add(Fact_.project.equals(project, caseSensitive: true));
        } else if (areaProjects != null) {
          add(Fact_.project.oneOf(areaProjects, caseSensitive: true));
        }
        if (numberMin != null || numberMax != null) {
          // A range filter implies valueType == number – never rely on a
          // null valueNumber failing to match by accident.
          add(Fact_.valueType.equals(FactValueType.number));
          if (numberMin != null) {
            add(Fact_.valueNumber.greaterOrEqual(numberMin));
          }
          if (numberMax != null) {
            add(Fact_.valueNumber.lessOrEqual(numberMax));
          }
        }
        final now = DateTime.now().toUtc();
        if (!includeHistory) {
          add(_factValidAtCondition(now));
        }
        // At least one of attribute/subjectPrefix/project/area is required
        // above, and each maps to a condition (project XOR area, always
        // one of them when area/project given) – condition is never null.
        final finalCondition = condition!;

        final total = _useQuery(_facts.query(finalCondition), (q) => q.count());
        final builder = _facts
            .query(finalCondition)
            .order(Fact_.subject)
            .order(Fact_.validFrom, flags: Order.descending);
        final rows = _useQuery(builder, (q) {
          q.limit = effectiveLimit;
          return q.find();
        });

        return {
          'facts': [for (final r in rows) _factSummary(r, now: now)],
          'count': total,
          'truncated': total > rows.length,
          '_provenance_note': MemoryService._provenanceNote,
        };
      });
    });
  }

  /// Three actions: soft (default) = retracted ("was never true");
  /// `validUntil:` given = "ended" (stays historically valid up to that
  /// date; rejected if that would overlap a successor already in the
  /// chain); `hard` = delete + clear `supersededBy` pointers. `retracted`
  /// and `hard-deleted` reopen the predecessor row when the forgotten row
  /// was current and had one – `ended` does not: the predecessor already
  /// correctly stopped being true earlier and stays closed.
  Future<Map<String, Object?>> factForget(
    int id, {
    bool hard = false,
    DateTime? validUntil,
  }) {
    final resolvedValidUntil = validUntil == null
        ? null
        : _truncToMs(validUntil);

    return _withSession('fact_forget', () {
      return store.runInTransaction(TxMode.write, () {
        final fact = _requireFact(id);
        // Captured BEFORE any mutation below – "was this the head of its
        // key's history", independent of validFrom<=now.
        final wasCurrent = fact.isCurrent;
        final now = _truncToMs(DateTime.now().toUtc());

        final String action;
        if (hard) {
          action = 'hard-deleted';
        } else if (resolvedValidUntil != null) {
          // "Ended" does not apply to an already-retracted fact – a
          // retracted fact "was never true", so it has no valid period
          // left to end.
          if (fact.retractedAt != null) {
            throw ValidationException(
              'fact_forget: fact $id is already retracted (at '
              '${fact.retractedAt!.toIso8601String()}) – "ended" does not '
              'apply to a retracted fact.',
            );
          }
          // validUntil must be strictly after validFrom – a zero-length
          // "ended" interval is never useful and is almost always a
          // caller mistake.
          if (!resolvedValidUntil.isAfter(fact.validFrom)) {
            throw ValidationException(
              'fact_forget: validUntil '
              '(${resolvedValidUntil.toIso8601String()}) must be after '
              'this fact\'s validFrom '
              '(${fact.validFrom.toIso8601String()}).',
            );
          }
          // Ending this row must not open a gap by overlapping whatever
          // already follows it in the same key's history (its nearest
          // non-retracted successor by validFrom) – that would violate
          // the same non-overlap invariant fact_set enforces on writes.
          final successor = _useQuery(
            _facts
                .query(
                  Fact_.factKey.equals(fact.factKey) &
                      Fact_.id.notEquals(id) &
                      Fact_.retractedAt.isNull() &
                      Fact_.validFrom.greaterOrEqualDate(fact.validFrom),
                )
                .order(Fact_.validFrom),
            (q) {
              q.limit = 1;
              return q.findFirst();
            },
          );
          if (successor != null &&
              resolvedValidUntil.isAfter(successor.validFrom)) {
            throw ValidationException(
              'fact_forget: validUntil '
              '(${resolvedValidUntil.toIso8601String()}) is after '
              'successor fact ${successor.id}\'s validFrom '
              '(${successor.validFrom.toIso8601String()}) for key '
              '"${_renderFactKey(fact.factKey)}" – that would overlap it.',
            );
          }
          action = 'ended';
        } else if (fact.retractedAt != null) {
          // Retracting an already-retracted fact must be idempotent –
          // overwriting retractedAt with a fresh timestamp on every
          // repeat call would be a silent history rewrite (the fact's
          // real retraction moment would be lost).
          final result = <String, Object?>{
            'id': id,
            'action': 'unchanged',
            'retractedAt': fact.retractedAt!.toIso8601String(),
            'warning':
                'fact $id was already retracted at '
                '${fact.retractedAt!.toIso8601String()}; fact_forget is a '
                'no-op.',
          };
          return _applyGuardPeerWarning(result);
        } else {
          action = 'retracted';
        }

        // Reopening the predecessor (the row whose supersededBy points at
        // THIS fact) applies to `retracted` and `hard-deleted` only – NOT
        // to `ended` (a `validUntil` given).
        // "Ended" means "this value was true until that date, with no
        // successor" – the predecessor already correctly stopped being
        // true earlier and must stay closed; reopening it would make an
        // OLDER value current again out of nowhere. Only `retracted`
        // ("never true") and `hard-deleted` (removed entirely) leave a
        // real gap that the predecessor should fill back in.
        final pointingHere = _useQuery(
          _facts.query(Fact_.supersededBy.equals(id)),
          (q) => q.find(),
        );
        int? reopenedId;
        String? reopenWarning;
        if (wasCurrent && action != 'ended') {
          if (pointingHere.isEmpty) {
            reopenWarning =
                'no current value remains for key '
                '"${_renderFactKey(fact.factKey)}" after '
                'forgetting fact $id (it had no predecessor).';
          } else if (pointingHere.length > 1) {
            // Only reachable via factSet's multi-row repair path, which
            // already warned when it happened – do not guess which of
            // several closed rows to reopen.
            reopenWarning =
                'fact $id had ${pointingHere.length} rows pointing to it as '
                'their successor (unexpected) – no automatic reopen after '
                'forgetting it; run fact_set to establish a new current '
                'value for key "${_renderFactKey(fact.factKey)}".';
          } else {
            final predecessor = pointingHere.single;
            if (predecessor.retractedAt != null) {
              reopenWarning =
                  'no current value remains for key '
                  '"${_renderFactKey(fact.factKey)}" after '
                  'forgetting fact $id: predecessor ${predecessor.id} was '
                  'already retracted.';
            } else {
              predecessor.validUntil = null;
              predecessor.supersededBy.targetId = 0;
              _facts.put(predecessor);
              reopenedId = predecessor.id;
              log(
                '[memory] fact_forget reopened predecessor '
                '${predecessor.id} for key '
                '"${_renderFactKey(fact.factKey)}" after '
                'forgetting fact $id',
              );
            }
          }
        }

        final extra = <String, Object?>{};
        if (hard) {
          var pointerLinksCleared = 0;
          for (final other in pointingHere) {
            if (other.id == reopenedId) continue;
            other.supersededBy.targetId = 0;
            _facts.put(other);
            pointerLinksCleared++;
          }
          _facts.remove(id);
          log(
            '[memory] fact_forget hard-deleted fact $id '
            '(supersededByPointersCleared=$pointerLinksCleared)',
          );
          extra['supersededByPointersCleared'] = pointerLinksCleared;
        } else if (resolvedValidUntil != null) {
          fact.validUntil = resolvedValidUntil;
          _facts.put(fact);
          log(
            '[memory] fact_forget ended fact $id at '
            '${resolvedValidUntil.toIso8601String()}',
          );
          extra['validUntil'] = resolvedValidUntil.toIso8601String();
        } else {
          fact.retractedAt = now;
          _facts.put(fact);
          log('[memory] fact_forget retracted fact $id');
          extra['retractedAt'] = now.toIso8601String();
        }

        final result = <String, Object?>{
          'id': id,
          'action': action,
          ...extra,
          'reopenedId': ?reopenedId,
        };
        if (reopenWarning != null) result['warning'] = reopenWarning;
        return _applyGuardPeerWarning(result);
      });
    });
  }
}
