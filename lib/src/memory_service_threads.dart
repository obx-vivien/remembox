/// Threads – 0.5.0: `thread_update` (the one write), `thread_list`,
/// `thread_get`, and the read projection [readThreadRows] that
/// `thread_list` and `remembox cockpit-sync` (lib/src/cockpit_sync.dart)
/// share.
///
/// A thread ([Thread]) is a concrete matter with a state from the fixed
/// set [ThreadStates]; its history is one [ThreadState] row per asserted
/// state, its entries are [ThreadEntry] rows. The current state is the
/// newest row by (recordedAt, id) that is not `asHistory`; the [Thread]
/// row carries a denormalized copy, recomputed on every write
/// ([MemoryServiceThreads._recomputeThreadState]).
///
/// Every check of `thread_update` runs before the first put, inside one
/// write transaction of one lending – in gated mode that lending holds
/// `store.lock` for the whole call (store_gate.dart), so the query-first
/// "at most one live thread per (project, title)" rule cannot interleave
/// with another process. The note's embedding happens BEFORE the lending
/// (never hold the lock across an embed).
part of 'memory_service.dart';

/// Cap on [Thread.title] (characters).
const int threadTitleMaxLen = 200;

/// Cap on `thread_update` `attachEntryIds`.
const int threadAttachMaxIds = 50;

/// Cap on `thread_update` `idempotencyKey` (characters).
const int threadIdempotencyKeyMaxLen = 128;

/// [ThreadOp] rows older than this are pruned by every `thread_update`.
const Duration _threadOpRetention = Duration(days: 30);

/// `thread_list` `limit`: default and cap.
const int threadListDefaultLimit = 100;
const int threadListMaxLimit = 500;

/// Cap of [readThreadRows] for callers without their own limit
/// (`cockpit-sync`).
const int threadReadMaxRows = 2000;

/// A full timestamp `eventAt` may lie this far in the future (clock skew
/// between devices) before it is rejected.
const Duration _threadEventAtSkew = Duration(minutes: 5);

/// `thread_update` with `expectedVersion` on a thread that has moved on.
/// The server maps it to `error: version_conflict` with [current] – the
/// thread as it stands – so the caller can re-read and retry. Nothing was
/// written.
class ThreadVersionConflict implements Exception {
  final String message;
  final Map<String, Object?> current;

  ThreadVersionConflict(this.message, this.current);

  @override
  String toString() => 'ThreadVersionConflict: $message';
}

/// A date for a message: `YYYY-MM-DD` for UTC midnight (how a date-only
/// argument is stored), the ISO timestamp otherwise.
String _shownDate(DateTime d) {
  final u = d.toUtc();
  if (u.hour == 0 &&
      u.minute == 0 &&
      u.second == 0 &&
      u.millisecond == 0 &&
      u.microsecond == 0) {
    return u.toIso8601String().substring(0, 10);
  }
  return u.toIso8601String();
}

bool _sameInstant(DateTime? a, DateTime? b) =>
    a == null ? b == null : (b != null && a.isAtSameMomentAs(b));

/// The condition "this thread is live" – `state` is neither `done` nor
/// `dropped`. Written as two `notEquals` (the binding has no string
/// `notOneOf`) so a state outside [ThreadStates.all] (e.g. from a newer
/// peer) still counts as live instead of vanishing.
Condition<Thread> _threadLiveCondition() =>
    Thread_.state.notEquals(ThreadStates.done, caseSensitive: true) &
    Thread_.state.notEquals(ThreadStates.dropped, caseSensitive: true);

/// One thread as `thread_list`/`thread_get`/`cockpit-sync` show it.
Map<String, Object?> threadRowOf(Thread t, DateTime now, {int? entryCount}) =>
    {
      'id': t.id,
      'title': t.title,
      'project': t.project,
      'state': t.state,
      'since': t.stateEventAt?.toIso8601String(),
      'sinceRecordedAt': t.stateRecordedAt.toIso8601String(),
      'pausedUntil': t.pausedUntil?.toIso8601String(),
      'pauseElapsed':
          t.state == ThreadStates.paused &&
          t.pausedUntil != null &&
          t.pausedUntil!.isBefore(now),
      'closed': ThreadStates.isClosed(t.state),
      'version': t.version,
      'entryCount': ?entryCount,
      'createdAt': t.createdAt.toIso8601String(),
      'updatedAt': t.updatedAt.toIso8601String(),
    };

/// The read projection shared by `thread_list` and `cockpit-sync`: threads
/// filtered by [projects] (`null` = every project; an empty list matches
/// nothing), by [states] (exactly these states, closed ones included when
/// named) or – without [states] – live only unless [includeClosed]; ordered
/// by project, title, id; at most [limit] rows; each with its
/// `entryCount`. Needs only a [StoreSession] (no service, no embedder), so
/// `cockpit-sync` can run it in one gated lending. Query-first: `count()`
/// for [total], one limited ordered query, and one indexed `count()` per
/// listed thread for the entry counts.
({List<Map<String, Object?>> threads, int total, bool truncated})
readThreadRows(
  StoreSession session, {
  List<String>? projects,
  List<String>? states,
  bool includeClosed = false,
  int limit = threadReadMaxRows,
  DateTime? now,
}) {
  final at = now ?? DateTime.now().toUtc();
  if (projects != null && projects.isEmpty) {
    return (threads: const [], total: 0, truncated: false);
  }
  Condition<Thread>? condition;
  void add(Condition<Thread> c) =>
      condition = condition == null ? c : condition! & c;
  if (projects != null) {
    add(
      projects.length == 1
          ? Thread_.project.equals(projects.single, caseSensitive: true)
          : Thread_.project.oneOf(projects, caseSensitive: true),
    );
  }
  if (states != null && states.isNotEmpty) {
    add(Thread_.state.oneOf(states, caseSensitive: true));
  } else if (!includeClosed) {
    add(_threadLiveCondition());
  }
  return session.store.runInTransaction(TxMode.read, () {
    QueryBuilder<Thread> builder() =>
        condition == null
              ? session.threads.query()
              : session.threads.query(condition);
    final total = _useBuiltQuery(builder(), (q) => q.count());
    final rows = _useBuiltQuery(
      builder()
        ..order(Thread_.project, flags: Order.caseSensitive)
        ..order(Thread_.title)
        ..order(Thread_.id),
      (q) {
        q.limit = limit;
        return q.find();
      },
    );
    // One indexed count() per listed thread (bounded by [limit]). Not one
    // `oneOf` pass over the attachments: objectbox-dart 5.3.2 rejects an
    // IN condition on a ToOne property ("Unsupported type for IN: 11").
    final counts = <int, int>{
      for (final t in rows)
        t.id: _useBuiltQuery(
          session.threadEntries.query(ThreadEntry_.thread.equals(t.id)),
          (q) => q.count(),
        ),
    };
    return (
      threads: [
        for (final t in rows) threadRowOf(t, at, entryCount: counts[t.id] ?? 0),
      ],
      total: total,
      truncated: total > rows.length,
    );
  });
}

