/// Tag discipline – 2026-09-21, tag discipline (0.3.0).
///
/// Tags are cross-project labels (people, recurring topics, markers like
/// `status`/`lesson`/`todo`) – NOT a second copy of `project`, `kind` or an
/// area name (those are already filterable on `recall`/`list_recent`/
/// `fact_query`), and not an identifier/version (those belong in the text).
/// [_prepareTags] is the SINGLE enforcement point for this rule, called by
/// every write path that attaches tags (`remember` directly; `supersede`
/// indirectly, since it always calls `remember`) – see that method's doc.
///
/// 2026-09-21, entries move (0.3.0): [_prepareTags] also drops a raw tag
/// outright (with a warning, before normalization) if it contains a
/// control character – see that method's Step 0 for why this is a DROP,
/// not the LOG-only sanitization SEC-5 applies elsewhere.
///
/// This file also owns the three tag-maintenance tools: [tagsList] (usage
/// counts + variant groups, to encourage reuse over inventing a new tag),
/// [tagMerge] and [tagRemove] (bulk rewrites over the tag graph, both
/// `dryRun`-capable, modeled on [MemoryServiceAreas.projectMerge]).
///
/// Neither `tagMerge` nor `tagRemove` touches [MemoryEntry.text]/
/// [MemoryEntry.contentHash] or the vector index ([MemoryIndex]) – tags are
/// not embedded, so a tag-graph rewrite never invalidates or needs to
/// refresh an entry's index row.
///
/// Sync note (same shape as [MemoryEntry.contentHash]'s doc): [Tag] is
/// `@Sync()` with `@Unique(onConflict: ConflictStrategy.replace)` on `name`.
/// Merging/removing a tag on one device while another device is still
/// writing the OLD name can re-create a `from`/removed tag row via that
/// device's own `_getOrCreateTag` call after this tool already ran. Both
/// tools are idempotent and safe to re-run (a re-run of `tag_merge` simply
/// finds the just-recreated `from` row and merges it again; a re-run of
/// `tag_remove` reports it via `notFound` once it is gone, or removes it
/// again if it came back) – this is the same "no alias, re-run instead"
/// discipline [MemoryServiceAreas.projectMerge] already uses for projects.
part of 'memory_service.dart';

/// Identifier-like tag shapes (F-16 / T-42 / GTD-7 / PHASE-2 style ticket,
/// task or run ids) – checked AFTER normalization, which never leaves a
/// `-` in the result (see [_normalizeTag]: separators are consumed, not
/// preserved), so this pattern has no optional hyphen, unlike the
/// raw-input shapes it is meant to catch.
final RegExp _tagIdentifierPattern = RegExp(r'^(t|b|f|fx|gtd|phase)\d+$');

/// A version-number substring (`5.3.2`, `4.1`) anywhere in the normalized
/// tag – dots are not a separator [_normalizeTag] touches, so a version
/// number survives normalization unchanged and this check still finds it.
final RegExp _tagVersionPattern = RegExp(r'\d+\.\d+');

/// A bare `v`-prefixed version number (`v5`, `v12`) with no dot – the
/// counterpart of [_tagVersionPattern] (2026-09-21 review3 m5 fix:
/// `v5.3` was already caught by `\d+\.\d+`, but `v5` alone was not).
final RegExp _tagVOnlyVersionPattern = RegExp(r'^v\d+$');

/// A tag that is purely digits post-normalization – normalization never
/// leaves a `-` in its output (see [_normalizeTag]), so unlike the original
/// "digits and -" brief this is just digits.
final RegExp _tagDigitsOnlyPattern = RegExp(r'^\d+$');

/// True if [normalized] looks like an identifier or version number and
/// should be WARNED about, never dropped – the single shared check behind
/// [_prepareTags] Step 5 and [MemoryServiceTags.tagMerge]'s own `into`
/// check (2026-09-21 review3 M3 fix: `into` used to skip this rule
/// entirely), so the two never drift apart (CLAUDE.md "No duplicated
/// logic").
bool _looksLikeIdentifierOrVersion(String normalized) =>
    _tagIdentifierPattern.hasMatch(normalized) ||
    _tagVersionPattern.hasMatch(normalized) ||
    _tagDigitsOnlyPattern.hasMatch(normalized) ||
    _tagVOnlyVersionPattern.hasMatch(normalized);

/// A "part" that is entirely uppercase letters/digits – an acronym
/// (`KPI`, `GA4`, `ISO9001`, `ÄÖÜ`) or a plain number (`9001`,
/// case-invariant either way) – gets lowercased as a whole by
/// [_normalizeTag] instead of having its inner casing preserved.
///
/// 2026-09-21 review3 m3 fix: `\p{Lu}`/`\p{Nd}` (Unicode uppercase
/// letter / decimal digit, `unicode: true`) instead of the ASCII-only
/// `A-Z0-9` – a superset, so every previously-matching part still
/// matches, and a non-ASCII all-uppercase part (`ÄÖÜ`, `ÉCOLE`) now does
/// too instead of only having its first letter case-adjusted.
final RegExp _tagAcronymPart = RegExp(r'^[\p{Lu}\p{Nd}]+$', unicode: true);

/// Splits a glued leading acronym off a following capitalized word within
/// one already-separator-split part – e.g. `GA4Report` -> `GA4` + `Report`,
/// `XMLHttpRequest` -> `XML` + `HttpRequest` (2026-09-21 review3 m4 fix).
///
/// Anchored at the START of the part (`^`), so a part that itself starts
/// with a lowercase letter (`iOS`, `macOS`) never matches and is left
/// alone, exactly as before this fix. The greedy `[\p{Lu}\p{Nd}]+` first
/// claims every leading uppercase/digit character, then backtracks (as
/// regex engines do) until what remains starts with `[\p{Lu}][\p{Ll}]` –
/// an uppercase letter immediately followed by a lowercase one, i.e. the
/// first letter of the NEXT capitalized word. That backtracking is what
/// correctly leaves the LAST letter of a glued all-caps run (the `H` of
/// `XMLHttp`) attached to the following word instead of the acronym.
final RegExp _tagGluedAcronymSplit = RegExp(
  r'^([\p{Lu}\p{Nd}]+)([\p{Lu}][\p{Ll}].*)$',
  unicode: true,
);

/// An acronym pluralized with a trailing lowercase `s` (`APIs`, `PDFs`,
/// `URLs`, `LLMs`, `IDs`) – checked BEFORE [_tagGluedAcronymSplit] (2026-09-21
/// review4 N2 fix) so the whole part is recognized and lowercased as one
/// unit instead of being glue-split. Without this check,
/// [_tagGluedAcronymSplit] treats the trailing `s` as the start of a new
/// glued word (its pattern only requires `[\p{Lu}][\p{Ll}]`, which the last
/// acronym letter + `s` satisfies, e.g. `AP`+`Is`), producing a mangled
/// `apIs`/`pdFs`/`urLs` instead of the correct `apis`/`pdfs`/`urls`.
/// Requires at least 2 characters before the `s` ({2,}) so a single
/// uppercase letter plus `s` (unlikely to be a real acronym plural) is left
/// to the ordinary rules; `MCPServer`-style glued-word parts still fail this
/// (they contain lowercase letters before the final run), so they are
/// unaffected and still split normally.
final RegExp _tagAcronymPluralPart = RegExp(
  r'^[\p{Lu}\p{Nd}]{2,}s$',
  unicode: true,
);

/// Runs of whitespace, `-` or `_` – the separators [_normalizeTag] splits
/// a raw tag on. Leading/trailing separators produce empty parts, which are
/// dropped (this IS the "strip leading/trailing separator" rule – no
/// extra step needed).
final RegExp _tagSeparatorPattern = RegExp(r'[\s\-_]+');

/// A trailing `es`, `en`, `e` or `s` – stripped by [_tagKey] for a LOOSE
/// (near-duplicate / redundancy-warning) comparison only, NEVER for the
/// stored/normalized form itself and NEVER to decide a drop (2026-09-21
/// review3 M1 fix – see [_prepareTags] Step 2's doc).
///
/// 2026-09-21 review3 M1 fix: `es` was missing. The three-alternative
/// version's own doc used to claim "only one alternative can ever match at
/// a fixed string end … so order does not matter" – that claim is exactly
/// what hid the bug: `rules` (`s` alternative -> `rule`) and `rule` (`e`
/// alternative -> `rul`) landed on DIFFERENT keys, so `rule`/`rules` never
/// shared a group, while `episode`/`episodes` accidentally did only
/// because `episodes` never reached the `s`-only branch. With `es` added,
/// alternative ORDER matters and must stay `es` before `s` (and before
/// `en`/`e`): `String.replaceFirst` finds the EARLIEST position in the
/// string where the pattern can match, and at the position two characters
/// before the end, `es` matches first – so `rules`/`rule` both -> `rul`,
/// `episodes`/`episode` both -> `episod`, `references`/`reference` both
/// -> `referenc`, consistently.
final RegExp _tagKeyPluralSuffix = RegExp(r'(es|en|e|s)$');

/// Exact-match kind lookup, keyed by the lowercased NORMALIZED kind name –
/// shared between [_prepareTags] Step 2 and [MemoryServiceTags.tagMerge]'s
/// `into` check (2026-09-21 review4 m8 fix: extracted so the two call
/// sites build this map identically, CLAUDE.md "No duplicated logic" –
/// before this both built the same map inline, independently).
Map<String, String> _kindByNormalizedLower() => {
  for (final k in MemoryKind.all) _normalizeTag(k).toLowerCase(): k,
};

/// Loose-key kind lookup – the [_tagKey] counterpart of
/// [_kindByNormalizedLower], shared the same way (2026-09-21 review4 m8
/// fix: [MemoryServiceTags.tagMerge]'s `into` check did not have this at
/// all before, so `into: "decisions"` warned about nothing even though an
/// ordinary tag "decisions" on a `remember` call warns as a near-duplicate
/// of the kind "decision" via [_prepareTags] Step 2b).
Map<String, String> _kindByLooseKey() => {
  for (final k in MemoryKind.all) _tagKey(_normalizeTag(k)): k,
};

/// How a normalized tag repeats a project, kind or area name – the result
/// of [_TagRedundancyContext.classify]. `exact*` means the normalized
/// strings are equal (case-insensitively); `near*` means only the loose
/// [_tagKey] matches.
enum _TagRedundancy {
  none,
  exactProject,
  exactKind,
  exactArea,
  nearProject,
  nearKind,
  nearArea,
}

/// The redundancy check behind [MemoryServiceTags._prepareTags] Step 2/2b
/// and `tag_define` – ONE classifier, two callers with different
/// candidate sets: `_prepareTags` passes the entry's own project and the
/// areas that project belongs to; `tag_define` (no entry, no single
/// project) passes every registered project and every area. Each caller
/// formats its own message from the result.
///
/// Pure: the lookup maps are built once from the candidate names, then
/// [classify] runs per tag with no store access.
class _TagRedundancyContext {
  final Map<String, String> _projectExact = {};
  final Map<String, String> _projectLoose = {};
  final Map<String, String> _kindExact = _kindByNormalizedLower();
  final Map<String, String> _kindLoose = _kindByLooseKey();
  final Map<String, String> _areaExact = {};
  final Map<String, String> _areaLoose = {};

  /// [projects]/[areas] in a deterministic order; when two candidates
  /// share a key, the later one wins for exact keys and the first one for
  /// loose keys – the same rule the inline maps of `_prepareTags` used.
  _TagRedundancyContext({
    required Iterable<String> projects,
    required Iterable<String> areas,
  }) {
    for (final p in projects) {
      final normalized = _normalizeTag(p);
      _projectExact[normalized.toLowerCase()] = p;
      _projectLoose.putIfAbsent(_tagKey(normalized), () => p);
    }
    for (final a in areas) {
      final normalized = _normalizeTag(a);
      _areaExact[normalized.toLowerCase()] = a;
      _areaLoose[_tagKey(normalized)] = a;
    }
  }

  /// Classifies an already-normalized tag. Exact matches are checked
  /// before loose ones, and project before kind before area – the order
  /// `_prepareTags` Step 2/2b has always used. [matched] is the project,
  /// kind or area name that matched (null for [_TagRedundancy.none]).
  ({_TagRedundancy kind, String? matched}) classify(String normalized) {
    final lower = normalized.toLowerCase();
    final exactProject = _projectExact[lower];
    if (exactProject != null) {
      return (kind: _TagRedundancy.exactProject, matched: exactProject);
    }
    final exactKind = _kindExact[lower];
    if (exactKind != null) {
      return (kind: _TagRedundancy.exactKind, matched: exactKind);
    }
    final exactArea = _areaExact[lower];
    if (exactArea != null) {
      return (kind: _TagRedundancy.exactArea, matched: exactArea);
    }
    final loose = _tagKey(normalized);
    final nearProject = _projectLoose[loose];
    if (nearProject != null) {
      return (kind: _TagRedundancy.nearProject, matched: nearProject);
    }
    final nearKind = _kindLoose[loose];
    if (nearKind != null) {
      return (kind: _TagRedundancy.nearKind, matched: nearKind);
    }
    final nearArea = _areaLoose[loose];
    if (nearArea != null) {
      return (kind: _TagRedundancy.nearArea, matched: nearArea);
    }
    return (kind: _TagRedundancy.none, matched: null);
  }
}

String _lowerFirst(String s) =>
    s.isEmpty ? s : s[0].toLowerCase() + s.substring(1);

String _upperFirst(String s) =>
    s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// Matches ANY letter, Unicode-aware – used by [_normalizeTag] to decide
/// whether the output built so far is still "first position" (2026-09-21
/// review4 N1 fix, see that method's doc).
final RegExp _tagAnyLetter = RegExp(r'\p{L}', unicode: true);

