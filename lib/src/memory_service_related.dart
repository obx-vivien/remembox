/// Related-entry suggestions on write – `remember`/`supersede` return up to
/// [MemoryService.relatedMax] existing LIVE entries that are semantically
/// close to the entry just written (plus a count of further ones above the
/// bar that were not shown), so the caller can link them (or supersede one)
/// without having to recall first.
///
/// Why this exists: links are the main lever for finding a thread of
/// memories later, but at write time the caller does not know which earlier
/// entries concern the same thing, so almost no links were ever created.
/// This closes that gap deterministically at tool level instead of asking a
/// prompt to remember to search first.
///
/// Reuse, not a second search: the candidates come from
/// [MemoryService._annSearch] – the very ANN query [recall] uses – with the
/// vector the write already computed and indexed (no extra embed call), one
/// query with a small k. The per-candidate liveness checks mirror the ones
/// in `_recallBody` (same model, fresh hash, not expired, not superseded);
/// recall counts why it drops each candidate for its own warnings, which is
/// why these few conditions are not literally shared code.
part of 'memory_service.dart';

/// One link to create in the same write transaction as a `remember` call
/// (the `links` argument): the new entry is always the link's SOURCE, so
/// [toId] is an existing entry the new one points at.
class LinkSpec {
  final int toId;
  final String type;
  final String note;

  const LinkSpec({required this.toId, required this.type, this.note = ''});
}

/// Outcome of the related search: the shown [items], how many further live
/// candidates above the bar were not shown ([more]) and whether that count
/// is only a lower bound ([moreIsLowerBound]: the ANN fetch was saturated,
/// so candidates beyond it were never looked at).
class RelatedSuggestions {
  final List<Map<String, Object?>> items;
  final int more;
  final bool moreIsLowerBound;

  const RelatedSuggestions({
    required this.items,
    required this.more,
    required this.moreIsLowerBound,
  });

  const RelatedSuggestions.none()
    : items = const [],
      more = 0,
      moreIsLowerBound = false;

  /// The `relatedHint` text, or null when there is nothing to say (no items
  /// and no saturation).
  String? get hint => items.isEmpty && !moreIsLowerBound
      ? null
      : MemoryService.relatedHintFor(
          hasItems: items.isNotEmpty,
          hasWeak: items.any((i) => i['weak'] == true),
          more: more,
          moreIsLowerBound: moreIsLowerBound,
        );
}

extension MemoryServiceRelated on MemoryService {
  /// Pure validation of a `remember` call's `links` list (cap, type, note
  /// length) – everything that does not need the store, so a bad list is
  /// rejected before anything is embedded or written. Target existence is
  /// checked inside the write transaction by [_createLinkInTx].
  void _requireLinkSpecs(List<LinkSpec> links) {
    if (links.length > MemoryService.maxLinksPerRemember) {
      throw ValidationException(
        'Too many links: ${links.length} exceeds the '
        '${MemoryService.maxLinksPerRemember} links allowed per remember '
        'call. Create the rest with the link tool.',
      );
    }
    for (final l in links) {
      _requireLinkFields(l.type, l.note);
    }
  }