/// What a `thread_update` call does to the state history (amendment A1).
enum _StateOutcome { created, updated, dated, historyAdded, unchanged }

extension MemoryServiceThreads on MemoryService {
  // ---------------------------------------------------------------------
  // Argument rules (no store access)
  // ---------------------------------------------------------------------

  /// A thread title: 1..[threadTitleMaxLen] characters, no leading/
  /// trailing whitespace (rejected, not trimmed – same rule as area
  /// names), no control characters.
  static void _requireThreadTitle(String title, {required String tool}) {
    if (title.trim().isEmpty) {
      throw ValidationException('$tool: title must not be blank.');
    }
    if (title != title.trim()) {
      throw ValidationException(
        '$tool: title must not have leading/trailing whitespace: '
        '"${MemoryService.sanitizeForLog(MemoryService._truncateForError(title))}".',
      );
    }
    MemoryService._requireLen('title', title, threadTitleMaxLen);
    _requireNoControlChars('title', title);
  }

  /// A state from [ThreadStates.all], exact and case-sensitive. Rejected
  /// in both registry modes (a thread's state is a closed set by
  /// construction), with the shared near-match suggestion.
  static void _requireThreadState(String state, {required String tool}) {
    if (ThreadStates.isValid(state)) return;
    final shown = MemoryService.sanitizeForLog(
      MemoryService._truncateForError(state),
    );
    throw ValidationException(
      '$tool: "$shown" is not a thread state. Allowed: '
      '${ThreadStates.all.join(', ')}.'
      '${MemoryServiceAttributes._didYouMean(state, ThreadStates.all)} '
      'Nothing was written.',
    );
  }

  /// Amendment A11: a date-only [eventAt] ([isDate]) is in the future only
  /// if its calendar date is after today's LOCAL date; a full timestamp
  /// only if it is more than [_threadEventAtSkew] after [now].
  static void _requireEventAtNotFuture(
    DateTime eventAt, {
    required bool isDate,
    required DateTime now,
  }) {
    final bool future;
    if (isDate) {
      final today = now.toLocal();
      final todayKey = today.year * 10000 + today.month * 100 + today.day;
      final e = eventAt.toUtc();
      future = e.year * 10000 + e.month * 100 + e.day > todayKey;
    } else {
      future = eventAt.isAfter(now.add(_threadEventAtSkew));
    }
    if (future) {
      throw ValidationException(
        'thread_update: eventAt (${_shownDate(eventAt)}) is in the future – '
        'a thread state records what already happened; use pausedUntil for '
        'a date ahead. Nothing was written.',
      );
    }
  }

  /// The calendar day of a stored time as `yyyymmdd`: a date-only value
  /// (stored as UTC midnight) keeps its own day, any other time counts by
  /// its LOCAL day.
  static int _dayKey(DateTime d) {
    final u = d.toUtc();
    final dateOnly =
        u.hour == 0 && u.minute == 0 && u.second == 0 && u.millisecond == 0;
    final day = dateOnly ? u : u.toLocal();
    return day.year * 10000 + day.month * 100 + day.day;
  }

  /// The ONE comparison of a call's [event] with a stored time [other]
  /// (amendment A11): a date-only [event] ([isDate]) compares by calendar
  /// day – its own day against [other]'s day ([_dayKey]), so a date and a
  /// timestamp of the same day are equal; a timestamp compares as an
  /// instant. Negative = before, 0 = same, positive = after.
  static int _compareEvent(
    DateTime event,
    DateTime other, {
    required bool isDate,
  }) {
    if (!isDate) return event.compareTo(other);
    final e = event.toUtc();
    return (e.year * 10000 + e.month * 100 + e.day).compareTo(_dayKey(other));
  }

  static void _requireIdempotencyKey(String key) {
    if (key.isEmpty ||
        key.length > threadIdempotencyKeyMaxLen ||
        _controlCharPattern.hasMatch(key)) {
      throw ValidationException(
        'thread_update: idempotencyKey must be 1-$threadIdempotencyKeyMaxLen '
        'characters without control characters.',
      );
    }
  }

  /// sha256 of the canonicalized arguments (keys sorted, absent values
  /// dropped, id list sorted) – amendment A4: the same idempotency key
  /// with different arguments is rejected instead of replayed.
  static String _threadArgsHash(Map<String, Object?> args) {
    final keys = [
      for (final e in args.entries)
        if (e.value != null) e.key,
    ]..sort();
    final canonical = jsonEncode({for (final k in keys) k: args[k]});
    return sha256.convert(utf8.encode(canonical)).toString();
  }

  // ---------------------------------------------------------------------
  // Reads inside a lending
  // ---------------------------------------------------------------------

  Thread _requireThread(int id, {required String tool}) {
    final thread = _threads.get(id);
    if (thread == null) {
      throw ValidationException('$tool: thread $id does not exist.');
    }
    return thread;
  }

  /// Threads in [project] whose [Thread.titleKey] is [titleKey], live or
  /// closed ([live]), ordered by id. Live-or-closed is decided by each
  /// thread's HISTORY (its current [ThreadState] row), not by the stored
  /// copy [Thread.state]: a stale copy that says `done` must not make a
  /// by-title call create a duplicate. A disagreement is logged here; the
  /// write path repairs the copy of the thread it updates.
  List<Thread> _threadsByTitle(
    String project,
    String titleKey, {
    required bool live,
  }) {
    final candidates = _useQuery(
      _threads.query(
        Thread_.project.equals(project, caseSensitive: true) &
            Thread_.titleKey.equals(titleKey, caseSensitive: true),
      )..order(Thread_.id),
      (q) => q.find(),
    );
    return [
      for (final t in candidates)
        if (ThreadStates.isClosed(_historyState(t)) != live) t,
    ];
  }

