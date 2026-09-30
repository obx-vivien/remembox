/// Areas/projects tools `areasList`, `projectMerge` and
/// `backfillProjectRegistry` – 2026-09-21, areas and facts (0.3.0).
///
/// `areaSet`/`projectSet`'s core (assign/unassign areas, describe,
/// archive) lives in memory_service_registry.dart, not here – do not
/// redefine them in this file (an extension method name defined twice on
/// the same type in one library is a compile error, not a shadow).
part of 'memory_service.dart';

/// "Live" MemoryEntry condition shared by every per-project/per-area count
/// in [MemoryServiceAreas.areasList]: not superseded, and either never
/// expires or has not expired yet (same shape `stats()`/`recall()` already
/// use for `expiresAt`). Defined once here (this file's
/// only caller of it) rather than duplicated per call site.
Condition<MemoryEntry> _liveEntryCondition(String project, DateTime now) =>
    MemoryEntry_.project.equals(project, caseSensitive: true) &
    MemoryEntry_.supersededBy.equals(0) &
    (MemoryEntry_.expiresAt.isNull() |
        MemoryEntry_.expiresAt.greaterThanDate(now));

/// Cap on [MemoryServiceAreas.entriesMove]'s `ids` argument – 2026-09-21,
/// entries move (0.3.0). A hard, generous cap (like [MemoryService.
/// _tagMaxCount]'s shape) that rejects an absurd request outright rather
/// than silently truncating it (contract §8).
const int _entriesMoveMaxIds = 500;

/// Hard cap on entriesMove's TOTAL moved id count – the explicit `ids`
/// PLUS every id `includeChain` pulls in – 2026-09-21 review3 m2 fix.
/// [_entriesMoveMaxIds] only bounds the REQUESTED `ids`; a supersede
/// chain has no length limit of its own, so without this second cap
/// `includeChain` could walk an unbounded number of rows into one move.
/// Same "reject outright, never silently truncate" shape as
/// [_entriesMoveMaxIds] itself.
const int _entriesMoveMaxTotalIds = 2000;

/// Validates [MemoryServiceAreas.entriesMove]'s `ids` argument BEFORE the
/// lending – 2026-09-21, entries move (0.3.0): 1..[_entriesMoveMaxIds]
/// entries, each a positive integer (same "ids start at 1" rule
/// server.dart's `_requiredId` applies at the MCP layer – checked again
/// here since [MemoryServiceAreas.entriesMove] is a public service method,
/// reachable directly, not only through the tool layer), and no
/// duplicates (a caller-side mistake, not a legitimate double-move – a
/// duplicate would otherwise silently double-count in `moved`/
/// `fromProjects`).
List<int> _requireMoveIds(List<int> ids) {
  if (ids.isEmpty) {
    throw ValidationException('entries_move: "ids" must not be empty.');
  }
  if (ids.length > _entriesMoveMaxIds) {
    throw ValidationException(
      'entries_move: "ids" has ${ids.length} entries, exceeding the '
      '$_entriesMoveMaxIds id limit.',
    );
  }
  final seen = <int>{};
  final duplicates = <int>{};
  for (final id in ids) {
    if (id < 1) {
      throw ValidationException(
        'entries_move: id $id must be a positive integer (ids start at '
        '1).',
      );
    }
    if (!seen.add(id)) duplicates.add(id);
  }
  if (duplicates.isNotEmpty) {
    final sortedDuplicates = duplicates.toList()..sort();
    throw ValidationException(
      'entries_move: duplicate id(s) in "ids": '
      '${sortedDuplicates.join(', ')}.',
    );
  }
  return ids;
}

extension MemoryServiceAreas on MemoryService {
  // ---------------------------------------------------------------------
  // areasList
  // ---------------------------------------------------------------------

