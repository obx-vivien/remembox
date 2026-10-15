/// In-place edits of stored entries – 0.5.0: `entries_update` (kind and
/// tags of selected entries) and `kind_migrate` (marker tags -> kinds).
///
/// Both change only [MemoryEntry.kind] and the [MemoryEntry.tags]
/// relation. They never touch the text, [MemoryEntry.contentHash], the
/// title, the project, links, `supersededBy` or the vector index
/// ([MemoryIndex]): kind and tags are not part of the content hash or the
/// embedding, so an in-place edit never makes an index row stale (`reindex`
/// reports `reembedded: 0` afterwards). [Tag] rows are never deleted here –
/// a tag left without entries is reported as `tagsNowUnused`, for
/// `tag_remove`.
part of 'memory_service.dart';

/// One entry's planned change in [MemoryServiceEntries.entriesUpdate] /
/// `kind_migrate`, decided before anything is written.
class _EntryEdit {
  final MemoryEntry entry;
  final String? kindTo;
  final List<String> tagsAdded;
  final List<String> tagsRemoved;

  _EntryEdit(this.entry, {this.kindTo, this.tagsAdded = const [], this.tagsRemoved = const []});

  bool get changes =>
      kindTo != null || tagsAdded.isNotEmpty || tagsRemoved.isNotEmpty;
}

extension MemoryServiceEntries on MemoryService {
  /// Applies [edits] (unless [dryRun]) – kind via put, tags via the
  /// relation – logs one line per changed entry, and returns the tag
  /// names in [removedTagNames] that no entry carries any more afterwards
  /// (`tagsNowUnused`; for a dry run: would no longer carry). The Tag rows
  /// themselves stay. MUST run inside the caller's write (or, for a dry
  /// run, read) transaction.
  List<String> _applyEntryEdits(
    List<_EntryEdit> edits, {
    required bool dryRun,
    required String tool,
  }) {
    final removedFrom = <String, int>{};
    for (final edit in edits) {
      for (final name in edit.tagsRemoved) {
        removedFrom[name] = (removedFrom[name] ?? 0) + 1;
      }
    }
    // Carriers counted BEFORE writing, so a dry run and a real run agree.
    final carriers = <String, int>{
      for (final name in removedFrom.keys)
        name: _useQuery(
          _entries.query()..linkMany(
            MemoryEntry_.tags,
            Tag_.name.equals(name, caseSensitive: true),
          ),
          (q) => q.count(),
        ),
    };
    for (final edit in edits) {
      if (!edit.changes) continue;
      final e = edit.entry;
      final kindFrom = e.kind;
      if (!dryRun) {
        if (edit.tagsRemoved.isNotEmpty) {
          e.tags.removeWhere((t) => edit.tagsRemoved.contains(t.name));
        }
        for (final name in edit.tagsAdded) {
          e.tags.add(_getOrCreateTag(name));
        }
        if (edit.kindTo != null) {
          e.kind = edit.kindTo!;
          _entries.put(e);
        } else {
          e.tags.applyToDb();
        }
      }
      log(
        '[memory] $tool${dryRun ? ' (dry run)' : ''}: entry ${e.id}'
        '${edit.kindTo == null ? '' : ' kind $kindFrom -> ${edit.kindTo}'}'
        '${edit.tagsAdded.isEmpty ? '' : ' +tags ${edit.tagsAdded.map(MemoryService.sanitizeForLog).join(',')}'}'
        '${edit.tagsRemoved.isEmpty ? '' : ' -tags ${edit.tagsRemoved.map(MemoryService.sanitizeForLog).join(',')}'}',
      );
    }
    return [
      for (final e in removedFrom.entries)
        if (carriers[e.key]! - e.value <= 0) e.key,
    ]..sort();
  }