  /// [t]'s state according to its history rows (its stored copy when it
  /// has none); a disagreement with the copy is logged.
  String _historyState(Thread t) {
    final current = _currentStateRow(_threadStateRows(t.id));
    if (current == null) return t.state;
    if (current.state != t.state) {
      log(
        '[memory] thread ${t.id}: the stored state ${t.state} disagrees with '
        'its history (${current.state}) – resolved by the history',
      );
    }
    return current.state;
  }

  /// Every [ThreadState] row of one thread – bounded by one thread's
  /// history (typically a few dozen rows), so a plain find.
  List<ThreadState> _threadStateRows(int threadId) => _useQuery(
    _threadStates.query(ThreadState_.thread.equals(threadId)),
    (q) => q.find(),
  );

  /// The current row: the newest by (recordedAt, id) that is not
  /// [ThreadState.asHistory] (amendment A1); null for a thread without
  /// rows.
  static ThreadState? _currentStateRow(Iterable<ThreadState> rows) {
    ThreadState? current;
    for (final r in rows) {
      if (r.asHistory) continue;
      if (current == null) {
        current = r;
        continue;
      }
      final byTime = r.recordedAt.compareTo(current.recordedAt);
      if (byTime > 0 || (byTime == 0 && r.id > current.id)) current = r;
    }
    return current;
  }

  /// Display order of the history: by effective time (eventAt, else
  /// recordedAt), then recordedAt, then id.
  static int _compareHistory(ThreadState a, ThreadState b) {
    final byEff = (a.eventAt ?? a.recordedAt).compareTo(
      b.eventAt ?? b.recordedAt,
    );
    if (byEff != 0) return byEff;
    final byRecorded = a.recordedAt.compareTo(b.recordedAt);
    return byRecorded != 0 ? byRecorded : a.id.compareTo(b.id);
  }

  /// Copies the current row onto the denormalized [Thread] fields; true if
  /// anything differed.
  static bool _recomputeThreadState(Thread thread, ThreadState? current) {
    if (current == null) return false;
    final changed =
        thread.state != current.state ||
        !_sameInstant(thread.stateEventAt, current.eventAt) ||
        !thread.stateRecordedAt.isAtSameMomentAs(current.recordedAt);
    thread
      ..state = current.state
      ..stateEventAt = current.eventAt
      ..stateRecordedAt = current.recordedAt;
    return changed;
  }

  /// The thread as a version-conflict result reports it.
  static Map<String, Object?> _threadConflictView(Thread t) => {
    'threadId': t.id,
    'title': t.title,
    'project': t.project,
    'state': t.state,
    'since': t.stateEventAt?.toIso8601String(),
    'sinceRecordedAt': t.stateRecordedAt.toIso8601String(),
    'pausedUntil': t.pausedUntil?.toIso8601String(),
    'version': t.version,
    'updatedAt': t.updatedAt.toIso8601String(),
  };

  // ---------------------------------------------------------------------
  // Writes inside a write transaction
  // ---------------------------------------------------------------------

  /// Attaches entry [entryId] to thread [threadId] unless it already is
  /// (query-first, contract §3). Returns whether a row was written. Does
  /// not touch the thread's version (amendment A3); callers set
  /// `updatedAt`.
  bool _attachEntryInTx(
    int threadId,
    int entryId, {
    required String via,
    required DateTime now,
  }) {
    final exists =
        _useQuery(
          _threadEntries.query(
            ThreadEntry_.thread.equals(threadId) &
                ThreadEntry_.entry.equals(entryId),
          ),
          (q) => q.count(),
        ) >
        0;
    if (exists) return false;
    _threadEntries.put(
      ThreadEntry(attachedAt: now, via: via)
        ..thread.targetId = threadId
        ..entry.targetId = entryId,
    );
    return true;
  }

  /// The warning for entries attached to a thread of another project –
  /// shared by `thread_update` and `remember(threadId)`.
  static String _otherProjectAttachWarning(List<int> ids, String project) =>
      'entr${ids.length == 1 ? 'y' : 'ies'} ${ids.join(', ')} '
      '${ids.length == 1 ? 'belongs' : 'belong'} to another project than the '
      'thread ("${MemoryService.sanitizeForLog(project)}") – attached anyway.';

  /// Sets `updatedAt` on every thread in [threadIds] (changed membership –
  /// not a version change, amendment A3).
  void _touchThreads(Iterable<int> threadIds, DateTime now) {
    for (final id in threadIds.toSet()) {
      final t = id == 0 ? null : _threads.get(id);
      if (t == null) {
        log(
          '[memory] WARN: thread $id of an attachment does not exist – '
          'its updatedAt was not set (skipped)',
        );
        continue;
      }
      t.updatedAt = now;
      _threads.put(t);
    }
  }

  /// `idempotencyKey` lookup: null when the key is unused; the stored
  /// result plus `replayed: true` when it was used for the same arguments;
  /// a rejection when it was used for different ones (amendment A4).
  Map<String, Object?>? _threadReplay(String key, String argsHash) {
    final op = _useQuery(
      _threadOps.query(ThreadOp_.key.equals(key, caseSensitive: true)),
      (q) => q.findFirst(),
    );
    if (op == null) return null;
    final shownKey = MemoryService.sanitizeForLog(key);
    if (op.argsHash != argsHash) {
      log(
        '[memory] thread_update rejected idempotencyKey "$shownKey": already '
        'used for a different request (thread ${op.threadId})',
      );
      throw ValidationException(
        'thread_update: idempotencyKey "$shownKey" was already used for a '
        'different request (thread ${op.threadId}) – use a new key. Nothing '
        'was written.',
      );
    }
    log(
      '[memory] thread_update replayed key "$shownKey" (thread '
      '${op.threadId}, version ${op.version})',
    );
    return {
      ...(jsonDecode(op.resultJson) as Map<String, Object?>),
      'replayed': true,
    };
  }

  /// Removes [ThreadOp] rows older than [_threadOpRetention]; logged when
  /// any were removed.
  void _pruneThreadOps(DateTime now) {
    final removed = _useQuery(
      _threadOps.query(
        ThreadOp_.createdAt.lessThanDate(now.subtract(_threadOpRetention)),
      ),
      (q) => q.remove(),
    );
    if (removed > 0) {
      log(
        '[memory] thread_update pruned $removed idempotency row(s) older '
        'than ${_threadOpRetention.inDays}d',
      );
    }
  }