  /// Lists every [Area] with its member projects (name + status + a live
  /// MemoryEntry count, per-area total), plus registry-health sections:
  /// `projectsWithoutArea` (registered, no membership), `unregisteredProjects`
  /// (distinct MemoryEntry project strings with no [ProjectScope] row),
  /// `membershipsWithoutArea`/`membershipsWithoutProjectRows` (replaces the
  /// un-computable `danglingMemberships` from an earlier design: these
  /// are name joins over bounded registry-scale data, not a ToMany load)
  /// and `blankProjectEntries` (the legacy empty-`project` case). Every
  /// count is a `count()`/distinct-property query – no `getAll()`. One
  /// lending, one read transaction, so every count below is a consistent
  /// snapshot.
  ///
  /// Archived projects are listed like any other (each marked with its
  /// `status`) and counted in every total: `status` is informational in
  /// v1, the same rule `recall`/`listRecent`/`factQuery`'s `area` filter
  /// already apply, so `areasList` does not hide archived projects behind
  /// an `includeArchived` toggle – one rule for the whole surface, not
  /// two. [ProjectStatus.merged] stays
  /// excluded: a merged project's entries/facts have already been moved
  /// to another name by `project_merge`, so listing it here would double
  /// count or point at data that is no longer there.
  Future<Map<String, Object?>> areasList() {
    return _withSession('areas_list', () {
      return store.runInTransaction(TxMode.read, () {
        final now = DateTime.now().toUtc();

        // Registered projects: name -> status. Registry-scale (not
        // box-wide entry/fact data), so a full page-through is cheap and
        // gives us the status lookup the rest of this method needs.
        final projectStatus = <String, String>{};
        _pageThrough<ProjectScope>(_projects.query(), (page) {
          for (final p in page) {
            projectStatus[p.name] = p.status;
          }
        });

        // Every Area row (registry-scale).
        final areaRows = <Area>[];
        _pageThrough<Area>(_areas.query(), (page) => areaRows.addAll(page));
        final areaNames = areaRows.map((a) => a.name).toSet();

        // One pass over every AreaMembership row, purely to detect rows
        // that reference an area or a project row that no longer exists –
        // the replacement for `stats.registry.
        // danglingMemberships` (which an earlier ToMany-based design could
        // not compute at all: a missing relation target is silently
        // dropped on load, box.dart:719-723) – and to know which
        // registered projects have ANY membership at all (for
        // projectsWithoutArea below). The actual per-area member list
        // (below) is resolved via `_resolveAreaProjects`
        // (memory_service_registry.dart) instead of read from this
        // pass, so the "which projects does this area contain, excluding
        // merged ones" rule lives in exactly one place – the same one
        // `recall`/`stats`/`fact_query`'s `area` filter also use.
        final projectsInMemberships = <String>{};
        var membershipsWithoutArea = 0;
        var membershipsWithoutProjectRows = 0;
        // A project can hold a live AreaMembership row while its own
        // ProjectScope.status is `merged` (typically the target of an
        // undone merge, or a row left over from before a merge). Reported
        // below (membershipsOnMergedProjects) instead of silently folding
        // it into membershipsWithoutProjectRows, which would misreport a
        // real (if excluded) project as a dangling reference.
        final membershipsOnMergedProjects = <String>{};
        _pageThrough<AreaMembership>(_memberships.query(), (page) {
          for (final m in page) {
            if (!areaNames.contains(m.area)) {
              membershipsWithoutArea++;
              continue;
            }
            if (!projectStatus.containsKey(m.project)) {
              membershipsWithoutProjectRows++;
              continue;
            }
            if (projectStatus[m.project] == ProjectStatus.merged) {
              membershipsOnMergedProjects.add(m.project);
              continue;
            }
            projectsInMemberships.add(m.project);
          }
        });

        // Only `merged` is a real exclusion – its entries/facts already
        // moved to another name (see the method doc comment). `archived`
        // is informational only and stays visible everywhere below.
        bool visible(String status) => status != ProjectStatus.merged;

        final areasOut = <Map<String, Object?>>[];
        for (final area in areaRows) {
          // Already excludes merged projects (registry.dart's own rule);
          // a name with no ProjectScope row at all (membershipsWithoutProjectRows,
          // counted above) is skipped here too – this method has no status
          // to report for it.
          final memberNames = _resolveAreaProjects(area.name);
          final projectsOut = <Map<String, Object?>>[];
          var areaLiveEntries = 0;
          for (final name in memberNames) {
            final status = projectStatus[name];
            if (status == null) continue;
            final liveEntries = _useQuery(
              _entries.query(_liveEntryCondition(name, now)),
              (q) => q.count(),
            );
            areaLiveEntries += liveEntries;
            // One count() per project (bounded by registry-scale project
            // counts, same discipline as liveEntries above) – a caller
            // browsing an area needs to know how many current facts each
            // member project has, not only its live entries.
            final currentFacts = _useQuery(
              _facts.query(
                Fact_.project.equals(name, caseSensitive: true) &
                    _factValidAtCondition(now),
              ),
              (q) => q.count(),
            );
            projectsOut.add({
              'name': name,
              'status': status,
              'liveEntries': liveEntries,
              'currentFacts': currentFacts,
            });
          }
          areasOut.add({
            'id': area.id,
            'name': area.name,
            'description': area.description,
            'projects': projectsOut,
            'liveEntries': areaLiveEntries,
          });
        }

        // Registered projects with zero membership rows (any status the
        // membership table records, even a since-orphaned one – presence
        // of a row at all means "an area was attempted", which is a
        // different situation from "never assigned"). Merged projects are
        // never reported here (their entries already moved elsewhere);
        // archived ones ARE reported (status is informational, see the
        // method doc comment).
        final projectsWithoutArea = <String>[
          for (final entry in projectStatus.entries)
            if (visible(entry.value) &&
                !projectsInMemberships.contains(entry.key))
              entry.key,
        ];

        // Distinct MemoryEntry.project strings with no ProjectScope row –
        // property projection with explicit distinct+caseSensitive (F3:
        // distinct string projections default to case-INSENSITIVE, which
        // would wrongly collapse e.g. "acme-app"/"Acme-App"). Blank
        // (`''`) is excluded here and reported separately as
        // blankProjectEntries instead – it is not an "unregistered
        // project name", it is missing data.
        final usedEntryProjects = _distinctUsedProjects(includeFacts: false);
        final unregisteredProjects = <String>[
          for (final name in usedEntryProjects)
            if (!MemoryService._isBlankProject(name) &&
                !projectStatus.containsKey(name))
              name,
        ];

        final blankProjectEntries = _countBlankProjectEntries();

        final membershipsOnMergedProjectsList =
            membershipsOnMergedProjects.toList()..sort();

        final warnings = <String>[];
        if (unregisteredProjects.isNotEmpty) {
          warnings.add(
            '${unregisteredProjects.length} project name(s) are used on '
            // `backfill_project_registry` is not an MCP tool name a
            // caller can act on directly – `reindex` runs it.
            'entries but have no registry row – run reindex (or '
            'project_set) to register them: '
            '${unregisteredProjects.map((p) => '"${MemoryService.sanitizeForLog(p)}"').join(', ')}.',
          );
        }
        if (membershipsWithoutArea > 0) {
          warnings.add(
            '$membershipsWithoutArea area membership row(s) reference an '
            'area that no longer exists; repair via project_set '
            're-assignment.',
          );
        }
        if (membershipsWithoutProjectRows > 0) {
          warnings.add(
            '$membershipsWithoutProjectRows area membership row(s) '
            'reference a project with no registry row; repair via '
            'project_set re-assignment.',
          );
        }
        if (membershipsOnMergedProjectsList.isNotEmpty) {
          warnings.add(
            '${membershipsOnMergedProjectsList.length} project(s) hold area '
            'membership rows but are merged into another name, so they are '
            'excluded from every area\'s project list: '
            '${membershipsOnMergedProjectsList.map((p) => '"${MemoryService.sanitizeForLog(p)}"').join(', ')}. '
            'Their entries/facts already moved to the target name – assign '
            'the target to the same area with project_set if needed.',
          );
        }
        if (blankProjectEntries > 0) {
          warnings.add(
            '$blankProjectEntries entr${blankProjectEntries == 1 ? 'y has' : 'ies have'} '
            'a blank project string (legacy data) and are excluded from '
            'every project/area count.',
          );
        }

        return {
          'areas': areasOut,
          'projectsWithoutArea': projectsWithoutArea,
          'unregisteredProjects': unregisteredProjects,
          'membershipsWithoutArea': membershipsWithoutArea,
          'membershipsWithoutProjectRows': membershipsWithoutProjectRows,
          'membershipsOnMergedProjects': membershipsOnMergedProjectsList,
          'blankProjectEntries': blankProjectEntries,
          // This result returns stored area descriptions and project
          // names, like every other read tool, so it carries the same
          // provenance note the contract requires on every read.
          '_provenance_note': MemoryService._provenanceNote,
          if (warnings.isNotEmpty) 'warnings': warnings,
        };
      });
    });
  }