/// Normalizes a raw tag to camelCase – the ONE place this transform is
/// implemented (reused by [_prepareTags] for `remember`/`supersede`, and by
/// [MemoryServiceTags.tagMerge]'s `into` argument).
///
/// Algorithm (2026-09-21 correction – camelCase, not lowercase-kebab;
/// extended 2026-09-21 review3 m3/m4 fix, see step 2a; extended 2026-09-21
/// review4 N1/N2 fix, see steps 2a/3 below):
/// 1. Trim, then split on runs of whitespace/`-`/`_` ([_tagSeparatorPattern]);
///    empty parts (from a leading/trailing/doubled separator) are dropped.
/// 2a. Each part is then checked, in order: first against
///    [_tagAcronymPluralPart] (review4 N2 fix – an acronym pluralized with
///    a trailing lowercase `s`, e.g. `APIs`/`PDFs`/`IDs`, is left as ONE
///    part, never split); only if that does not match is the part checked
///    against [_tagGluedAcronymSplit] (a part that GLUES a leading acronym
///    onto a following capitalized word with no separator between them,
///    e.g. `GA4Report`, `XMLHttpRequest`, is split into two parts there). A
///    part that starts with a lowercase letter (`iOS`, `macOS`) never
///    matches either check and is left as one part.
/// 2b. A part that is entirely uppercase letters/digits ([_tagAcronymPart] –
///    an acronym like `KPI`/`GA4`/`ISO9001`/`ÄÖÜ`, or a plain number) OR
///    matches [_tagAcronymPluralPart] (review4 N2 fix) is lowercased as a
///    whole. Any other part keeps its inner casing as written.
/// 3. Every part then has its first character case-adjusted by POSITION IN
///    THE OUTPUT, not by part index (2026-09-21 review4 N1 fix): a part is
///    "first position" for as long as the output built so far ([_tagAnyLetter]
///    match) contains no letter yet – i.e. a run of leading digit-only
///    parts never "uses up" first position, so the FIRST part that
///    actually contributes a letter is the one that gets lowercased; every
///    part reached once the output already has a letter gets its first
///    character uppercased instead (a no-op on a leading digit/symbol).
///    Before this fix, position was decided by part INDEX (`i == 0`), so a
///    digit-only leading part (`"3 D Printing"`'s `"3"`) consumed position
///    0, leaving the acronym-lowercased `"d"` at position 1 to be
///    UPPERCASED to `"D"` on the FIRST pass (`3DPrinting`) – correct
///    camelCase only on the SECOND pass, once `"3D"` was already one part
///    starting with a letter (`3dPrinting`) – i.e. not idempotent.
/// 4. Parts are joined with no separator.
///
/// `AppsScript` -> `appsScript`; `apps-script`/`apps_script`/`Apps Script`
/// -> `appsScript`; `Alice` -> `alice`; `KPI` -> `kpi`; `GA4` -> `ga4`;
/// `ÄÖÜ` -> `äöü`; `GA4Report` -> `ga4Report`; `XMLHttpRequest` ->
/// `xmlHttpRequest`; `iOS` -> `iOS` (unchanged: starts lowercase, step 2a
/// never applies); `macOS` -> `macOS` (same reason); `iso9001` ->
/// `iso9001` (unchanged: no separators, no all-caps part); `ISO 9001` ->
/// `iso9001`; `store-gate` -> `storeGate`; `---` -> `''` (empty –
/// [_prepareTags] drops it with a warning, never silently); `3 D Printing`
/// -> `3dPrinting`; `2026 Q3` -> `2026q3`; `5 G` -> `5g`; `APIs` -> `apis`;
/// `PDFs` -> `pdfs`; `IDs` -> `ids` (review4 N1/N2 fixes – all idempotent:
/// re-normalizing any of these outputs returns it unchanged).
///
/// Deliberately does NOT strip control characters or other punctuation
/// (`:`, `[`, `]`, an ESC byte, ...) – only whitespace/`-`/`_` are
/// separators. A poisoned raw tag (SEC-5 threat model: a newline/ANSI
/// escape meant to forge a log line) still ends up camelCased with those
/// bytes intact in the STORED value; only the LOG line built from it goes
/// through [MemoryService.sanitizeForLog] (never the stored value itself –
/// same rule [MemoryService.sanitizeForLog]'s own doc states).
String _normalizeTag(String raw) {
  final rawParts = raw
      .trim()
      .split(_tagSeparatorPattern)
      .where((p) => p.isNotEmpty)
      .toList(growable: false);
  if (rawParts.isEmpty) return '';
  // Step 2a (2026-09-21 review3 m3/m4 fix; review4 N2 fix adds the
  // acronym-plural guard): expand a part that glues a leading acronym onto
  // a following capitalized word into two parts BEFORE the position-based
  // casing pass below – so a single raw part like "GA4Report" is treated
  // exactly as if it had arrived pre-split as "GA4 Report". See
  // [_tagGluedAcronymSplit]'s doc for why this is anchored to the START of
  // a part (so `iOS`/`macOS` never split). An acronym-plural part (`APIs`)
  // is checked FIRST and, if matched, never handed to the glued-split at
  // all – seeing it whole is what [_tagAcronymPluralPart]'s lowering step
  // below needs.
  final parts = <String>[];
  for (final part in rawParts) {
    if (_tagAcronymPluralPart.hasMatch(part)) {
      parts.add(part);
      continue;
    }
    final split = _tagGluedAcronymSplit.firstMatch(part);
    if (split == null) {
      parts.add(part);
    } else {
      parts
        ..add(split.group(1)!)
        ..add(split.group(2)!);
    }
  }
  final out = StringBuffer();
  for (final rawPart in parts) {
    var part = rawPart;
    if (_tagAcronymPart.hasMatch(part) || _tagAcronymPluralPart.hasMatch(part)) {
      part = part.toLowerCase();
    }
    // Step 3 (2026-09-21 review4 N1 fix): "first position" is decided by
    // whether the OUTPUT SO FAR contains a letter yet, not by part index –
    // see this method's doc for why the old `i == 0` check broke
    // idempotency for a digit-only leading part.
    final isFirstPosition = !_tagAnyLetter.hasMatch(out.toString());
    part = isFirstPosition ? _lowerFirst(part) : _upperFirst(part);
    out.write(part);
  }
  return out.toString();
}

/// Loose "same tag family" key for near-duplicate detection ([_prepareTags]'
/// existing-tag suggestion) and grouping ([MemoryServiceTags.tagsList]'s
/// `variantGroups`), and, as a WARNING-only signal (2026-09-21 review3 M1
/// fix – never a drop, see [_prepareTags] Step 2's doc for why the earlier
/// drop-on-loose-key behavior was wrong), for the project/kind/area
/// near-duplicate check in [_prepareTags] too – comparing keys on both
/// sides means e.g. project `acme-app` (key `acmeapp`) and tag `acmeApp`
/// (key `acmeapp`) are flagged as related even when neither string is
/// literally the other.
///
/// Lowercases the input (which may already be [_normalizeTag]'s camelCase
/// output, or a legacy/foreign-spelling [Tag.name] this normalization never
/// touched) and strips one trailing `es`/`en`/`e`/`s` ([_tagKeyPluralSuffix]
/// – see its own doc for the 2026-09-21 review3 M1 fix that added `es`) –
/// so `alice`/`Alice`, `kontakt`/`kontakte`, `rule`/`rules` and
/// `appsScript`/`apps-script` (the latter two already collapsed to the
/// identical string `appsScript` by [_normalizeTag] itself, so their keys
/// trivially match too) fall into one group.
///
/// 2026-09-21 review4 N3 fix: the suffix is stripped only when the
/// REMAINING STEM is at least [_tagKeyMinStemLen] characters – e.g. `en`
/// (stem `''`, 0 chars) or `ops` (stem `op`, 2 chars) no longer lose their
/// suffix. Without this, two unrelated short words that happen to end the
/// same way collapsed onto one loose key (`en`/`es` both -> `''`;
/// `open`/`ops` both -> `op`), which is pure noise for the near-duplicate
/// warning ([_prepareTags] Step 2b/3) and for [MemoryServiceTags.tagsList]'s
/// `variantGroups`. The threshold is a length heuristic, not a dictionary
/// lookup, so it cannot distinguish every case (a longer word ending in a
/// real plural/case-suffix pattern that happens to equal an unrelated
/// shorter word, e.g. "rate"/"rat", still collides) – this is a WARNING-
/// only signal either way (never a drop), so a residual false-positive
/// pair is a cosmetic near-duplicate suggestion, not a data-loss risk.
String _tagKey(String tag) {
  final lower = tag.toLowerCase();
  final match = _tagKeyPluralSuffix.firstMatch(lower);
  if (match == null) return lower;
  final stemLen = match.start;
  if (stemLen < _tagKeyMinStemLen) return lower;
  return lower.substring(0, match.start);
}

/// Minimum remaining-stem length for [_tagKey] to strip a trailing
/// `es`/`en`/`e`/`s` – 2026-09-21 review4 N3 fix, see [_tagKey]'s own doc.
const int _tagKeyMinStemLen = 3;

/// Default `tagsList` page size when the caller passes no `limit` –
/// 2026-09-21 review3 m10 fix: previously unbounded by default (500+ rows
/// in the live store). `totalMatching`/`truncated` already tell the
/// caller whether more exist, same "cap, never silently balloon" shape as
/// [_entriesMoveMaxIds].
const int _tagsListDefaultLimit = 100;

/// Hard cap on an explicit `limit` – rejected outright rather than
/// silently clamped, same discipline [_entriesMoveMaxIds] uses.
const int _tagsListMaxLimit = 500;

extension MemoryServiceTags on MemoryService {
  // ---------------------------------------------------------------------
  // _prepareTags – the single enforcement point, called by remember()
  // (supersede() goes through remember(), so it is covered for free).
  // ---------------------------------------------------------------------

