/// Attribute value register – 0.5.0: `attribute_define`, `attributes_list`
/// and [MemoryServiceAttributes._checkAttributeValue], the ONE place
/// `fact_set` checks a value against the register.
///
/// A registered attribute ([AttributeDefinition]) has a description and,
/// optionally, allowed text values ([AttributeValue]). Without values it
/// only describes the attribute; with values it restricts `fact_set`:
/// strict registry mode rejects any other value (or a non-text value, or
/// an attribute that differs from a registered one only by case/space/
/// -/_), open mode stores it with a warning. Nothing is checked while no
/// attribute is registered, so a store without definitions takes exactly
/// the old `fact_set` path. `fact_get`/`fact_query`/`fact_forget` never
/// check (a predecessor reopened by `fact_forget` is history, not a new
/// write), and `attribute_define` never touches a fact.
part of 'memory_service.dart';

/// Cap on one allowed value (characters).
const int _attributeValueMaxLen = 128;

/// Cap on the number of allowed values per attribute.
const int _attributeValueMaxCount = 64;

/// Cap on `nonConformingExamples` in an `attribute_define` result.
const int _nonConformingExampleMax = 20;

extension MemoryServiceAttributes on MemoryService {
  // ---------------------------------------------------------------------
  // Reads (inside a lending)
  // ---------------------------------------------------------------------

  AttributeDefinition? _attributeDefinitionFor(String name) => _useQuery(
    _attrDefs.query(
      AttributeDefinition_.name.equals(name, caseSensitive: true),
    ),
    (q) => q.findFirst(),
  );

  /// The allowed values of [attribute] in display order.
  List<AttributeValue> _attributeValuesOf(String attribute) =>
      _useQuery(
        _attrValues.query(
          AttributeValue_.attribute.equals(attribute, caseSensitive: true),
        ),
        (q) => q.find(),
      )..sort((a, b) {
        final byPosition = a.position.compareTo(b.position);
        return byPosition != 0 ? byPosition : a.value.compareTo(b.value);
      });

  /// Registered attribute names that differ from [attribute] only by
  /// case/space/-/_ ([ScopeKey]), sorted. Registry-scale page-through.
  List<String> _attributeVariantsOf(String attribute) {
    final key = ScopeKey.of(attribute);
    final names = <String>[];
    _pageThrough<AttributeDefinition>(_attrDefs.query(), (page) {
      for (final d in page) {
        if (d.name != attribute && ScopeKey.of(d.name) == key) {
          names.add(d.name);
        }
      }
    });
    return names..sort();
  }

  /// Current facts (valid at [now]) of [attribute], paged.
  void _pageCurrentFactsOf(
    String attribute,
    DateTime now,
    void Function(List<Fact> page) onPage,
  ) => _pageThrough<Fact>(
    _facts.query(
      Fact_.attribute.equals(attribute, caseSensitive: true) &
          _factValidAtCondition(now),
    ),
    onPage,
  );

  /// True if [f] conforms to the allowed [values] (empty = no restriction).
  static bool _factConforms(Fact f, Set<String> values) =>
      values.isEmpty ||
      (f.valueType == FactValueType.text && values.contains(f.valueText));

  /// The near-match rule for a rejected value from a closed set: the first
  /// of [candidates] (in their order) whose [ScopeKey] equals [value]'s –
  /// `"In Progress"` → `inProgress`. Returns `' Did you mean "x"?'` or `''`
  /// for no match. Shared by `fact_set`'s attribute check and
  /// `thread_update`'s state check (0.5.0) – one rule, not two copies.
  static String _didYouMean(String value, Iterable<String> candidates) {
    final key = ScopeKey.of(value);
    final suggestion = candidates
        .where((c) => ScopeKey.of(c) == key)
        .firstOrNull;
    return suggestion == null
        ? ''
        : ' Did you mean "${MemoryService.sanitizeForLog(suggestion)}"?';
  }

  // ---------------------------------------------------------------------
  // The fact_set check
  // ---------------------------------------------------------------------