  // ---------------------------------------------------------------------
  // Shared write primitive – "rewrite project on these entry ids" – used
  // by both [projectMerge] (every entry under one project moves to
  // another) and [entriesMove] (an explicit id list moves, whatever
  // project each id currently sits in). One place, not two copies that
  // could drift (CLAUDE.md "No duplicated logic") – 2026-09-21, entries
  // move (0.3.0).
  // ---------------------------------------------------------------------

  /// Chunked rewrite of [MemoryEntry.project] to [newProject] for every id
  /// in [entryIds] – ids collected FIRST by the caller (a query whose own
  /// predicate the loop changes would shift offsets mid-page), then moved
  /// in bounded chunks via getMany/putMany (F12), never getAll(). MUST run
  /// inside an existing write transaction (or read transaction for a
  /// [dryRun] caller) and `StoreGate` lending, same as its callers.
  ///
  /// Returns each moved row's project as it stood BEFORE this rewrite, in
  /// the same order as [entryIds] – [projectMerge] already knows the
  /// single source project and ignores this; [entriesMove] uses it to
  /// tally `alreadyThere` and `fromProjects` (an explicit id list can span
  /// several source projects, unlike a whole-project merge).
  List<String> _rewriteEntriesProject(
    List<int> entryIds,
    String newProject, {
    required bool dryRun,
  }) {
    final priorProjects = <String>[];
    for (var i = 0; i < entryIds.length; i += MemoryService._scanPageSize) {
      final chunkIds = entryIds.sublist(
        i,
        math.min(i + MemoryService._scanPageSize, entryIds.length),
      );
      final rows = _entries
          .getMany(chunkIds)
          .whereType<MemoryEntry>()
          .toList(growable: false);
      for (final row in rows) {
        priorProjects.add(row.project);
        row.project = newProject;
      }
      if (!dryRun) _entries.putMany(rows);
    }
    return priorProjects;
  }

