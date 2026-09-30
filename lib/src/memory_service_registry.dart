/// Areas/projects registry primitives – 2026-09-21, areas and facts
/// (0.3.0).
///
/// This file implements these FOR REAL, not as stubs: every other part of
/// the feature needs them, so they cannot wait behind `UnimplementedError`.
/// Everything in this file runs INSIDE a caller's existing
/// [MemoryService._withSession] lending and (for the primitives documented
/// as such) an existing write transaction – none of it opens its own
/// lending, per store_gate.dart's INVARIANT (no entity crosses a lending
/// boundary) and F15 (nested `withStore` is rejected, not deadlocking).
part of 'memory_service.dart';

/// Cap for [Area.name] (mirrors the `areaNameMaxLen` cap server.dart's
/// tool-schema layer exposes – defined here, not there, since this is what
/// actually enforces it first).
const int _areaNameMaxLen = 64;

/// Cap for [ProjectScope.description] / [Area.description].
const int _registryDescriptionMaxLen = 1024;

/// C0/C1 control characters (incl. DEL, 0x7F) – rejected in area names and
/// (by memory_service_facts.dart) in `subject`/`attribute`. This range includes
/// [kFactKeySep] (U+001F), which is exactly the point: no caller-supplied
/// value that becomes part of a synthetic composite key may contain the
/// separator itself.
final RegExp _controlCharPattern = RegExp('[\\x00-\\x1F\\x7F]');

/// Shared by memory_service_registry.dart (area names) and, later,
/// memory_service_facts.dart (subject/attribute) – one place, not
/// duplicated (CLAUDE.md "No duplicated logic").
void _requireNoControlChars(String field, String value) {
  if (_controlCharPattern.hasMatch(value)) {
    throw ValidationException(
      '$field must not contain control characters (this also blocks the '
      'internal key separator U+001F, so a caller cannot forge a composite '
      'key): '
      '"${MemoryService.sanitizeForLog(MemoryService._truncateForError(value))}".',
    );
  }
}

/// Registry project-name validation: identical to what
/// `remember`'s own `_requireProject` + the `projectMaxLen` cap already
/// accept – deliberately NEVER stricter. No trimming (a legacy " acme"
/// would register as a DIFFERENT name than "acme" if trimmed here, and
/// exact-name area resolution would then silently never match its
/// existing entries) and no control-character rejection (`remember`
/// doesn't reject them either, and this registry must not start rejecting
/// project strings `remember` accepts today).
String _requireRegistryProjectName(String? name) {
  final validated = MemoryService._requireProject(name);
  MemoryService._requireLen('project', validated, MemoryService.projectMaxLen);
  return validated;
}

/// Area-name validation. Unlike project names, area names are a NEW
/// surface (only `area_set`/`project_set` ever write them) with no
/// existing lax caller to stay compatible with, so this is deliberately
/// stricter: non-blank, no leading/trailing whitespace (REJECTED, not
/// silently trimmed – contract §8's "never silently truncate" extends to
/// "never silently reshape" caller input), length-capped, and
/// control-character-free (also blocks [kFactKeySep] – see
/// [_requireNoControlChars]).
void _requireAreaName(String name) {
  if (name.trim().isEmpty) {
    throw ValidationException('Area name must not be blank.');
  }
  if (name != name.trim()) {
    throw ValidationException(
      'Area name must not have leading/trailing whitespace: '
      '"${MemoryService.sanitizeForLog(name)}".',
    );
  }
  MemoryService._requireLen('name', name, _areaNameMaxLen);
  _requireNoControlChars('area name', name);
}