  // ---------------------------------------------------------------------
  // thread_update
  // ---------------------------------------------------------------------

  /// Creates a thread or changes it in ONE call – see the tool description
  /// in server.dart and docs/usage-guide.md "Threads". [threadId] updates;
  /// without it, [title] + [project] resolve the live thread with that
  /// title in that project (created when there is none). [eventAtIsDate]
  /// says [eventAt] was a date without time (amendment A11).
  Future<Map<String, Object?>> threadUpdate({
    int? threadId,
    String? title,
    String? project,
    String? state,
    DateTime? eventAt,
    bool eventAtIsDate = false,
    String? note,
    String sourceType = MemorySource.note,
    String sourceRef = '',
    String language = '',
    List<int>? attachEntryIds,
    DateTime? pausedUntil,
    bool clearPausedUntil = false,
    int? expectedVersion,
    String? idempotencyKey,
  }) async {
    const tool = 'thread_update';
    // -- Arguments, before any store access -------------------------------
    if (threadId == null && (title == null || project == null)) {
      throw ValidationException(
        '$tool: pass threadId (to update) or title and project (to '
        'create). Nothing was written.',
      );
    }
    if (title != null) _requireThreadTitle(title, tool: tool);
    final validatedProject = project == null
        ? null
        : _requireRegistryProjectName(project);
    if (state != null) _requireThreadState(state, tool: tool);
    if (eventAt != null && state == null) {
      throw ValidationException(
        '$tool: eventAt needs state – it says when that state became true. '
        'Nothing was written.',
      );
    }
    // Only for the future check: every stored time is taken inside the
    // write transaction (under store.lock), see below.
    final callNow = _truncToMs(DateTime.now().toUtc());
    final event = eventAt == null ? null : _truncToMs(eventAt);
    if (event != null) {
      _requireEventAtNotFuture(event, isDate: eventAtIsDate, now: callNow);
    }
    MemoryService._requireSourceType(sourceType);
    _requireArgLengths(sourceRef: sourceRef, language: language);
    String? normalizedNote;
    if (note != null) {
      normalizedNote = MemoryService.normalizeText(note);
      if (normalizedNote.isEmpty) {
        throw ValidationException('$tool: note must not be empty.');
      }
      if (normalizedNote.length > maxTextChars) {
        throw ValidationException(
          '$tool: note is too long: ${normalizedNote.length} characters '
          'exceeds the $maxTextChars character limit (configurable via '
          'OBX_MEMORY_MAX_TEXT_CHARS).',
        );
      }
    }
    final attachIds = attachEntryIds == null
        ? null
        : _requireEntryIds(
            attachEntryIds,
            tool: tool,
            field: 'attachEntryIds',
            max: threadAttachMaxIds,
          );
    if (pausedUntil != null && clearPausedUntil) {
      throw ValidationException(
        '$tool: pass pausedUntil or clearPausedUntil, not both.',
      );
    }
    if (expectedVersion != null && threadId == null) {
      throw ValidationException(
        '$tool: expectedVersion needs threadId (a version belongs to an '
        'existing thread). Nothing was written.',
      );
    }
    if (idempotencyKey != null) _requireIdempotencyKey(idempotencyKey);
    final nothingElse =
        state == null &&
        note == null &&
        attachIds == null &&
        pausedUntil == null &&
        !clearPausedUntil;
    const nothingToDo =
        '$tool: nothing to do – pass at least one of state, note, '
        'attachEntryIds, title (rename), project (move), pausedUntil, '
        'clearPausedUntil.';
    if (threadId != null && nothingElse && title == null && project == null) {
      throw ValidationException(nothingToDo);
    }
    final argsHash = _threadArgsHash({
      'threadId': threadId,
      'title': title,
      'project': validatedProject,
      'state': state,
      'eventAt': event?.toIso8601String(),
      'eventAtIsDate': event == null ? null : eventAtIsDate,
      'note': normalizedNote,
      'sourceType': sourceType,
      'sourceRef': sourceRef,
      'language': language,
      'attachEntryIds': attachIds == null ? null : ([...attachIds]..sort()),
      'pausedUntil': pausedUntil?.toUtc().toIso8601String(),
      'clearPausedUntil': clearPausedUntil ? true : null,
      'expectedVersion': expectedVersion,
    });

    // -- Replay before embedding (amendment A4): a retry costs no embed.
    if (idempotencyKey != null) {
      final replay = await _withSession(
        '$tool-replay',
        () => store.runInTransaction(
          TxMode.read,
          () => _threadReplay(idempotencyKey, argsHash),
        ),
      );
      if (replay != null) return _applyGuardPeerWarning(replay);
    }

    // -- The note's embedding, outside the lending ------------------------
    final noteHash = normalizedNote == null
        ? null
        : MemoryService.contentHashOf(normalizedNote);
    List<double>? noteVector;
    String? embedWarning;
    if (normalizedNote != null) {
      try {
        noteVector = await _embedForIndex(normalizedNote);
      } on EmbedderException catch (err) {
        embedWarning =
            'The note was stored but NOT indexed yet: ${err.message} The '
            'index will be repaired automatically once embedding works '
            '(observer sweep or the reindex tool).';
        log('[memory] WARN: $tool: $embedWarning');
      }
    }

    // -- One lending, one write transaction --------------------------------
    return _withSession(tool, () {
      return store.runInTransaction(TxMode.write, () {
        // Taken here, under store.lock – not before the lending: a call
        // that waited for the lock (or embedded a note first) must not
        // record a time older than a call that committed before it.
        final now = _truncToMs(DateTime.now().toUtc());
        final warnings = <String>[];
        void warn(String w) {
          warnings.add(w);
          log('[memory] $tool: ${MemoryService.sanitizeForLog(w)}');
        }

        _pruneThreadOps(now);
        if (idempotencyKey != null) {
          final replay = _threadReplay(idempotencyKey, argsHash);
          if (replay != null) return _applyGuardPeerWarning(replay);
        }

        // Resolve.
        Thread? thread;
        if (threadId != null) {
          thread = _requireThread(threadId, tool: tool);
        } else {
          final live = _threadsByTitle(
            validatedProject!,
            ScopeKey.of(title!),
            live: true,
          );
          if (live.length > 1) {
            throw ValidationException(
              '$tool: ${live.length} live threads match the title '
              '"${MemoryService.sanitizeForLog(title)}" in project '
              '"${MemoryService.sanitizeForLog(validatedProject)}" (ids '
              '${live.map((t) => t.id).join(', ')}) – pass threadId. Nothing '
              'was written.',
            );
          }
          thread = live.firstOrNull;
        }
        final creating = thread == null;
        final previousVersion = thread?.version;

        if (thread != null &&
            expectedVersion != null &&
            thread.version != expectedVersion) {
          final message =
              '$tool: thread ${thread.id} is at version ${thread.version}, '
              'you expected $expectedVersion – re-read it (thread_get) and '
              'retry. Nothing was written.';
          log('[memory] $tool version conflict: $message');
          throw ThreadVersionConflict(message, _threadConflictView(thread));
        }
        if (creating && state == null) {
          throw ValidationException(
            '$tool: state is required to create a thread. Nothing was '
            'written.',
          );
        }
        if (!creating && threadId == null && nothingElse) {
          throw ValidationException(nothingToDo);
        }

        final rename =
            !creating && threadId != null && title != null &&
            title != thread.title;
        final move =
            !creating && threadId != null && validatedProject != null &&
            validatedProject != thread.project;
        final targetProject = creating || move
            ? validatedProject!
            : thread.project;
        final targetTitle = creating || rename ? title! : thread.title;
        if (creating || move || normalizedNote != null) {
          _requireWritableProject(targetProject, tool: tool);
        }

        // The state outcome (amendment A1), decided before any write.
        final rows = creating ? <ThreadState>[] : _threadStateRows(thread.id);
        final current = _currentStateRow(rows);
        if (!creating && current == null) {
          warn(
            'thread ${thread.id} has no current state row (incomplete '
            'history, e.g. not yet synced) – the given state becomes '
            'current.',
          );
        }
        // The stored copy of the current state disagrees with the rows
        // (e.g. an interrupted write on another device): repaired below by
        // the recompute and put even when nothing else changes.
        final staleCopy =
            !creating &&
            current != null &&
            (thread.state != current.state ||
                !_sameInstant(thread.stateEventAt, current.eventAt) ||
                !thread.stateRecordedAt.isAtSameMomentAs(current.recordedAt));
        final staleFrom = staleCopy ? thread.state : null;
        // The latest known event date among the non-history rows – late
        // information dated before it never becomes current (amendment A1
        // decision 6: not only the current row's date).
        DateTime? latestKnown;
        ThreadState? latestKnownRow;
        for (final r in rows) {
          if (r.asHistory || r.eventAt == null) continue;
          if (latestKnown == null || r.eventAt!.isAfter(latestKnown)) {
            latestKnown = r.eventAt;
            latestKnownRow = r;
          }
        }
        // A refusal of late information: the state history is not changed,
        // and a pausedUntil given with it is not applied either.
        var refused = false;
        _StateOutcome? outcome;
        if (creating) {
          outcome = _StateOutcome.created;
        } else if (state != null && current == null) {
          outcome = _StateOutcome.updated;
        } else if (state != null) {
          final c = current!;
          if (state == c.state) {
            if (event == null || _sameInstant(c.eventAt, event)) {
              outcome = _StateOutcome.unchanged;
            } else if (c.eventAt == null) {
              final laterKnown = rows.where(
                (r) =>
                    !r.asHistory &&
                    r.id != c.id &&
                    r.eventAt != null &&
                    _compareEvent(event, r.eventAt!, isDate: eventAtIsDate) <
                        0,
              );
              if (_compareEvent(event, c.recordedAt, isDate: eventAtIsDate) >
                  0) {
                outcome = _StateOutcome.unchanged;
                refused = true;
                warn(
                  'eventAt (${_shownDate(event)}) is after the current '
                  "state's recordedAt (${_shownDate(c.recordedAt)}) – an "
                  'unknown date can only be filled in with an earlier one; '
                  'the state history was not changed.',
                );
              } else if (laterKnown.isNotEmpty) {
                final r = laterKnown.first;
                outcome = _StateOutcome.unchanged;
                refused = true;
                warn(
                  'eventAt (${_shownDate(event)}) is before the earlier '
                  'state ${r.state} dated ${_shownDate(r.eventAt!)} – the '
                  'date was not filled in; the state history was not '
                  'changed.',
                );
              } else {
                outcome = _StateOutcome.dated;
              }
            } else {
              outcome = _StateOutcome.unchanged;
              refused = true;
              warn(
                'the current state ${c.state} is already dated '
                '${_shownDate(c.eventAt!)}; dates are not corrected in '
                '0.5.0 – the state history was not changed.',
              );
            }
          } else if (event != null &&
              rows.any(
                (r) => r.state == state && _sameInstant(r.eventAt, event),
              )) {
            outcome = _StateOutcome.unchanged;
            refused = true;
            warn(
              'a $state row dated ${_shownDate(event)} already exists – '
              'repeated late information, the state history was not '
              'changed.',
            );
          } else if (event != null &&
              latestKnown != null &&
              _compareEvent(event, latestKnown, isDate: eventAtIsDate) < 0) {
            outcome = _StateOutcome.historyAdded;
            warn(
              'eventAt ${_shownDate(event)} is before the latest known '
              'state date (${latestKnownRow!.state} since '
              '${_shownDate(latestKnown)}) – stored as history only; the '
              'current state (${c.state}) is unchanged. If the current state '
              'is wrong, call thread_update with the right state and date.',
            );
          } else {
            outcome = _StateOutcome.updated;
            if (event != null && c.eventAt == null) {
              warn(
                'the previous state ${c.state} had no date (recorded '
                '${_shownDate(c.recordedAt)}) – the new state is current '
                'from ${_shownDate(event)}.',
              );
            }
          }
        }
        final resultingState =
            outcome == _StateOutcome.created ||
                outcome == _StateOutcome.updated
            ? state!
            : (current?.state ?? thread!.state);
        final reopen =
            !creating &&
            ThreadStates.isClosed(current?.state ?? thread.state) &&
            !ThreadStates.isClosed(resultingState);

        // Live-title uniqueness in the target project (write-path rule,
        // contract §3 – the schema cannot express it, see model.dart).
        if (!ThreadStates.isClosed(resultingState) &&
            (creating || rename || move || reopen)) {
          final clash = _threadsByTitle(
            targetProject,
            ScopeKey.of(targetTitle),
            live: true,
          ).where((t) => t.id != thread?.id).firstOrNull;
          if (clash != null) {
            final hint = creating
                ? 'pass threadId: ${clash.id} to update it, or a different '
                      'title'
                : 'rename this thread first, or update or drop thread '
                      '${clash.id}';
            throw ValidationException(
              '$tool: a live thread titled '
              '"${MemoryService.sanitizeForLog(clash.title)}" already exists '
              'in project "${MemoryService.sanitizeForLog(targetProject)}" '
              '(id ${clash.id}, state ${clash.state}) – $hint. Nothing was '
              'written.',
            );
          }
        }
        final attachEntries = attachIds == null
            ? const <MemoryEntry>[]
            : _requireEntriesExist(
                attachIds,
                tool: tool,
                nothing: 'nothing written',
              );

        // -- Writes ------------------------------------------------------
        var versionBump = false;
        final stateRowWritten = <ThreadState>[];
        if (creating) {
          final closedSame = _threadsByTitle(
            targetProject,
            ScopeKey.of(targetTitle),
            live: false,
          );
          thread = Thread(
            title: targetTitle,
            titleKey: ScopeKey.of(targetTitle),
            project: targetProject,
            state: state!,
            stateEventAt: event,
            stateRecordedAt: now,
            pausedUntil: pausedUntil?.toUtc(),
            createdAt: now,
            updatedAt: now,
          );
          thread.id = _threads.put(thread);
          for (final w in _registerProjectInTx(
            targetProject,
            reason: tool,
          )) {
            warn(w);
          }
          if (closedSame.isNotEmpty) {
            final c = closedSame.last;
            final since = c.stateEventAt == null
                ? 'recorded ${_shownDate(c.stateRecordedAt)}'
                : 'since ${_shownDate(c.stateEventAt!)}';
            warn(
              'a closed thread with the same title exists (id ${c.id}, '
              '${c.state} $since) – a new thread was created; to reopen the '
              'old one instead, pass threadId: ${c.id}.',
            );
          }
        }
        final t = thread;
        final renamedFrom = rename ? t.title : null;
        final projectFrom = move ? t.project : null;
        if (rename) {
          t
            ..title = targetTitle
            ..titleKey = ScopeKey.of(targetTitle);
          versionBump = true;
        }
        if (move) {
          t.project = targetProject;
          versionBump = true;
          for (final w in _registerProjectInTx(targetProject, reason: tool)) {
            warn(w);
          }
        }

        switch (outcome) {
          case _StateOutcome.created:
          case _StateOutcome.updated:
          case _StateOutcome.historyAdded:
            // A new current row must be the newest by recordedAt even if
            // another device's clock ran ahead: max(now, latest + 1 ms).
            var recordedAt = now;
            if (outcome != _StateOutcome.historyAdded) {
              for (final r in rows) {
                if (r.asHistory || r.recordedAt.isBefore(recordedAt)) continue;
                recordedAt = r.recordedAt.add(const Duration(milliseconds: 1));
              }
            }
            final row = ThreadState(
              state: state!,
              eventAt: event,
              recordedAt: recordedAt,
              pausedUntil: pausedUntil?.toUtc(),
              sourceRef: sourceRef,
              asHistory: outcome == _StateOutcome.historyAdded,
            )..thread.targetId = t.id;
            row.id = _threadStates.put(row);
            rows.add(row);
            stateRowWritten.add(row);
            if (!creating) versionBump = true;
            if (outcome == _StateOutcome.historyAdded) {
              log(
                '[memory] $tool thread ${t.id}: late info ($state at '
                '${_shownDate(event!)}) stored as history – current state '
                'unchanged',
              );
            }
          case _StateOutcome.dated:
            current!.eventAt = event;
            _threadStates.put(current);
            stateRowWritten.add(current);
            versionBump = true;
          case _StateOutcome.unchanged:
          case null:
            break;
        }

        // pausedUntil (plan §3.5): explicit set/clear, or cleared when the
        // thread leaves the paused state.
        var pausedUntilCleared = false;
        var pausedUntilSet = false;
        if (!creating) {
          if (clearPausedUntil) {
            if (t.pausedUntil != null) {
              t.pausedUntil = null;
              pausedUntilCleared = true;
              versionBump = true;
            } else {
              warn('clearPausedUntil: the thread had no pausedUntil.');
            }
          } else if (pausedUntil != null &&
              (refused || outcome == _StateOutcome.historyAdded)) {
            // Late or refused information: its pause date belongs to that
            // history row (if one was written), never to the thread.
            warn(
              outcome == _StateOutcome.historyAdded
                  ? 'pausedUntil was kept on the history row only – the '
                        "thread's pause date is unchanged."
                  : 'pausedUntil was not applied – it came with information '
                        'that did not change the state history.',
            );
          } else if (pausedUntil != null) {
            if (!_sameInstant(t.pausedUntil, pausedUntil.toUtc())) {
              t.pausedUntil = pausedUntil.toUtc();
              pausedUntilSet = true;
              versionBump = true;
            }
          } else if (outcome == _StateOutcome.updated &&
              resultingState != ThreadStates.paused &&
              t.pausedUntil != null) {
            t.pausedUntil = null;
            pausedUntilCleared = true;
            versionBump = true;
            log(
              '[memory] $tool thread ${t.id}: left paused – pausedUntil '
              'cleared',
            );
          }
        }
        if (pausedUntil != null &&
            !refused &&
            outcome != _StateOutcome.historyAdded &&
            resultingState != ThreadStates.paused) {
          warn(
            'pausedUntil was stored, but the thread is $resultingState, not '
            'paused.',
          );
        }

        final newCurrent = _currentStateRow(rows);
        if ((outcome == _StateOutcome.created ||
                outcome == _StateOutcome.updated) &&
            newCurrent?.id != stateRowWritten.single.id) {
          // Never report "updated" for a state that did not become current.
          throw StateError(
            '$tool thread ${t.id}: the new ${stateRowWritten.single.state} '
            'row ${stateRowWritten.single.id} is not the current row '
            '(${newCurrent?.id}) after the write – aborted, nothing written.',
          );
        }
        if (_recomputeThreadState(t, newCurrent) && !creating) {
          log(
            '[memory] $tool thread ${t.id}: current state now ${t.state}',
          );
        }
        if (staleCopy) {
          log(
            '[memory] $tool repaired thread ${t.id}: stored state $staleFrom '
            'disagreed with its history – now ${t.state}',
          );
          warn(
            'the stored copy of the state ($staleFrom) disagreed with the '
            'history and was repaired (now ${t.state}).',
          );
        }

        // Note: one entry through the shared creation path, indexed in
        // this transaction (vector embedded before the lending).
        Map<String, Object?>? noteResult;
        final attached = <int>[];
        final alreadyAttached = <int>[];
        final fromOtherProject = <int>[];
        if (normalizedNote != null) {
          final noteEntry = MemoryEntry(
            title: MemoryService._deriveTitle(normalizedNote),
            text: normalizedNote,
            kind: MemoryKind.snapshot,
            sourceType: sourceType,
            sourceRef: sourceRef,
            project: t.project,
            language: language,
            contentHash: noteHash!,
          );
          final put = _putEntryInTx(
            noteEntry,
            reason: tool,
            warnings: warnings,
          );
          final existing = put.existing;
          if (existing != null) {
            warn(
              'the note text is already stored as entry ${existing.id} – '
              'attached instead of stored again.',
            );
            noteResult = {'id': existing.id, 'duplicate': true};
            if (existing.project != t.project) fromOtherProject.add(existing.id);
          } else {
            if (noteVector != null) {
              _upsertIndexRow(put.id, normalizedNote, noteHash, noteVector);
            } else {
              warnings.add(embedWarning!);
            }
            noteResult = {
              'id': put.id,
              'duplicate': false,
              'indexed': noteVector != null,
            };
          }
          final noteId = noteResult['id'] as int;
          (_attachEntryInTx(t.id, noteId, via: ThreadVia.note, now: now)
                  ? attached
                  : alreadyAttached)
              .add(noteId);
        }
        for (final e in attachEntries) {
          (_attachEntryInTx(t.id, e.id, via: ThreadVia.attach, now: now)
                  ? attached
                  : alreadyAttached)
              .add(e.id);
          if (e.project != t.project) fromOtherProject.add(e.id);
        }
        if (fromOtherProject.isNotEmpty) {
          warn(_otherProjectAttachWarning(fromOtherProject, t.project));
        }

        final otherChange =
            rename ||
            move ||
            pausedUntilCleared ||
            pausedUntilSet ||
            attached.isNotEmpty;
        if (versionBump) t.version++;
        if (creating || versionBump || otherChange || staleCopy) {
          t.updatedAt = now;
          _threads.put(t);
        }

        final String action;
        if (outcome != null && outcome != _StateOutcome.unchanged) {
          action = outcome.name;
        } else {
          action = otherChange || versionBump || staleCopy
              ? 'updated'
              : 'unchanged';
        }
        final stateRow = stateRowWritten.firstOrNull;
        final result = <String, Object?>{
          'threadId': t.id,
          'action': action,
          'title': t.title,
          'project': t.project,
          'state': t.state,
          'since': t.stateEventAt?.toIso8601String(),
          'sinceRecordedAt': t.stateRecordedAt.toIso8601String(),
          'pausedUntil': t.pausedUntil?.toIso8601String(),
          'version': t.version,
          'previousVersion': ?previousVersion,
          if (stateRow != null)
            'stateRow': {
              'id': stateRow.id,
              'state': stateRow.state,
              'eventAt': stateRow.eventAt?.toIso8601String(),
              'recordedAt': stateRow.recordedAt.toIso8601String(),
              'appliedAsHistory': stateRow.asHistory,
            },
          'note': ?noteResult,
          if (attached.isNotEmpty) 'attached': attached,
          if (alreadyAttached.isNotEmpty) 'alreadyAttached': alreadyAttached,
          if (fromOtherProject.isNotEmpty)
            'attachedFromOtherProject': fromOtherProject,
          'renamedFrom': ?renamedFrom,
          'projectFrom': ?projectFrom,
          if (pausedUntilCleared) 'pausedUntilCleared': true,
          if (warnings.isNotEmpty) 'warning': {...warnings}.join(' '),
        };
        if (idempotencyKey != null) {
          _threadOps.put(
            ThreadOp(
              key: idempotencyKey,
              threadId: t.id,
              version: t.version,
              argsHash: argsHash,
              resultJson: jsonEncode(result),
              createdAt: now,
            ),
          );
        }
        log(
          '[memory] $tool thread ${t.id} '
          '"${MemoryService.sanitizeForLog(t.title)}": action=$action '
          'state=${t.state} eventAt=${event?.toIso8601String() ?? '-'} '
          'version=${t.version} note=${noteResult?['id'] ?? '-'} '
          'attached=${attached.length} '
          'history=${outcome == _StateOutcome.historyAdded} replayed=false',
        );
        return _applyGuardPeerWarning(result);
      });
    });
  }