  // ---------------------------------------------------------------------
  // projectMerge
  // ---------------------------------------------------------------------

  /// Rewrites every [MemoryEntry]/[Fact] row's `project` from [from] to
  /// [into], carries [from]'s area memberships to [into], and tombstones
  /// the [from] [ProjectScope] row (`status: merged`, `mergedInto: into`)
  /// rather than deleting it (no alias – a later write under
  /// the old name still succeeds, `_ensureProjectScope` just warns).
  ///
  /// One lending, one transaction – `TxMode.write` normally, `TxMode.read`
  /// for [dryRun] (same counting code either way; every mutating call
  /// below is individually guarded by `if (!dryRun)` (dry-run: read tx,
  /// same counting code).
  Future<Map<String, Object?>> projectMerge({
    required String from,
    required String into,
    bool dryRun = false,
  }) {
    final validatedFrom = _requireRegistryProjectName(from);
    final validatedInto = _requireRegistryProjectName(into);
    if (validatedFrom == validatedInto) {
      throw ValidationException(
        'project_merge: "from" and "into" must differ (both are '
        '"${MemoryService.sanitizeForLog(validatedFrom)}").',
      );
    }

    return _withSession('project_merge', () {
      return store.runInTransaction(dryRun ? TxMode.read : TxMode.write, () {
        final fromScope = _useQuery(
          _projects.query(
            ProjectScope_.name.equals(validatedFrom, caseSensitive: true),
          ),
          (q) => q.findFirst(),
        );

        final entryIds = _useQuery(
          _entries.query(
            MemoryEntry_.project.equals(validatedFrom, caseSensitive: true),
          ),
          (q) => q.findIds(),
        );
        final factIds = _useQuery(
          _facts.query(
            Fact_.project.equals(validatedFrom, caseSensitive: true),
          ),
          (q) => q.findIds(),
        );

        if (entryIds.isEmpty && factIds.isEmpty && fromScope == null) {
          throw ValidationException(
            'project_merge: nothing to merge – project '
            '"${MemoryService.sanitizeForLog(validatedFrom)}" has no '
            'entries, no facts, and no registry row.',
          );
        }

        // Captured once, read-only, before anything below mutates a
        // ProjectScope row – used both for the fact collision check
        // (valid-at-`now` comparison) and for `intoReactivated`, which
        // must answer truthfully under `dryRun` too (no write has
        // happened yet to base it on).
        final now = DateTime.now().toUtc();

        // Entries: chunked rewrite via the shared [_rewriteEntriesProject]
        // primitive (2026-09-21, entries move (0.3.0) – extracted here so
        // entriesMove reuses the exact same chunked getMany/putMany move,
        // not a second copy). Every entry under `from` moves, so the
        // returned prior-project list is ignored here – projectMerge
        // already knows the single source project.
        _rewriteEntriesProject(entryIds, validatedInto, dryRun: dryRun);

        // Facts: same chunked move, PLUS a recomputed factKey (project is
        // part of the composite key) and a collision check against any
        // fact already sitting under `into` with the same new key (keep
        // both rows, list them – never silently closes one; that decision
        // stays with the caller via fact_set). `into`'s own rows are
        // never touched by this move, so the collision check is
        // order-independent and valid under dryRun too.
        //
        // A moved row can violate the facts invariant (no two
        // non-retracted rows for one key overlap) two different ways, so
        // both are checked: it is the open chain head and `into` already
        // has one too (an eventual, permanent overlap once both stay
        // open), or it is valid right now and `into` already has a row
        // valid right now too (an immediate overlap, even when the moved
        // row is not the head – e.g. already closed at a future date).
        // Checking only the head (as an earlier version did) missed the
        // second case: a row that is genuinely in effect today but is not
        // the open head went unreported.
        final factKeyConflicts = <Map<String, Object?>>[];
        for (var i = 0; i < factIds.length; i += MemoryService._scanPageSize) {
          final chunkIds = factIds.sublist(
            i,
            math.min(i + MemoryService._scanPageSize, factIds.length),
          );
          final rows = _facts
              .getMany(chunkIds)
              .whereType<Fact>()
              .toList(growable: false);
          for (final row in rows) {
            final newKey = Fact.keyFor(
              validatedInto,
              row.subject,
              row.attribute,
            );
            row.project = validatedInto;
            row.factKey = newKey;
            if (row.retractedAt == null) {
              final targetHasOpenHead =
                  row.validUntil == null &&
                  _useQuery(
                    _facts.query(
                      Fact_.project.equals(validatedInto, caseSensitive: true) &
                          Fact_.factKey.equals(newKey) &
                          Fact_.validUntil.isNull() &
                          Fact_.retractedAt.isNull(),
                    ),
                    (q) => q.count(),
                  ) >
                      0;
              final targetHasValidNow =
                  _factValidAt(row, now) &&
                  _useQuery(
                    _facts.query(
                      Fact_.project.equals(validatedInto, caseSensitive: true) &
                          Fact_.factKey.equals(newKey) &
                          _factValidAtCondition(now),
                    ),
                    (q) => q.count(),
                  ) >
                      0;
              if (targetHasOpenHead || targetHasValidNow) {
                factKeyConflicts.add({
                  'movedFactId': row.id,
                  'subject': row.subject,
                  'attribute': row.attribute,
                  'factKey': newKey,
                });
              }
            }
          }
          if (!dryRun) _facts.putMany(rows);
        }

        // Memberships: create target memberships for the same areas,
        // delete source memberships. The
        // membership box is registry-scale, so a plain find() (not a
        // chunked scan) is fine here – consistent with `_resolveAreaProjects`.
        final sourceMemberships = _useQuery(
          _memberships.query(
            AreaMembership_.project.equals(validatedFrom, caseSensitive: true),
          ),
          (q) => q.find(),
        );
        final areasCarried = <String>[];
        for (final m in sourceMemberships) {
          areasCarried.add(m.area);
          final targetKey = AreaMembership.keyFor(m.area, validatedInto);
          final targetExists =
              _useQuery(
                _memberships.query(AreaMembership_.key.equals(targetKey)),
                (q) => q.count(),
              ) >
              0;
          if (!dryRun) {
            if (!targetExists) {
              _memberships.put(
                AreaMembership(
                  key: targetKey,
                  area: m.area,
                  project: validatedInto,
                ),
              );
            }
            _memberships.remove(m.id);
          }
        }

        // Merging INTO a project that is itself tombstoned (`status:
        // merged`, typically from undoing an earlier merge, e.g. x->X
        // then X->x) reactivates it – otherwise the data just moved here
        // becomes invisible everywhere area filters are used
        // (_resolveAreaProjects excludes every `merged` name), with
        // nothing pointing at why. The caller is explicitly moving data
        // into this name right now, so "still merged" would be a lie.
        // Read BEFORE any write below (and unconditionally, not only
        // under `!dryRun`) so a `dryRun` call reports the SAME answer a
        // real run would act on, rather than always reporting `false`.
        final priorIntoScope = _useQuery(
          _projects.query(
            ProjectScope_.name.equals(validatedInto, caseSensitive: true),
          ),
          (q) => q.findFirst(),
        );
        final intoReactivated =
            priorIntoScope?.status == ProjectStatus.merged;

        final warnings = <String>[];
        if (!dryRun) {
          final ensured = _ensureProjectScope(
            validatedInto,
            reason: 'project_merge',
          );
          final intoScope = ensured.scope;
          if (intoReactivated) {
            final previousMergedInto = intoScope.mergedInto;
            intoScope.status = ProjectStatus.active;
            intoScope.mergedInto = '';
            intoScope.updatedAt = now;
            _projects.put(intoScope);
            log(
              '[memory] project_merge: "into" project '
              '"${MemoryService.sanitizeForLog(validatedInto)}" was merged '
              'into "${MemoryService.sanitizeForLog(previousMergedInto)}" – '
              'reactivated (status: active) since data is being merged '
              'into it now.',
            );
          } else {
            warnings.addAll(ensured.warnings);
          }
          if (intoScope.description.isEmpty &&
              fromScope != null &&
              fromScope.description.isNotEmpty) {
            intoScope.description = fromScope.description;
            intoScope.updatedAt = now;
            _projects.put(intoScope);
          }

          if (fromScope != null) {
            fromScope.status = ProjectStatus.merged;
            fromScope.mergedInto = validatedInto;
            fromScope.updatedAt = now;
            _projects.put(fromScope);
          } else {
            _projects.put(
              ProjectScope(
                name: validatedFrom,
                nameKey: ScopeKey.of(validatedFrom),
                status: ProjectStatus.merged,
                mergedInto: validatedInto,
              ),
            );
          }
        }

        log(
          '[memory] project_merge '
          '"${MemoryService.sanitizeForLog(validatedFrom)}" -> '
          '"${MemoryService.sanitizeForLog(validatedInto)}": '
          'entries=${entryIds.length} facts=${factIds.length} '
          'areasCarried=${areasCarried.length} dryRun=$dryRun',
        );

        final result = <String, Object?>{
          'from': validatedFrom,
          'into': validatedInto,
          'dryRun': dryRun,
          'entriesMoved': entryIds.length,
          'factsMoved': factIds.length,
          'areasCarried': areasCarried,
          'factKeyConflicts': factKeyConflicts,
          'fromStatus': ProjectStatus.merged,
          'mergedInto': validatedInto,
          'intoReactivated': intoReactivated,
        };
        if (warnings.isNotEmpty) result['warning'] = warnings.join(' ');
        return dryRun ? result : _applyGuardPeerWarning(result);
      });
    });
  }