/// Project status a caller may set directly via [MemoryServiceRegistry.
/// projectSet]. [ProjectStatus.merged] is deliberately excluded: that
/// status (plus [ProjectScope.mergedInto]) is set ONLY by `project_merge`
/// – allowing `project_set` to also set it would let two different
/// write paths race to decide what "merged" means for a row, exactly the
/// kind of duplicated-invariant-owner this repo's incident history warns
/// against.
void _requireSettableProjectStatus(String status) {
  if (status == ProjectStatus.merged) {
    throw ValidationException(
      'project_set cannot set status to "${ProjectStatus.merged}" '
      'directly – that status (and mergedInto) is set only by '
      'project_merge.',
    );
  }
  if (!ProjectStatus.isValid(status)) {
    throw ValidationException(
      'Unknown status "${MemoryService._truncateForError(status)}". Valid: '
      '${ProjectStatus.active}, ${ProjectStatus.archived}.',
    );
  }
}

extension MemoryServiceRegistry on MemoryService {
  // ---------------------------------------------------------------------
  // Shared read/write primitives – called by every other part file's
  // extensions too, from inside THEIR OWN write tx/lending. Resolution
  // works because all part files of memory_service.dart share one
  // library scope: an extension method declared here is visible,
  // unqualified, from any other extension on MemoryService anywhere in
  // this library – no import needed.
  // ---------------------------------------------------------------------

  /// MUST run inside an existing write transaction AND `StoreGate` lending
  /// – never opens its own (F15; called by `remember`/`supersede`,
  /// `fact_set` and `projectSet`/`projectMerge` from
  /// inside their own single write tx). Query-first by EXACT (case-
  /// sensitive) name; creates the row if missing, logged either way.
  ///
  /// If a row already exists with [ProjectStatus.merged], the caller is
  /// writing under a name that was folded into another one – this does
  /// NOT redirect or reject the write (no alias), it just
  /// surfaces a warning naming `mergedInto` so the caller can decide.
  ({ProjectScope scope, List<String> warnings, bool created})
  _ensureProjectScope(String name, {required String reason}) {
    final existing = _useQuery(
      _projects.query(ProjectScope_.name.equals(name, caseSensitive: true)),
      (q) => q.findFirst(),
    );
    if (existing != null) {
      final warnings = <String>[];
      if (existing.status == ProjectStatus.merged &&
          existing.mergedInto.isNotEmpty) {
        warnings.add(
          'project "${MemoryService.sanitizeForLog(name)}" was merged into '
          '"${MemoryService.sanitizeForLog(existing.mergedInto)}" – the '
          'write still succeeded under the old name; consider using '
          '"${MemoryService.sanitizeForLog(existing.mergedInto)}" instead.',
        );
      }
      return (scope: existing, warnings: warnings, created: false);
    }
    final scope = ProjectScope(name: name, nameKey: ScopeKey.of(name));
    scope.id = _projects.put(scope);
    log(
      '[memory] registered project "${MemoryService.sanitizeForLog(name)}" '
      '(id ${scope.id}, reason: $reason)',
    );
    return (scope: scope, warnings: const [], created: true);
  }

  /// Read. Registered project names whose [ScopeKey] equals
  /// `ScopeKey.of(name)` but whose exact name differs from [name] –
  /// candidates for `project_merge`. Must be called from
  /// inside an existing lending; opens no session of its own.
  List<String> _nearDuplicateProjects(String name) {
    final key = ScopeKey.of(name);
    if (key.isEmpty) return const [];
    final matches = _useQuery(
      _projects.query(ProjectScope_.nameKey.equals(key)),
      (q) => q.find(),
    );
    return matches
        .where((p) => p.name != name)
        .map((p) => p.name)
        .toList(growable: false);
  }

  /// Read. Area names whose [ScopeKey] equals `ScopeKey.of(name)` but
  /// whose exact name differs from [name], excluding the row with
  /// [ownId] itself (the row just created/updated, if any). Used by
  /// [areaSet] for the same near-duplicate warning `remember`/`fact_set`
  /// get for projects (the case-sensitive-exact-plus-warning rule
  /// applies to area names too).
  List<String> _nearDuplicateAreas(String name, {int? ownId}) {
    final key = ScopeKey.of(name);
    if (key.isEmpty) return const [];
    final matches = _useQuery(
      _areas.query(Area_.nameKey.equals(key)),
      (q) => q.find(),
    );
    return matches
        .where((a) => a.id != ownId && a.name != name)
        .map((a) => a.name)
        .toList(growable: false);
  }