  /// One entry of an `entries_update` result.
  Map<String, Object?> _editSummary(
    _EntryEdit edit, {
    List<String> alreadyPresent = const [],
    List<String> notPresent = const [],
    required DateTime now,
  }) {
    final e = edit.entry;
    return {
      'id': e.id,
      'title': e.title,
      if (edit.kindTo != null) 'kindFrom': e.kind,
      'kindTo': ?edit.kindTo,
      'tagsAdded': edit.tagsAdded,
      'tagsRemoved': edit.tagsRemoved,
      'alreadyPresent': alreadyPresent,
      'notPresent': notPresent,
      if (e.isSuperseded) 'superseded': true,
      if (e.isExpiredAt(now)) 'expired': true,
    };
  }

  /// Joins per-entry warnings, each distinct text once, naming the entries
  /// it applies to.
  static String? _joinEntryWarnings(Map<String, List<int>> byText) {
    if (byText.isEmpty) return null;
    return [
      for (final e in byText.entries)
        e.value.length == 1
            ? '${e.key} (entry ${e.value.single})'
            : '${e.key} (entries ${e.value.join(', ')})',
    ].join(' ');
  }

  // ---------------------------------------------------------------------
  // entries_update
  // ---------------------------------------------------------------------

  /// Changes the kind and/or the tags of the entries [ids] IN PLACE – no
  /// new entry, no supersede. At least one of [kind], [addTags],
  /// [removeTags]; a tag in both lists is rejected.
  ///
  /// [ids]: 1..500, positive, no duplicates; an unknown id rejects the
  /// whole call naming every missing id. [kind] must be valid.
  /// [addTags] go through `_prepareTags` per entry – the same rules as on
  /// `remember` (normalization, aliases, retired tags, redundancy with the
  /// entry's project/kind/area, strict registration), with the entry's
  /// project and its NEW kind; the tags an entry already carries are not
  /// re-validated. More than [MemoryService._tagMaxCount] tags on one
  /// entry afterwards rejects the call. [removeTags] match a stored tag
  /// name exactly or its normalized form, also an unregistered or retired
  /// one (removing is always allowed); a [Tag] row left without entries
  /// stays and is listed in `tagsNowUnused`.
  ///
  /// Superseded and expired entries are updated too and flagged in the
  /// result. [dryRun] runs every check (strict rejections included) and
  /// reports the same result without writing. One lending, one
  /// transaction; any rejection leaves every entry unchanged. Result:
  /// `{dryRun, changed, unchanged, entries: [...], tagsNowUnused,
  /// warning?}`.
  Future<Map<String, Object?>> entriesUpdate({
    required List<int> ids,
    String? kind,
    List<String>? addTags,
    List<String>? removeTags,
    bool dryRun = false,
  }) async {
    const tool = 'entries_update';
    final validatedIds = _requireEntryIds(ids, tool: tool);
    if (kind != null) MemoryService._requireKind(kind);
    final adds = addTags ?? const <String>[];
    final removes = removeTags ?? const <String>[];
    if (kind == null && adds.isEmpty && removes.isEmpty) {
      throw ValidationException(
        '$tool: pass at least one of "kind", "addTags", "removeTags".',
      );
    }
    _requireArgLengths(tags: adds);
    _requireArgLengths(tags: removes);
    final both = <String>[];
    for (final a in adds) {
      final na = _normalizeTag(a);
      if (removes.any((r) => r == a || (na.isNotEmpty && _normalizeTag(r) == na))) {
        both.add('"${MemoryService.sanitizeForLog(a)}"');
      }
    }
    if (both.isNotEmpty) {
      throw ValidationException(
        '$tool: ${both.join(', ')} appear in both "addTags" and '
        '"removeTags".',
      );
    }

    return _withSession(tool, () {
      return store.runInTransaction(dryRun ? TxMode.read : TxMode.write, () {
        final now = DateTime.now().toUtc();
        final entries = _requireEntriesExist(
          validatedIds,
          tool: tool,
          nothing: 'nothing changed',
        );
        final warningsByText = <String, List<int>>{};
        final summaries = <Map<String, Object?>>[];
        final edits = <_EntryEdit>[];
        for (final e in entries) {
          final current = [for (final t in e.tags) t.name];
          final newKind = kind ?? e.kind;
          final tagsRemoved = <String>[];
          final notPresent = <String>[];
          // removeTags entry -> the stored spellings it matched.
          final matchedBy = <String, List<String>>{};
          for (final r in removes) {
            final nr = _normalizeTag(r);
            final matches = current
                .where((c) => c == r || (nr.isNotEmpty && c == nr))
                .toList();
            matchedBy[r] = matches;
            if (matches.isEmpty) {
              notPresent.add(r);
              continue;
            }
            for (final m in matches) {
              if (!tagsRemoved.contains(m)) tagsRemoved.add(m);
            }
          }
          final tagsAdded = <String>[];
          final alreadyPresent = <String>[];
          if (adds.isNotEmpty) {
            final prepared = _prepareTags(
              adds,
              project: e.project,
              kind: newKind,
              tool: tool,
              alreadyAttached: {
                for (final c in current)
                  if (!tagsRemoved.contains(c)) c,
              },
            );
            for (final w in prepared.warnings) {
              (warningsByText[w] ??= <int>[]).add(e.id);
            }
            // The overlap check above compares the raw/normalized names;
            // aliases resolve only in _prepareTags, so a resolved added tag
            // can still be one a removeTags entry names. Such a tag is
            // netted out – neither added nor removed – with a warning.
            for (final t in prepared.tags) {
              final conflicting = [
                for (final r in removes)
                  if (r == t || _normalizeTag(r) == t) r,
              ];
              if (conflicting.isNotEmpty) {
                // Every stored spelling those removeTags entries matched
                // (also an old unnormalized one, e.g. "my_tag") stays.
                for (final r in conflicting) {
                  for (final m in matchedBy[r]!) {
                    tagsRemoved.remove(m);
                  }
                  notPresent.remove(r);
                }
                final w =
                    'Tag "${MemoryService.sanitizeForLog(t)}" is both added '
                    '(after alias resolution) and removed – left as it is.';
                (warningsByText[w] ??= <int>[]).add(e.id);
                log('[memory] $tool: entry ${e.id}: $w');
                continue;
              }
              if (current.contains(t)) {
                alreadyPresent.add(t);
              } else if (!tagsAdded.contains(t)) {
                tagsAdded.add(t);
              }
            }
          }
          final after = current.length - tagsRemoved.length + tagsAdded.length;
          if (after > MemoryService._tagMaxCount) {
            throw ValidationException(
              '$tool: entry ${e.id} would carry $after tags, exceeding the '
              '${MemoryService._tagMaxCount} tag limit. Nothing was written.',
            );
          }
          final edit = _EntryEdit(
            e,
            kindTo: newKind == e.kind ? null : newKind,
            tagsAdded: tagsAdded,
            tagsRemoved: tagsRemoved,
          );
          edits.add(edit);
          summaries.add(
            _editSummary(
              edit,
              alreadyPresent: alreadyPresent,
              notPresent: notPresent,
              now: now,
            ),
          );
        }
        final tagsNowUnused = _applyEntryEdits(
          edits,
          dryRun: dryRun,
          tool: tool,
        );
        final changed = edits.where((e) => e.changes).length;
        log(
          '[memory] $tool${dryRun ? ' (dry run)' : ''}: '
          '${validatedIds.length} entr${validatedIds.length == 1 ? 'y' : 'ies'}, '
          'changed=$changed unchanged=${edits.length - changed} '
          'tagsNowUnused=${tagsNowUnused.length}',
        );
        final warning = _joinEntryWarnings(warningsByText);
        final result = <String, Object?>{
          'dryRun': dryRun,
          'changed': changed,
          'unchanged': edits.length - changed,
          'entries': summaries,
          'tagsNowUnused': tagsNowUnused,
          'warning': ?warning,
        };
        return dryRun ? result : _applyGuardPeerWarning(result);
      });
    });
  }
}