  // ---------------------------------------------------------------------
  // entriesMove
  // ---------------------------------------------------------------------

  /// Moves SELECTED [MemoryEntry] rows (by id) into [toProject] – splits a
  /// catch-all project, as opposed to [projectMerge], which moves a WHOLE
  /// project. 2026-09-21, entries move (0.3.0).
  ///
  /// [ids] is validated before the lending ([_requireMoveIds]: 1..500,
  /// each a positive integer, no duplicates); [toProject] is validated
  /// exactly like `remember`'s `project` ([_requireRegistryProjectName] –
  /// byte-exact, no trimming, no control-character rejection, same cap).
  ///
  /// One lending, one transaction (`TxMode.write` normally, `TxMode.read`
  /// for [dryRun] – same counting code either way, mirroring
  /// [projectMerge]). Every id in [ids] must already exist, checked FIRST
  /// via one `getMany` round-trip inside the transaction: if any is
  /// missing, throws [ValidationException] naming every missing id and
  /// writes nothing (the transaction never reaches a mutating call).
  ///
  /// With [includeChain] (default true), every id's supersede chain –
  /// predecessors AND successors, via [MemoryEntry.supersededBy] walked in
  /// both directions – is pulled in too, so a history never straddles two
  /// projects; the ids added this way (not already present in [ids]) are
  /// reported both as a count (`chainEntriesAdded`) and, 2026-09-21
  /// review3 m2 fix, as the actual ids themselves (`chainEntryIds`).
  /// [ids] plus every chain-added id together are capped at
  /// [_entriesMoveMaxTotalIds] (review3 m2 – [_requireMoveIds] only
  /// bounds [ids] itself, not what an unbounded chain can add), rejected
  /// with a [ValidationException] naming the total if exceeded. Pass
  /// `includeChain: false` to move only the given ids verbatim.
  ///
  /// Rewrites `project` on every entry via the shared
  /// [_rewriteEntriesProject] primitive (the same chunked getMany/putMany
  /// move [projectMerge] uses) and registers [toProject]
  /// ([_ensureProjectScope]), collecting its warnings (incl. a
  /// still-merged target) plus a near-duplicate-name warning
  /// ([_nearDuplicateProjects]) – same registry discipline as
  /// [projectMerge]. An entry already sitting in [toProject] (verbatim id,
  /// or pulled in via the chain) is counted in `alreadyThere`, not an
  /// error; every other moved entry's PRIOR project is tallied into
  /// `fromProjects`.
  ///
  /// Deliberately does NOT touch [Fact] rows – facts belong to projects
  /// explicitly (via their own `project` field, set by `fact_set`), so
  /// moving memory entries never moves facts; the result says so via
  /// `factsUnaffected: true`. Also does not change
  /// [MemoryEntry.text]/[MemoryEntry.contentHash] or the vector index
  /// ([MemoryIndex]) – nothing about an entry's content changes, only
  /// which project it belongs to.
  Future<Map<String, Object?>> entriesMove({
    required List<int> ids,
    required String toProject,
    bool dryRun = false,
    bool includeChain = true,
  }) {
    final validatedIds = _requireMoveIds(ids);
    final validatedTo = _requireRegistryProjectName(toProject);

    return _withSession('entries_move', () {
      return store.runInTransaction(dryRun ? TxMode.read : TxMode.write, () {
        // Every requested id must exist – one getMany round-trip (not one
        // query per id), checked BEFORE any mutation so a missing id rolls
        // the whole transaction back with nothing written.
        final requestedRows = _entries.getMany(validatedIds);
        final missing = <int>[];
        for (var i = 0; i < validatedIds.length; i++) {
          if (requestedRows[i] == null) missing.add(validatedIds[i]);
        }
        if (missing.isNotEmpty) {
          throw ValidationException(
            'entries_move: id(s) do not exist, nothing moved: '
            '${missing.join(', ')}.',
          );
        }

        // includeChain: BFS over `supersededBy` (ToOne, old -> new) in
        // BOTH directions – forward via the entity's own relation,
        // backward via a query for rows pointing AT the current id – so
        // the whole connected chain (not just one hop) is pulled in
        // regardless of which link in the chain the caller named.
        final moveIds = <int>{...validatedIds};
        // review3 m2 fix: the ids the chain itself added, in the order
        // they were found – reported back as `chainEntryIds` (not only a
        // count) so a caller, especially in `dryRun`, can see exactly
        // which rows a supersede chain pulled in.
        final chainEntryIds = <int>[];
        if (includeChain) {
          final queue = List<int>.of(validatedIds);
          while (queue.isNotEmpty) {
            final id = queue.removeLast();
            final entry = _entries.get(id);
            if (entry == null) continue; // defensive; existence already checked
            final successorId = entry.supersededBy.targetId;
            if (successorId != 0 && moveIds.add(successorId)) {
              chainEntryIds.add(successorId);
              queue.add(successorId);
            }
            final predecessorIds = _useQuery(
              _entries.query(MemoryEntry_.supersededBy.equals(id)),
              (q) => q.findIds(),
            );
            for (final predecessorId in predecessorIds) {
              if (moveIds.add(predecessorId)) {
                chainEntryIds.add(predecessorId);
                queue.add(predecessorId);
              }
            }
          }
        }
        final allIds = moveIds.toList(growable: false);

        // review3 m2 fix: [_entriesMoveMaxIds] only bounds the REQUESTED
        // `ids` – `includeChain` can pull in an unbounded number of rows
        // (a supersede chain has no length limit), so a second, generous
        // cap on the TOTAL (requested + chain) rejects an absurd request
        // outright instead of silently walking an unbounded chain.
        // Checked BEFORE any write (`_rewriteEntriesProject` below), same
        // "throw before mutating" discipline the missing-id check above
        // uses.
        if (allIds.length > _entriesMoveMaxTotalIds) {
          throw ValidationException(
            'entries_move: moving ${validatedIds.length} requested id(s) '
            'would pull in a total of ${allIds.length} entries (including '
            '${chainEntryIds.length} via includeChain), exceeding the '
            '$_entriesMoveMaxTotalIds total-entry limit. Pass '
            'includeChain: false, or move a smaller/different set of ids.',
          );
        }

        final priorProjects = _rewriteEntriesProject(
          allIds,
          validatedTo,
          dryRun: dryRun,
        );

        var moved = 0;
        var alreadyThere = 0;
        final fromProjects = <String, int>{};
        for (final prior in priorProjects) {
          if (prior == validatedTo) {
            alreadyThere++;
            continue;
          }
          moved++;
          fromProjects[prior] = (fromProjects[prior] ?? 0) + 1;
        }

        // review3 m1 fix: looked up read-only and UNCONDITIONALLY (not
        // only under `!dryRun`), so a `dryRun` call reports the identical
        // "target was merged" warning a real run would act on – mirrors
        // `projectMerge`'s own `priorIntoScope`/`intoReactivated` read-
        // before-write pattern above, for the same reason. Deliberately
        // NOT routed through `_ensureProjectScope`'s generic "the write
        // still succeeded under the old name" wording below (correct for
        // remember/fact_set/project_set, misleading for a project-to-
        // project move): entries_move re-creates the exact drift
        // project_merge just removed, so it gets its own wording naming
        // `mergedInto` explicitly. `_ensureProjectScope`'s own `warnings`
        // only ever repeats this same merged-target case (see its doc),
        // so it is not appended a second time below.
        final targetScope = _useQuery(
          _projects.query(
            ProjectScope_.name.equals(validatedTo, caseSensitive: true),
          ),
          (q) => q.findFirst(),
        );
        final warnings = <String>[];
        if (targetScope != null &&
            targetScope.status == ProjectStatus.merged &&
            targetScope.mergedInto.isNotEmpty) {
          warnings.add(
            'entries_move: target project '
            '"${MemoryService.sanitizeForLog(validatedTo)}" was merged '
            'into "${MemoryService.sanitizeForLog(targetScope.mergedInto)}" '
            'via project_merge – moving entries into '
            '"${MemoryService.sanitizeForLog(validatedTo)}" now '
            're-creates the drift that merge removed; move into '
            '"${MemoryService.sanitizeForLog(targetScope.mergedInto)}" '
            'instead.',
          );
        }
        if (!dryRun) {
          _ensureProjectScope(validatedTo, reason: 'entries_move');
        }
        final dupeProjects = _nearDuplicateProjects(validatedTo);
        if (dupeProjects.isNotEmpty) {
          warnings.add(
            'project "${MemoryService.sanitizeForLog(validatedTo)}" '
            'differs from existing '
            '${dupeProjects.map((n) => '"${MemoryService.sanitizeForLog(n)}"').join(', ')} '
            'only by case/space/-/_; use the existing name or run '
            'project_merge.',
          );
        }

        log(
          '[memory] entries_move ${validatedIds.length} requested id(s) '
          '(+${chainEntryIds.length} via chain) -> '
          '"${MemoryService.sanitizeForLog(validatedTo)}": moved=$moved '
          'alreadyThere=$alreadyThere includeChain=$includeChain '
          'dryRun=$dryRun',
        );

        final result = <String, Object?>{
          'moved': moved,
          'alreadyThere': alreadyThere,
          'chainEntriesAdded': chainEntryIds.length,
          // review3 m2 fix: the actual chain-added ids, not only a count –
          // see the field's own doc above (moveIds/chainEntryIds
          // construction).
          'chainEntryIds': chainEntryIds,
          'fromProjects': fromProjects,
          'toProject': validatedTo,
          'factsUnaffected': true,
          'dryRun': dryRun,
        };
        // Singular 'warning' (joined string), not a plural 'warnings' array
        // – matches every other WRITE tool that goes through
        // [MemoryService._applyGuardPeerWarning] (projectMerge, tagMerge,
        // tagRemove, projectSet, areaSet, remember, ...); that helper's own
        // doc notes 'recall' (read-only) is the sole plural-array
        // exception and there is no plural variant of it – a second write
        // tool inventing its own 'warnings' key would fork the convention
        // and risk both keys existing at once if the peer guard also fires.
        if (warnings.isNotEmpty) result['warning'] = warnings.join(' ');
        return dryRun ? result : _applyGuardPeerWarning(result);
      });
    });
  }