  /// Normalizes, dedups, drops redundant tags and warns about the rest –
  /// see this file's top doc for the full rule set. MUST run inside an
  /// existing write transaction AND `StoreGate` lending (F15 – called from
  /// `remember`'s write tx, same as `_ensureProjectScope`), since the
  /// near-duplicate/redundancy checks below query `_tags`/`_memberships`.
  ///
  /// Returns the FINAL tag list to attach (normalized, deduped, redundant
  /// ones already dropped – safe to pass straight to
  /// `tags.map(_getOrCreateTag)`) plus every warning generated along the
  /// way, in the order the input tags were processed. Never throws for bad
  /// tag CONTENT (that is what warnings are for) – the hard caps (tag
  /// length, tag count) still throw, but those are checked earlier, in
  /// [MemoryService._requireArgLengths], against the RAW tags, before this
  /// method ever runs.
  ///
  /// Strict registry mode (2026-10-06) is the one exception: after the
  /// redundancy step, every surviving tag must have a [TagDefinition] row
  /// (exact, case-sensitive, on the NORMALIZED name); otherwise this
  /// THROWS a [ValidationException] naming each unregistered tag with up
  /// to three similar registered ones, and logs one `[registry] strict:`
  /// rejection line naming [tool] (the calling tool). Blank, control-
  /// character and redundant tags are still dropped with a warning before
  /// that check, never rejected. The caller runs this before anything is
  /// written, so a rejection leaves nothing behind. Open mode never
  /// throws here.
  ({List<String> tags, List<String> warnings}) _prepareTags(
    List<String> raw, {
    required String project,
    required String kind,
    String tool = 'remember',
  }) {
    final warnings = <String>[];
    if (raw.isEmpty) return (tags: const [], warnings: warnings);

    // Step 0 (2026-09-21, entries move (0.3.0)): a raw tag containing any
    // control character (U+0000-U+001F, U+007F – the same
    // [_controlCharPattern] memory_service_registry.dart's area-name check
    // already uses, reused here rather than duplicated) is DROPPED
    // outright, before normalization ever sees it. Unlike SEC-5's
    // sanitizeForLog rule (LOG-only – the STORED tag keeps whatever bytes
    // normalization leaves in it, see [_normalizeTag]'s doc), a control
    // character in a tag has no legitimate use and normalization does not
    // touch it (only whitespace/-/_ are separators) – letting it through
    // to storage would keep a forged-log-line payload alive in the tag
    // graph indefinitely (every future log line that names this tag, e.g.
    // tagsList/tagMerge, would carry it). The echoed tag in the warning is
    // sanitized ([MemoryService.sanitizeForLog]) so the warning text
    // itself cannot forge a log line.
    final controlCharFree = <String>[];
    for (final rawTag in raw) {
      if (_controlCharPattern.hasMatch(rawTag)) {
        warnings.add(
          'Tag "${MemoryService.sanitizeForLog(rawTag)}" dropped: contains '
          'control characters.',
        );
        continue;
      }
      controlCharFree.add(rawTag);
    }

    // Step 1: normalize, drop empty, collapse exact duplicate NORMALIZED
    // tags to one (warning only when the raw spellings actually differed –
    // two identical raw tags collapsing silently is not news).
    final firstRawFor = <String, String>{}; // normalized -> first raw seen
    final survivingNormalized = <String>[]; // normalized, in first-seen order
    for (final rawTag in controlCharFree) {
      final normalized = _normalizeTag(rawTag);
      if (normalized.isEmpty) {
        warnings.add(
          'Tag "${MemoryService.sanitizeForLog(rawTag)}" dropped: empty '
          'after normalization.',
        );
        continue;
      }
      if (normalized != rawTag) {
        warnings.add(
          'Tag "${MemoryService.sanitizeForLog(rawTag)}" stored as '
          '"${MemoryService.sanitizeForLog(normalized)}".',
        );
      }
      final firstRaw = firstRawFor[normalized];
      if (firstRaw == null) {
        firstRawFor[normalized] = rawTag;
        survivingNormalized.add(normalized);
      } else if (firstRaw != rawTag) {
        warnings.add(
          'Tag "${MemoryService.sanitizeForLog(rawTag)}" is a duplicate of '
          '"${MemoryService.sanitizeForLog(firstRaw)}" (both normalize to '
          '"${MemoryService.sanitizeForLog(normalized)}") – kept once.',
        );
      }
      // else: the exact same raw string repeated verbatim – silently
      // collapsed, nothing "differed" to warn about (spec).
    }

    // Step 1b (2026-10-06, tag aliases): a tag that is not a registered
    // tag itself but exactly matches a TagAlias is replaced by the
    // canonical tag – in both registry modes, with a warning and a log
    // line, never silently. Only runs when any alias exists, so a store
    // without aliases takes exactly the path it took before. Duplicates
    // that the substitution creates collapse to the first occurrence.
    // Before the redundancy and strict steps, so those judge the tag
    // that will actually be stored.
    var resolvedNormalized = survivingNormalized;
    if (survivingNormalized.isNotEmpty && _tagAliases.count() > 0) {
      resolvedNormalized = <String>[];
      for (final normalized in survivingNormalized) {
        var resolved = normalized;
        if (!_isRegisteredTag(normalized)) {
          final alias = _tagAliasFor(normalized);
          if (alias != null) {
            final a = MemoryService.sanitizeForLog(normalized);
            final t = MemoryService.sanitizeForLog(alias.tag);
            if (_isRegisteredTag(alias.tag)) {
              resolved = alias.tag;
              warnings.add('Tag "$a" is an alias of "$t" – stored as "$t".');
              log('[memory] tag alias resolved: "$a" -> "$t"');
              firstRawFor.putIfAbsent(resolved, () => firstRawFor[normalized]!);
            } else {
              // A dangling alias (its tag's definition is gone, e.g.
              // removed on another device): never resolve to an
              // unregistered tag – keep the name and say why.
              warnings.add(
                'Tag "$a" is an alias of "$t", but "$t" is not a registered '
                'tag – kept as "$a".',
              );
              log(
                '[memory] tag alias not resolved: "$a" -> "$t" (target not '
                'registered)',
              );
            }
          }
        }
        if (!resolvedNormalized.contains(resolved)) {
          resolvedNormalized.add(resolved);
        }
      }
    }

    // Step 2: drop tags redundant with project/kind/area – all three are
    // already filterable (recall/list_recent/fact_query), so repeating one
    // as a tag adds noise, not a new axis.
    //
    // 2026-09-21 review3 M1 fix: a DROP now requires exact equality of the
    // normalized strings, compared case-insensitively – NEVER the loose
    // [_tagKey]. The old code compared loose keys directly, which both
    // dropped unrelated tags (project "rul" wrongly dropped tag "rule" –
    // different words, same loose key) and missed real near-duplicates
    // inconsistently (loose keys were not stable across -e/-es words, so
    // "facts"/"decisions" were dropped but "episodes"/"references" were
    // not, purely by accident of which suffix [_tagKeyPluralSuffix] used to
    // strip). A tag whose loose key matches but is NOT an exact match is
    // now only WARNED about (Step 2b below), never dropped – the loose key
    // stays a near-duplicate SIGNAL, never a data-dropping decision.
    //
    // 2026-10-06, strict registry mode: the matching itself lives in
    // [_TagRedundancyContext] (shared with `tag_define`); the messages
    // below are unchanged. Kinds are keyed by their NORMALIZED form, so a
    // match reports WHICH kind matched (review3 M2 fix: not the entry's own
    // `kind` argument – tag "reference" on a kind="fact" entry names
    // "reference").
    //
    // Areas this project belongs to – exact-match query + distinct
    // property projection, the same pattern `projectSet`'s `currentAreas`
    // already uses (memory_service_registry.dart) – reused, not duplicated.
    final areaNames = _useQuery(
      _memberships.query(
        AreaMembership_.project.equals(project, caseSensitive: true),
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
    final redundancy = _TagRedundancyContext(
      projects: [project],
      areas: areaNames,
    );

    final afterRedundancy = <String>[];
    for (final normalized in resolvedNormalized) {
      final match = redundancy.classify(normalized);
      switch (match.kind) {
        case _TagRedundancy.exactProject:
          warnings.add(
            'Tag "${MemoryService.sanitizeForLog(normalized)}" dropped: '
            'matches the project name "${MemoryService.sanitizeForLog(project)}" '
            '– project is already filterable.',
          );
          continue;
        case _TagRedundancy.exactKind:
          warnings.add(
            'Tag "${MemoryService.sanitizeForLog(normalized)}" dropped: '
            'matches a memory kind ("${MemoryService.sanitizeForLog(match.matched!)}") '
            '– kind is already filterable.',
          );
          continue;
        case _TagRedundancy.exactArea:
          warnings.add(
            'Tag "${MemoryService.sanitizeForLog(normalized)}" dropped: '
            'matches an area this project belongs to – area is already '
            'filterable.',
          );
          continue;
        // Step 2b (2026-09-21 review3 M1 fix): not an exact match, so kept
        // – but if its LOOSE key matches project/kind/area, warn about the
        // near-duplicate instead of silently keeping it (this is what makes
        // e.g. tag "episodes" warn as a near-duplicate of the kind
        // "episode" instead of vanishing without a trace, while still being
        // stored – the operator can decide, the server does not decide for
        // them).
        case _TagRedundancy.nearProject:
          warnings.add(
            'Tag "${MemoryService.sanitizeForLog(normalized)}" looks like a '
            'near-duplicate of the project name '
            '"${MemoryService.sanitizeForLog(project)}" – kept, but consider '
            'the project filter instead of a tag.',
          );
        case _TagRedundancy.nearKind:
          warnings.add(
            'Tag "${MemoryService.sanitizeForLog(normalized)}" looks like a '
            'near-duplicate of the kind '
            '"${MemoryService.sanitizeForLog(match.matched!)}" – '
            'kept, but consider the kind filter instead of a tag.',
          );
        case _TagRedundancy.nearArea:
          warnings.add(
            'Tag "${MemoryService.sanitizeForLog(normalized)}" looks like a '
            'near-duplicate of an area this project belongs to – kept, but '
            'consider the area filter instead of a tag.',
          );
        case _TagRedundancy.none:
          break;
      }

      afterRedundancy.add(normalized);
    }

    // Step 2c (strict registry mode only): every surviving tag must be
    // registered. One exact count() per tag (at most _tagMaxCount); the
    // definitions are paged only when something is missing, to build the
    // suggestions.
    if (registryMode == RegistryMode.strict && afterRedundancy.isNotEmpty) {
      final unregistered = [
        for (final t in afterRedundancy)
          if (!_isRegisteredTag(t)) t,
      ];
      if (unregistered.isNotEmpty) {
        final registered = _registeredTagNames();
        final allAliases = _allTagAliases();
        final defContext = _tagDefinitionContext();
        final described = <String>[];
        var registrable = 0;
        for (final t in unregistered) {
          // Every surviving tag has a raw spelling (an alias is only
          // substituted by a registered tag, which never reaches this
          // check); `?? t` keeps the message intact if that ever changes.
          final raw = firstRawFor[t] ?? t;
          final from = raw == t
              ? ''
              : 'from "${MemoryService.sanitizeForLog(raw)}"; ';
          // A tag that repeats another project, an area or a kind exactly
          // can never be registered (tag_define rejects it) – say so
          // instead of pointing at tag_define.
          final check = _checkNewTagDefinition(
            t,
            defContext,
            registered: registered,
          );
          final String hint;
          if (check.redundantWith != null) {
            hint = 'repeats ${check.redundantWith}, so it cannot be '
                'registered as a tag – drop it';
          } else if (check.aliasOf != null &&
              !_isRegisteredTag(check.aliasOf!)) {
            // A dangling alias: Step 1b kept the name (with a warning) –
            // repeat that here, since this rejection replaces the result.
            hint = 'kept as "${MemoryService.sanitizeForLog(t)}": '
                '${_danglingAliasAdvice(t, check.aliasOf!)}';
          } else {
            final similar = _nearestRegisteredTags(
              t,
              registered,
              aliases: allAliases,
            );
            final similarText = similar.isEmpty
                ? 'no similar registered tag'
                : 'similar registered tag${similar.length == 1 ? '' : 's'}: '
                      '${similar.join(', ')}';
            if (check.variants.isNotEmpty || check.aliasVariants.isNotEmpty) {
              hint = '$similarText; tag_define accepts it only with '
                  'allowSimilar: true';
            } else {
              registrable++;
              hint = similarText;
            }
          }
          described.add(
            '"${MemoryService.sanitizeForLog(t)}" ($from$hint)',
          );
        }
        final registerAdvice = registrable == 0
            ? ''
            : 'If a tag is genuinely new, register it first with tag_define '
                  '(name, description: "<one sentence: what the tag '
                  'marks>"), then retry. ';
        _rejectStrict(
          tool,
          'tag(s) not registered (strict registry mode): '
          '${described.join(', ')}. Use a registered tag or drop it. '
          '${registerAdvice}tags_list shows every registered tag. Nothing '
          'was written.',
        );
      }
    }

    // Step 3: near-duplicate suggestion – a normalized tag that is not YET
    // an exact-name Tag row, but an EXISTING Tag row shares its [_tagKey].
    //
    // 2026-09-21 review3 m7 fix: the existing-tag lookup maps are built
    // with ONE page-through of the Tag box for the WHOLE call, not one
    // full page-through PER new tag (up to [MemoryService._tagMaxCount]
    // per remember/supersede call) – the old code opened a fresh
    // `_pageThrough<Tag>` inside the per-tag loop, which degraded to
    // O(new tags x Tag rows). Still bounded (registry-scale), never a
    // `getAll()`.
    if (afterRedundancy.isNotEmpty) {
      final existingNames = <String>{};
      final existingByKey = <String, String>{}; // first name seen per key
      _pageThrough<Tag>(_tags.query(), (page) {
        for (final t in page) {
          existingNames.add(t.name);
          existingByKey.putIfAbsent(_tagKey(t.name), () => t.name);
        }
      });
      for (final normalized in afterRedundancy) {
        if (existingNames.contains(normalized)) continue;
        final found = existingByKey[_tagKey(normalized)];
        if (found != null && found != normalized) {
          warnings.add(
            'New tag "${MemoryService.sanitizeForLog(normalized)}" – did '
            'you mean the existing "${MemoryService.sanitizeForLog(found)}"?',
          );
        }
      }
    }

    // Step 4: too many tags on one entry – the hard security cap
    // ([MemoryService._tagMaxCount]) already ran against the RAW list in
    // `_requireArgLengths`; this is a softer, lower threshold that still
    // stores everything, just warns.
    if (afterRedundancy.length > 5) {
      warnings.add(
        '${afterRedundancy.length} tags on one entry – more than 5 rarely '
        'help grouping.',
      );
    }

    // Step 5: identifier/version-like tags – belong in the text. Shared
    // with [MemoryServiceTags.tagMerge]'s `into` check (2026-09-21 review3
    // M3 fix) via [_looksLikeIdentifierOrVersion].
    for (final normalized in afterRedundancy) {
      if (_looksLikeIdentifierOrVersion(normalized)) {
        warnings.add(
          'Tag "${MemoryService.sanitizeForLog(normalized)}" looks like an '
          'identifier or version – identifiers and versions belong in the '
          'text, not in tags.',
        );
      }
    }

    return (tags: afterRedundancy, warnings: warnings);
  }

  // ---------------------------------------------------------------------
  // Tag registry helpers (strict registry mode, 2026-10-06)
  // ---------------------------------------------------------------------

  /// Read. `true` iff a [TagDefinition] row has exactly this
  /// (case-sensitive) name. Must run inside a lending.
  bool _isRegisteredTag(String name) =>
      _useQuery(
        _tagDefs.query(TagDefinition_.name.equals(name, caseSensitive: true)),
        (q) => q.count(),
      ) >
      0;

  /// Read. The [TagDefinition] row for exactly this name, or null.
  TagDefinition? _tagDefinitionFor(String name) => _useQuery(
    _tagDefs.query(TagDefinition_.name.equals(name, caseSensitive: true)),
    (q) => q.findFirst(),
  );

  /// Read. Every registered tag name – one bounded page-through of the
  /// (registry-scale) [TagDefinition] box, never a `getAll()`.
  List<String> _registeredTagNames() {
    final names = <String>[];
    _pageThrough<TagDefinition>(_tagDefs.query(), (page) {
      for (final d in page) {
        names.add(d.name);
      }
    });
    return names;
  }

  /// Deterministic suggestions for an unregistered tag, ready to show:
  /// registered names with the same loose key ([_tagKey]) first, then
  /// names where one contains the other (case-insensitive; the shorter
  /// side at least 3 characters, so `ab` does not match everything); each
  /// group ordered by length difference, then name. [aliases] (alias ->
  /// canonical tag) take part the same way: a match on an alias suggests
  /// its canonical tag, shown as `"cooking" (alias "recipes")`. Each tag
  /// is suggested once. At most [max].
  List<String> _nearestRegisteredTags(
    String normalized,
    List<String> registered, {
    Map<String, String> aliases = const {},
    int max = 3,
  }) {
    final key = _tagKey(normalized);
    final lower = normalized.toLowerCase();
    // (compared name, suggested tag, alias or null)
    final candidates = <(String, String, String?)>[
      for (final r in registered) (r, r, null),
      for (final a in aliases.entries) (a.key, a.value, a.key),
    ];
    int byCloseness((String, String, String?) a, (String, String, String?) b) {
      final byLen = (a.$1.length - normalized.length).abs().compareTo(
        (b.$1.length - normalized.length).abs(),
      );
      return byLen != 0 ? byLen : a.$1.compareTo(b.$1);
    }

    final sameKey = [
      for (final c in candidates)
        if (c.$1 != normalized && _tagKey(c.$1) == key) c,
    ]..sort(byCloseness);
    final contained = <(String, String, String?)>[];
    for (final c in candidates) {
      if (c.$1 == normalized || sameKey.contains(c)) continue;
      final other = c.$1.toLowerCase();
      final shorter = other.length < lower.length ? other : lower;
      if (shorter.length < 3) continue;
      if (other.contains(lower) || lower.contains(other)) contained.add(c);
    }
    contained.sort(byCloseness);
    final out = <String>[];
    final suggested = <String>{};
    for (final c in [...sameKey, ...contained]) {
      if (out.length >= max) break;
      if (!suggested.add(c.$2)) continue;
      final tag = '"${MemoryService.sanitizeForLog(c.$2)}"';
      out.add(
        c.$3 == null
            ? tag
            : '$tag (alias "${MemoryService.sanitizeForLog(c.$3!)}")',
      );
    }
    return out;
  }

  /// Read. Every active or archived project (by name) and a redundancy
  /// context over those projects and every area – what a new tag
  /// definition (or alias) must not repeat. Merged tombstones are left
  /// out: their name is no longer filterable. Built once per call;
  /// registry-scale page-throughs.
  ({_TagRedundancyContext context, Map<String, ProjectScope> projects})
  _tagDefinitionContext() {
    final projects = <String, ProjectScope>{};
    // Only active and archived projects (2026-10-07): a merged-away name is
    // a tombstone – its entries moved to the target, so it is no longer
    // filterable and must not block a tag of the same name.
    _pageThrough<ProjectScope>(
      _projects.query(ProjectScope_.status.notEquals(ProjectStatus.merged)),
      (page) {
        for (final p in page) {
          projects[p.name] = p;
        }
      },
    );
    final areaNames = <String>[];
    _pageThrough<Area>(_areas.query(), (page) {
      for (final a in page) {
        areaNames.add(a.name);
      }
    });
    areaNames.sort();
    return (
      context: _TagRedundancyContext(
        projects: projects.keys.toList()..sort(),
        areas: areaNames,
      ),
      projects: projects,
    );
  }

  /// The create checks for a NEW [TagDefinition] named [normalized] – the
  /// ONE implementation behind `tag_define` and the definition carry in
  /// [_mergeTagsInto], so a merge can never register a name tag_define
  /// would refuse.
  ///
  /// [redundantWith] is set when the name repeats a registered project,
  /// a memory kind or an area exactly (e.g. `the archived project
  /// "garden"`) – such a name can never be registered. [nearWarnings]
  /// are the loose-key near matches (warnings only). [variants] are the
  /// registered tags (minus [ignoreRegistered], e.g. the definitions a
  /// merge is about to remove) that differ only by case, plural or
  /// separators – tag_define rejects those unless `allowSimilar`.
  /// [aliasOf] is the registered tag the name is already an alias of
  /// (`TagAlias`, owners in [ignoreRegistered] excepted) – such a name must
  /// not become a tag of its own, or the alias would stop resolving.
  ({
    String? redundantWith,
    List<String> nearWarnings,
    List<String> variants,
    String? aliasOf,
    List<String> aliasVariants,
  })
  _checkNewTagDefinition(
    String normalized,
    ({_TagRedundancyContext context, Map<String, ProjectScope> projects})
    defContext, {
    required List<String> registered,
    Set<String> ignoreRegistered = const {},
    bool includeNearKind = true,
  }) {
    final shown = MemoryService.sanitizeForLog(normalized);
    final match = defContext.context.classify(normalized);
    final matched = match.matched;
    final quotedMatch = '"${MemoryService.sanitizeForLog(matched ?? '')}"';
    String? redundantWith;
    final nearWarnings = <String>[];
    switch (match.kind) {
      case _TagRedundancy.exactProject:
        // Merged projects are not in the context (see
        // [_tagDefinitionContext]), so only active or archived rows match.
        final row = defContext.projects[matched];
        redundantWith = row?.status == ProjectStatus.archived
            ? 'the archived project $quotedMatch'
            : 'the registered project $quotedMatch';
      case _TagRedundancy.exactKind:
        redundantWith = 'the memory kind $quotedMatch';
      case _TagRedundancy.exactArea:
        redundantWith = 'the area $quotedMatch';
      case _TagRedundancy.nearProject:
        nearWarnings.add(
          '"$shown" looks like a near-duplicate of the project '
          '$quotedMatch – registered, but consider the project filter '
          'instead of a tag.',
        );
      case _TagRedundancy.nearKind:
        if (includeNearKind) {
          nearWarnings.add(
            '"$shown" looks like a near-duplicate of the kind $quotedMatch – '
            'registered, but consider the kind filter instead of a tag.',
          );
        }
      case _TagRedundancy.nearArea:
        nearWarnings.add(
          '"$shown" looks like a near-duplicate of the area $quotedMatch – '
          'registered, but consider the area filter instead of a tag.',
        );
      case _TagRedundancy.none:
        break;
    }
    final key = _tagKey(normalized);
    final variants = [
      for (final r in registered)
        if (r != normalized &&
            !ignoreRegistered.contains(r) &&
            _tagKey(r) == key)
          r,
    ]..sort();
    final aliasRow = _tagAliasFor(normalized);
    final aliasOf =
        aliasRow == null || ignoreRegistered.contains(aliasRow.tag)
        ? null
        : aliasRow.tag;
    // Spelling variants of an existing alias (`"recipes"` while `"recipe"`
    // is an alias of `"cooking"`): shown as `"recipe" (alias of
    // "cooking")`.
    final aliasVariants = <String>[];
    if (_tagAliases.count() > 0) {
      for (final e in _allTagAliases().entries) {
        if (e.key == normalized || ignoreRegistered.contains(e.value)) {
          continue;
        }
        if (_tagKey(e.key) != key) continue;
        aliasVariants.add(
          '"${MemoryService.sanitizeForLog(e.key)}" (alias of '
          '"${MemoryService.sanitizeForLog(e.value)}")',
        );
      }
      aliasVariants.sort();
    }
    return (
      redundantWith: redundantWith,
      nearWarnings: nearWarnings,
      variants: variants,
      aliasOf: aliasOf,
      aliasVariants: aliasVariants,
    );
  }

  /// `"x" matches the registered project "p" – projects, kinds and areas
  /// are already filterable, so a tag must not repeat one.`
  static String _redundantTagReason(String normalized, String redundantWith) =>
      '"${MemoryService.sanitizeForLog(normalized)}" matches $redundantWith '
      '– projects, kinds and areas are already filterable, so a tag must not '
      'repeat one.';

  /// `"lessons" looks like a variant of the registered tag "lesson" (same
  /// word apart from case, plural or separators)` – no final full stop.
  static String _variantTagReason(String normalized, List<String> variants) =>
      '"${MemoryService.sanitizeForLog(normalized)}" looks like a variant of '
      'the registered tag${variants.length == 1 ? '' : 's'} '
      '${variants.map((v) => '"${MemoryService.sanitizeForLog(v)}"').join(', ')} '
      '(same word apart from case, plural or separators)';

  /// Advice for a name that is an alias of a tag that is NOT registered
  /// (a dangling alias): it does not resolve, so in strict mode writes
  /// using it are rejected. Lists the ways out.
  static String _danglingAliasAdvice(String alias, String tag) {
    final a = MemoryService.sanitizeForLog(alias);
    final t = MemoryService.sanitizeForLog(tag);
    return 'the alias "$a" points at "$t", which is not registered – '
        'tag_define "$t" first (then "$a" resolves to it); to drop the '
        'alias instead, tag_define("$t", removeAliases: ["$a"]) after '
        'registering "$t", or tag_remove "$a"';
  }

  /// Why tag_define would refuse [normalized] as a NEW tag, as one clause
  /// built from a [_checkNewTagDefinition] result – or null when it would
  /// accept it (given a description). The one source every "register it
  /// with tag_define" hint consults, so no message points there in vain.
  String? _tagDefineBlocker(
    String normalized,
    ({
      String? redundantWith,
      List<String> nearWarnings,
      List<String> variants,
      String? aliasOf,
      List<String> aliasVariants,
    })
    check,
  ) {
    final shown = MemoryService.sanitizeForLog(normalized);
    if (check.aliasOf != null) {
      final owner = check.aliasOf!;
      return _isRegisteredTag(owner)
          ? '"$shown" is an alias of '
                '"${MemoryService.sanitizeForLog(owner)}" – use that tag'
          : _danglingAliasAdvice(normalized, owner);
    }
    if (check.redundantWith != null) {
      return '"$shown" cannot be registered: it repeats '
          '${check.redundantWith}';
    }
    if (check.variants.isNotEmpty) {
      return '${_variantTagReason(normalized, check.variants)} – tag_define '
          'accepts it only with allowSimilar: true';
    }
    if (check.aliasVariants.isNotEmpty) {
      return '"$shown" looks like a variant of '
          '${check.aliasVariants.join(', ')} – tag_define accepts it only '
          'with allowSimilar: true';
    }
    return null;
  }

  // ---------------------------------------------------------------------
  // Tag aliases (TagAlias) – 2026-10-06
  // ---------------------------------------------------------------------

  /// Read. The alias row named exactly (case-sensitive) [name], or null.
  TagAlias? _tagAliasFor(String name) => _useQuery(
    _tagAliases.query(TagAlias_.name.equals(name, caseSensitive: true)),
    (q) => q.findFirst(),
  );

  /// Read. Every alias row of the canonical [tag], sorted by name.
  List<TagAlias> _aliasesOf(String tag) =>
      _useQuery(
        _tagAliases.query(TagAlias_.tag.equals(tag, caseSensitive: true)),
        (q) => q.find(),
      )..sort((a, b) => a.name.compareTo(b.name));

  /// Read. Every alias, as alias name -> canonical tag – one bounded
  /// page-through of the (registry-scale) TagAlias box.
  Map<String, String> _allTagAliases() {
    final aliases = <String, String>{};
    _pageThrough<TagAlias>(_tagAliases.query(), (page) {
      for (final a in page) {
        aliases[a.name] = a.tag;
      }
    });
    return aliases;
  }

  /// Pure. Validates and normalizes raw alias names for [tool] ([field]
  /// is the argument name, for messages): a control character, an
  /// over-long or an empty-after-normalization name rejects the call.
  /// Duplicates collapse (first occurrence kept) with a warning;
  /// [normalizedFrom] maps each raw spelling that normalization changed to
  /// what is stored.
  static ({
    List<String> names,
    List<String> warnings,
    Map<String, String> normalizedFrom,
  })
  _normalizeAliasArgs(String tool, String field, List<String> raw) {
    if (raw.length > MemoryService._tagMaxCount) {
      throw ValidationException(
        '$tool: "$field" has ${raw.length} entries, exceeding the '
        '${MemoryService._tagMaxCount} limit.',
      );
    }
    final names = <String>[];
    final warnings = <String>[];
    final normalizedFrom = <String, String>{};
    final firstRaw = <String, String>{};
    for (final alias in raw) {
      MemoryService._requireLen(field, alias, MemoryService._tagMaxLen);
      if (_controlCharPattern.hasMatch(alias)) {
        throw ValidationException(
          '$tool: alias "${MemoryService.sanitizeForLog(alias)}" contains '
          'control characters.',
        );
      }
      final normalized = _normalizeTag(alias);
      if (normalized.isEmpty) {
        throw ValidationException(
          '$tool: alias "${MemoryService.sanitizeForLog(alias)}" is empty '
          'after normalization.',
        );
      }
      if (normalized != alias) normalizedFrom[alias] = normalized;
      final first = firstRaw[normalized];
      if (first == null) {
        firstRaw[normalized] = alias;
        names.add(normalized);
      } else if (first != alias) {
        warnings.add(
          'Alias "${MemoryService.sanitizeForLog(alias)}" is a duplicate of '
          '"${MemoryService.sanitizeForLog(first)}" (both normalize to '
          '"${MemoryService.sanitizeForLog(normalized)}") – kept once.',
        );
      } else {
        warnings.add(
          'Alias "${MemoryService.sanitizeForLog(alias)}" is listed more '
          'than once – kept once.',
        );
      }
    }
    return (names: names, warnings: warnings, normalizedFrom: normalizedFrom);
  }

  /// Read. Why [alias] cannot become an alias of [tag], or null when it
  /// can: it is the tag itself, a registered tag of its own (definitions
  /// in [ignoreRegistered] – about to be removed by a merge – excepted),
  /// already an alias of ANOTHER tag (owners in [ignoreRegistered]
  /// excepted – a merge moves those), repeats a project, area or kind
  /// name exactly (the shared redundancy rule), or – unless
  /// [allowSimilar] – is a spelling variant ([_tagKey]) of a registered
  /// tag other than [tag] or of another tag's alias. An existing
  /// unregistered Tag row of that name is fine – that is what aliases are
  /// for. [registered]/[allAliases] may be passed in when checking several
  /// aliases in one call.
  ({String reason, bool similar})? _aliasConflict(
    String alias,
    String tag,
    ({_TagRedundancyContext context, Map<String, ProjectScope> projects})
    defContext, {
    Set<String> ignoreRegistered = const {},
    bool allowSimilar = false,
    List<String>? registered,
    Map<String, String>? allAliases,
  }) {
    final shown = '"${MemoryService.sanitizeForLog(alias)}"';
    ({String reason, bool similar}) hard(String reason) =>
        (reason: reason, similar: false);
    if (alias == tag) return hard('$shown is the tag itself');
    if (!ignoreRegistered.contains(alias) && _isRegisteredTag(alias)) {
      return hard('$shown is a registered tag of its own');
    }
    final owner = _tagAliasFor(alias);
    if (owner != null &&
        owner.tag != tag &&
        !ignoreRegistered.contains(owner.tag)) {
      return hard(
        '$shown is already an alias of '
        '"${MemoryService.sanitizeForLog(owner.tag)}"',
      );
    }
    final redundantWith = _checkNewTagDefinition(
      alias,
      defContext,
      registered: const [],
    ).redundantWith;
    if (redundantWith != null) return hard('$shown repeats $redundantWith');
    if (!allowSimilar) {
      final key = _tagKey(alias);
      final similarTags = [
        for (final r in registered ?? _registeredTagNames())
          if (r != tag &&
              r != alias &&
              !ignoreRegistered.contains(r) &&
              _tagKey(r) == key)
            '"${MemoryService.sanitizeForLog(r)}"',
      ]..sort();
      final similarAliases = [
        for (final e in (allAliases ?? _allTagAliases()).entries)
          if (e.value != tag &&
              e.key != alias &&
              !ignoreRegistered.contains(e.value) &&
              _tagKey(e.key) == key)
            '"${MemoryService.sanitizeForLog(e.key)}" (alias of '
                '"${MemoryService.sanitizeForLog(e.value)}")',
      ]..sort();
      final similar = [...similarTags, ...similarAliases];
      // The caller adds how to accept it anyway (tag_define:
      // allowSimilar; a merge: tag_define with addAliases).
      if (similar.isNotEmpty) {
        return (
          reason:
              '$shown looks like a variant of ${similar.join(', ')} (same '
              'word apart from case, plural or separators)',
          similar: true,
        );
      }
    }
    return null;
  }

  /// Read. The warning for an alias that is also the name of a Tag row in
  /// use: entries keep that tag until a tag_merge moves them.
  String? _aliasInUseWarning(String alias, String tag) {
    final row = _useQuery(
      _tags.query(Tag_.name.equals(alias, caseSensitive: true)),
      (q) => q.findFirst(),
    );
    if (row == null) return null;
    final a = MemoryService.sanitizeForLog(alias);
    final t = MemoryService.sanitizeForLog(tag);
    return 'entries still carry "$a" – tag_merge(from: ["$a"], into: '
        '"$t") moves them.';
  }

  /// Read. A merge target ([normalized]) that is an alias of a REGISTERED
  /// tag is replaced by that tag – otherwise `tag_merge`/`tags_normalize`
  /// would write the alias name as a tag of its own and bypass the
  /// resolution `_prepareTags` does on every write. Logged, and the
  /// returned [warning] uses the `_prepareTags` wording. An alias whose
  /// tag is not registered (dangling) is left alone.
  ({String target, String? warning}) _resolveAliasTarget(
    String normalized, {
    required String logPrefix,
  }) {
    if (_tagAliases.count() == 0 || _isRegisteredTag(normalized)) {
      return (target: normalized, warning: null);
    }
    final alias = _tagAliasFor(normalized);
    if (alias == null || !_isRegisteredTag(alias.tag)) {
      return (target: normalized, warning: null);
    }
    final a = MemoryService.sanitizeForLog(normalized);
    final t = MemoryService.sanitizeForLog(alias.tag);
    log('[memory] $logPrefix: target "$a" is an alias of "$t" – using "$t"');
    return (
      target: alias.tag,
      warning: 'Tag "$a" is an alias of "$t" – merged into "$t".',
    );
  }

  // ---------------------------------------------------------------------
  // tagDefine
  // ---------------------------------------------------------------------

  /// Registers a tag (a [TagDefinition] row) or updates its description.
  /// Works in both registry modes; in strict mode only registered tags can
  /// be attached by `remember`/`supersede`.
  ///
  /// [name] is normalized exactly like a tag on `remember`
  /// ([_normalizeTag]: `apps-script` registers `appsScript`); a control
  /// character or an empty result is rejected. An existing definition is
  /// updated when a different non-blank [description] is given (action
  /// `updated`), otherwise left alone (`unchanged`). Creating one needs a
  /// non-blank [description] and is rejected when the name repeats a
  /// registered project, a kind or an area exactly (those are filterable
  /// already – the [_TagRedundancyContext] rule `remember` applies, here
  /// against every registered project and area), or when it is a loose-key
  /// variant ([_tagKey]: case, plural, separators) of another definition
  /// unless [allowSimilar] is true. Warnings (never rejections): a near
  /// match with a project/kind/area, unregistered [Tag] rows that are
  /// spelling variants of the new name (candidates for `tag_merge`), and
  /// an identifier/version-like name.
  ///
  /// [aliases] (2026-10-06), when given, REPLACES the tag's alias set
  /// (an empty list clears it); [addAliases]/[removeAliases] change single
  /// aliases instead (not combinable with [aliases]). Any of them may come
  /// with or without a description, on create or on update. Each alias is
  /// normalized like the name (`aliasesNormalizedFrom`, duplicates warned
  /// about); the whole call is rejected, nothing written, when an alias to
  /// add is the tag itself, another registered tag, an alias of ANOTHER
  /// tag, a project/area/kind name, or – unless [allowSimilar] – a
  /// spelling variant of another tag or alias ([_aliasConflict]). An
  /// alias that is still a tag in use is allowed – that is the main use –
  /// with a warning pointing at tag_merge. Every removed alias is named in
  /// a warning. A name that is already an alias of another tag, or a
  /// spelling variant of one (unless [allowSimilar]), cannot be registered
  /// as a tag of its own.
  ///
  /// One lending, one write transaction. Result: `{name, action,
  /// description, normalizedFrom?, aliases, aliasesAdded, aliasesRemoved,
  /// warning?}`.
  Future<Map<String, Object?>> tagDefine({
    required String name,
    String? description,
    bool allowSimilar = false,
    List<String>? aliases,
    List<String>? addAliases,
    List<String>? removeAliases,
  }) async {
    MemoryService._requireLen('name', name, MemoryService._tagMaxLen);
    if (aliases != null && (addAliases != null || removeAliases != null)) {
      throw ValidationException(
        'tag_define: pass either "aliases" (replaces the whole alias set) '
        'or "addAliases"/"removeAliases" (change single aliases), not '
        'both.',
      );
    }
    final replaceArg = aliases == null
        ? null
        : _normalizeAliasArgs('tag_define', 'aliases', aliases);
    final addArg = addAliases == null
        ? null
        : _normalizeAliasArgs('tag_define', 'addAliases', addAliases);
    final removeArg = removeAliases == null
        ? null
        : _normalizeAliasArgs('tag_define', 'removeAliases', removeAliases);
    final toAdd = replaceArg?.names ?? addArg?.names ?? const <String>[];
    final toRemove = removeArg?.names ?? const <String>[];
    final both = [
      for (final a in toAdd)
        if (toRemove.contains(a)) '"${MemoryService.sanitizeForLog(a)}"',
    ];
    if (both.isNotEmpty) {
      throw ValidationException(
        'tag_define: ${both.join(', ')} appear in both "addAliases" and '
        '"removeAliases".',
      );
    }
    final aliasArgWarnings = [
      ...?replaceArg?.warnings,
      ...?addArg?.warnings,
      ...?removeArg?.warnings,
    ];
    final aliasesNormalizedFrom = {
      ...?replaceArg?.normalizedFrom,
      ...?addArg?.normalizedFrom,
      ...?removeArg?.normalizedFrom,
    };
    if (description != null) {
      MemoryService._requireLen(
        'description',
        description,
        _registryDescriptionMaxLen,
      );
    }
    if (_controlCharPattern.hasMatch(name)) {
      throw ValidationException(
        'tag_define: "${MemoryService.sanitizeForLog(name)}" contains '
        'control characters.',
      );
    }
    final normalized = _normalizeTag(name);
    if (normalized.isEmpty) {
      throw ValidationException(
        'tag_define: "${MemoryService.sanitizeForLog(name)}" is empty after '
        'normalization.',
      );
    }
    if (description != null && description.trim().isEmpty) {
      throw ValidationException(
        'tag_define: description must not be blank (one sentence: what the '
        'tag marks).',
      );
    }
    final shown = MemoryService.sanitizeForLog(normalized);

    return _withSession('tag_define', () {
      return store.runInTransaction(TxMode.write, () {
        final warnings = <String>[...aliasArgWarnings];
        // Aliases are validated first, so any conflict rejects the whole
        // call before anything is written.
        if (toAdd.isNotEmpty) {
          final defContext = _tagDefinitionContext();
          final registeredNames = _registeredTagNames();
          final allAliases = _allTagAliases();
          final conflicts = <String>[];
          for (final alias in toAdd) {
            final c = _aliasConflict(
              alias,
              normalized,
              defContext,
              allowSimilar: allowSimilar,
              registered: registeredNames,
              allAliases: allAliases,
            );
            if (c == null) continue;
            final hint = c.similar
                ? ' – pass allowSimilar: true if it is genuinely another '
                      'name of "$shown"'
                : '';
            conflicts.add('${c.reason}$hint');
          }
          if (conflicts.isNotEmpty) {
            throw ValidationException(
              'tag_define: alias(es) rejected for "$shown": '
              '${conflicts.join('; ')}. Nothing was written.',
            );
          }
        }
        final existing = _tagDefinitionFor(normalized);
        String action;
        final TagDefinition def;
        if (existing != null) {
          def = existing;
          if (description != null && description != existing.description) {
            existing.description = description;
            existing.updatedAt = DateTime.now().toUtc();
            _tagDefs.put(existing);
            action = 'updated';
            log(
              '[memory] tag_define: updated the description of tag "$shown" '
              '(id ${existing.id})',
            );
          } else {
            action = 'unchanged';
          }
        } else {
          if (description == null) {
            throw ValidationException(
              'tag_define: "$shown" is not registered yet – a description is '
              'required to register a new tag (one sentence: what the tag '
              'marks).',
            );
          }

          // Same redundancy rule as remember's tags, against every
          // registered project and area (a definition belongs to no single
          // project) – the shared create checks, also used when a merge
          // carries a definition over.
          final check = _checkNewTagDefinition(
            normalized,
            _tagDefinitionContext(),
            registered: _registeredTagNames(),
          );
          if (check.redundantWith != null) {
            final reason = _redundantTagReason(
              normalized,
              check.redundantWith!,
            );
            throw ValidationException('tag_define: $reason');
          }
          if (check.aliasOf != null) {
            final owner = MemoryService.sanitizeForLog(check.aliasOf!);
            throw ValidationException(
              'tag_define: "$shown" is an alias of "$owner" – use "$owner", '
              'or first remove the alias from it (tag_define with name: '
              '"$owner" and removeAliases: ["$shown"]).',
            );
          }
          if (check.aliasVariants.isNotEmpty) {
            if (!allowSimilar) {
              throw ValidationException(
                'tag_define: "$shown" looks like a variant of '
                '${check.aliasVariants.join(', ')} (same word apart from '
                'case, plural or separators). Use the tag the alias belongs '
                'to, or pass allowSimilar: true if "$shown" is genuinely a '
                'different label.',
              );
            }
            log(
              '[memory] tag_define: registering "$shown" next to the '
              'similar alias(es) ${check.aliasVariants.join(', ')} '
              '(allowSimilar: true)',
            );
          }
          warnings.addAll(check.nearWarnings);
          final variants = check.variants;
          if (variants.isNotEmpty) {
            final quoted = variants
                .map((v) => '"${MemoryService.sanitizeForLog(v)}"')
                .join(', ');
            if (!allowSimilar) {
              throw ValidationException(
                'tag_define: ${_variantTagReason(normalized, variants)}. Use '
                '${variants.length == 1 ? quoted : 'one of those'}, or pass '
                'allowSimilar: true if "$shown" is genuinely a different '
                'label.',
              );
            }
            log(
              '[memory] tag_define: registering "$shown" next to the similar '
              'registered $quoted (allowSimilar: true)',
            );
          }
          final key = _tagKey(normalized);

          // Unregistered tag rows that are spelling variants of the new
          // name: not an error (they may be legacy spellings), but worth a
          // tag_merge.
          final tagVariants = <String>[];
          _pageThrough<Tag>(_tags.query(), (page) {
            for (final t in page) {
              if (t.name != normalized && _tagKey(t.name) == key) {
                tagVariants.add(t.name);
              }
            }
          });
          tagVariants.removeWhere(_isRegisteredTag);
          // An alias in use belongs to its own tag – never suggest merging
          // it into this one.
          tagVariants.removeWhere((t) => _tagAliasFor(t) != null);
          tagVariants.sort();
          if (tagVariants.isNotEmpty) {
            final quoted = tagVariants
                .map((v) => '"${MemoryService.sanitizeForLog(v)}"')
                .join(', ');
            warnings.add(
              'Existing unregistered tag${tagVariants.length == 1 ? '' : 's'} '
              '$quoted look${tagVariants.length == 1 ? 's' : ''} like a '
              'spelling variant of "$shown" – consider tag_merge (from: '
              '[$quoted], into: "$shown").',
            );
          }

          if (_looksLikeIdentifierOrVersion(normalized)) {
            warnings.add(
              '"$shown" looks like an identifier or version – identifiers '
              'and versions belong in the text, not in tags.',
            );
          }

          def = TagDefinition(name: normalized, description: description);
          def.id = _tagDefs.put(def);
          action = 'created';
          log('[memory] tag_define: registered tag "$shown" (id ${def.id})');
        }

        // Aliases: `aliases` REPLACES the tag's alias set; `addAliases`/
        // `removeAliases` change single ones.
        final current = _aliasesOf(def.name);
        final have = {for (final row in current) row.name};
        final aliasesAdded = <String>[];
        final aliasesRemoved = <String>[];
        if (replaceArg != null || addArg != null || removeArg != null) {
          for (final alias in toRemove) {
            if (!have.contains(alias)) {
              warnings.add(
                '"${MemoryService.sanitizeForLog(alias)}" is not an alias of '
                '"$shown" – nothing removed.',
              );
            }
          }
          for (final row in current) {
            final drop = replaceArg != null
                ? !toAdd.contains(row.name)
                : toRemove.contains(row.name);
            if (!drop) continue;
            _tagAliases.remove(row.id);
            aliasesRemoved.add(row.name);
            log(
              '[memory] tag_define: removed alias '
              '"${MemoryService.sanitizeForLog(row.name)}" of "$shown"',
            );
          }
          for (final alias in toAdd) {
            if (have.contains(alias)) continue;
            final row = TagAlias(name: alias, tag: def.name);
            row.id = _tagAliases.put(row);
            aliasesAdded.add(alias);
            log(
              '[memory] tag_define: added alias '
              '"${MemoryService.sanitizeForLog(alias)}" of "$shown" '
              '(id ${row.id})',
            );
            final inUse = _aliasInUseWarning(alias, def.name);
            if (inUse != null) warnings.add(inUse);
          }
          if (action == 'unchanged' &&
              (aliasesAdded.isNotEmpty || aliasesRemoved.isNotEmpty)) {
            action = 'updated';
          }
          // Never drop aliases unnoticed (e.g. a replace that forgot the
          // ones tag_merge recorded).
          if (aliasesRemoved.isNotEmpty) {
            final listed = ([...aliasesRemoved]..sort())
                .map((a) => '"${MemoryService.sanitizeForLog(a)}"')
                .join(', ');
            warnings.add('Alias(es) removed from "$shown": $listed.');
          }
        }
        final aliasNames = [
          for (final row in _aliasesOf(def.name)) row.name,
        ];

        final result = <String, Object?>{
          'name': def.name,
          'action': action,
          'description': def.description,
          if (normalized != name) 'normalizedFrom': name,
          'aliases': aliasNames,
          'aliasesAdded': aliasesAdded..sort(),
          'aliasesRemoved': aliasesRemoved..sort(),
          if (aliasesNormalizedFrom.isNotEmpty)
            'aliasesNormalizedFrom': aliasesNormalizedFrom,
          if (warnings.isNotEmpty) 'warning': warnings.join(' '),
        };
        return _applyGuardPeerWarning(result);
      });
    });
  }

  // ---------------------------------------------------------------------
  // tagsList
  // ---------------------------------------------------------------------

  /// Lists every [Tag] with its LIVE usage count (live = not superseded,
  /// not expired – matches [_liveEntryCondition]'s definition, restated
  /// here since tags are cross-project and this method has no single
  /// `project` to scope that condition to), sorted by count desc then name.
  /// `prefix` filters by literal (case-sensitive) prefix on the stored
  /// name; `minCount` filters by usage count; `limit` caps the returned
  /// `tags` list (the full, unfiltered-by-limit count is still reported
  /// separately as `totalMatching`, so a caller can tell whether it was
  /// truncated – also reported directly as `truncated`). 2026-09-21
  /// review3 m10 fix: `limit` now defaults to [_tagsListDefaultLimit] (100)
  /// when omitted, capped at [_tagsListMaxLimit] (500) when given
  /// explicitly – the response used to be unbounded by default.
  ///
  /// Also returns `variantGroups` (existing [Tag] rows that share a
  /// [_tagKey] – candidates for [tagMerge]) and `unused` (a plain count of
  /// [Tag] rows with zero live usage – candidates for [tagRemove]).
  /// Purpose: lets a caller check for an existing tag before inventing a
  /// new one, and drives cleanup.
  ///
  /// Tag registry (2026-10-06): registered names ([TagDefinition]) are
  /// listed alongside the [Tag] rows – a definition that is not used yet
  /// appears with count 0 (and counts as `unused`, and joins
  /// `variantGroups`). Every row carries `registered` and `description`
  /// (null when unregistered); within one count, registered tags sort
  /// first. Top-level `registryMode`, `registered` (definition count) and
  /// `unregisteredInUse` (tags in live use without a definition – what a
  /// switch to strict mode would reject) are added.
  ///
  /// Tag aliases (2026-10-06): a registered row carries its `aliases`; a
  /// row for an unregistered tag that is an alias carries `aliasOf`; a
  /// `prefix` also matches aliases, returning the canonical tag's row with
  /// `matchedAlias`. An alias whose tag is not registered (dangling) is
  /// flagged `aliasTargetMissing: true`. Top-level `aliases` is the number
  /// of aliases.
  ///
  /// The two cleanup counts: `unregisteredInUse` – tags in live use that
  /// are neither registered nor a resolvable alias (strict mode rejects
  /// writes using them); `aliasesInUse` – alias names entries still carry
  /// (writes resolve them; tag_merge them into their tag to clean up). A
  /// name that is both registered and an alias row (a Sync edge case) is
  /// treated as a tag, not listed as an alias, and logged.
  ///
  /// Bounded: one page-through of `Tag` (registry-scale) and one
  /// page-through of `MemoryEntry` (hydrating only the small `.tags`
  /// relation per entry, same pattern `stats()`'s `orphanedTags` already
  /// uses) – never a `getAll()`. One read transaction, one consistent
  /// snapshot.
  Future<Map<String, Object?>> tagsList({
    String? prefix,
    int? minCount,
    int? limit,
  }) {
    if (prefix != null) {
      MemoryService._requireLen('prefix', prefix, MemoryService._tagMaxLen);
    }
    if (minCount != null && minCount < 0) {
      throw ValidationException('"minCount" must be zero or a positive integer.');
    }
    if (limit != null && limit < 1) {
      throw ValidationException('"limit" must be a positive integer.');
    }
    // 2026-09-21 review3 m10 fix: a caller-supplied limit above the hard
    // cap is rejected outright (never silently clamped – CLAUDE.md "no
    // silent failure paths": a clamp with no signal back to the caller is
    // exactly that).
    if (limit != null && limit > _tagsListMaxLimit) {
      throw ValidationException(
        '"limit" must be at most $_tagsListMaxLimit.',
      );
    }
    return _withSession('tags_list', () {
      return store.runInTransaction(TxMode.read, () {
        final now = DateTime.now().toUtc();

        final tagNames = <int, String>{};
        _pageThrough<Tag>(_tags.query(), (page) {
          for (final t in page) {
            tagNames[t.id] = t.name;
          }
        });

        // Live-entry usage counts – bounded hydrate-and-tally over
        // MemoryEntry.tags (no id-only relation projection exists, see
        // stats()'s orphanedTags/referencedTagIds comment for why this is
        // the sanctioned bounded fallback), restricted to LIVE entries via
        // the same condition [_liveEntryCondition] expresses for one
        // project – inlined here since tags cut across every project.
        final usage = <int, int>{};
        _pageThrough<MemoryEntry>(
          _entries.query(
            MemoryEntry_.supersededBy.equals(0) &
                (MemoryEntry_.expiresAt.isNull() |
                    MemoryEntry_.expiresAt.greaterThanDate(now)),
          ),
          (page) {
            for (final e in page) {
              for (final tag in e.tags) {
                usage[tag.id] = (usage[tag.id] ?? 0) + 1;
              }
            }
          },
        );

        // Tag registry (2026-10-06): every TagDefinition (registry-scale,
        // one page-through). A definition without a Tag row yet (registered
        // but never used) is listed too, with count 0.
        final descriptions = <String, String>{};
        _pageThrough<TagDefinition>(_tagDefs.query(), (page) {
          for (final d in page) {
            descriptions[d.name] = d.description;
          }
        });
        // name -> live usage count, over Tag rows and definitions.
        final countByName = <String, int>{
          for (final entry in tagNames.entries)
            entry.value: usage[entry.key] ?? 0,
        };
        for (final name in descriptions.keys) {
          countByName.putIfAbsent(name, () => 0);
        }
        // Tag aliases (2026-10-06): alias -> canonical tag, and the
        // aliases of every registered tag.
        final aliasOf = _allTagAliases();
        final aliasesByTag = <String, List<String>>{};
        for (final e in aliasOf.entries) {
          // A name that is both a registered tag and an alias row (only
          // possible via Sync): the registered tag wins, as on writes, so
          // it is not listed as an alias.
          if (descriptions.containsKey(e.key)) {
            log(
              '[memory] tags_list: "${MemoryService.sanitizeForLog(e.key)}" '
              'is both a registered tag and an alias of '
              '"${MemoryService.sanitizeForLog(e.value)}" – listed as a tag',
            );
            continue;
          }
          (aliasesByTag[e.value] ??= <String>[]).add(e.key);
        }
        for (final list in aliasesByTag.values) {
          list.sort();
        }
        Map<String, Object?> rowFor(String name) => {
          'name': name,
          'count': countByName[name]!,
          'registered': descriptions.containsKey(name),
          'description': descriptions[name],
          // Only on registered rows / alias rows, so a store without
          // aliases keeps its row shape.
          if (descriptions.containsKey(name))
            'aliases': aliasesByTag[name] ?? const <String>[],
          if (!descriptions.containsKey(name) && aliasOf.containsKey(name))
            'aliasOf': aliasOf[name],
          // A dangling alias: its tag is not registered, so writes keep
          // the alias name instead of resolving it.
          if (!descriptions.containsKey(name) &&
              aliasOf.containsKey(name) &&
              !descriptions.containsKey(aliasOf[name]))
            'aliasTargetMissing': true,
        };

        var rows = <Map<String, Object?>>[
          for (final name in countByName.keys) rowFor(name),
        ];
        if (prefix != null && prefix.isNotEmpty) {
          // A prefix also matches aliases: the canonical tag's row is
          // returned (once), with the alias that matched.
          final byName = {for (final r in rows) r['name']! as String: r};
          final matched = <Map<String, Object?>>[];
          final seen = <String>{};
          for (final r in rows) {
            final name = r['name']! as String;
            if (name.startsWith(prefix) && seen.add(name)) matched.add(r);
          }
          final aliasNames = aliasOf.keys.toList()..sort();
          for (final alias in aliasNames) {
            if (!alias.startsWith(prefix)) continue;
            final canonical = aliasOf[alias]!;
            if (descriptions.containsKey(alias)) continue; // a tag itself
            final row = byName[canonical];
            if (row == null || !seen.add(canonical)) continue;
            matched.add({
              ...row,
              'matchedAlias': alias,
              if (!descriptions.containsKey(canonical))
                'aliasTargetMissing': true,
            });
          }
          rows = matched;
        }
        if (minCount != null) {
          rows = rows.where((r) => (r['count']! as int) >= minCount).toList();
        }
        // Count desc, then registered before unregistered (2026-10-06 – a
        // no-op while nothing is registered, so open-mode listings keep
        // their order), then name.
        rows.sort((a, b) {
          final byCount = (b['count']! as int).compareTo(a['count']! as int);
          if (byCount != 0) return byCount;
          final byRegistered = (b['registered']! as bool ? 1 : 0).compareTo(
            a['registered']! as bool ? 1 : 0,
          );
          if (byRegistered != 0) return byRegistered;
          return (a['name']! as String).compareTo(b['name']! as String);
        });
        final totalMatching = rows.length;
        // 2026-09-21 review3 m10 fix: a `limit` is now ALWAYS applied –
        // the caller's explicit value, or [_tagsListDefaultLimit] when
        // omitted – so the default response is bounded too, not only an
        // explicit one.
        final effectiveLimit = limit ?? _tagsListDefaultLimit;
        final limited = effectiveLimit < rows.length
            ? rows.sublist(0, effectiveLimit)
            : rows;
        final truncated = limited.length < totalMatching;

        // Variant groups: every Tag row (unfiltered by prefix/minCount –
        // this is a store-wide cleanup aid, not scoped to the listing
        // above) grouped by _tagKey; only groups with more than one member
        // are reported (a lone tag is not a "variant" of anything).
        final byKey = <String, List<Map<String, Object?>>>{};
        for (final name in countByName.keys) {
          final key = _tagKey(name);
          (byKey[key] ??= []).add({
            'name': name,
            'count': countByName[name]!,
            'registered': descriptions.containsKey(name),
          });
        }
        final variantGroups = <Map<String, Object?>>[];
        for (final group in byKey.entries) {
          if (group.value.length < 2) continue;
          group.value.sort((a, b) {
            final byCount = (b['count']! as int).compareTo(a['count']! as int);
            if (byCount != 0) return byCount;
            return (a['name']! as String).compareTo(b['name']! as String);
          });
          variantGroups.add({'key': group.key, 'tags': group.value});
        }
        variantGroups.sort((a, b) {
          final aTags = a['tags']! as List<Map<String, Object?>>;
          final bTags = b['tags']! as List<Map<String, Object?>>;
          final aTotal = aTags.fold<int>(0, (s, t) => s + (t['count']! as int));
          final bTotal = bTags.fold<int>(0, (s, t) => s + (t['count']! as int));
          final byTotal = bTotal.compareTo(aTotal);
          if (byTotal != 0) return byTotal;
          return (a['key']! as String).compareTo(b['key']! as String);
        });

        final unused = countByName.values.where((c) => c == 0).length;
        // An alias in use is not counted in unregisteredInUse (a write
        // resolves it); it is counted in aliasesInUse instead – entries
        // still carrying the alias name, cleanup work for tag_merge.
        bool isUsableAlias(String name) =>
            !descriptions.containsKey(name) &&
            aliasOf.containsKey(name) &&
            descriptions.containsKey(aliasOf[name]);
        final unregisteredInUse = countByName.entries
            .where(
              (e) =>
                  e.value > 0 &&
                  !descriptions.containsKey(e.key) &&
                  !isUsableAlias(e.key),
            )
            .length;
        final aliasesInUse = countByName.entries
            .where((e) => e.value > 0 && isUsableAlias(e.key))
            .length;

        return {
          'tags': limited,
          // 2026-09-21 review4 fix: `total` alongside the pre-existing
          // `totalMatching` (kept for compatibility, same value) – the
          // count of tags matching `prefix`/`minCount`, independent of
          // `limit`, right next to `truncated` so a caller doesn't have to
          // know the older field's name to see whether more exist.
          'total': totalMatching,
          'totalMatching': totalMatching,
          'truncated': truncated,
          'liveDefinition': 'live = not superseded, not expired',
          'variantGroups': variantGroups,
          'unused': unused,
          // Tag registry (2026-10-06): the mode this process enforces, how
          // many tags are registered, and how many tags in live use are
          // not (each row also says `registered` and carries its
          // `description`).
          'registryMode': registryMode.name,
          'registered': descriptions.length,
          'unregisteredInUse': unregisteredInUse,
          // Tag aliases (2026-10-06): number of TagAlias rows, and how
          // many alias names entries still carry.
          'aliases': aliasOf.length,
          'aliasesInUse': aliasesInUse,
          '_provenance_note': MemoryService._provenanceNote,
        };
      });
    });
  }

  // ---------------------------------------------------------------------
  // tagMerge
  // ---------------------------------------------------------------------

  /// Merges every tag in [from] into [into] on EVERY [MemoryEntry] (live
  /// AND superseded – this is a tag-graph maintenance operation, not
  /// scoped to live data), then removes the now-unused `from` [Tag] rows.
  /// [into] is normalized ([_normalizeTag]) and created if missing.
  ///
  /// [from] entries are matched by EXACT [Tag.name] (as [tagsList] reports
  /// them – including a legacy, pre-normalization spelling) – NOT
  /// re-normalized, so this tool can target exactly the row a caller saw.
  /// A name in [from] with no matching [Tag] row is reported in the
  /// result's `notFound` list, not fatal – the rest of the merge still
  /// runs.
  ///
  /// `dryRun: true` reports the same counts a real run would produce
  /// (same counting code either way, mirroring [MemoryServiceAreas.
  /// projectMerge]) without writing anything.
  ///
  /// Does not touch [MemoryEntry.text]/[MemoryEntry.contentHash] or
  /// [MemoryIndex] – see this file's top doc.
  Future<Map<String, Object?>> tagMerge({
    required List<String> from,
    required String into,
    bool dryRun = false,
  }) {
    if (from.isEmpty) {
      throw ValidationException('tag_merge: "from" must not be empty.');
    }
    if (from.length > MemoryService._tagMaxCount) {
      throw ValidationException(
        'tag_merge: "from" has ${from.length} entries, exceeding the '
        '${MemoryService._tagMaxCount} tag limit.',
      );
    }
    for (final f in from) {
      MemoryService._requireLen('from', f, MemoryService._tagMaxLen);
    }
    MemoryService._requireLen('into', into, MemoryService._tagMaxLen);
    // 2026-09-21 review3 M3 fix: "into" bypassed the control-character
    // rule [_prepareTags] Step 0 applies to every other tag write path –
    // [_normalizeTag] deliberately does not strip control characters (see
    // its own doc), so an unchecked "into" would store an ESC/newline
    // payload in the tag graph (the exact SEC-5 threat 0d5cec6 excluded
    // elsewhere). Checked on the RAW value, before normalization, same as
    // Step 0.
    if (_controlCharPattern.hasMatch(into)) {
      throw ValidationException(
        'tag_merge: "into" ("${MemoryService.sanitizeForLog(into)}") '
        'contains control characters.',
      );
    }
    final normalizedInto = _normalizeTag(into);
    if (normalizedInto.isEmpty) {
      throw ValidationException(
        'tag_merge: "into" ("${MemoryService.sanitizeForLog(into)}") is '
        'empty after normalization.',
      );
    }
    // 2026-09-21 review3 B1 fix: reject only a LITERAL self-merge – "from"
    // containing the exact normalized "into" string. The old condition
    // (`_normalizeTag(f) == normalizedInto`) rejected every legacy
    // spelling that merely NORMALIZES to "into", which is exactly the
    // migration this tool exists for (a pre-camelCase row "Alice"/legacy
    // "apps-script" merged into its own normalized form "alice"/
    // "appsScript") – see review3 finding B1. A row literally named
    // "alice" appearing in "from" while "into" also normalizes to
    // "alice" is still a genuine self-merge and stays rejected.
    if (from.contains(normalizedInto)) {
      throw ValidationException(
        'tag_merge: "into" ("${MemoryService.sanitizeForLog(into)}") must '
        'not also appear in "from".',
      );
    }

    // 2026-09-21 review3 M3 fix (review m8; review4 m8 extends this to the
    // LOOSE key too): "into" used to skip every redundancy/identifier rule
    // [_prepareTags] applies to an ordinary tag, so e.g. `into: "decision"`
    // was accepted silently. These are WARNINGS only, never a drop – the
    // operator named this target explicitly, so the server never overrides
    // that choice, only informs it (same "warn, don't decide for the
    // caller" rule [_prepareTags] Step 2b uses). Kind-redundancy is the
    // only part of Step 2/2b that applies here: unlike [_prepareTags],
    // `tag_merge` has no single project/entry to compare "into" against, so
    // project/area redundancy cannot be evaluated. Uses the same shared
    // [_kindByNormalizedLower]/[_kindByLooseKey] maps [_prepareTags] Step
    // 2/2b build, not a re-implementation (CLAUDE.md "No duplicated
    // logic").
    final intoWarnings = <String>[];
    final normalizedIntoLower = normalizedInto.toLowerCase();
    final matchedKind = _kindByNormalizedLower()[normalizedIntoLower];
    if (matchedKind != null) {
      intoWarnings.add(
        '"into" ("${MemoryService.sanitizeForLog(normalizedInto)}") '
        'matches a memory kind ("${MemoryService.sanitizeForLog(matchedKind)}") '
        '– kind is already filterable.',
      );
    } else {
      // review4 m8 fix: an exact match already warned above (and takes
      // precedence – no point also reporting the same kind as a "near"
      // match); only check the loose key when there was no exact match,
      // mirroring [_prepareTags] Step 2b's own if/else-if shape.
      final looseMatchedKind = _kindByLooseKey()[_tagKey(normalizedInto)];
      if (looseMatchedKind != null) {
        intoWarnings.add(
          '"into" ("${MemoryService.sanitizeForLog(normalizedInto)}") looks '
          'like a near-duplicate of the kind '
          '"${MemoryService.sanitizeForLog(looseMatchedKind)}" – kept, but '
          'consider the kind filter instead of a tag.',
        );
      }
    }
    if (_looksLikeIdentifierOrVersion(normalizedInto)) {
      intoWarnings.add(
        '"into" ("${MemoryService.sanitizeForLog(normalizedInto)}") looks '
        'like an identifier or version – identifiers and versions belong '
        'in the text, not in tags.',
      );
    }

    // 2026-09-21 review4 N4 fix: dedupe "from" by the LITERAL string
    // (never re-normalized – "from" is matched literally against stored
    // [Tag] rows, per this method's own doc) before the row lookup below,
    // so a duplicate name in the input isn't matched/counted/removed
    // twice. `tag_merge(from: ["Bob", "Bob"], into: "bob")` used to report
    // `tagsRemoved: 2` for a single row and call `_tags.remove` on the same
    // id twice.
    final dedupedFrom = <String>[];
    final seenFrom = <String>{};
    for (final name in from) {
      if (seenFrom.add(name)) dedupedFrom.add(name);
    }

    return _withSession('tag_merge', () {
      return store.runInTransaction(dryRun ? TxMode.read : TxMode.write, () {
        // Tag aliases: a target that is an alias of a registered tag means
        // that tag (both modes, dry run alike).
        final resolvedInto = _resolveAliasTarget(
          normalizedInto,
          logPrefix: 'tag_merge',
        );
        final target = resolvedInto.target;
        if (resolvedInto.warning != null) {
          intoWarnings.add(resolvedInto.warning!);
          if (dedupedFrom.contains(target)) {
            throw ValidationException(
              'tag_merge: "into" ("${MemoryService.sanitizeForLog(into)}") '
              'is an alias of "${MemoryService.sanitizeForLog(target)}", '
              'which also appears in "from" – nothing to merge.',
            );
          }
        }
        // Strict registry mode: the merge target must end up registered –
        // either it already is, or a "from" definition is carried over.
        // Otherwise the merge would leave entries carrying a tag nobody
        // could write again. Checked before anything changes (dry run
        // too). Open mode merges into an unregistered target as before.
        if (registryMode == RegistryMode.strict &&
            !_isRegisteredTag(target) &&
            !dedupedFrom.any(_isRegisteredTag)) {
          // Only point at tag_define when it would accept the name.
          final check = _checkNewTagDefinition(
            target,
            _tagDefinitionContext(),
            registered: _registeredTagNames(),
          );
          final String advice;
          if (check.aliasOf != null) {
            // An alias whose own tag is not registered (the registered
            // case was resolved above): merging into it would not help.
            final dangling = _danglingAliasAdvice(target, check.aliasOf!);
            advice = '${_upperFirst(dangling)}.';
          } else if (check.aliasVariants.isNotEmpty) {
            advice = '${_upperFirst(_tagDefineBlocker(target, check)!)} – '
                'merge into the tag that alias belongs to instead, or '
                'register it first if it is genuinely a different label, '
                'then retry.';
          } else if (check.redundantWith != null) {
            advice = 'It cannot be registered: '
                '${_redundantTagReason(target, check.redundantWith!)} '
                'Merge into a registered tag (tags_list) instead.';
          } else if (check.variants.isNotEmpty) {
            advice = '${_variantTagReason(target, check.variants)}. '
                'Merge into that registered tag instead, or – if it is '
                'genuinely a different label – register it first with '
                'tag_define (allowSimilar: true), then retry.';
          } else {
            advice = 'Register it first with tag_define, then retry.';
          }
          _rejectStrict(
            'tag_merge',
            'tag_merge: "into" ("${MemoryService.sanitizeForLog(target)}") '
            'is not a registered tag and none of the "from" tags has a '
            'definition to carry over (strict registry mode). $advice '
            'Nothing was changed.',
          );
        }
        final merge = _mergeTagsInto(
          dedupedFrom,
          target,
          dryRun: dryRun,
          logPrefix: 'tag_merge',
          // Strict: a definition tag_define would refuse is never carried
          // – the merge is rejected instead (nothing changed).
          rejectBlockedCarry: registryMode == RegistryMode.strict,
          // The kind near-match is already reported by the "into" check
          // above – not twice.
          carryNearKindWarning: false,
        );
        if (merge.carryWarning != null) intoWarnings.add(merge.carryWarning!);
        intoWarnings.addAll(merge.carryNearWarnings);
        intoWarnings.addAll(merge.aliasWarnings);

        log(
          '[memory] tag_merge ${dedupedFrom.length} tag(s) -> '
          '"${MemoryService.sanitizeForLog(target)}": '
          'entriesChanged=${merge.entriesChanged} '
          'linksReplaced=${merge.linksChanged} tagsRemoved=${merge.tagsRemoved} '
          'notFound=${merge.notFound.length} dryRun=$dryRun',
        );

        final result = <String, Object?>{
          'entriesChanged': merge.entriesChanged,
          'linksReplaced': merge.linksChanged,
          'tagsRemoved': merge.tagsRemoved,
          'notFound': merge.notFound,
          'into': target,
          'intoCreated': merge.intoCreated,
          'dryRun': dryRun,
          // Tag registry: what happened to the definitions.
          'definitionsRemoved': merge.definitionsRemoved,
          'intoDefinition': merge.intoDefinition,
          if (merge.carriedFrom != null) 'carriedFrom': merge.carriedFrom,
          // Tag aliases: merged-away names recorded as aliases of "into",
          // and aliases dropped with a merged-away definition.
          'aliasesAdded': merge.aliasesAdded,
          'aliasesRemoved': merge.aliasesRemoved,
        };
        // review3 M3: reported regardless of dryRun – these warnings are
        // pure validation of "into" itself, not data-dependent, so a
        // dryRun call reports the identical warning a real run would.
        if (intoWarnings.isNotEmpty) {
          result['warning'] = intoWarnings.join(' ');
        }
        return dryRun ? result : _applyGuardPeerWarning(result);
      });
    });
  }

  // ---------------------------------------------------------------------
  // _mergeTagsInto – the shared internal merge primitive behind BOTH
  // tagMerge and tagsNormalize (2026-09-21 review4: extracted so the
  // actual row-rewrite logic – from-lookup, into-creation, chunked
  // link-rewrite, from-row removal – lives in exactly ONE place, CLAUDE.md
  // "No duplicated logic". [tagMerge] additionally validates/normalizes
  // its arguments and computes "into" redundancy warnings BEFORE calling
  // this; [tagsNormalize] has no separate "into" to validate (its target
  // is always [_normalizeTag]'s own output) and calls this once per
  // distinct normalized target it found.
  // ---------------------------------------------------------------------

  /// Merges every [Tag] row named in [fromNames] (matched by EXACT
  /// [Tag.name], never re-normalized – same contract [tagMerge]'s own doc
  /// states) into a [Tag] row named [intoNormalized] (created if missing),
  /// rewriting every [MemoryEntry] link (live AND superseded) and removing
  /// the now-unused `from` rows. MUST run inside an existing StoreGate
  /// lending AND transaction (same discipline every other helper in this
  /// file follows) – callers open both.
  ///
  /// [fromNames] must already be deduped by the caller (both [tagMerge] and
  /// [tagsNormalize] build their own de-duped/grouped input before calling
  /// this, for their own reasons) – this helper does not dedupe again.
  ///
  /// `dryRun: true` reports the same counts a real run would produce
  /// without writing anything – same "same counting code either way" shape
  /// [tagMerge]'s own doc describes.
  ///
  /// Tag registry (2026-10-06): definitions follow the merge. If
  /// [intoNormalized] has no [TagDefinition] but a `from` name has one,
  /// the first such description (in [fromNames] order) is carried over to
  /// a new definition for [intoNormalized] (`intoDefinition: carried`,
  /// `carriedFrom`); an existing target definition is kept (`kept`);
  /// otherwise `none`. Every `from` definition is removed
  /// (`definitionsRemoved`), each with a log line that also names a
  /// description that was not carried. A name with neither a [Tag] row
  /// nor a definition is reported in `notFound`.
  ///
  /// Tag aliases (2026-10-06): with a registered target (`kept` or
  /// `carried`), every merged-away name becomes an alias of the target and
  /// the merged-away definitions' aliases move to it (`aliasesAdded`);
  /// conflicts are skipped with a warning ([_aliasConflict]). Aliases that
  /// do not move are removed (`aliasesRemoved`). Dry run: reported, not
  /// written.
  ({
    int entriesChanged,
    int linksChanged,
    int tagsRemoved,
    List<String> notFound,
    bool intoCreated,
    int definitionsRemoved,
    String intoDefinition,
    String? carriedFrom,
    String? carryWarning,
    List<String> carryNearWarnings,
    List<String> aliasesAdded,
    List<String> aliasesRemoved,
    List<String> aliasWarnings,
  })
  _mergeTagsInto(
    List<String> fromNames,
    String intoNormalized, {
    required bool dryRun,
    required String logPrefix,
    bool rejectBlockedCarry = false,
    bool carryNearKindWarning = true,
  }) {
    final fromRows = <Tag>[];
    final fromDefs = <TagDefinition>[];
    final notFound = <String>[];
    for (final name in fromNames) {
      final row = _useQuery(
        _tags.query(Tag_.name.equals(name)),
        (q) => q.findFirst(),
      );
      final def = _tagDefinitionFor(name);
      if (row == null && def == null) {
        notFound.add(name);
        continue;
      }
      if (row != null) fromRows.add(row);
      if (def != null) fromDefs.add(def);
    }
    final fromIds = fromRows.map((t) => t.id).toSet();

    // Definition carry, decided BEFORE anything is written: the target gets
    // a definition only if tag_define itself would accept the name – the
    // [_checkNewTagDefinition] result read the way tag_define reads it
    // (project/area/kind name, alias of a tag, variant of a registered tag
    // or of an alias – no allowSimilar here), ignoring the `from`
    // definitions this merge removes. Otherwise the carry is blocked:
    // [rejectBlockedCarry] (strict tag_merge) rejects the whole merge here,
    // with nothing changed; otherwise (open tag_merge, tags_normalize) the
    // merge goes ahead without the carry and says why.
    final intoShown = MemoryService.sanitizeForLog(intoNormalized);
    final intoRegistered = _isRegisteredTag(intoNormalized);
    String? carryBlocked;
    var blockedAsVariant = false;
    var blockedByAliasVariant = false;
    String? carryAliasOf;
    // Near-match warnings of the target, reported when the carry happens
    // (the same warnings tag_define gives when it registers a name).
    var carryNearWarnings = const <String>[];
    if (!intoRegistered && fromDefs.isNotEmpty) {
      final check = _checkNewTagDefinition(
        intoNormalized,
        _tagDefinitionContext(),
        registered: _registeredTagNames(),
        ignoreRegistered: {for (final d in fromDefs) d.name},
        includeNearKind: carryNearKindWarning,
      );
      if (check.redundantWith != null) {
        carryBlocked = _redundantTagReason(
          intoNormalized,
          check.redundantWith!,
        );
      } else if (check.aliasOf != null) {
        carryAliasOf = check.aliasOf;
        carryBlocked =
            '"$intoShown" is an alias of the registered tag '
            '"${MemoryService.sanitizeForLog(carryAliasOf!)}".';
      } else if (check.variants.isNotEmpty) {
        carryBlocked = '${_variantTagReason(intoNormalized, check.variants)}.';
        blockedAsVariant = true;
      } else if (check.aliasVariants.isNotEmpty) {
        carryBlocked =
            '"$intoShown" looks like a variant of '
            '${check.aliasVariants.join(', ')} (same word apart from case, '
            'plural or separators).';
        blockedAsVariant = true;
        blockedByAliasVariant = true;
      } else {
        carryNearWarnings = check.nearWarnings;
      }
    }
    if (carryBlocked != null && rejectBlockedCarry) {
      final mergeInto = blockedByAliasVariant
          ? 'the tag that alias belongs to'
          : 'that registered tag';
      final advice = carryAliasOf != null
          ? 'Merge into "${MemoryService.sanitizeForLog(carryAliasOf)}" '
                'instead.'
          : blockedAsVariant
          ? 'Merge into $mergeInto instead, or – if "$intoShown" is '
                'genuinely a different label – register it first with '
                'tag_define (allowSimilar: true), then merge.'
          : '"$intoShown" cannot be registered – merge into a registered '
                'tag (tags_list) instead.';
      _rejectStrict(
        logPrefix,
        '$logPrefix: the definition of '
        '"${MemoryService.sanitizeForLog(fromDefs.first.name)}" cannot be '
        'carried over to "$intoShown" (strict registry mode): '
        '$carryBlocked $advice Nothing was changed.',
      );
    }

    var intoTag = _useQuery(
      _tags.query(Tag_.name.equals(intoNormalized)),
      (q) => q.findFirst(),
    );
    final intoCreated = intoTag == null;
    if (intoTag == null && !dryRun) {
      final created = Tag(name: intoNormalized);
      created.id = _tags.put(created);
      intoTag = created;
      log(
        '[memory] $logPrefix: created target tag '
        '"${MemoryService.sanitizeForLog(intoNormalized)}" (id ${created.id})',
      );
    }

    // id-first, chunked processing via _pageThrough over EVERY MemoryEntry
    // (bounded batches, never getAll()) – the same bounded hydrate-and-
    // check approach stats()'s orphanedTags/referencedTagIds already
    // establishes for this exact ToMany limitation (no id-only relation
    // projection exists).
    var entriesChanged = 0;
    var linksChanged = 0;
    if (fromIds.isNotEmpty) {
      _pageThrough<MemoryEntry>(_entries.query(), (page) {
        for (final entry in page) {
          final currentIds = entry.tags.map((t) => t.id).toSet();
          final removedCount = currentIds.where(fromIds.contains).length;
          if (removedCount == 0) continue;
          entriesChanged++;
          linksChanged += removedCount;
          if (!dryRun) {
            entry.tags.removeWhere((t) => fromIds.contains(t.id));
            final alreadyHasInto = entry.tags.any((t) => t.id == intoTag!.id);
            if (!alreadyHasInto) entry.tags.add(intoTag!);
            entry.tags.applyToDb();
          }
        }
      });
    }

    // Every entry that carried a `from` tag had it removed above (the
    // page-through covers every MemoryEntry, live and superseded), so
    // every `from` row is now definitionally unused – removed
    // unconditionally rather than re-checked (a re-check would just
    // re-derive the same fact via another bounded read, see this method's
    // own removal loop above for why that is safe to skip).
    var tagsRemoved = 0;
    if (!dryRun) {
      for (final tag in fromRows) {
        _tags.remove(tag.id);
        tagsRemoved++;
        log(
          '[memory] $logPrefix: removed merged-away tag '
          '"${MemoryService.sanitizeForLog(tag.name)}" (id ${tag.id})',
        );
      }
    }

    // Definitions follow the merge (see this method's doc).
    final String intoDefinition;
    String? carriedFrom;
    String? carryWarning;
    if (intoRegistered) {
      intoDefinition = 'kept';
    } else if (carryBlocked != null) {
      intoDefinition = 'none';
      carryWarning =
          'The definition of '
          '"${MemoryService.sanitizeForLog(fromDefs.first.name)}" was not '
          'carried over to "$intoShown": $carryBlocked "$intoShown" stays '
          'unregistered.';
      log(
        '[memory] $logPrefix: did not carry the definition of '
        '"${MemoryService.sanitizeForLog(fromDefs.first.name)}" to '
        '"$intoShown" – ${MemoryService.sanitizeForLog(carryBlocked)}'
        '${dryRun ? ' (dry run)' : ''}',
      );
    } else if (fromDefs.isNotEmpty) {
      intoDefinition = 'carried';
      carriedFrom = fromDefs.first.name;
      if (!dryRun) {
        final carried = TagDefinition(
          name: intoNormalized,
          description: fromDefs.first.description,
        );
        carried.id = _tagDefs.put(carried);
        log(
          '[memory] $logPrefix: carried the definition of '
          '"${MemoryService.sanitizeForLog(carriedFrom)}" to "$intoShown" '
          '(id ${carried.id})',
        );
      }
    } else {
      intoDefinition = 'none';
    }
    // Taken BEFORE the merged-away definitions go, so a dry run and a
    // real run see the same register (see the no-aliases warning below).
    final registerInUse = _tagDefs.count() > 0;
    if (!dryRun) {
      for (final def in fromDefs) {
        _tagDefs.remove(def.id);
        final dropped = def.name == carriedFrom
            ? ''
            : ' – its description was not carried over: '
                  '"${MemoryService.sanitizeForLog(MemoryService._truncateForError(def.description))}"';
        log(
          '[memory] $logPrefix: removed the definition of merged-away tag '
          '"${MemoryService.sanitizeForLog(def.name)}" (id ${def.id})$dropped',
        );
      }
    }

    // Aliases (2026-10-06): when the target ends up registered, every
    // merged-away name becomes an alias of it (so a later write under the
    // old name resolves to the target), and the aliases of the merged-away
    // definitions move along. A candidate that conflicts (another tag's
    // alias, a registered tag, a project/area/kind name) is skipped with a
    // warning; one that normalizes to the target itself needs no alias
    // (normalization already resolves it) and is only logged. Without a
    // registered target, the merged-away definitions' aliases are removed.
    final fromDefNames = {for (final d in fromDefs) d.name};
    final movedAliases = [for (final d in fromDefs) ..._aliasesOf(d.name)];
    final aliasesAdded = <String>[];
    final aliasWarnings = <String>[];
    if (intoDefinition == 'none' && registerInUse) {
      // The target is not registered, so the merged-away names cannot
      // become its aliases. Said out loud once a register exists (a store
      // without any registered tag keeps its old output).
      final skipped = <String>[
        for (final name in fromNames)
          if (!notFound.contains(name) &&
              _normalizeTag(name).isNotEmpty &&
              _normalizeTag(name) != intoNormalized)
            _normalizeTag(name),
      ];
      if (skipped.isNotEmpty) {
        final listed = skipped
            .map((n) => '"${MemoryService.sanitizeForLog(n)}"')
            .join(', ');
        // Only point at tag_define when it would accept the target.
        final blocker = _tagDefineBlocker(
          intoNormalized,
          _checkNewTagDefinition(
            intoNormalized,
            _tagDefinitionContext(),
            registered: _registeredTagNames(),
            ignoreRegistered: fromDefNames,
          ),
        );
        aliasWarnings.add(
          blocker == null
              ? 'No aliases recorded for $listed – "$intoShown" is not a '
                    'registered tag; register it with tag_define first (or '
                    'add them later with tag_define addAliases).'
              : 'No aliases recorded for $listed – "$intoShown" is not a '
                    'registered tag, and $blocker.',
        );
        log(
          '[memory] $logPrefix: no aliases recorded for $listed – target '
          '"$intoShown" is not registered${dryRun ? ' (dry run)' : ''}',
        );
      }
    }
    if (intoDefinition != 'none') {
      final defContext = _tagDefinitionContext();
      final candidates = <String>[];
      for (final name in fromNames) {
        if (notFound.contains(name)) continue;
        final normalized = _normalizeTag(name);
        if (normalized.isEmpty || _controlCharPattern.hasMatch(normalized)) {
          aliasWarnings.add(
            'alias "${MemoryService.sanitizeForLog(name)}" not recorded for '
            '"$intoShown": not a valid tag name.',
          );
          continue;
        }
        if (normalized == intoNormalized) {
          log(
            '[memory] $logPrefix: no alias needed for '
            '"${MemoryService.sanitizeForLog(name)}" – it normalizes to '
            '"$intoShown"',
          );
          continue;
        }
        if (!candidates.contains(normalized)) candidates.add(normalized);
      }
      for (final row in movedAliases) {
        if (row.name == intoNormalized) continue;
        if (!candidates.contains(row.name)) candidates.add(row.name);
      }
      final existing = {for (final a in _aliasesOf(intoNormalized)) a.name};
      for (final alias in candidates) {
        if (existing.contains(alias)) continue;
        final c = _aliasConflict(
          alias,
          intoNormalized,
          defContext,
          ignoreRegistered: fromDefNames,
        );
        if (c != null) {
          // tag_merge has no allowSimilar – say how to record it anyway.
          final a = MemoryService.sanitizeForLog(alias);
          final conflict = c.similar
              ? '${c.reason} – tag_define("$intoShown", addAliases: '
                    '["$a"], allowSimilar: true) records it anyway'
              : c.reason;
          aliasWarnings.add(
            'alias "${MemoryService.sanitizeForLog(alias)}" not recorded for '
            '"$intoShown": $conflict.',
          );
          log(
            '[memory] $logPrefix: skipped alias '
            '"${MemoryService.sanitizeForLog(alias)}" for "$intoShown" – '
            '${MemoryService.sanitizeForLog(conflict)}',
          );
          continue;
        }
        aliasesAdded.add(alias);
      }
    }
    final aliasesRemoved = [
      for (final row in movedAliases)
        if (!aliasesAdded.contains(row.name)) row.name,
    ]..sort();
    if (!dryRun) {
      // Old rows first: a moved alias is re-created pointing at the target.
      for (final row in movedAliases) {
        _tagAliases.remove(row.id);
        if (!aliasesAdded.contains(row.name)) {
          log(
            '[memory] $logPrefix: removed alias '
            '"${MemoryService.sanitizeForLog(row.name)}" of merged-away tag '
            '"${MemoryService.sanitizeForLog(row.tag)}"',
          );
        }
      }
      for (final alias in aliasesAdded) {
        final row = TagAlias(name: alias, tag: intoNormalized);
        row.id = _tagAliases.put(row);
        log(
          '[memory] $logPrefix: added alias '
          '"${MemoryService.sanitizeForLog(alias)}" of "$intoShown" '
          '(id ${row.id})',
        );
      }
    }
    aliasesAdded.sort();

    return (
      entriesChanged: entriesChanged,
      linksChanged: linksChanged,
      tagsRemoved: dryRun ? fromRows.length : tagsRemoved,
      notFound: notFound,
      intoCreated: intoCreated,
      definitionsRemoved: fromDefs.length,
      intoDefinition: intoDefinition,
      carriedFrom: carriedFrom,
      carryWarning: carryWarning,
      carryNearWarnings: carryNearWarnings,
      aliasesAdded: aliasesAdded,
      aliasesRemoved: aliasesRemoved,
      aliasWarnings: aliasWarnings,
    );
  }

  // ---------------------------------------------------------------------
  // tagRemove
  // ---------------------------------------------------------------------

  /// Unlinks every tag in [tags] from every [MemoryEntry] (live and
  /// superseded) and deletes the [Tag] rows. Matched by EXACT [Tag.name],
  /// same rationale as [tagMerge]'s `from`. A name with no matching row is
  /// reported in `notFound`, not fatal. `dryRun: true` reports the same
  /// counts without writing.
  ///
  /// Does not touch [MemoryEntry.text]/[MemoryEntry.contentHash] or
  /// [MemoryIndex] – see this file's top doc.
  Future<Map<String, Object?>> tagRemove({
    required List<String> tags,
    bool dryRun = false,
  }) {
    if (tags.isEmpty) {
      throw ValidationException('tag_remove: "tags" must not be empty.');
    }
    if (tags.length > MemoryService._tagMaxCount) {
      throw ValidationException(
        'tag_remove: "tags" has ${tags.length} entries, exceeding the '
        '${MemoryService._tagMaxCount} tag limit.',
      );
    }
    for (final t in tags) {
      MemoryService._requireLen('tags', t, MemoryService._tagMaxLen);
    }

    // 2026-09-21 review4 N4 fix: dedupe by the LITERAL string, same
    // rationale and same shape as [tagMerge]'s "from" dedupe above – a
    // duplicate name in the input must not be matched/counted/removed
    // twice.
    final dedupedTags = <String>[];
    final seenTags = <String>{};
    for (final name in tags) {
      if (seenTags.add(name)) dedupedTags.add(name);
    }

    return _withSession('tag_remove', () {
      return store.runInTransaction(dryRun ? TxMode.read : TxMode.write, () {
        final rows = <Tag>[];
        final defs = <TagDefinition>[];
        final notFound = <String>[];
        for (final name in dedupedTags) {
          final row = _useQuery(
            _tags.query(Tag_.name.equals(name)),
            (q) => q.findFirst(),
          );
          // Tag registry: a matching definition is removed with the tag; a
          // name is "not found" only when it has neither.
          final def = _tagDefinitionFor(name);
          if (row == null && def == null) {
            notFound.add(name);
            continue;
          }
          if (row != null) rows.add(row);
          if (def != null) defs.add(def);
        }
        final ids = rows.map((t) => t.id).toSet();
        // Tag aliases: a removed definition takes its aliases with it.
        final removedAliases = [
          for (final def in defs) ..._aliasesOf(def.name),
        ];

        var entriesChanged = 0;
        var linksRemoved = 0;
        if (ids.isNotEmpty) {
          _pageThrough<MemoryEntry>(_entries.query(), (page) {
            for (final entry in page) {
              final currentIds = entry.tags.map((t) => t.id).toSet();
              final removedCount = currentIds.where(ids.contains).length;
              if (removedCount == 0) continue;
              entriesChanged++;
              linksRemoved += removedCount;
              if (!dryRun) {
                entry.tags.removeWhere((t) => ids.contains(t.id));
                entry.tags.applyToDb();
              }
            }
          });
        }

        var tagsRemoved = 0;
        if (!dryRun) {
          for (final tag in rows) {
            _tags.remove(tag.id);
            tagsRemoved++;
          }
          for (final def in defs) {
            _tagDefs.remove(def.id);
            log(
              '[memory] tag_remove: removed the definition of tag '
              '"${MemoryService.sanitizeForLog(def.name)}" (id ${def.id})',
            );
          }
          for (final alias in removedAliases) {
            _tagAliases.remove(alias.id);
            log(
              '[memory] tag_remove: removed alias '
              '"${MemoryService.sanitizeForLog(alias.name)}" of tag '
              '"${MemoryService.sanitizeForLog(alias.tag)}"',
            );
          }
        }

        log(
          '[memory] tag_remove ${dedupedTags.length} tag(s): '
          'entriesChanged=$entriesChanged linksRemoved=$linksRemoved '
          'tagsRemoved=${dryRun ? rows.length : tagsRemoved} '
          'notFound=${notFound.length} dryRun=$dryRun',
        );

        final result = <String, Object?>{
          'entriesChanged': entriesChanged,
          'linksRemoved': linksRemoved,
          'tagsRemoved': dryRun ? rows.length : tagsRemoved,
          'notFound': notFound,
          'dryRun': dryRun,
          'definitionsRemoved': defs.length,
          'aliasesRemoved': [for (final a in removedAliases) a.name]..sort(),
        };
        // A name that is an alias stays an alias: tag_remove removes tags
        // and registrations, not aliases of other tags – say how instead.
        final aliasHints = <String>[];
        if (_tagAliases.count() > 0) {
          for (final name in dedupedTags) {
            final alias = _tagAliasFor(name);
            if (alias == null || defs.any((d) => d.name == alias.tag)) {
              continue;
            }
            final a = MemoryService.sanitizeForLog(name);
            final t = MemoryService.sanitizeForLog(alias.tag);
            aliasHints.add(
              '"$a" is an alias of "$t" and stays one – tag_define(name: '
              '"$t", removeAliases: ["$a"]) removes it.',
            );
          }
        }
        if (aliasHints.isNotEmpty) result['warning'] = aliasHints.join(' ');
        return dryRun ? result : _applyGuardPeerWarning(result);
      });
    });
  }

  // ---------------------------------------------------------------------
  // tagsNormalize
  // ---------------------------------------------------------------------

  /// One-shot upgrade helper for stores written before 0.3.0's tag
  /// discipline (2026-09-21 review4): for every [Tag] row whose name
  /// differs from [_normalizeTag] applied to itself, merges it into the
  /// normalized name – reusing [_mergeTagsInto], the EXACT same primitive
  /// [tagMerge] uses (CLAUDE.md "No duplicated logic"), never a parallel
  /// re-implementation.
  ///
  /// A [Tag] row whose normalized form is EMPTY, or itself contains a
  /// control character, is left untouched and reported in `skipped` with a
  /// reason – never silently dropped or half-migrated. ([_normalizeTag]
  /// never strips control characters, see its own doc, so a stored [Tag]
  /// row can only carry one via a legacy write that bypassed
  /// [_prepareTags] Step 0, e.g. a direct box write from before that rule
  /// existed, or from an older client.)
  ///
  /// Multiple legacy spellings that all normalize to the SAME target
  /// (`Alice`/`ALICE` -> `alice`) are merged together in ONE
  /// [_mergeTagsInto] call per target (not one call per legacy name) –
  /// avoids a redundant target-row create/lookup per name, the same as
  /// calling [tagMerge] once with a multi-entry `from` list would.
  ///
  /// `merged` counts every `from` row whose target [Tag] row ALREADY
  /// EXISTED (as its own row – e.g. a store that already had a correctly
  /// spelled `kpi` row alongside a legacy `KPI` row) at the moment this
  /// tool processed that target, i.e. `intoCreated == false` for that
  /// target's [_mergeTagsInto] call. When several legacy spellings
  /// collapse into the SAME brand-new target in one run (`Alice`+`ALICE`
  /// -> a not-yet-existing `alice`), NONE of them count toward `merged`
  /// (the target is fresh, not "existing") even though two rows still get
  /// unified – decided once per TARGET, not per individual `from` name,
  /// since [_mergeTagsInto] processes a target's whole group in one step.
  /// Every migrated row (whichever bucket) is still listed in `renamed`.
  ///
  /// `dryRun: true` reports the same result without writing anything (same
  /// shape [tagMerge]/[tagRemove] use). Idempotent: a second run finds
  /// every remaining [Tag] row already normalized (`name ==
  /// _normalizeTag(name)`), so nothing lands in `byTarget` and the result
  /// is `renamed: [], merged: 0, skipped: [], tagsRemoved: 0` – same
  /// "no alias, re-run instead" discipline this file's top doc describes
  /// for [tagMerge]/[tagRemove].
  ///
  /// One [StoreGate] lending, one transaction, chunked via [_pageThrough]
  /// throughout (never a `getAll()`): one page-through of every [Tag] row
  /// to decide what needs migrating (phase 1), one page-through of every
  /// [MemoryEntry] to tally a per-`from`-name `entries` count for the
  /// report (phase 2 – a single whole-store pass regardless of how many
  /// legacy names/targets exist, not one pass per name), then
  /// [_mergeTagsInto]'s own page-through per target (phase 3). Does not
  /// touch [MemoryEntry.text]/[MemoryEntry.contentHash] or [MemoryIndex]
  /// (via [_mergeTagsInto] – see this file's top doc).
  Future<Map<String, Object?>> tagsNormalize({bool dryRun = false}) {
    return _withSession('tags_normalize', () {
      return store.runInTransaction(dryRun ? TxMode.read : TxMode.write, () {
        // Phase 1: bucket every Tag row that needs migrating by its
        // normalized target; set aside rows we must not touch, with a
        // reason – never silently skipped.
        final byTarget = <String, List<String>>{};
        final skipped = <Map<String, Object?>>[];
        _pageThrough<Tag>(_tags.query(), (page) {
          for (final t in page) {
            final normalized = _normalizeTag(t.name);
            // The empty/control-character checks run BEFORE the
            // already-normalized check below, on purpose: a row can
            // already equal its own "normalized" form (`name ==
            // normalized`) and still be a legacy anomaly worth flagging –
            // e.g. a raw control character in a tag name that [_normalizeTag]
            // never strips (see its own doc), so `normalized == t.name`
            // trivially holds. Checking these FIRST means such a row is
            // still reported in `skipped`, not silently treated as "nothing
            // to do" just because there is no rename to perform.
            if (normalized.isEmpty) {
              skipped.add({
                'name': MemoryService.sanitizeForLog(t.name),
                'reason': 'empty after normalization',
              });
              continue;
            }
            if (_controlCharPattern.hasMatch(normalized)) {
              skipped.add({
                'name': MemoryService.sanitizeForLog(t.name),
                'reason': 'normalized form contains control characters',
              });
              continue;
            }
            if (normalized == t.name) continue; // already normalized
            (byTarget[normalized] ??= <String>[]).add(t.name);
          }
        });

        // Phase 2: ONE whole-store MemoryEntry page-through, tallying
        // live+superseded usage per `from` id – used only to report the
        // per-name `entries` count in `renamed` below.
        final fromIdToName = <int, String>{};
        for (final names in byTarget.values) {
          for (final name in names) {
            final row = _useQuery(
              _tags.query(Tag_.name.equals(name)),
              (q) => q.findFirst(),
            );
            if (row != null) fromIdToName[row.id] = name;
          }
        }
        final usageByName = <String, int>{};
        if (fromIdToName.isNotEmpty) {
          _pageThrough<MemoryEntry>(_entries.query(), (page) {
            for (final entry in page) {
              for (final tag in entry.tags) {
                final name = fromIdToName[tag.id];
                if (name == null) continue;
                usageByName[name] = (usageByName[name] ?? 0) + 1;
              }
            }
          });
        }

        // Tag aliases (2026-10-06): a normalized target that is an alias
        // of a registered tag means that tag – same rule as tag_merge's
        // "into", so normalization never writes an alias as a tag of its
        // own. Groups that resolve to the same tag are merged.
        final targetAliasWarnings = <String>[];
        if (byTarget.isNotEmpty && _tagAliases.count() > 0) {
          final resolvedByTarget = <String, List<String>>{};
          for (final key in byTarget.keys.toList()..sort()) {
            final r = _resolveAliasTarget(key, logPrefix: 'tags_normalize');
            if (r.warning != null) targetAliasWarnings.add(r.warning!);
            (resolvedByTarget[r.target] ??= <String>[]).addAll(byTarget[key]!);
          }
          byTarget
            ..clear()
            ..addAll(resolvedByTarget);
        }

        // Phase 3: merge each target group via the SAME primitive
        // [tagMerge] uses – processed in SORTED target order for
        // deterministic output/logs (a Map's iteration order is not
        // itself a contract worth relying on here).
        final renamed = <Map<String, Object?>>[];
        var merged = 0;
        var tagsRemoved = 0;
        var definitionsRemoved = 0;
        final normalizeWarnings = <String>[...targetAliasWarnings];
        final aliasesAdded = <String>[];
        final aliasesRemoved = <String>[];
        final targets = byTarget.keys.toList()..sort();
        for (final target in targets) {
          final names = byTarget[target]!;
          final result = _mergeTagsInto(
            names,
            target,
            dryRun: dryRun,
            logPrefix: 'tags_normalize',
          );
          tagsRemoved += result.tagsRemoved;
          definitionsRemoved += result.definitionsRemoved;
          // tags_normalize never rejects: a blocked carry is reported, and
          // in strict mode so is a target that stays unregistered (every
          // write using it would be rejected).
          if (result.carryWarning != null) {
            normalizeWarnings.add(result.carryWarning!);
          }
          normalizeWarnings.addAll(result.carryNearWarnings);
          normalizeWarnings.addAll(result.aliasWarnings);
          aliasesAdded.addAll(result.aliasesAdded);
          aliasesRemoved.addAll(result.aliasesRemoved);
          if (registryMode == RegistryMode.strict &&
              result.intoDefinition == 'none') {
            final shown = MemoryService.sanitizeForLog(target);
            // Only point at tag_define when it would accept the name.
            final check = _checkNewTagDefinition(
              target,
              _tagDefinitionContext(),
              registered: _registeredTagNames(),
            );
            final String advice;
            if (check.aliasOf != null) {
              // An alias whose own tag is not registered (a registered
              // one was resolved above): it does not resolve.
              advice = 'writes using it are rejected; '
                  '${_danglingAliasAdvice(target, check.aliasOf!)}.';
            } else if (check.aliasVariants.isNotEmpty) {
              advice = 'writes using it are rejected; '
                  '${_tagDefineBlocker(target, check)} – or tag_merge it '
                  'into the tag that alias belongs to.';
            } else if (check.redundantWith != null) {
              advice = 'writes using it are rejected; it cannot be registered '
                  '(it repeats ${check.redundantWith}) – tag_merge it into a '
                  'real tag or tag_remove it.';
            } else if (check.variants.isNotEmpty) {
              final reason = _variantTagReason(target, check.variants);
              advice = 'writes using it are rejected; $reason – tag_merge '
                  'it into that tag, or register it with tag_define '
                  '(allowSimilar: true) if it is genuinely a different label.';
            } else {
              advice = 'writes using it are rejected; register it with '
                  'tag_define, or merge or remove it (tag_merge, tag_remove).';
            }
            normalizeWarnings.add(
              '"$shown" is not a registered tag (strict registry mode) – '
              '$advice',
            );
            log(
              '[memory] tags_normalize: target "$shown" stays unregistered '
              '(strict registry mode)${dryRun ? ' (dry run)' : ''}',
            );
          }
          for (final name in names) {
            renamed.add({
              'from': name,
              'into': target,
              'entries': usageByName[name] ?? 0,
            });
          }
          if (!result.intoCreated) {
            merged += names.length;
          }
        }

        log(
          '[memory] tags_normalize: renamed=${renamed.length} merged=$merged '
          'skipped=${skipped.length} tagsRemoved=$tagsRemoved dryRun=$dryRun',
        );

        final resultMap = <String, Object?>{
          'renamed': renamed,
          'merged': merged,
          'skipped': skipped,
          'tagsRemoved': tagsRemoved,
          'dryRun': dryRun,
          'definitionsRemoved': definitionsRemoved,
          'aliasesAdded': aliasesAdded..sort(),
          'aliasesRemoved': aliasesRemoved..sort(),
          if (normalizeWarnings.isNotEmpty)
            'warning': normalizeWarnings.join(' '),
        };
        return dryRun ? resultMap : _applyGuardPeerWarning(resultMap);
      });
    });
  }
}