  // ---------------------------------------------------------------------
  // thread_list / thread_get (read-only)
  // ---------------------------------------------------------------------

  /// Lists threads – see [readThreadRows] for the filters. [area] resolves
  /// to its projects like `list_recent`'s (same warnings).
  Future<Map<String, Object?>> threadList({
    String? project,
    String? area,
    List<String>? states,
    bool includeClosed = false,
    int limit = threadListDefaultLimit,
  }) {
    const tool = 'thread_list';
    if (limit < 1 || limit > threadListMaxLimit) {
      throw ValidationException(
        '$tool: limit must be 1-$threadListMaxLimit, got $limit.',
      );
    }
    if (project != null) {
      MemoryService._requireLen('project', project, MemoryService.projectMaxLen);
    }
    for (final s in states ?? const <String>[]) {
      _requireThreadState(s, tool: tool);
    }
    return _withSession(tool, () {
      return store.runInTransaction(TxMode.read, () {
        List<String>? projects = project == null ? null : [project];
        if (area != null) {
          final areaProjects = _resolveAreaProjects(area);
          String? empty;
          if (project != null && !areaProjects.contains(project)) {
            empty =
                'project "${MemoryService.sanitizeForLog(project)}" is not a '
                'member of area "${MemoryService.sanitizeForLog(area)}".';
          } else if (areaProjects.isEmpty) {
            empty = 'area "${MemoryService.sanitizeForLog(area)}" has no '
                'projects.';
          }
          if (empty != null) {
            log('[memory] $tool: $empty');
            return {
              'count': 0,
              'total': 0,
              'truncated': false,
              'threads': const [],
              'warning': empty,
            };
          }
          projects ??= areaProjects;
        }
        final read = readThreadRows(
          _requireSession(tool),
          projects: projects,
          states: states,
          includeClosed: includeClosed,
          limit: limit,
        );
        if (read.truncated) {
          log(
            '[memory] $tool: ${read.total} threads match, ${read.threads.length} '
            'listed (limit $limit)',
          );
        }
        return {
          'count': read.threads.length,
          'total': read.total,
          'truncated': read.truncated,
          'threads': read.threads,
          if (read.truncated)
            'warning':
                '${read.total} threads match; only the first '
                '${read.threads.length} are listed – raise limit (at most '
                '$threadListMaxLimit) or filter by project/state.',
        };
      });
    });
  }