  /// Checks a `fact_set` value against the attribute register – the ONE
  /// place this rule lives. MUST run inside the write transaction, before
  /// anything is written. Returns the open-mode warnings (each also
  /// logged); in strict registry mode a violation throws via
  /// `_rejectStrict`. Returns immediately (no warning, nothing logged)
  /// while no attribute is registered.
  ///
  /// Violations: an unregistered [attribute] that differs from a
  /// registered one only by case/space/-/_; for a registered attribute
  /// with allowed values, a non-text value or a [valueText] that is not
  /// exactly (case-sensitively) one of them. A registered attribute
  /// without values is never a violation.
  List<String> _checkAttributeValue(
    String attribute,
    String valueType,
    String? valueText, {
    required String tool,
  }) {
    if (_attrDefs.count() == 0) return const [];
    final shownAttribute = MemoryService.sanitizeForLog(attribute);
    final strict = registryMode == RegistryMode.strict;
    final warnings = <String>[];

    void violation(String strictMessage, String openMessage) {
      if (strict) _rejectStrict(tool, strictMessage);
      warnings.add(openMessage);
      log('[memory] $tool: ${MemoryService.sanitizeForLog(openMessage)}');
    }

    final def = _attributeDefinitionFor(attribute);
    if (def == null) {
      final variants = _attributeVariantsOf(attribute);
      if (variants.isNotEmpty) {
        final registered = MemoryService.sanitizeForLog(variants.first);
        violation(
          '$tool: attribute "$shownAttribute" differs from the registered '
          'attribute "$registered" only by case/space/-/_ (strict registry '
          'mode) – use "$registered". Nothing was written.',
          '$tool: attribute "$shownAttribute" differs from the registered '
          'attribute "$registered" only by case/space/-/_; use '
          '"$registered" – stored anyway (open registry mode).',
        );
      }
      return warnings;
    }

    final values = _attributeValuesOf(def.name);
    if (values.isEmpty) return warnings;
    final allowed = values
        .map((v) => MemoryService.sanitizeForLog(v.value))
        .join(', ');
    if (valueType != FactValueType.text) {
      violation(
        '$tool: the attribute "$shownAttribute" takes a text value '
        '(valueText), one of: $allowed. Nothing was written.',
        '$tool: the attribute "$shownAttribute" takes a text value '
        '(valueText), one of: $allowed – stored anyway (open registry '
        'mode).',
      );
      return warnings;
    }
    final text = valueText ?? '';
    if (values.any((v) => v.value == text)) return warnings;
    final didYouMean = _didYouMean(text, values.map((v) => v.value));
    final shownValue = MemoryService.sanitizeForLog(
      MemoryService._truncateForError(text),
    );
    violation(
      '$tool: "$shownValue" is not an allowed value of the attribute '
      '"$shownAttribute" (strict registry mode). Allowed: $allowed.'
      '$didYouMean The allowed values are maintained with attribute_define. '
      'Nothing was written.',
      '$tool: "$shownValue" is not an allowed value of the attribute '
      '"$shownAttribute". Allowed: $allowed.$didYouMean The allowed values '
      'are maintained with attribute_define – stored anyway (open registry '
      'mode).',
    );
    return warnings;
  }

  // ---------------------------------------------------------------------
  // attribute_define
  // ---------------------------------------------------------------------

  /// Validates and de-duplicates a list of values for [field]: non-blank,
  /// no control characters, at most [_attributeValueMaxLen] characters.
  /// Exact duplicates collapse to the first one, with a warning.
  static ({List<String> values, List<String> warnings}) _normalizeValueArgs(
    String field,
    List<String> raw,
  ) {
    if (raw.length > _attributeValueMaxCount) {
      throw ValidationException(
        'attribute_define: "$field" has ${raw.length} entries, exceeding the '
        '$_attributeValueMaxCount value limit.',
      );
    }
    final values = <String>[];
    final warnings = <String>[];
    for (final v in raw) {
      MemoryService._requireLen(field, v, _attributeValueMaxLen);
      if (v.trim().isEmpty) {
        throw ValidationException(
          'attribute_define: "$field" contains a blank value.',
        );
      }
      if (_controlCharPattern.hasMatch(v)) {
        throw ValidationException(
          'attribute_define: value "${MemoryService.sanitizeForLog(v)}" '
          'contains control characters.',
        );
      }
      if (values.contains(v)) {
        warnings.add(
          'Value "${MemoryService.sanitizeForLog(v)}" is listed more than '
          'once – kept once.',
        );
        continue;
      }
      values.add(v);
    }
    return (values: values, warnings: warnings);
  }