  /// Read. `true` iff an [Area] row with this EXACT (case-sensitive) name
  /// exists. Small helper shared by [_resolveAreaProjects] and
  /// [projectSet]'s unknown-area check – no duplicated query.
  bool _areaExists(String name) =>
      _useQuery(
        _areas.query(Area_.name.equals(name, caseSensitive: true)),
        (q) => q.count(),
      ) >
      0;

  /// Read. Distinct, exact (case-sensitive) project strings referenced by
  /// [MemoryEntry.project] and, when [includeFacts] is true (the
  /// default), also [Fact.project] – the shared "which project names are
  /// actually in use" primitive shared by `backfillProjectRegistry`,
  /// `areasList` and `stats` (integration follow-up, 2026-09-21, areas
  /// and facts (0.3.0): those had each grown their own copy of this
  /// exact query while working in parallel – folded into one here per
  /// CLAUDE.md "No duplicated logic").
  ///
  /// Blanks (`''`) are returned as-is, not filtered – callers that treat
  /// a blank project string specially (e.g. `blankProjectEntries`) do
  /// that themselves; this primitive only answers "what distinct strings
  /// are on these rows". F3: distinct string projections default to
  /// case-INsensitive, so `distinct`/`caseSensitive` are always set
  /// explicitly here (belt-and-braces; the store itself already defaults
  /// case-sensitive).
  Set<String> _distinctUsedProjects({bool includeFacts = true}) {
    final fromEntries = _useQuery(_entries.query(), (q) {
      final prop = q.property(MemoryEntry_.project)
        ..distinct = true
        ..caseSensitive = true;
      try {
        return prop.find();
      } finally {
        prop.close();
      }
    });
    if (!includeFacts) return fromEntries.toSet();
    final fromFacts = _useQuery(_facts.query(), (q) {
      final prop = q.property(Fact_.project)
        ..distinct = true
        ..caseSensitive = true;
      try {
        return prop.find();
      } finally {
        prop.close();
      }
    });
    return {...fromEntries, ...fromFacts};
  }

  /// Read. Count of [MemoryEntry] rows whose `project` is blank per
  /// [MemoryService._isBlankProject] (the same "blank" rule `remember`'s
  /// own project check uses – one predicate, not a second copy that could
  /// drift, so a legacy whitespace-only project name is judged the same
  /// way everywhere it matters: reported as "unregistered", listed,
  /// counted, or silently registered). Bounded: one `equals()` count()
  /// query per distinct blank-ish project string actually used
  /// (registry-scale), never a box-wide scan.
  int _countBlankProjectEntries() {
    var total = 0;
    for (final name in _distinctUsedProjects(includeFacts: false)) {
      if (!MemoryService._isBlankProject(name)) continue;
      total += _useQuery(
        _entries.query(MemoryEntry_.project.equals(name, caseSensitive: true)),
        (q) => q.count(),
      );
    }
    return total;
  }