  /// Finds up to [MemoryService.relatedMax] live entries close to the entry
  /// [entryId] whose just-computed [vector] is given. Same-project
  /// candidates rank first, then others, each group by similarity
  /// (descending). Only candidates at or above
  /// [MemoryService.relatedMinSimilarity] qualify; those at or above
  /// [MemoryService.relatedLikelySameSimilarity] are flagged
  /// `likelySameThing`. Qualifying candidates beyond the cap are counted in
  /// [RelatedSuggestions.more], never dropped silently. If the ANN fetch was
  /// saturated (full, and even its farthest candidate still at or above the
  /// bar) there may be qualifying entries that were never fetched, so the
  /// count is flagged as a lower bound.
  ///
  /// Weak tier ([MemoryService.relatedWeakMinSimilarity]): if no same-project
  /// candidate qualifies, the nearest live same-project candidate below the
  /// bar but at or above the weak minimum is added as the first item, marked
  /// `weak: true`. It takes one of the [MemoryService.relatedMax] slots and
  /// is not part of the `more` count.
  ///
  /// [excludeIds] are never returned (supersede passes the entry being
  /// replaced: it is about to become history and is not a link candidate).
  ///
  /// MUST be called from inside a StoreGate lending. Throws on store
  /// failure – the caller ([MemoryService.remember]) logs and downgrades
  /// that to a warning so the write itself still succeeds.
  RelatedSuggestions _findRelated({
    required int entryId,
    required List<double> vector,
    required String project,
    required Set<int> excludeIds,
  }) {
    final now = DateTime.now().toUtc();
    final picked =
        <({MemoryEntry entry, double similarity, bool sameProject})>[];
    var considered = 0,
        otherModel = 0,
        stale = 0,
        expired = 0,
        superseded = 0,
        excluded = 0,
        belowBar = 0;
    var saturated = false;
    ({MemoryEntry entry, double similarity})? weakCandidate;
    store.runInTransaction(TxMode.read, () {
      final candidates = _annSearch(vector, MemoryService.relatedFetchK);
      considered = candidates.length;
      // Saturation is judged on ALL fetched candidates, whatever happens to
      // them below: a full fetch whose farthest hit still clears the bar
      // says nothing about what lies beyond it.
      var farthest = 1.0;
      for (final hit in candidates) {
        final sim = MemoryService.similarityOfDistance(hit.score);
        if (sim < farthest) farthest = sim;
      }
      saturated =
          considered >= MemoryService.relatedFetchK &&
          farthest >= MemoryService.relatedMinSimilarity;
      for (final hit in candidates) {
        final row = hit.object;
        // The entry itself is not a drop worth counting.
        if (row.entryId == 0 || row.entryId == entryId) continue;
        if (excludeIds.contains(row.entryId)) {
          excluded++;
          continue;
        }
        if (row.embedModel != embedder.modelId) {
          otherModel++;
          continue;
        }
        final entry = _entries.get(row.entryId);
        if (entry == null || row.textHash != entry.contentHash) {
          stale++;
          continue;
        }
        if (entry.isExpiredAt(now)) {
          expired++;
          continue;
        }
        if (entry.isSuperseded) {
          superseded++;
          continue;
        }
        final similarity = MemoryService.similarityOfDistance(hit.score);
        if (similarity < MemoryService.relatedMinSimilarity) {
          belowBar++;
          final best = weakCandidate;
          if (entry.project == project &&
              similarity >= MemoryService.relatedWeakMinSimilarity &&
              (best == null || similarity > best.similarity)) {
            weakCandidate = (entry: entry, similarity: similarity);
          }
          continue;
        }
        picked.add((
          entry: entry,
          similarity: similarity,
          sameProject: entry.project == project,
        ));
      }
    });
    picked.sort((a, b) {
      if (a.sameProject != b.sameProject) return a.sameProject ? -1 : 1;
      return b.similarity.compareTo(a.similarity);
    });
    // Weak tier only when no same-project candidate qualified; it takes a
    // slot of the cap but is not counted in `more`.
    final weak = picked.any((p) => p.sameProject) ? null : weakCandidate;
    final top = picked
        .take(MemoryService.relatedMax - (weak == null ? 0 : 1))
        .toList();
    final more = picked.length - top.length;
    final shown = top.length + (weak == null ? 0 : 1);
    log(
      '[memory] related for entry $entryId: $shown shown'
      '${weak == null ? '' : ' (1 weak)'}, $more more'
      '${saturated ? ' (lower bound: candidate fetch saturated)' : ''}, of '
      '$considered ANN candidate(s); dropped: other model $otherModel, '
      'stale/orphaned $stale, expired $expired, superseded $superseded, '
      'excluded $excluded, below ${MemoryService.relatedMinSimilarity} '
      '$belowBar',
    );
    Map<String, Object?> item(
      MemoryEntry entry,
      double similarity, {
      required bool isWeak,
    }) => {
      'id': entry.id,
      'title': entry.title,
      'project': entry.project,
      'kind': entry.kind,
      // Same definition as recall (1 - cosineDistance / 2), rounded for
      // readability – three decimals are far finer than the scale needs.
      'similarity': (similarity * 1000).round() / 1000,
      'createdAt': entry.createdAt.toIso8601String(),
      // The item is the OLDER entry: probably an older state of what was
      // just written (see the constant). Decided on the unrounded
      // similarity; a weak item never qualifies.
      if (!isWeak && similarity >= MemoryService.relatedLikelySameSimilarity)
        'likelySameThing': true,
      if (isWeak) 'weak': true,
      // SEC-4: same lower-trust signal recall hits carry.
      if (MemoryService._isExternallySourced(entry.sourceType))
        'externallySourced': true,
    };
    return RelatedSuggestions(
      items: [
        if (weak != null) item(weak.entry, weak.similarity, isWeak: true),
        for (final p in top) item(p.entry, p.similarity, isWeak: false),
      ],
      more: more,
      moreIsLowerBound: saturated,
    );
  }
}