/// One rule of `kind_migrate` (0.5.0): entries carrying any of [tags]
/// (marker tags) move to [kind]. See [MemoryServiceEntries.kindMigrate].
class KindMigrationRule {
  /// The marker tags, matched by stored name or its normalized form.
  final List<String> tags;

  /// Target kind; null = only remove the markers.
  final String? kind;

  /// Kinds that convert to [kind] (default: the call's `fromKinds`).
  final List<String>? convertFrom;

  /// Kinds that keep their kind and only lose the marker.
  final List<String>? dropFrom;

  /// Also list the matching entries under `listed[<first tag>]`.
  final bool list;

  /// Leave the marker on the entries (only with [list] and without
  /// [kind]): list them for review without removing anything.
  final bool keep;

  const KindMigrationRule({
    required this.tags,
    this.kind,
    this.convertFrom,
    this.dropFrom,
    this.list = false,
    this.keep = false,
  });
}

/// At most this many rules per `kind_migrate` call.
const int _kindMigrateMaxRules = 20;

extension MemoryServiceKindMigrate on MemoryService {
  /// Moves marker tags to kinds in one pass (0.5.0): for every entry
  /// carrying a marker of a rule, IN PLACE – kind and tags only, like
  /// `entries_update`.
  ///
  /// Per entry and matched rule (rules in precedence order): a rule
  /// without kind drops the marker; an entry already of the rule's kind
  /// drops it; a kind in `convertFrom` (default [fromKinds], default
  /// `["fact", "episode"]`) converts; a kind in `dropFrom` drops the
  /// marker and keeps the kind; any other kind needs review; a rule with
  /// `keep: true` (only with `list: true` and no kind) lists its entries
  /// and leaves the marker. An entry
  /// with any review goes to `review` UNCHANGED (with a suggested kind and
  /// one reason per marker). Otherwise its kind becomes the first convert
  /// in precedence (later conflicting converts are reported as
  /// `overridden`) and every matched marker is removed, except those of
  /// `keep` rules.
  ///
  /// [scope] `all` (default) includes superseded and expired entries,
  /// `live` only the others; at most [_entriesMoveMaxTotalIds] entries may
  /// match, otherwise the call is rejected. `list: true` on a rule also
  /// lists its entries (with supersede state and links). `legacyLinks`
  /// always reports every parent/child link in the store (direction
  /// undefined – retype them with unlink + link). Rule tags that do not
  /// exist as a tag (neither as given nor normalized) are reported in
  /// `notFound`. Idempotent; [dryRun] reports
  /// the same without writing. One lending, one transaction; the result
  /// is complete, never truncated.
  Future<Map<String, Object?>> kindMigrate({
    required List<KindMigrationRule> rules,
    List<String>? fromKinds,
    String scope = 'all',
    bool dryRun = false,
  }) async {
    const tool = 'kind_migrate';
    if (rules.isEmpty) {
      throw ValidationException('$tool: "rules" must not be empty.');
    }
    if (rules.length > _kindMigrateMaxRules) {
      throw ValidationException(
        '$tool: ${rules.length} rules exceed the $_kindMigrateMaxRules rule '
        'limit.',
      );
    }
    if (scope != 'all' && scope != 'live') {
      throw ValidationException(
        '$tool: "scope" must be "all" or "live", got '
        '"${MemoryService._truncateForError(MemoryService.sanitizeForLog(scope))}".',
      );
    }
    final from = fromKinds ?? const [MemoryKind.fact, MemoryKind.episode];
    from.forEach(MemoryService._requireKind);
    final seenMarkers = <String, int>{};
    for (var i = 0; i < rules.length; i++) {
      final rule = rules[i];
      final n = i + 1;
      if (rule.tags.isEmpty) {
        throw ValidationException('$tool: rule $n has no tags.');
      }
      _requireArgLengths(tags: rule.tags);
      if (rule.kind != null) MemoryService._requireKind(rule.kind!);
      if (rule.kind == null &&
          (rule.convertFrom != null || rule.dropFrom != null)) {
        throw ValidationException(
          '$tool: rule $n has no kind – convertFrom/dropFrom need one (a '
          'rule without kind only removes its markers).',
        );
      }
      if (rule.keep && (rule.kind != null || !rule.list)) {
        throw ValidationException(
          '$tool: rule $n has keep: true – only valid together with list: '
          'true and without kind (it lists the marker for review and leaves '
          'it on the entries).',
        );
      }
      rule.convertFrom?.forEach(MemoryService._requireKind);
      rule.dropFrom?.forEach(MemoryService._requireKind);
      final outside = [
        for (final k in rule.convertFrom ?? const <String>[])
          if (!from.contains(k)) k,
      ];
      if (outside.isNotEmpty) {
        throw ValidationException(
          '$tool: rule $n converts from ${outside.join(', ')}, which is not '
          'in fromKinds (${from.join(', ')}).',
        );
      }
      // A kind may either convert or only lose the marker, never both –
      // convert is checked first, so an overlapping dropFrom kind would be
      // ignored without a word.
      final effectiveConvert = rule.convertFrom ?? from;
      final overlap = [
        for (final k in rule.dropFrom ?? const <String>[])
          if (effectiveConvert.contains(k)) k,
      ];
      if (overlap.isNotEmpty) {
        throw ValidationException(
          '$tool: rule $n lists ${overlap.join(', ')} in dropFrom, but '
          '${overlap.length == 1 ? 'it also converts' : 'they also convert'} '
          '(${rule.convertFrom == null ? 'convertFrom defaults to fromKinds' : 'convertFrom'}: '
          '${effectiveConvert.join(', ')}) – a kind either converts or only '
          'loses the marker. Pass convertFrom without '
          '${overlap.length == 1 ? 'it' : 'them'}. Nothing was written.',
        );
      }
      for (final t in rule.tags) {
        final key = _normalizeTag(t).isEmpty ? t : _normalizeTag(t);
        final earlier = seenMarkers[key];
        if (earlier != null && earlier != n) {
          throw ValidationException(
            '$tool: tag "${MemoryService.sanitizeForLog(t)}" appears in rule '
            '$earlier and rule $n – a tag belongs to one rule only.',
          );
        }
        seenMarkers[key] = n;
      }
    }

    return _withSession(tool, () {
      return store.runInTransaction(dryRun ? TxMode.read : TxMode.write, () {
        final now = DateTime.now().toUtc();
        Condition<MemoryEntry>? scopeCondition;
        if (scope == 'live') {
          scopeCondition =
              MemoryEntry_.supersededBy.equals(0) &
              (MemoryEntry_.expiresAt.isNull() |
                  MemoryEntry_.expiresAt.greaterThanDate(now));
        }

        // Which stored tag names each rule tag matches, and the entries
        // carrying them.
        final notFound = <String>[];
        final candidateIds = <int>{};
        for (final rule in rules) {
          for (final t in rule.tags) {
            final names = {t, if (_normalizeTag(t).isNotEmpty) _normalizeTag(t)};
            var found = false;
            for (final name in names) {
              final tagRow = _useQuery(
                _tags.query(Tag_.name.equals(name, caseSensitive: true)),
                (q) => q.findFirst(),
              );
              if (tagRow == null) continue;
              found = true;
              final builder = scopeCondition == null
                  ? _entries.query()
                  : _entries.query(scopeCondition);
              builder.linkMany(
                MemoryEntry_.tags,
                Tag_.name.equals(name, caseSensitive: true),
              );
              candidateIds.addAll(_useQuery(builder, (q) => q.findIds()));
            }
            if (!found) notFound.add(t);
          }
        }
        if (candidateIds.length > _entriesMoveMaxTotalIds) {
          throw ValidationException(
            '$tool: ${candidateIds.length} entries carry the rule tags, '
            'exceeding the $_entriesMoveMaxTotalIds entry limit of one call '
            '– split the rules or use scope "live". Nothing was written.',
          );
        }
        final ids = candidateIds.toList()..sort();
        final entries = _entries.getMany(ids).whereType<MemoryEntry>().toList();

        bool matches(String stored, String t) {
          final nt = _normalizeTag(t);
          return stored == t || (nt.isNotEmpty && stored == nt);
        }

        // Per rule, counted from what was APPLIED: converted (this rule set
        // the kind), markerRemoved (its marker removed without this rule
        // setting the kind – incl. overridden), overridden (its convert
        // lost to an earlier rule; a subset of markerRemoved), kept
        // (keep: true – listed, marker left), review (the entry carries
        // the rule's marker and went to review unchanged).
        final byRule = [
          for (final rule in rules)
            <String, Object?>{
              'tags': rule.tags,
              'kind': rule.kind,
              'matched': 0,
              'converted': 0,
              'markerRemoved': 0,
              'overridden': 0,
              'kept': 0,
              'review': 0,
            },
        ];
        void bump(int ruleIndex, String key) =>
            byRule[ruleIndex][key] = (byRule[ruleIndex][key]! as int) + 1;

        final converted = <Map<String, Object?>>[];
        final markerRemoved = <Map<String, Object?>>[];
        final review = <Map<String, Object?>>[];
        final listed = <String, Map<String, Object?>>{};
        final edits = <_EntryEdit>[];

        for (final e in entries) {
          final stored = [for (final t in e.tags) t.name];
          final matchedMarkers = <String>[];
          final removable = <String>[];
          final reasons = <String>[];
          // (rule index, decision) for every rule this entry matches.
          final decisions = <(int, String)>[];
          String? convertTo;
          int? convertRule;
          String? suggested;
          final overridden = <Map<String, Object?>>[];
          var needsReview = false;
          for (var i = 0; i < rules.length; i++) {
            final rule = rules[i];
            final markers = [
              for (final s in stored)
                if (rule.tags.any((t) => matches(s, t))) s,
            ];
            if (markers.isEmpty) continue;
            bump(i, 'matched');
            matchedMarkers.addAll(markers.where((m) => !matchedMarkers.contains(m)));
            if (!rule.keep) {
              removable.addAll(markers.where((m) => !removable.contains(m)));
            }
            if (rule.list) {
              final group = listed.putIfAbsent(
                rule.tags.first,
                () => {'count': 0, 'superseded': 0, 'entries': <Object?>[]},
              );
              group['count'] = (group['count']! as int) + 1;
              if (e.isSuperseded) {
                group['superseded'] = (group['superseded']! as int) + 1;
              }
              (group['entries']! as List<Object?>).add({
                'id': e.id,
                'title': e.title,
                'kind': e.kind,
                'project': e.project,
                'supersededBy': e.isSuperseded ? e.supersededBy.targetId : null,
                'links': [
                  for (final l in _linksFor(e.id))
                    {
                      'type': l['type'],
                      'direction': l['direction'],
                      'otherId': l['otherId'],
                    },
                ],
              });
            }
            final kind = rule.kind;
            final String decision;
            if (rule.keep) {
              decision = 'keep';
            } else if (kind == null || e.kind == kind) {
              decision = 'drop';
            } else if ((rule.convertFrom ?? from).contains(e.kind)) {
              decision = 'convert';
            } else if ((rule.dropFrom ?? const <String>[]).contains(e.kind)) {
              decision = 'drop';
            } else {
              decision = 'review';
            }
            decisions.add((i, decision));
            if (decision == 'review') {
              needsReview = true;
              suggested ??= kind;
              for (final m in markers) {
                reasons.add(
                  '"${MemoryService.sanitizeForLog(m)}" does not convert kind '
                  '${e.kind} (not in convertFrom/dropFrom) – review.',
                );
              }
            } else if (decision == 'convert') {
              suggested ??= kind;
              if (convertTo == null) {
                convertTo = kind;
                convertRule = i;
              } else if (kind != convertTo) {
                overridden.add({'tags': rule.tags, 'kind': kind});
              }
            }
          }
          if (matchedMarkers.isEmpty) continue;
          if (needsReview) {
            for (final (i, _) in decisions) {
              bump(i, 'review');
            }
            review.add({
              'id': e.id,
              'title': e.title,
              'kind': e.kind,
              'markers': matchedMarkers,
              'suggestedKind': suggested,
              'reasons': reasons,
              if (e.isSuperseded) 'superseded': true,
            });
            continue;
          }
          for (final (i, decision) in decisions) {
            if (decision == 'keep') {
              bump(i, 'kept');
            } else if (i == convertRule) {
              bump(i, 'converted');
            } else {
              bump(i, 'markerRemoved');
              if (decision == 'convert' && rules[i].kind != convertTo) {
                bump(i, 'overridden');
              }
            }
          }
          // Only keep-rule markers: nothing to change on this entry.
          if (removable.isEmpty && convertTo == null) continue;
          final edit = _EntryEdit(
            e,
            kindTo: convertTo,
            tagsRemoved: removable,
          );
          edits.add(edit);
          if (convertTo != null) {
            converted.add({
              'id': e.id,
              'title': e.title,
              'kindFrom': e.kind,
              'kindTo': convertTo,
              'markersRemoved': removable,
              if (overridden.isNotEmpty) 'overridden': overridden,
              if (e.isSuperseded) 'superseded': true,
            });
          } else {
            markerRemoved.add({
              'id': e.id,
              'title': e.title,
              'kind': e.kind,
              'markersRemoved': removable,
              if (e.isSuperseded) 'superseded': true,
            });
          }
        }

        // Every parent/child link in the store (direction undefined).
        final legacyLinks = <Map<String, Object?>>[];
        _pageThrough<MemoryLink>(
          _links.query(
            MemoryLink_.linkType.oneOf(
              LinkType.legacy.toList(),
              caseSensitive: true,
            ),
          ),
          (page) {
            for (final l in page) {
              legacyLinks.add({
                'linkId': l.id,
                'type': l.linkType,
                'fromId': l.from.targetId,
                'toId': l.to.targetId,
              });
            }
          },
        );

        final tagsNowUnused = _applyEntryEdits(
          edits,
          dryRun: dryRun,
          tool: tool,
        );

        final warnings = <String>[];
        if (notFound.isNotEmpty) {
          warnings.add(
            'No tag named '
            '${notFound.map((t) => '"${MemoryService.sanitizeForLog(t)}"').join(', ')} '
            'exists (notFound).',
          );
        }
        if (review.isNotEmpty) {
          warnings.add(
            '${review.length} entr${review.length == 1 ? 'y needs' : 'ies need'} '
            'review and ${review.length == 1 ? 'was' : 'were'} left unchanged '
            '(see review) – fix them with entries_update, or extend '
            'convertFrom/dropFrom.',
          );
        }
        if (legacyLinks.isNotEmpty) {
          warnings.add(
            '${legacyLinks.length} parent/child link(s) have no defined '
            'direction (see legacyLinks) – re-create each with unlink and '
            'link(fromId: <the part>, toId: <the whole>, type: "partOf"), or '
            'another type.',
          );
        }
        log(
          '[memory] $tool${dryRun ? ' (dry run)' : ''}: scope=$scope '
          'examined=${entries.length} converted=${converted.length} '
          'markerRemoved=${markerRemoved.length} review=${review.length} '
          'legacyLinks=${legacyLinks.length} notFound=${notFound.length} '
          'tagsNowUnused=${tagsNowUnused.length}',
        );
        final result = <String, Object?>{
          'dryRun': dryRun,
          'scope': scope,
          'examined': entries.length,
          'byRule': byRule,
          'converted': converted,
          'markerRemoved': markerRemoved,
          'review': review,
          'listed': listed,
          'legacyLinks': legacyLinks,
          'notFound': notFound,
          'tagsNowUnused': tagsNowUnused,
          if (warnings.isNotEmpty) 'warning': warnings.join(' '),
        };
        return dryRun ? result : _applyGuardPeerWarning(result);
      });
    });
  }
}