  /// Read. Exact, case-sensitive project names that belong to [area] via
  /// [AreaMembership], excluding projects whose [ProjectScope.status] is
  /// [ProjectStatus.merged] (their entries were moved by `project_merge`).
  /// Throws [ValidationException] if no [Area] row named [area] exists.
  /// Returns an empty list (never throws) for a real area with zero
  /// memberships, and returns early – without any merged-status follow-up
  /// query – when there is nothing to filter (never build an `oneOf([])`
  /// over an empty list).
  ///
  /// Property projection only: no [AreaMembership] or [ProjectScope]
  /// entity is ever hydrated here.
  ///
  /// Shared by `areasList`, `projectMerge`'s callers and
  /// `recall`/`listRecent`/`stats`/`fact_query`'s `area` filter – one
  /// place decides "which projects does this area contain, excluding
  /// merged ones", not several copies that could drift apart.
  List<String> _resolveAreaProjects(String area) {
    if (!_areaExists(area)) {
      throw ValidationException(
        'Unknown area '
        '"${MemoryService.sanitizeForLog(MemoryService._truncateForError(area))}". '
        'Use area_set to create it first.',
      );
    }
    final projectNames = _useQuery(
      _memberships.query(
        AreaMembership_.area.equals(area, caseSensitive: true),
      ),
      (q) {
        final prop = q.property(AreaMembership_.project)
          ..distinct = true
          ..caseSensitive = true;
        try {
          return prop.find();
        } finally {
          prop.close();
        }
      },
    );
    if (projectNames.isEmpty) return const [];
    final mergedNames = _useQuery(
      _projects.query(
        ProjectScope_.status.equals(ProjectStatus.merged) &
            ProjectScope_.name.oneOf(projectNames, caseSensitive: true),
      ),
      (q) {
        final prop = q.property(ProjectScope_.name)
          ..distinct = true
          ..caseSensitive = true;
        try {
          return prop.find();
        } finally {
          prop.close();
        }
      },
    );
    if (mergedNames.isEmpty) return projectNames;
    // A project can hold a live area-membership row while its registry
    // status is already `merged` (e.g. a row surviving from before a
    // project_merge). Excluding it here without a log line would make it
    // silently vanish from every area result with nothing explaining why
    // (contract: no silent failure/exclusion paths) – one line per call,
    // naming exactly which names were excluded and where their data went.
    log(
      '[memory] _resolveAreaProjects("${MemoryService.sanitizeForLog(area)}"): '
      'excluded ${mergedNames.length} merged project(s) '
      '${mergedNames.map((n) => '"${MemoryService.sanitizeForLog(n)}"').join(', ')} '
      '– their entries/facts already moved to another name via '
      'project_merge.',
    );
    final mergedSet = mergedNames.toSet();
    return projectNames
        .where((p) => !mergedSet.contains(p))
        .toList(growable: false);
  }

  /// Read. Every non-retracted [Fact] row for [key], whatever its own
  /// `validFrom`/`validUntil` – not only the open chain head. `factSet`
  /// is the single writer that owns the invariant "this key's
  /// non-retracted rows' `[validFrom, validUntil)` intervals never
  /// overlap", so it needs every row that could possibly overlap the
  /// write it is about to make, including one already closed at a FUTURE
  /// date (a scheduled replacement, or a `fact_forget` given a future
  /// `validUntil`) – restricting this to the open head alone (as an earlier
  /// version did) made such a row invisible to the write path, which then
  /// treated the key as having no current row at all and started a
  /// second, parallel chain instead of extending the one already there.
  /// Judging whether a row has started yet (`validFrom <= now`) is a READ
  /// concern ([_factValidAtCondition], memory_service_facts.dart), not
  /// this primitive's job.
  List<Fact> _nonRetractedFactsForKey(String key) {
    return _useQuery(
      _facts.query(Fact_.factKey.equals(key) & Fact_.retractedAt.isNull()),
      (q) => q.find(),
    );
  }

  // ---------------------------------------------------------------------
  // Public tools – the "minimal working core" this file owns:
  // areaSet in full, and projectSet's assign/unassign-areas + describe +
  // archive core (merge itself is memory_service_areas.dart's
  // projectMerge).
  // ---------------------------------------------------------------------