  /// Registers a fact attribute (an [AttributeDefinition]) with a
  /// one-sentence [description], updates it, or – with [remove] – deletes
  /// it together with its allowed values.
  ///
  /// [attribute] is exactly the `Fact.attribute` string (case-sensitive,
  /// not normalized). Allowed values: [values] REPLACES the set (order =
  /// display order; an empty list clears it – then the definition only
  /// describes the attribute); [addValues]/[removeValues] change single
  /// ones (not combinable with [values]); [remove] takes nothing else.
  /// Values are exact, non-blank, without control characters, at most
  /// 128 characters, at most 64 per attribute; duplicates collapse with a
  /// warning.
  ///
  /// Never touches a fact. The result reports how many CURRENT facts of
  /// the attribute do not conform to the new set (`nonConformingCurrent`,
  /// up to 20 `nonConformingExamples`) and warns when a removed value is
  /// still the current value of a fact. One lending, one write
  /// transaction. Result: `{attribute, action, description, values,
  /// valuesAdded, valuesRemoved, nonConformingCurrent,
  /// nonConformingExamples, warning?}`.
  Future<Map<String, Object?>> attributeDefine({
    required String attribute,
    String? description,
    List<String>? values,
    List<String>? addValues,
    List<String>? removeValues,
    bool remove = false,
  }) async {
    if (attribute.trim().isEmpty) {
      throw ValidationException('attribute_define: attribute is required.');
    }
    MemoryService._requireLen('attribute', attribute, _attributeMaxLen);
    _requireNoControlChars('attribute', attribute);
    if (remove &&
        (description != null ||
            values != null ||
            addValues != null ||
            removeValues != null)) {
      throw ValidationException(
        'attribute_define: "remove" deletes the whole definition – pass it '
        'without description or values.',
      );
    }
    if (values != null && (addValues != null || removeValues != null)) {
      throw ValidationException(
        'attribute_define: pass either "values" (replaces the whole set) or '
        '"addValues"/"removeValues" (change single values), not both.',
      );
    }
    if (description != null) {
      MemoryService._requireLen(
        'description',
        description,
        _registryDescriptionMaxLen,
      );
      if (description.trim().isEmpty) {
        throw ValidationException(
          'attribute_define: description must not be blank (one sentence: '
          'what the attribute records).',
        );
      }
    }
    final replaceArg = values == null
        ? null
        : _normalizeValueArgs('values', values);
    final addArg = addValues == null
        ? null
        : _normalizeValueArgs('addValues', addValues);
    final removeArg = removeValues == null
        ? null
        : _normalizeValueArgs('removeValues', removeValues);
    final both = [
      for (final v in addArg?.values ?? const <String>[])
        if (removeArg?.values.contains(v) ?? false)
          '"${MemoryService.sanitizeForLog(v)}"',
    ];
    if (both.isNotEmpty) {
      throw ValidationException(
        'attribute_define: ${both.join(', ')} appear in both "addValues" '
        'and "removeValues".',
      );
    }
    final shown = MemoryService.sanitizeForLog(attribute);

    return _withSession('attribute_define', () {
      return store.runInTransaction(TxMode.write, () {
        final now = DateTime.now().toUtc();
        final warnings = <String>[
          ...?replaceArg?.warnings,
          ...?addArg?.warnings,
          ...?removeArg?.warnings,
        ];
        final existing = _attributeDefinitionFor(attribute);
        final current = existing == null
            ? const <AttributeValue>[]
            : _attributeValuesOf(attribute);

        Map<String, Object?> finish(
          String action,
          List<String> added,
          List<String> removed,
        ) {
          final def = _attributeDefinitionFor(attribute);
          final finalValues = def == null
              ? const <String>[]
              : [for (final v in _attributeValuesOf(attribute)) v.value];
          final allowed = finalValues.toSet();
          var nonConforming = 0;
          final examples = <Map<String, Object?>>[];
          final stillCurrent = <String, int>{};
          _pageCurrentFactsOf(attribute, now, (page) {
            for (final f in page) {
              if (f.valueType == FactValueType.text &&
                  removed.contains(f.valueText)) {
                stillCurrent[f.valueText] = (stillCurrent[f.valueText] ?? 0) + 1;
              }
              if (def == null || _factConforms(f, allowed)) continue;
              nonConforming++;
              if (examples.length < _nonConformingExampleMax) {
                examples.add({
                  'id': f.id,
                  'project': f.project,
                  'subject': f.subject,
                  'value': _factValue(f),
                });
              }
            }
          });
          // Only while the attribute still restricts its values: after
          // remove: true or an empty value set every value is accepted.
          for (final e in finalValues.isEmpty
              ? const <MapEntry<String, int>>[]
              : stillCurrent.entries) {
            warnings.add(
              '"${MemoryService.sanitizeForLog(e.key)}" is still the current '
              'value of ${e.value} fact(s) of "$shown" – they keep it; '
              'fact_set no longer accepts it in strict registry mode.',
            );
          }
          if (nonConforming > examples.length) {
            log(
              '[memory] attribute_define "$shown": $nonConforming '
              'non-conforming current fact(s), ${examples.length} shown as '
              'examples',
            );
          }
          log(
            '[memory] attribute_define "$shown": action=$action '
            'values=${finalValues.length} added=${added.length} '
            'removed=${removed.length} nonConformingCurrent=$nonConforming',
          );
          final result = <String, Object?>{
            'attribute': attribute,
            'action': action,
            'description': def?.description,
            'values': finalValues,
            'valuesAdded': added,
            'valuesRemoved': removed,
            'nonConformingCurrent': nonConforming,
            'nonConformingExamples': examples,
            if (warnings.isNotEmpty) 'warning': warnings.join(' '),
          };
          return _applyGuardPeerWarning(result);
        }

        if (remove) {
          if (existing == null) {
            warnings.add('"$shown" is not registered – nothing removed.');
            log('[memory] attribute_define: "$shown" is not registered – '
                'nothing removed');
            return finish('unchanged', const [], const []);
          }
          for (final v in current) {
            _attrValues.remove(v.id);
          }
          _attrDefs.remove(existing.id);
          log(
            '[memory] attribute_define: removed "$shown" (id ${existing.id}) '
            'and its ${current.length} value(s)',
          );
          return finish('removed', const [], [for (final v in current) v.value]);
        }

        var action = 'unchanged';
        if (existing == null) {
          if (description == null) {
            throw ValidationException(
              'attribute_define: "$shown" is not registered yet – a '
              'description is required (one sentence: what the attribute '
              'records).',
            );
          }
          final variants = _attributeVariantsOf(attribute);
          if (variants.isNotEmpty) {
            warnings.add(
              '"$shown" differs from the registered attribute(s) '
              '${variants.map((v) => '"${MemoryService.sanitizeForLog(v)}"').join(', ')} '
              'only by case/space/-/_ – registered anyway.',
            );
          }
          final def = AttributeDefinition(
            name: attribute,
            description: description,
          );
          def.id = _attrDefs.put(def);
          action = 'created';
          log('[memory] attribute_define: registered "$shown" (id ${def.id})');
        } else if (description != null &&
            description != existing.description) {
          existing
            ..description = description
            ..updatedAt = now;
          _attrDefs.put(existing);
          action = 'updated';
          log('[memory] attribute_define: updated the description of '
              '"$shown"');
        }

        // The target value list, in display order.
        final have = [for (final v in current) v.value];
        final List<String> target;
        if (replaceArg != null) {
          target = replaceArg.values;
        } else {
          target = [...have];
          for (final v in removeArg?.values ?? const <String>[]) {
            if (!target.remove(v)) {
              warnings.add(
                '"${MemoryService.sanitizeForLog(v)}" is not an allowed value '
                'of "$shown" – nothing removed.',
              );
            }
          }
          for (final v in addArg?.values ?? const <String>[]) {
            if (target.contains(v)) {
              warnings.add(
                '"${MemoryService.sanitizeForLog(v)}" is already an allowed '
                'value of "$shown".',
              );
              continue;
            }
            target.add(v);
          }
        }
        if (target.length > _attributeValueMaxCount) {
          throw ValidationException(
            'attribute_define: "$shown" would have ${target.length} values, '
            'exceeding the $_attributeValueMaxCount value limit. Nothing was '
            'written.',
          );
        }
        final removed = [
          for (final v in have)
            if (!target.contains(v)) v,
        ];
        final added = [
          for (final v in target)
            if (!have.contains(v)) v,
        ];
        var reordered = false;
        for (final v in current) {
          if (!target.contains(v.value)) {
            _attrValues.remove(v.id);
            log(
              '[memory] attribute_define: removed value '
              '"${MemoryService.sanitizeForLog(v.value)}" of "$shown"',
            );
          }
        }
        for (var i = 0; i < target.length; i++) {
          final v = target[i];
          final row = current.where((c) => c.value == v).firstOrNull;
          if (row == null) {
            final created = AttributeValue(
              key: AttributeValue.keyFor(attribute, v),
              attribute: attribute,
              value: v,
              position: i,
            );
            created.id = _attrValues.put(created);
            log(
              '[memory] attribute_define: added value '
              '"${MemoryService.sanitizeForLog(v)}" of "$shown" '
              '(id ${created.id})',
            );
          } else if (row.position != i) {
            row.position = i;
            _attrValues.put(row);
            reordered = true;
          }
        }
        if (action == 'unchanged' &&
            (added.isNotEmpty || removed.isNotEmpty || reordered)) {
          action = 'updated';
        }
        return finish(action, added, removed);
      });
    });
  }