  /// One thread with its full state history and its entries. Strictly
  /// read-only (amendment A9): a denormalized state that disagrees with the
  /// history rows is reported (warning + log), and repaired by the next
  /// `thread_update` on the thread.
  Future<Map<String, Object?>> threadGet({
    int? threadId,
    String? title,
    String? project,
    bool includeText = false,
  }) {
    const tool = 'thread_get';
    if (threadId == null && (title == null || project == null)) {
      throw ValidationException(
        '$tool: pass threadId, or title and project.',
      );
    }
    if (title != null) {
      MemoryService._requireLen('title', title, threadTitleMaxLen);
    }
    if (project != null) {
      MemoryService._requireLen('project', project, MemoryService.projectMaxLen);
    }
    return _withSession(tool, () {
      return store.runInTransaction(TxMode.read, () {
        final now = DateTime.now().toUtc();
        final Thread thread;
        if (threadId != null) {
          thread = _requireThread(threadId, tool: tool);
        } else {
          final key = ScopeKey.of(title!);
          var matches = _threadsByTitle(project!, key, live: true);
          if (matches.isEmpty) {
            matches = _threadsByTitle(project, key, live: false);
          }
          if (matches.isEmpty) {
            throw ValidationException(
              '$tool: no thread titled "${MemoryService.sanitizeForLog(title)}" '
              'in project "${MemoryService.sanitizeForLog(project)}" – '
              'thread_list shows the existing ones.',
            );
          }
          if (matches.length > 1) {
            throw ValidationException(
              '$tool: ${matches.length} threads match the title '
              '"${MemoryService.sanitizeForLog(title)}" in project '
              '"${MemoryService.sanitizeForLog(project)}" (ids '
              '${matches.map((t) => t.id).join(', ')}) – pass threadId.',
            );
          }
          thread = matches.single;
        }

        final warnings = <String>[];
        final rows = _threadStateRows(thread.id)..sort(_compareHistory);
        final current = _currentStateRow(rows);
        if (current != null &&
            (current.state != thread.state ||
                !_sameInstant(current.eventAt, thread.stateEventAt) ||
                !current.recordedAt.isAtSameMomentAs(
                  thread.stateRecordedAt,
                ))) {
          final msg =
              'thread ${thread.id}: the stored state (${thread.state}) '
              'disagrees with its history (current row ${current.id}: '
              '${current.state}) – the history is authoritative; the next '
              'thread_update on this thread repairs the stored copy.';
          warnings.add(msg);
          log('[memory] $tool: $msg');
        }

        final links = _useQuery(
          _threadEntries.query(ThreadEntry_.thread.equals(thread.id)),
          (q) => q.find(),
        )..sort((a, b) {
            final byTime = b.attachedAt.compareTo(a.attachedAt);
            return byTime != 0 ? byTime : b.id.compareTo(a.id);
          });
        final entries = <Map<String, Object?>>[];
        final missing = <int>[];
        // A link whose entry id reads back as 0 (the entry row is gone and
        // the binding no longer reports its id) is identified by the link
        // row's own id instead.
        final danglingLinks = <int>[];
        // One getMany for every attached entry (id 0 stays unresolved).
        final linkedIds = [
          for (final l in links)
            if (l.entry.targetId != 0) l.entry.targetId,
        ];
        final loaded = <int, MemoryEntry>{
          for (final e in _entries.getMany(linkedIds).whereType<MemoryEntry>())
            e.id: e,
        };
        for (final link in links) {
          final entryId = link.entry.targetId;
          final entry = loaded[entryId];
          if (entry == null) {
            (entryId == 0 ? danglingLinks : missing).add(
              entryId == 0 ? link.id : entryId,
            );
            continue;
          }
          entries.add({
            ..._entrySummary(entry, includeText: includeText),
            'attachedAt': link.attachedAt.toIso8601String(),
            'via': link.via,
          });
        }
        final goneCount = missing.length + danglingLinks.length;
        if (goneCount > 0) {
          final msg =
              '$goneCount attached entr'
              '${goneCount == 1 ? 'y no longer exists' : 'ies no longer exist'} '
              '– e.g. replaced on another device; listed in missingEntryIds '
              '(entry ids) and danglingAttachmentIds (attachment rows whose '
              'entry id is unknown).';
          warnings.add(msg);
          log(
            '[memory] $tool thread ${thread.id}: $msg missing='
            '${missing.join(',')} dangling=${danglingLinks.join(',')}',
          );
        }
        return {
          ...threadRowOf(thread, now, entryCount: links.length),
          'history': [
            for (final r in rows)
              {
                'id': r.id,
                'state': r.state,
                'eventAt': r.eventAt?.toIso8601String(),
                'recordedAt': r.recordedAt.toIso8601String(),
                'pausedUntil': r.pausedUntil?.toIso8601String(),
                'sourceRef': r.sourceRef,
                'asHistory': r.asHistory,
                'current': r.id == current?.id,
              },
          ],
          'entries': entries,
          if (missing.isNotEmpty) 'missingEntryIds': missing,
          if (danglingLinks.isNotEmpty) 'danglingAttachmentIds': danglingLinks,
          '_provenance_note': MemoryService._provenanceNote,
          if (warnings.isNotEmpty) 'warning': warnings.join(' '),
        };
      });
    });
  }
}