  /// Creates or updates an [Area] row. One write tx, one lending. Result:
  /// `{id, name, action: created|updated|unchanged, warning?}`.
  Future<Map<String, Object?>> areaSet({
    required String name,
    String? description,
  }) async {
    _requireAreaName(name);
    if (description != null) {
      MemoryService._requireLen(
        'description',
        description,
        _registryDescriptionMaxLen,
      );
    }
    return _withSession('area_set', () {
      return store.runInTransaction(TxMode.write, () {
        final existing = _useQuery(
          _areas.query(Area_.name.equals(name, caseSensitive: true)),
          (q) => q.findFirst(),
        );
        final Area area;
        final String action;
        if (existing != null) {
          final newDescription = description ?? existing.description;
          final changed = newDescription != existing.description;
          // Only write (and only bump updatedAt) when something actually
          // changed – writing and bumping updatedAt unconditionally would
          // both generate needless sync traffic AND make "unchanged" a
          // lie (the row's updatedAt would change even though the action
          // label said otherwise).
          if (changed) {
            existing.description = newDescription;
            existing.updatedAt = DateTime.now().toUtc();
            _areas.put(existing);
          }
          area = existing;
          action = changed ? 'updated' : 'unchanged';
          log(
            '[memory] area_set "${MemoryService.sanitizeForLog(name)}" -> '
            '$action (id ${area.id})',
          );
        } else {
          final created = Area(
            name: name,
            nameKey: ScopeKey.of(name),
            description: description ?? '',
          );
          created.id = _areas.put(created);
          area = created;
          action = 'created';
          log(
            '[memory] area_set created area '
            '"${MemoryService.sanitizeForLog(name)}" (id ${area.id})',
          );
        }
        final result = <String, Object?>{
          'id': area.id,
          'name': area.name,
          'action': action,
        };
        final dupes = _nearDuplicateAreas(name, ownId: area.id);
        if (dupes.isNotEmpty) {
          result['warning'] =
              'area "${MemoryService.sanitizeForLog(name)}" differs from '
              'existing ${dupes.map((n) => '"${MemoryService.sanitizeForLog(n)}"').join(', ')} '
              'only by case/space/-/_; consider using the existing name or '
              'merging them by hand (no automatic area merge in v1).';
        }
        return _applyGuardPeerWarning(result);
      });
    });
  }

