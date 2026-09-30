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
  ({List<String> tags, List<String> warnings}) _prepareTags(
    List<String> raw, {
    required String project,
    required String kind,
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
    final projectNormalizedLower = _normalizeTag(project).toLowerCase();
    // kind -> its own normalized form, both directions keyed by the
    // lowercased normalized string so a match also reports WHICH kind
    // matched (2026-09-21 review3 M2 fix: the old code always named the
    // entry's own `kind` argument, which is wrong whenever a tag collides
    // with a DIFFERENT kind than the one this entry was stored under, e.g.
    // tag "reference" on a kind="fact" entry).
    final kindByNormalizedLower = _kindByNormalizedLower();
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
    final areaByNormalizedLower = <String, String>{
      for (final a in areaNames) _normalizeTag(a).toLowerCase(): a,
    };

    // Step 2b's loose-key candidates (project/kind/every area), built once
    // here alongside Step 2's exact-match maps – see that step's doc.
    final projectLooseKey = _tagKey(_normalizeTag(project));
    final kindByLooseKey = _kindByLooseKey();
    final areaByLooseKey = <String, String>{
      for (final a in areaNames) _tagKey(_normalizeTag(a)): a,
    };

    final afterRedundancy = <String>[];
    for (final normalized in survivingNormalized) {
      final normalizedLower = normalized.toLowerCase();
      if (normalizedLower == projectNormalizedLower) {
        warnings.add(
          'Tag "${MemoryService.sanitizeForLog(normalized)}" dropped: '
          'matches the project name "${MemoryService.sanitizeForLog(project)}" '
          '– project is already filterable.',
        );
        continue;
      }
      final matchedKind = kindByNormalizedLower[normalizedLower];
      if (matchedKind != null) {
        warnings.add(
          'Tag "${MemoryService.sanitizeForLog(normalized)}" dropped: '
          'matches a memory kind ("${MemoryService.sanitizeForLog(matchedKind)}") '
          '– kind is already filterable.',
        );
        continue;
      }
      final matchedArea = areaByNormalizedLower[normalizedLower];
      if (matchedArea != null) {
        warnings.add(
          'Tag "${MemoryService.sanitizeForLog(normalized)}" dropped: '
          'matches an area this project belongs to – area is already '
          'filterable.',
        );
        continue;
      }

      // Step 2b (2026-09-21 review3 M1 fix): not an exact match, so kept –
      // but if its LOOSE key matches project/kind/area, warn about the
      // near-duplicate instead of silently keeping it (this is what makes
      // e.g. tag "episodes" warn as a near-duplicate of the kind
      // "episode" instead of vanishing without a trace, while still being
      // stored – the operator can decide, the server does not decide for
      // them).
      final looseKey = _tagKey(normalized);
      if (looseKey == projectLooseKey) {
        warnings.add(
          'Tag "${MemoryService.sanitizeForLog(normalized)}" looks like a '
          'near-duplicate of the project name '
          '"${MemoryService.sanitizeForLog(project)}" – kept, but consider '
          'the project filter instead of a tag.',
        );
      } else if (kindByLooseKey.containsKey(looseKey)) {
        warnings.add(
          'Tag "${MemoryService.sanitizeForLog(normalized)}" looks like a '
          'near-duplicate of the kind '
          '"${MemoryService.sanitizeForLog(kindByLooseKey[looseKey]!)}" – '
          'kept, but consider the kind filter instead of a tag.',
        );
      } else if (areaByLooseKey.containsKey(looseKey)) {
        warnings.add(
          'Tag "${MemoryService.sanitizeForLog(normalized)}" looks like a '
          'near-duplicate of an area this project belongs to – kept, but '
          'consider the area filter instead of a tag.',
        );
      }

      afterRedundancy.add(normalized);
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

        var rows = <Map<String, Object?>>[
          for (final entry in tagNames.entries)
            {'name': entry.value, 'count': usage[entry.key] ?? 0},
        ];
        if (prefix != null && prefix.isNotEmpty) {
          rows = rows
              .where((r) => (r['name']! as String).startsWith(prefix))
              .toList();
        }
        if (minCount != null) {
          rows = rows.where((r) => (r['count']! as int) >= minCount).toList();
        }
        rows.sort((a, b) {
          final byCount = (b['count']! as int).compareTo(a['count']! as int);
          if (byCount != 0) return byCount;
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
        for (final entry in tagNames.entries) {
          final key = _tagKey(entry.value);
          (byKey[key] ??= []).add({
            'name': entry.value,
            'count': usage[entry.key] ?? 0,
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

        final unused = tagNames.keys
            .where((id) => (usage[id] ?? 0) == 0)
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
        final merge = _mergeTagsInto(
          dedupedFrom,
          normalizedInto,
          dryRun: dryRun,
          logPrefix: 'tag_merge',
        );

        log(
          '[memory] tag_merge ${dedupedFrom.length} tag(s) -> '
          '"${MemoryService.sanitizeForLog(normalizedInto)}": '
          'entriesChanged=${merge.entriesChanged} '
          'linksReplaced=${merge.linksChanged} tagsRemoved=${merge.tagsRemoved} '
          'notFound=${merge.notFound.length} dryRun=$dryRun',
        );

        final result = <String, Object?>{
          'entriesChanged': merge.entriesChanged,
          'linksReplaced': merge.linksChanged,
          'tagsRemoved': merge.tagsRemoved,
          'notFound': merge.notFound,
          'into': normalizedInto,
          'intoCreated': merge.intoCreated,
          'dryRun': dryRun,
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
  ({
    int entriesChanged,
    int linksChanged,
    int tagsRemoved,
    List<String> notFound,
    bool intoCreated,
  })
  _mergeTagsInto(
    List<String> fromNames,
    String intoNormalized, {
    required bool dryRun,
    required String logPrefix,
  }) {
    final fromRows = <Tag>[];
    final notFound = <String>[];
    for (final name in fromNames) {
      final row = _useQuery(
        _tags.query(Tag_.name.equals(name)),
        (q) => q.findFirst(),
      );
      if (row == null) {
        notFound.add(name);
      } else {
        fromRows.add(row);
      }
    }
    final fromIds = fromRows.map((t) => t.id).toSet();

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

    return (
      entriesChanged: entriesChanged,
      linksChanged: linksChanged,
      tagsRemoved: dryRun ? fromRows.length : tagsRemoved,
      notFound: notFound,
      intoCreated: intoCreated,
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
        final notFound = <String>[];
        for (final name in dedupedTags) {
          final row = _useQuery(
            _tags.query(Tag_.name.equals(name)),
            (q) => q.findFirst(),
          );
          if (row == null) {
            notFound.add(name);
          } else {
            rows.add(row);
          }
        }
        final ids = rows.map((t) => t.id).toSet();

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
        };
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

        // Phase 3: merge each target group via the SAME primitive
        // [tagMerge] uses – processed in SORTED target order for
        // deterministic output/logs (a Map's iteration order is not
        // itself a contract worth relying on here).
        final renamed = <Map<String, Object?>>[];
        var merged = 0;
        var tagsRemoved = 0;
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
        };
        return dryRun ? resultMap : _applyGuardPeerWarning(resultMap);
      });
    });
  }
}