  // ---------------------------------------------------------------------
  // backfillProjectRegistry
  // ---------------------------------------------------------------------

  /// Registers a [ProjectScope] row (byte-exact name) for every distinct
  /// project string used on [MemoryEntry] OR [Fact] that has none yet.
  /// Never throws for data – a blank project string is skipped and
  /// counted, logged once. Called by `reindex`'s "registry" phase;
  /// also callable directly. One lending, one transaction
  /// (`TxMode.read` for [dryRun], same counting code, mirroring
  /// [projectMerge]).
  Future<Map<String, Object?>> backfillProjectRegistry({bool dryRun = false}) {
    return _withSession('backfill_project_registry', () {
      return store.runInTransaction(dryRun ? TxMode.read : TxMode.write, () {
        final registered = <String>{};
        _pageThrough<ProjectScope>(_projects.query(), (page) {
          for (final p in page) {
            registered.add(p.name);
          }
        });

        final usedProjects = _distinctUsedProjects();

        var registeredCount = 0;
        var alreadyRegistered = 0;
        var skippedBlank = 0;
        for (final name in usedProjects) {
          // The shared blank rule (trim().isEmpty), not just the exact
          // empty string – a whitespace-only legacy project name must not
          // be registered as a real project here.
          if (MemoryService._isBlankProject(name)) {
            skippedBlank++;
            log(
              '[memory] backfill_project_registry: skipped a blank project '
              'string (legacy data – see areas_list.blankProjectEntries for '
              'the affected row count)',
            );
            continue;
          }
          if (registered.contains(name)) {
            alreadyRegistered++;
            continue;
          }
          if (!dryRun) {
            final scope = ProjectScope(name: name, nameKey: ScopeKey.of(name));
            scope.id = _projects.put(scope);
            log(
              '[memory] backfill_project_registry: registered project '
              '"${MemoryService.sanitizeForLog(name)}" (id ${scope.id})',
            );
          }
          registeredCount++;
        }

        log(
          '[memory] backfill_project_registry: registered=$registeredCount '
          'alreadyRegistered=$alreadyRegistered skippedBlank=$skippedBlank '
          'dryRun=$dryRun',
        );

        final result = <String, Object?>{
          'registered': registeredCount,
          'skippedBlank': skippedBlank,
          'alreadyRegistered': alreadyRegistered,
          'dryRun': dryRun,
        };
        return dryRun ? result : _applyGuardPeerWarning(result);
      });
    });
  }
}