  /// Query-or-create a [ProjectScope] row and apply the requested changes
  /// (description, status – never `merged`, see
  /// [_requireSettableProjectStatus] – and area assignment) in one write
  /// tx. Unknown area names in [addAreas]/[removeAreas] are REJECTED
  /// (never auto-created – typo protection). Result:
  /// `{id, name, status, areas, added, removed, action, warning?}`.
  Future<Map<String, Object?>> projectSet({
    required String name,
    String? description,
    List<String> addAreas = const [],
    List<String> removeAreas = const [],
    String? status,
  }) async {
    final validatedName = _requireRegistryProjectName(name);
    if (description != null) {
      MemoryService._requireLen(
        'description',
        description,
        _registryDescriptionMaxLen,
      );
    }
    if (status != null) _requireSettableProjectStatus(status);
    for (final a in {...addAreas, ...removeAreas}) {
      _requireAreaName(a);
    }
    return _withSession('project_set', () {
      return store.runInTransaction(TxMode.write, () {
        // Validated BEFORE _ensureProjectScope below – that call both
        // creates AND logs a new registry row as a side effect. Running
        // this check after it would mean an unknown area throws here and
        // rolls back the whole write transaction (including the new row),
        // but the "registered project …" log line was already written and
        // is not rolled back with it – leaving a log claiming a
        // registration that never actually happened.
        final unknownAreas = {
          ...addAreas,
          ...removeAreas,
        }.where((a) => !_areaExists(a)).toList(growable: false);
        if (unknownAreas.isNotEmpty) {
          throw ValidationException(
            'project_set: unknown area(s) '
            '${unknownAreas.map((a) => '"${MemoryService.sanitizeForLog(a)}"').join(', ')}. '
            'Create with area_set first – project_set never auto-creates '
            'areas.',
          );
        }

        final ensured = _ensureProjectScope(
          validatedName,
          reason: 'project_set',
        );
        final scope = ensured.scope;
        final warnings = <String>[...ensured.warnings];

        // Same near-duplicate signal `remember`/`fact_set` surface –
        // exactly as relevant here: an operator explicitly registering
        // "Acme_App" while "acme-app" already exists should find out
        // immediately, not only the next time they `remember` something.
        final dupeProjects = _nearDuplicateProjects(validatedName);
        if (dupeProjects.isNotEmpty) {
          warnings.add(
            'project "${MemoryService.sanitizeForLog(validatedName)}" '
            'differs from existing '
            '${dupeProjects.map((n) => '"${MemoryService.sanitizeForLog(n)}"').join(', ')} '
            'only by case/space/-/_; use the existing name or run '
            'project_merge.',
          );
        }

        final added = <String>[];
        for (final a in addAreas) {
          final key = AreaMembership.keyFor(a, validatedName);
          final alreadyMember =
              _useQuery(
                _memberships.query(AreaMembership_.key.equals(key)),
                (q) => q.count(),
              ) >
              0;
          if (!alreadyMember) {
            _memberships.put(
              AreaMembership(key: key, area: a, project: validatedName),
            );
            added.add(a);
            log(
              '[memory] project_set: added '
              '"${MemoryService.sanitizeForLog(validatedName)}" to area '
              '"${MemoryService.sanitizeForLog(a)}"',
            );
          }
        }
        final removed = <String>[];
        for (final a in removeAreas) {
          final key = AreaMembership.keyFor(a, validatedName);
          final removedCount = _useQuery(
            _memberships.query(AreaMembership_.key.equals(key)),
            (q) => q.remove(),
          );
          if (removedCount > 0) {
            removed.add(a);
            log(
              '[memory] project_set: removed '
              '"${MemoryService.sanitizeForLog(validatedName)}" from area '
              '"${MemoryService.sanitizeForLog(a)}"',
            );
          }
        }

        // "action" is purely a reporting label with a fixed priority
        // (created > updated > unchanged) – a project can be newly
        // created AND have its description set AND gain area memberships
        // all in the SAME call, and "created" is the dominant fact about
        // that call regardless of what else it also did. Whether a
        // SECOND `_projects.put` is needed is decided separately, by
        // `fieldsChanged` – `_ensureProjectScope` already persisted the
        // bare row when it created one.
        var fieldsChanged = false;
        if (description != null && description != scope.description) {
          scope.description = description;
          fieldsChanged = true;
        }
        if (status != null && status != scope.status) {
          log(
            '[memory] project_set: "${MemoryService.sanitizeForLog(validatedName)}" '
            'status ${scope.status} -> $status',
          );
          // Leaving `merged` behind (the only way to reach this line
          // with scope.status == merged, since
          // _requireSettableProjectStatus already rejects `merged` as a
          // target) must clear the now-stale mergedInto pointer too – a
          // reactivated project that still claims to be merged into
          // another name is a contradictory row state that would hide
          // its data from area filters again.
          if (scope.status == ProjectStatus.merged) {
            scope.mergedInto = '';
          }
          scope.status = status;
          fieldsChanged = true;
        }
        if (fieldsChanged) {
          scope.updatedAt = DateTime.now().toUtc();
          _projects.put(scope);
        }
        final action = ensured.created
            ? 'created'
            : (fieldsChanged || added.isNotEmpty || removed.isNotEmpty
                  ? 'updated'
                  : 'unchanged');

        final hasEntries =
            _useQuery(
              _entries.query(
                MemoryEntry_.project.equals(validatedName, caseSensitive: true),
              ),
              (q) => q.count(),
            ) >
            0;
        final hasFacts =
            _useQuery(
              _facts.query(
                Fact_.project.equals(validatedName, caseSensitive: true),
              ),
              (q) => q.count(),
            ) >
            0;
        if (!hasEntries && !hasFacts) {
          warnings.add(
            'project "${MemoryService.sanitizeForLog(validatedName)}" has '
            'no entries or facts yet.',
          );
        }

        final currentAreas = _useQuery(
          _memberships.query(
            AreaMembership_.project.equals(validatedName, caseSensitive: true),
          ),
          (q) {
            final prop = q.property(AreaMembership_.area)
              ..distinct = true
              ..caseSensitive = true;
            try {
              return prop.find();
            } finally {
              prop.close();
            }
          },
        );

        final result = <String, Object?>{
          'id': scope.id,
          'name': scope.name,
          'status': scope.status,
          'areas': currentAreas,
          'added': added,
          'removed': removed,
          'action': action,
        };
        if (warnings.isNotEmpty) result['warning'] = warnings.join(' ');
        return _applyGuardPeerWarning(result);
      });
    });
  }
}