  // ---------------------------------------------------------------------
  // attributes_list
  // ---------------------------------------------------------------------

  /// Every registered attribute (or only [attribute]) with its description,
  /// its allowed values with the number of current facts holding each
  /// (`current`), and `nonConformingCurrent` – current facts of the
  /// attribute whose value is not allowed. One read transaction;
  /// registry-scale page-throughs plus one paged pass over each
  /// attribute's current facts.
  Future<Map<String, Object?>> attributesList({String? attribute}) {
    if (attribute != null) {
      MemoryService._requireLen('attribute', attribute, _attributeMaxLen);
    }
    return _withSession('attributes_list', () {
      return store.runInTransaction(TxMode.read, () {
        final now = DateTime.now().toUtc();
        final defs = <AttributeDefinition>[];
        if (attribute != null) {
          final def = _attributeDefinitionFor(attribute);
          if (def != null) defs.add(def);
        } else {
          _pageThrough<AttributeDefinition>(
            _attrDefs.query(),
            defs.addAll,
          );
        }
        defs.sort((a, b) => a.name.compareTo(b.name));
        final rows = <Map<String, Object?>>[];
        for (final def in defs) {
          final values = _attributeValuesOf(def.name);
          final allowed = {for (final v in values) v.value};
          final currentByValue = <String, int>{};
          var nonConforming = 0;
          _pageCurrentFactsOf(def.name, now, (page) {
            for (final f in page) {
              if (f.valueType == FactValueType.text) {
                currentByValue[f.valueText] =
                    (currentByValue[f.valueText] ?? 0) + 1;
              }
              if (!_factConforms(f, allowed)) nonConforming++;
            }
          });
          rows.add({
            'attribute': def.name,
            'description': def.description,
            'values': [
              for (final v in values)
                {'value': v.value, 'current': currentByValue[v.value] ?? 0},
            ],
            'nonConformingCurrent': nonConforming,
          });
        }
        final result = <String, Object?>{
          'registryMode': registryMode.name,
          'attributes': rows,
        };
        if (attribute != null && rows.isEmpty) {
          final shown = MemoryService.sanitizeForLog(attribute);
          result['warning'] = 'attribute "$shown" is not registered.';
          log('[memory] attributes_list: attribute "$shown" is not '
              'registered');
        }
        return result;
      });
    });
  }
}
