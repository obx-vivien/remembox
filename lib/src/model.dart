/// Data model for the ObjectBox memory MCP server.
///
/// Design follows the hard constraints in docs/contract/:
/// - Rich domain entities are the source of truth; exactly ONE canonical
///   ANN retrieval index ([MemoryIndex]) owns vectors
///   (objectbox-capabilities.md §6).
/// - Synced vs local-only is explicit: domain entities are `@Sync()`,
///   the recomputable vector index is deliberately NOT
///   (objectbox-capabilities.md §7, how-to-use-objectbox.md §8).
/// - Invariants live in the schema (`@Unique` keys), not comments
///   (how-to-use-objectbox.md §3).
/// - Queryable structure is modeled (Tag / MemoryLink / SourceDocument
///   entities), never JSON/CSV string bags (objectbox-capabilities.md §2).
library;

import 'package:objectbox/objectbox.dart';

// ---------------------------------------------------------------------------
// Typed constants — no raw magic strings scattered through code
// (how-to-use-objectbox.md, "Learned from review failures": raw ints/strings
// without a constants class were review rejections).
// ---------------------------------------------------------------------------

/// What kind of memory an entry is.
abstract final class MemoryKind {
  static const fact = 'fact';
  static const decision = 'decision';
  static const preference = 'preference';
  static const episode = 'episode';
  static const reference = 'reference';

  // 0.5.0 – formerly marker tags, now kinds (filterable on recall and
  // list_recent, so a tag of the same name is dropped as redundant).

  /// A dated status report on a thread (the current state itself is set
  /// with `thread_update`, see [Thread]).
  static const snapshot = 'snapshot';

  /// What to apply next time – a takeaway from something that happened.
  static const lesson = 'lesson';

  /// A dropped approach and why – check these before a new attempt.
  static const deadEnd = 'deadEnd';

  static const all = [
    fact,
    decision,
    preference,
    episode,
    reference,
    snapshot,
    lesson,
    deadEnd,
  ];

  /// One line per kind, in [all] order – the text tool descriptions use.
  static const meanings = {
    fact: 'knowledge that holds',
    decision: 'a choice and its reason',
    preference: 'how the operator wants things done',
    episode: 'something that happened',
    reference: 'where something is (a document, a link)',
    snapshot:
        'a dated status report on a thread (the current state itself '
        'is set with thread_update)',
    lesson: 'what to apply next time',
    deadEnd: 'a dropped approach and why – check these before a new attempt',
  };

  static bool isValid(String value) => all.contains(value);
}

/// Where a memory came from.
abstract final class MemorySource {
  static const chat = 'chat';
  static const file = 'file';
  static const url = 'url';
  static const note = 'note';

  static const all = [chat, file, url, note];

  static bool isValid(String value) => all.contains(value);
}

/// Semantic link types between memories ([MemoryLink.linkType]).
///
/// Directions are fixed (0.5.0). For `link(fromId: A, toId: B, type)`:
/// - [derivedFrom]: A follows from B (B is the source of A).
/// - [contradicts]: A contradicts B.
/// - [partOf]: A belongs to B (B has A as a part).
/// - [related]: undirected.
/// - [parent]/[child]: legacy – their direction was never defined. Still
///   accepted in open registry mode and kept in [all] so existing links
///   stay valid; strict registry mode rejects new ones ([legacy]).
abstract final class LinkType {
  static const parent = 'parent';
  static const child = 'child';
  static const related = 'related';
  static const contradicts = 'contradicts';
  static const derivedFrom = 'derivedFrom';

  /// A belongs to B – the directed replacement for [parent]/[child].
  static const partOf = 'partOf';

  static const all = [parent, child, related, contradicts, derivedFrom, partOf];

  /// Types whose direction is undefined; rejected for new links in strict
  /// registry mode.
  static const legacy = {parent, child};

  static bool isValid(String value) => all.contains(value);

  /// How a link of [type] reads from one end: [outgoing] is the `from`
  /// entry's view (`partOf`), otherwise the `to` entry's (`hasPart`). Used
  /// for the `relation` field `get`/`recall` add to each link. [related]
  /// reads the same both ways; legacy and unknown types are returned
  /// unchanged.
  static String relationFrom(String type, {required bool outgoing}) =>
      switch (type) {
        partOf => outgoing ? partOf : 'hasPart',
        derivedFrom => outgoing ? derivedFrom : 'sourceOf',
        contradicts => outgoing ? contradicts : 'contradictedBy',
        _ => type,
      };
}

/// Health of a [MemoryIndex] row.
abstract final class IndexStatus {
  static const ok = 'ok';
  static const stale = 'stale';
  static const failed = 'failed';

  static const all = [ok, stale, failed];

  static bool isValid(String value) => all.contains(value);
}

// ---------------------------------------------------------------------------
// Areas and facts (0.3.0) – 2026-09-21, areas and facts (0.3.0)
// ---------------------------------------------------------------------------

/// Lifecycle status of a [ProjectScope] row.
///
/// `merged` (added by the 2026-09-21 addendum to the areas/facts plan,
/// overriding the plan's original `active`/`archived`-only set): the row
/// for a project name that was folded into another one via `project_merge`
/// stays around as a tombstone instead of being deleted, so a later write
/// under the old name warns instead of silently re-registering with no
/// area.
abstract final class ProjectStatus {
  static const active = 'active';
  static const archived = 'archived';
  static const merged = 'merged';

  static const all = [active, archived, merged];

  static bool isValid(String value) => all.contains(value);
}

/// The value slot a [Fact] row actually uses ([Fact.valueText] /
/// [Fact.valueNumber] / [Fact.valueDate]). Exactly one of the three is set
/// per row – enforced by the write path (memory_service_facts.dart),
/// not by the schema (ObjectBox has no cross-property constraint).
abstract final class FactValueType {
  static const text = 'text';
  static const number = 'number';
  static const date = 'date';

  static const all = [text, number, date];

  static bool isValid(String value) => all.contains(value);
}

/// Key separator for synthetic composite keys ([Fact.factKey],
/// [AreaMembership.key]): U+001F (INFORMATION SEPARATOR ONE), written as an
/// escaped code point on purpose – never a raw control character in source
/// (addendum "minor changes": a raw control char in source code is easy to
/// mis-paste and invisible in a diff). `project`/`subject`/`attribute`/
/// area and project names reject this character outright on every write
/// path so no caller can forge a composite key by embedding the separator
/// itself.
const String kFactKeySep = '\u001f';

/// Normalizes a project/area name for near-duplicate detection: lowercase,
/// strip whitespace, `-` and `_`. `Acme-App`, `acme_app`, ` acme app ` all
/// normalize to `acmeapp`. ONE helper, reused by [ProjectScope.nameKey],
/// [Area.nameKey] and the near-duplicate warning helpers in
/// memory_service_registry.dart – no duplicated logic.
///
/// This is a NEAR-duplicate signal only: registered names stay
/// case-sensitive and exact everywhere else (query filters, area
/// resolution, `project_merge`) – see [ProjectScope.name]'s doc for why.
abstract final class ScopeKey {
  static String of(String name) =>
      name.trim().toLowerCase().replaceAll(RegExp(r'[\s\-_]+'), '');
}

// ---------------------------------------------------------------------------
// Unique value index – 2026-09-23, unique value index (0.3.1)
// ---------------------------------------------------------------------------
//
// Every `@Unique` String property below also carries
// `@Index(type: IndexType.value)`. ObjectBox indexes EVERY indexed String
// property as a 32-bit HASH by default – whether the index comes from
// `@Index` or from `@Unique`; what makes that default dangerous here is
// the uniqueness check, not the annotation that selected it. A put's
// uniqueness check must load each hash-bucket candidate by id to resolve
// possible
// collisions – if a candidate is gone (a stale index entry), that load
// fails and the whole put fails hard with "Entity unavailable for
// indexed ID <n>" (OBX 10502), permanently blocking that value
// (objectbox-java #1150, identical symptom; the maintainer there says the
// uniqueness check looks up the entities in the index by their ID and
// throws when one of them cannot be found). A value index keeps the
// real value inside the index, so the uniqueness check should no longer
// need to load candidates by id (our reading of the mechanism; ObjectBox
// does not document the value-index path, and in #1150 the maintainer
// asked which index type was in use); a genuine match is still found and
// replaced. Changing the index type also made ObjectBox rebuild the index
// when an existing store was opened in our tests (objectbox 5.3.2, macOS
// arm64; not documented by ObjectBox), which removed stale entries from a
// store that already carried them.

// ---------------------------------------------------------------------------
// Synced domain entities (source of truth, replicate across devices)
// ---------------------------------------------------------------------------

/// One remembered piece of knowledge. Domain source of truth.
///
/// `@Sync()`: durable business record that must replicate across devices
/// (how-to-use-objectbox.md §8). Cross-device identity is [contentHash]
/// (stable, content-derived); object IDs stay device-local and are mapped
/// by ObjectBox Sync — we deliberately do NOT use assignable/shared global
/// IDs.
@Entity()
@Sync()
class MemoryEntry {
  @Id()
  int id = 0;

  String title;

  /// The memory text itself (embedded for semantic recall).
  String text;

  /// One of [MemoryKind.all]. Validated on every write path.
  @Index()
  String kind;

  /// One of [MemorySource.all]. Validated on every write path.
  @Index()
  String sourceType;

  /// Free-form reference into the source: session id, file path, URL, ...
  String sourceRef;

  /// Project scope (e.g. git repo name or cwd); '' = global.
  @Index()
  String project;

  /// ISO language code of [text] ('en', 'de', ...). Empty string means
  /// unknown/unspecified — FIX-8 (the 2026-07-06 engineering log (internal),
  /// my own finding): a German text was once stored with language:"en"
  /// because
  /// the default silently guessed English. Never guess: if the caller
  /// doesn't pass a language, this stays ''.
  String language;

  /// All timestamps use [PropertyType.dateUtc]: millisecond precision,
  /// stored and read back as UTC (a bare DateTime would default to
  /// PropertyType.date and read back local time).
  @Property(type: PropertyType.dateUtc)
  DateTime createdAt;

  @Property(type: PropertyType.dateUtc)
  DateTime? lastAccessedAt;

  int accessCount;

  /// Soft-forget marker: entries with `expiresAt <= now` are excluded from
  /// recall. `forget(hard: false)` sets this to now.
  @Property(type: PropertyType.dateUtc)
  DateTime? expiresAt;

  /// SHA-256 of the normalized [text]. Schema-enforced dedup identity
  /// (how-to-use-objectbox.md §3: invariants in schema, not comments).
  ///
  /// DOCUMENTED DEVIATION from contract §3's "no ConflictStrategy.replace
  /// on root identity entities": ObjectBox Sync REQUIRES replace-on-conflict
  /// for all unique properties of `@Sync()` entities (the generator rejects
  /// anything else: "Synced entities must use @Unique(onConflict:
  /// ConflictStrategy.replace)"). Fail-fast uniqueness cannot exist across
  /// devices. The local write path therefore NEVER relies on replace: it
  /// dedups via explicit query-first-in-transaction with logging
  /// ([MemoryService.remember]); replace semantics only resolve the
  /// cross-device case where two devices independently stored the same
  /// content hash, which must converge deterministically.
  ///
  /// HONEST CAVEAT (FIX-2, the 2026-07-06 engineering log (internal),
  /// review round 1): a cross-device replace on this conflict mints a NEW
  /// local object id for
  /// the surviving row. Any [MemoryLink.from]/[MemoryLink.to] or
  /// [MemoryIndex.entryId] that pointed at the OLD id is now dangling — the
  /// replace is entirely local-identity-based and does not (and cannot,
  /// from this single-entity conflict hook) walk the relation graph to fix
  /// up references elsewhere. [MemoryService.reindex] detects and reports
  /// dangling links (bulk id-diff, never per-link queries) and can purge
  /// them with the explicit `purgeDanglingLinks` option; it does NOT do so
  /// by default because a link can legitimately arrive via sync BEFORE its
  /// target entry (eventual consistency) — auto-purging on every sweep
  /// would destroy valid in-flight data, not just genuine orphans.
  /// Value-indexed, not hash – see "Unique value index" above
  /// (2026-09-23, 0.3.1).
  @Unique(onConflict: ConflictStrategy.replace)
  @Index(type: IndexType.value)
  String contentHash;

  /// Corrections link forward instead of deleting: if set, this entry has
  /// been superseded by the target. Dedicated lifecycle relation — semantic
  /// links between memories use [MemoryLink] instead.
  final supersededBy = ToOne<MemoryEntry>();

  /// Tags are a real relation, not a CSV/JSON string
  /// (objectbox-capabilities.md §2).
  final tags = ToMany<Tag>();

  /// Optional source document (files/URLs); chat/note memories leave this
  /// unset (targetId == 0).
  final source = ToOne<SourceDocument>();

  MemoryEntry({
    this.id = 0,
    required this.title,
    required this.text,
    required this.kind,
    required this.sourceType,
    this.sourceRef = '',
    this.project = '',
    this.language = '',
    required this.contentHash,
    DateTime? createdAt,
    this.lastAccessedAt,
    this.accessCount = 0,
    this.expiresAt,
  }) : createdAt = createdAt ?? DateTime.now().toUtc();

  /// True if this entry has been superseded by another entry.
  bool get isSuperseded => supersededBy.targetId != 0;

  /// True if this entry is expired (soft-forgotten) at [now].
  bool isExpiredAt(DateTime now) =>
      expiresAt != null && !expiresAt!.isAfter(now);
}

/// A tag. Unique name makes "one tag per name" a schema invariant;
/// the write path uses transaction-safe query-or-create
/// (how-to-use-objectbox.md §3). Replace-on-conflict is mandated by
/// ObjectBox Sync for synced unique properties — see
/// [MemoryEntry.contentHash] for the full rationale.
@Entity()
@Sync()
class Tag {
  @Id()
  int id = 0;

  /// Value-indexed, not hash – see "Unique value index" above
  /// (2026-09-23, 0.3.1).
  @Unique(onConflict: ConflictStrategy.replace)
  @Index(type: IndexType.value)
  String name;

  /// Reverse side of [MemoryEntry.tags]; lets us query/verify which entries
  /// carry this tag without a manual join table.
  @Backlink('tags')
  final entries = ToMany<MemoryEntry>();

  Tag({this.id = 0, required this.name});
}

/// Metadata about an external source document (file, URL, paper, ...).
/// Normalized per objectbox-capabilities.md §2: many memories can share one
/// document, so this is its own entity instead of copied columns.
@Entity()
@Sync()
class SourceDocument {
  @Id()
  int id = 0;

  String name;

  /// File path or URL of the document.
  String pathOrUrl;

  String author;

  String mimeType;

  /// When the source document itself was created/published (if known).
  @Property(type: PropertyType.dateUtc)
  DateTime? docCreatedAt;

  /// When the document was first registered here.
  @Property(type: PropertyType.dateUtc)
  DateTime addedAt;

  /// SHA-256 of the document content — dedup identity for documents;
  /// write path is explicit query-or-create in a transaction (contract §3).
  /// Replace-on-conflict is mandated by ObjectBox Sync — see
  /// [MemoryEntry.contentHash]. Value-indexed, not hash – see "Unique value
  /// index" above (2026-09-23, 0.3.1).
  @Unique(onConflict: ConflictStrategy.replace)
  @Index(type: IndexType.value)
  String contentHash;

  SourceDocument({
    this.id = 0,
    required this.name,
    this.pathOrUrl = '',
    this.author = '',
    this.mimeType = '',
    this.docCreatedAt,
    DateTime? addedAt,
    required this.contentHash,
  }) : addedAt = addedAt ?? DateTime.now().toUtc();
}

/// A typed, user-defined semantic link between two memories.
/// Link entity per how-to-use-objectbox.md §4: the edge carries meaning
/// ([linkType], [note]), so it is modeled as its own entity rather than a
/// bare ToMany.
@Entity()
@Sync()
class MemoryLink {
  @Id()
  int id = 0;

  /// One of [LinkType.all]. Validated on every write path.
  @Index()
  String linkType;

  /// Optional free-form annotation for the edge.
  String note;

  @Property(type: PropertyType.dateUtc)
  DateTime createdAt;

  final from = ToOne<MemoryEntry>();
  final to = ToOne<MemoryEntry>();

  MemoryLink({
    this.id = 0,
    required this.linkType,
    this.note = '',
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now().toUtc();
}

// ---------------------------------------------------------------------------
// Areas and facts (0.3.0) – 2026-09-21, areas and facts (0.3.0)
// ---------------------------------------------------------------------------
//
// Sync caveats (documented here, same style as [MemoryEntry.contentHash]):
// [ProjectScope.name] / [Area.name] replace across devices mints a new
// local id; an [AreaMembership] row pointing at the old id would dangle –
// this is exactly the hazard the 2026-09-21 addendum's M1 fix avoids: area
// membership is a synced LINK ENTITY keyed by NAMES (not a ToMany owned by
// ProjectScope/backlinked by Area), so a cross-device replace of an
// identical `key` (area + [kFactKeySep] + project) changes nothing
// semantically – same area, same project, new local id, no dangling
// reference anywhere. [Fact] has no unique property at all, so it has no
// replace hazard; concurrent cross-device `fact_set` on the same key can
// produce two current rows, which the write path detects and repairs
// explicitly – never silently.

/// The project registry: one row per project name ever seen by `remember`/
/// `fact_set`/`project_set`, created lazily (memory_service_registry.dart,
/// or explicitly via `project_set`/`reindex`. Exists so areas have
/// something stable to reference by name and so `stats`/`areas_list`
/// can report registered-vs-used projects.
///
/// `@Sync()`: a durable, user-visible record (area assignment, description,
/// lifecycle status) that must replicate across devices
/// (how-to-use-objectbox.md §8).
@Entity()
@Sync()
class ProjectScope {
  @Id()
  int id = 0;

  /// EXACT project string as used on [MemoryEntry.project] / [Fact.project]
  /// – case-sensitive, never trimmed by the registry write path (plan
  /// review M2: the registry must not be stricter than `remember`'s own
  /// `_requireProject`, which neither trims nor rejects control
  /// characters). `X` and `x` legitimately coexist as two rows until an
  /// operator runs `project_merge`.
  ///
  /// DOCUMENTED DEVIATION from contract §3's "no ConflictStrategy.replace
  /// on root identity entities": ObjectBox Sync REQUIRES replace-on-conflict
  /// for every unique property of an `@Sync()` entity – see
  /// [MemoryEntry.contentHash] for the full rationale, which applies here
  /// unchanged. The local write path never relies on replace: it is
  /// query-first-in-a-write-transaction (`_ensureProjectScope`,
  /// memory_service_registry.dart), always logged on creation. Replace
  /// semantics only resolve the cross-device case, and per this entity's
  /// class-level doc that case is content-neutral for [AreaMembership] by
  /// construction (name-keyed, not id-keyed). Value-indexed, not hash – see
  /// "Unique value index" above (2026-09-23, 0.3.1).
  @Unique(onConflict: ConflictStrategy.replace)
  @Index(type: IndexType.value)
  String name;

  /// [ScopeKey.of] of [name]. NOT unique – see [name]'s doc.
  @Index()
  String nameKey;

  /// '' by default; cap enforced by the write path (`descriptionMaxLen`).
  String description;

  /// One of [ProjectStatus.all]. Default [ProjectStatus.active].
  @Index()
  String status;

  /// Target project name once [status] is [ProjectStatus.merged]; '' until
  /// then. Addendum Q3: `project_merge` keeps the source row as a tombstone
  /// instead of deleting it, so a later write under the merged-away name
  /// warns naming this field instead of silently re-registering with no
  /// area.
  String mergedInto;

  @Property(type: PropertyType.dateUtc)
  DateTime createdAt;

  @Property(type: PropertyType.dateUtc)
  DateTime updatedAt;

  ProjectScope({
    this.id = 0,
    required this.name,
    required this.nameKey,
    this.description = '',
    this.status = ProjectStatus.active,
    this.mergedInto = '',
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : createdAt = createdAt ?? DateTime.now().toUtc(),
       updatedAt = updatedAt ?? createdAt ?? DateTime.now().toUtc();
}

/// A life/work area grouping one or more projects, via [AreaMembership].
///
/// `@Sync()`: same rationale as [ProjectScope] – a durable, user-visible
/// grouping decision that must replicate.
@Entity()
@Sync()
class Area {
  @Id()
  int id = 0;

  /// Exact, case-sensitive area name (cap enforced by the write path,
  /// `areaNameMaxLen`). Replace-on-conflict is Sync-mandated – see
  /// [ProjectScope.name]'s doc; content-neutral in the same sense
  /// ([AreaMembership] references areas by name, not by id). Value-indexed,
  /// not hash – see "Unique value index" above (2026-09-23, 0.3.1).
  @Unique(onConflict: ConflictStrategy.replace)
  @Index(type: IndexType.value)
  String name;

  /// [ScopeKey.of] of [name]. NOT unique – near-duplicate detection only
  /// (the same case-sensitive-exact-plus-warning rule used for projects
  /// applies to area names too).
  @Index()
  String nameKey;

  /// '' by default; cap enforced by the write path.
  String description;

  @Property(type: PropertyType.dateUtc)
  DateTime createdAt;

  @Property(type: PropertyType.dateUtc)
  DateTime updatedAt;

  Area({
    this.id = 0,
    required this.name,
    required this.nameKey,
    this.description = '',
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : createdAt = createdAt ?? DateTime.now().toUtc(),
       updatedAt = updatedAt ?? createdAt ?? DateTime.now().toUtc();
}

/// Area <-> project membership, as a synced LINK ENTITY keyed by NAMES –
/// not a `ProjectScope.areas` `ToMany`/`Area.projects` `@Backlink`. Reason:
/// with a ToMany, two devices independently assigning the SAME project to
/// the SAME area would each create their own `ProjectScope`/`Area` id, and
/// a cross-device `@Unique(replace)` on either owning entity mints a new
/// local id – silently dropping every relation row that pointed at the
/// old one, including area memberships and their metadata. Keying the link
/// itself by `area + [kFactKeySep] + project` instead means a cross-device
/// replace of an IDENTICAL key changes nothing semantically: same area,
/// same project, new local row id, membership intact.
///
/// `@Sync()`: the membership itself (which project is in which area) is
/// the durable, user-visible fact that must replicate – not an
/// implementation detail of [ProjectScope]/[Area].
@Entity()
@Sync()
class AreaMembership {
  @Id()
  int id = 0;

  /// `area + [kFactKeySep] + project`, deterministic from [area]/[project].
  /// Sync-mandated replace on this synthetic identity key is exactly the
  /// content-neutral case described in this class's doc – never rely on
  /// this for anything OTHER than that replace target; all reads resolve
  /// by [area]/[project], never by [key]. Value-indexed, not hash – see
  /// "Unique value index" above (2026-09-23, 0.3.1).
  @Unique(onConflict: ConflictStrategy.replace)
  @Index(type: IndexType.value)
  String key;

  /// Exact, case-sensitive [Area.name]. Not a relation on purpose – see
  /// class doc; resolved by name query, never by id.
  @Index()
  String area;

  /// Exact, case-sensitive [ProjectScope.name].
  @Index()
  String project;

  @Property(type: PropertyType.dateUtc)
  DateTime createdAt;

  AreaMembership({
    this.id = 0,
    required this.key,
    required this.area,
    required this.project,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now().toUtc();

  /// Canonical [key] for an (area, project) pair – the ONE place this
  /// composite is built, reused by every write/query site
  /// (memory_service_registry.dart) so it can never drift.
  static String keyFor(String area, String project) =>
      '$area$kFactKeySep$project';
}

/// One EAV (entity-attribute-value) fact row: an exact, structured value
/// keyed by (project, subject, attribute), with history – `fact_set`
/// closes the previous current row instead of overwriting it.
///
/// `@Sync()`: durable, user-authored structured data that must replicate.
///
/// No embeddings for facts in v1: exact access is the whole
/// point of this entity – a fact's value is addressed by
/// (project, subject, attribute), not by meaning, so embedding short EAV
/// strings would give poor ANN neighbours, cost an Ollama call per write,
/// and either add a second vector path (forbidden,
/// objectbox-capabilities.md §6) or mix a second source kind into the one
/// canonical [MemoryIndex]. A [MemoryEntry] linked via [explainedBy] can
/// carry the prose that `recall` finds instead.
@Entity()
@Sync()
class Fact {
  @Id()
  int id = 0;

  /// Required; same exact-string, server-validated rule as
  /// [MemoryEntry.project].
  @Index()
  String project;

  /// Cap `subjectMaxLen` (write path). Value-indexed (not hash) so
  /// `subjectPrefix` `startsWith` queries can use the index (F5).
  @Index(type: IndexType.value)
  String subject;

  /// Cap `attributeMaxLen` (write path).
  @Index()
  String attribute;

  /// Deterministic synthetic key
  /// `project + [kFactKeySep] + subject + [kFactKeySep] + attribute`
  /// (memory_service_registry.dart). Hash-indexed, DELIBERATELY NOT
  /// `@Unique`: history rows share this key on purpose, and the
  /// Sync-mandated replace on a unique key would DELETE history on every
  /// value change. The "at most one CURRENT row per key"
  /// invariant is therefore enforced by the write path (query-first in one
  /// write transaction), not by the schema – see [Fact.isCurrent] and the
  /// write path's explicit duplicate detection/repair.
  @Index()
  String factKey;

  /// One of [FactValueType.all].
  @Index()
  String valueType;

  /// '' unless [valueType] is [FactValueType.text]. Cap `factTextMaxLen`.
  String valueText;

  /// Set only when [valueType] is [FactValueType.number]. Not indexable –
  /// ObjectBox does not support `@Index` on `double`/`float` properties
  /// (F4); range filters (`numberMin`/`numberMax`) scan
  /// post-index.
  double? valueNumber;

  /// Set only when [valueType] is [FactValueType.date].
  @Property(type: PropertyType.dateUtc)
  DateTime? valueDate;

  /// '' by default. Cap `unitMaxLen`.
  String unit;

  /// When this value became true. Defaults to now on write.
  @Property(type: PropertyType.dateUtc)
  DateTime validFrom;

  /// Null = open-ended (still current, subject to [retractedAt]). Set by
  /// the write path when a newer value for the same [factKey] arrives.
  @Property(type: PropertyType.dateUtc)
  DateTime? validUntil;

  /// Soft-forget marker ("this was never true", as opposed to [validUntil]
  /// "this was true until a known date").
  @Property(type: PropertyType.dateUtc)
  DateTime? retractedAt;

  /// One of [MemorySource.all].
  @Index()
  String sourceType;

  /// Cap `factTextMaxLen` (reuses [MemoryEntry.sourceRef]'s cap).
  String sourceRef;

  @Property(type: PropertyType.dateUtc)
  DateTime createdAt;

  /// Forward history link, mirrors [MemoryEntry.supersededBy]: set on the
  /// row that was closed when a newer value replaced it.
  final supersededBy = ToOne<Fact>();

  /// Optional link to a [MemoryEntry] carrying the prose explanation for
  /// this fact. Synced-to-synced reference, allowed per
  /// how-to-use-objectbox.md §7/§8 (both entities replicate; this is not a
  /// sync/local-only boundary crossing).
  final explainedBy = ToOne<MemoryEntry>();

  Fact({
    this.id = 0,
    required this.project,
    required this.subject,
    required this.attribute,
    required this.factKey,
    required this.valueType,
    this.valueText = '',
    this.valueNumber,
    this.valueDate,
    this.unit = '',
    DateTime? validFrom,
    this.validUntil,
    this.retractedAt,
    required this.sourceType,
    this.sourceRef = '',
    DateTime? createdAt,
  }) : validFrom = validFrom ?? DateTime.now().toUtc(),
       createdAt = createdAt ?? DateTime.now().toUtc();

  /// "Current" per the addendum's definition: open-ended AND not retracted.
  /// Whether it is current AT A GIVEN INSTANT also requires
  /// `validFrom <= that instant` – checked by the write/read path,
  /// not here, since this getter has no `now` to compare against.
  bool get isCurrent => validUntil == null && retractedAt == null;

  /// Canonical [factKey] for a (project, subject, attribute) triple – the
  /// ONE place this composite is built (memory_service_registry.dart).
  static String keyFor(String project, String subject, String attribute) =>
      '$project$kFactKeySep$subject$kFactKeySep$attribute';
}

// ---------------------------------------------------------------------------
// Tag registry (strict registry mode)
// ---------------------------------------------------------------------------

/// Registered tag vocabulary: one row per tag name that `tag_define`
/// registered, with a one-sentence description. In strict registry mode
/// (`OBX_MEMORY_REGISTRY_MODE=strict`) a write may only attach tags that
/// have a row here; in open mode the table is informational
/// (`tags_list` reports `registered`/`description`).
///
/// A new entity instead of a property on [Tag]: every pre-existing entity
/// stays byte-identical (additive-only schema, see CLAUDE.md).
///
/// Name-keyed, NO relation to [Tag] – same reason as [AreaMembership]: a
/// cross-device replace on a unique name mints a new local id, which would
/// leave a ToOne dangling. Two devices defining the same name converge via
/// the Sync-mandated replace (content-neutral apart from the description:
/// the last write wins).
///
/// No stored loose key (unlike [ProjectScope.nameKey]): the tag loose key
/// (`_tagKey` in memory_service_tags.dart) has changed several times, so a
/// persisted derived key would go stale; the registry is small enough to
/// page through, as the near-duplicate check over [Tag] already does.
///
/// `@Sync()`: user-authored vocabulary that must replicate with the tags
/// it describes.
@Entity()
@Sync()
class TagDefinition {
  @Id()
  int id = 0;

  /// Normalized tag name (camelCase, as `_normalizeTag` produces it) –
  /// exact and case-sensitive; equals the [Tag.name] a write attaches.
  /// Replace-on-conflict is Sync-mandated – see [MemoryEntry.contentHash];
  /// the local write path is query-first in a write transaction
  /// (`tagDefine`, `_mergeTagsInto`). Value-indexed, not hash – see
  /// "Unique value index" above (2026-09-23, 0.3.1).
  @Unique(onConflict: ConflictStrategy.replace)
  @Index(type: IndexType.value)
  String name;

  /// What the tag marks, one sentence. Non-blank on create (enforced by
  /// the write path); cap `descriptionMaxLen`.
  String description;

  @Property(type: PropertyType.dateUtc)
  DateTime createdAt;

  @Property(type: PropertyType.dateUtc)
  DateTime updatedAt;

  TagDefinition({
    this.id = 0,
    required this.name,
    required this.description,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : createdAt = createdAt ?? DateTime.now().toUtc(),
       updatedAt = updatedAt ?? createdAt ?? DateTime.now().toUtc();
}

/// An alternative name for a registered tag: an old spelling, a synonym
/// or a term from another language (`chores` for `housework`, `recipe`
/// for `cooking`). A write that names the alias stores the canonical
/// [tag] instead (with a warning) – resolved in `_prepareTags`, the single
/// place for tag rules; `tag_define` sets the aliases, `tag_merge` records
/// merged-away names as aliases.
///
/// Name-keyed, NO relation to [TagDefinition] or [Tag] – same reason as
/// [TagDefinition] and [AreaMembership]: a cross-device replace on a
/// unique name mints a new local id, which would leave a ToOne dangling.
///
/// `@Sync()`: replicates with the definitions it belongs to.
@Entity()
@Sync()
class TagAlias {
  @Id()
  int id = 0;

  /// The alias, normalized like a tag (`_normalizeTag`) – exact and
  /// case-sensitive. One alias belongs to exactly one tag: unique.
  /// Replace-on-conflict is Sync-mandated – see [MemoryEntry.contentHash];
  /// the local write path is query-first in a write transaction and
  /// rejects an alias that already belongs to another tag. Value-indexed,
  /// not hash – see "Unique value index" above (2026-09-23, 0.3.1).
  @Unique(onConflict: ConflictStrategy.replace)
  @Index(type: IndexType.value)
  String name;

  /// The canonical tag: a [TagDefinition.name]. Value-indexed, so every
  /// alias of one tag is a single indexed lookup.
  @Index(type: IndexType.value)
  String tag;

  @Property(type: PropertyType.dateUtc)
  DateTime createdAt;

  TagAlias({
    this.id = 0,
    required this.name,
    required this.tag,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now().toUtc();
}

// ---------------------------------------------------------------------------
// Retired tags and attribute values (0.5.0)
// ---------------------------------------------------------------------------
//
// Three new entities instead of new properties on shipped ones: a property
// added to an existing entity changes that entity's model (property count,
// lastPropertyId), and a Sync peer still running an older binary would
// silently drop the field it does not know. New entities leave every
// shipped entity byte-identical (additive-only schema, see CLAUDE.md).

/// A tag name that must no longer be written: `tag_retire` marks it, with a
/// [hint] saying what to do instead (`status` – "use thread_update for the
/// state and kind snapshot for the report"). In strict registry mode a write naming
/// a retired tag is rejected; in open mode it is stored with a warning.
/// Checked in `_prepareTags` (Step 1a), the single place for tag rules –
/// only when any row exists, so a store without retirements takes the old
/// path.
///
/// One row per retired NAME: the tag itself ([aliasOf] `''`) and every
/// alternative name retired with it ([aliasOf] = the retired tag), so a
/// write using an old alias is caught even after its `TagAlias` row is
/// gone. Independent of [TagDefinition]/[TagAlias]/[Tag]: retiring a tag
/// neither removes its definition nor touches the entries that carry it
/// (`kind_migrate`/`entries_update` do that), and `tag_remove` never
/// deletes a retirement.
///
/// Name-keyed, NO relation – same reason as [TagAlias]: a cross-device
/// replace on a unique name mints a new local id, which would leave a
/// ToOne dangling.
///
/// `@Sync()`: replicates with the vocabulary it restricts.
@Entity()
@Sync()
class TagRetirement {
  @Id()
  int id = 0;

  /// The retired name, normalized like a tag (`_normalizeTag`) – exact and
  /// case-sensitive. Replace-on-conflict is Sync-mandated – see
  /// [MemoryEntry.contentHash]; the local write path is query-first in a
  /// write transaction (`tagRetire`). Value-indexed, not hash – see
  /// "Unique value index" above.
  @Unique(onConflict: ConflictStrategy.replace)
  @Index(type: IndexType.value)
  String name;

  /// What to do instead, one sentence (non-blank on create, enforced by
  /// the write path; cap `descriptionMaxLen`). Every row of one retirement
  /// carries the same hint.
  String hint;

  /// `''` for the retired tag itself; for an alternative name retired with
  /// it, the retired tag's [name]. Value-indexed, so every name retired
  /// with one tag is a single indexed lookup.
  @Index(type: IndexType.value)
  String aliasOf;

  @Property(type: PropertyType.dateUtc)
  DateTime createdAt;

  @Property(type: PropertyType.dateUtc)
  DateTime updatedAt;

  TagRetirement({
    this.id = 0,
    required this.name,
    required this.hint,
    this.aliasOf = '',
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : createdAt = createdAt ?? DateTime.now().toUtc(),
       updatedAt = updatedAt ?? createdAt ?? DateTime.now().toUtc();
}

/// Registered fact attribute (`attribute_define`): a one-sentence
/// [description] and, optionally, the allowed text values
/// ([AttributeValue] rows). A definition without values only describes the
/// attribute; one with values restricts `fact_set` – strict registry mode
/// rejects any other value, open mode stores it with a warning. Checked in
/// `_checkAttributeValue` (memory_service_attributes.dart), the single
/// place for this rule, and only when any definition exists.
///
/// Name-keyed, NO relation to [Fact] or [AttributeValue] – same reason as
/// [TagDefinition].
///
/// `@Sync()`: user-authored vocabulary that must replicate with the facts
/// it describes.
@Entity()
@Sync()
class AttributeDefinition {
  @Id()
  int id = 0;

  /// Exactly the [Fact.attribute] string it describes – case-sensitive,
  /// never normalized (fact attributes are byte-exact). Replace-on-conflict
  /// is Sync-mandated – see [MemoryEntry.contentHash]; the local write path
  /// is query-first in a write transaction (`attributeDefine`).
  /// Value-indexed, not hash – see "Unique value index" above.
  @Unique(onConflict: ConflictStrategy.replace)
  @Index(type: IndexType.value)
  String name;

  /// What the attribute records, one sentence. Non-blank on create
  /// (enforced by the write path); cap `descriptionMaxLen`.
  String description;

  @Property(type: PropertyType.dateUtc)
  DateTime createdAt;

  @Property(type: PropertyType.dateUtc)
  DateTime updatedAt;

  AttributeDefinition({
    this.id = 0,
    required this.name,
    required this.description,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : createdAt = createdAt ?? DateTime.now().toUtc(),
       updatedAt = updatedAt ?? createdAt ?? DateTime.now().toUtc();
}

/// One allowed text value of a registered attribute
/// ([AttributeDefinition]): `state` allows `backlog`, `inProgress`, `done`,
/// …. [position] keeps the order the values were given in (display order).
///
/// Name-keyed via the synthetic [key] (attribute + [kFactKeySep] + value),
/// NO relation – same reason as [AreaMembership]: a cross-device replace of
/// an identical key changes nothing semantically.
///
/// `@Sync()`: replicates with its definition.
@Entity()
@Sync()
class AttributeValue {
  @Id()
  int id = 0;

  /// `attribute + [kFactKeySep] + value` ([keyFor]) – one row per allowed
  /// value. Replace-on-conflict is Sync-mandated – see
  /// [MemoryEntry.contentHash]; the local write path is query-first in a
  /// write transaction. Value-indexed, not hash – see "Unique value index"
  /// above.
  @Unique(onConflict: ConflictStrategy.replace)
  @Index(type: IndexType.value)
  String key;

  /// Exactly [AttributeDefinition.name]. Value-indexed, so every value of
  /// one attribute is a single indexed lookup.
  @Index(type: IndexType.value)
  String attribute;

  /// The allowed value, exact and case-sensitive (compared with
  /// [Fact.valueText]).
  String value;

  /// Display order within the attribute (0-based).
  int position;

  @Property(type: PropertyType.dateUtc)
  DateTime createdAt;

  AttributeValue({
    this.id = 0,
    required this.key,
    required this.attribute,
    required this.value,
    this.position = 0,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now().toUtc();

  /// Canonical [key] for an (attribute, value) pair – the ONE place this
  /// composite is built. The write path rejects control characters (and
  /// with them [kFactKeySep]) in both parts, so the key cannot be forged.
  static String keyFor(String attribute, String value) =>
      '$attribute$kFactKeySep$value';
}

// ---------------------------------------------------------------------------
// Threads (0.5.0)
// ---------------------------------------------------------------------------
//
// Four new entities instead of new properties on shipped ones (additive-
// only schema, see CLAUDE.md). A thread is a concrete matter with a state
// that will be done one day; entries belong to it via [ThreadEntry]. The
// state history is one [ThreadState] row per asserted state.
//
// Sync caveats (same style as [Fact]): [Thread], [ThreadState] and
// [ThreadEntry] carry no `@Unique` property, so the Sync-mandated replace
// hazard (a new local id on a cross-device replace) does not exist for
// them. "At most one LIVE thread per (project, titleKey)" is therefore a
// write-path rule (query-first in one write transaction,
// memory_service_threads.dart), exactly like "one current fact per key"
// – two devices can still create the same title independently; then
// `thread_update` by title finds two live rows and rejects the call with
// both ids ("pass threadId"), `thread_list` shows both – never a silent
// pick. [Thread.version] is a per-device optimistic check: across devices
// the last write wins, as for every other synced row. [ThreadEntry.entry]
// can dangle after a cross-device [MemoryEntry.contentHash] replace – the
// same, documented hazard as [MemoryLink]; `thread_get` reports such rows
// as `missingEntryIds` with a warning instead of hiding them.

/// The states a thread can be in – a fixed set (not the attribute
/// register): filters, closed-detection and the cockpit symbols all depend
/// on it. [done] and [dropped] END a thread; every other state is live.
/// [symbols] is shared by the cockpit renderer and parser
/// (lib/src/cockpit_sync.dart).
abstract final class ThreadStates {
  static const backlog = 'backlog';
  static const planned = 'planned';
  static const inProgress = 'inProgress';
  static const waiting = 'waiting';
  static const paused = 'paused';
  static const done = 'done';
  static const dropped = 'dropped';

  static const all = [
    backlog,
    planned,
    inProgress,
    waiting,
    paused,
    done,
    dropped,
  ];

  /// The states that end a thread.
  static const closed = {done, dropped};

  /// One cockpit symbol per state.
  static const symbols = {
    inProgress: '▶',
    waiting: '⏳',
    paused: '⏸',
    planned: '❓',
    backlog: '○',
    done: '✅',
    dropped: '✖',
  };

  static bool isValid(String value) => all.contains(value);

  static bool isClosed(String value) => closed.contains(value);
}

/// A thread: a concrete matter with a state (`inProgress`, `waiting`, …)
/// that will be done one day. Entries belong to it via [ThreadEntry]; its
/// state history is the [ThreadState] rows. Written only by
/// `thread_update` (and `remember`/`supersede`/`forget` for attachments).
///
/// `@Sync()`: a durable, user-visible record that must replicate
/// (how-to-use-objectbox.md §8). See the "Threads (0.5.0)" section comment
/// above for the cross-device caveats.
@Entity()
@Sync()
class Thread {
  @Id()
  int id = 0;

  /// Display title, 1..200 characters, no leading/trailing whitespace, no
  /// control characters (enforced by the write path). Renamable.
  String title;

  /// [ScopeKey.of] of [title] – lookup key for "the thread with this
  /// title". NOT unique: the write path keeps at most one LIVE thread per
  /// ([project], [titleKey]) (contract §3, see the section comment).
  @Index()
  String titleKey;

  /// Exact project name – same rule as [MemoryEntry.project].
  @Index()
  String project;

  /// Denormalized current state: the state of the newest
  /// [ThreadState] row by (recordedAt, id) that is not [ThreadState.asHistory].
  /// Recomputed from the rows on every `thread_update`; `thread_get`
  /// re-derives it and reports a mismatch (contract §8).
  @Index()
  String state;

  /// When the current state became true; null = unknown (never defaulted
  /// to now).
  @Property(type: PropertyType.dateUtc)
  DateTime? stateEventAt;

  /// When the current state was recorded.
  @Property(type: PropertyType.dateUtc)
  DateTime stateRecordedAt;

  /// Until when a `paused` thread is paused (informational – the server
  /// never changes a state on its own).
  @Property(type: PropertyType.dateUtc)
  DateTime? pausedUntil;

  /// Optimistic version: +1 on every call that writes a state row (or
  /// fills in an unknown date), renames, moves, or changes [pausedUntil].
  /// Attachments do not change it. Per device – see the section comment.
  int version;

  @Property(type: PropertyType.dateUtc)
  DateTime createdAt;

  @Property(type: PropertyType.dateUtc)
  DateTime updatedAt;

  Thread({
    this.id = 0,
    required this.title,
    required this.titleKey,
    required this.project,
    required this.state,
    this.stateEventAt,
    required this.stateRecordedAt,
    this.pausedUntil,
    this.version = 1,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : createdAt = createdAt ?? DateTime.now().toUtc(),
       updatedAt = updatedAt ?? createdAt ?? DateTime.now().toUtc();

  /// True while the thread is not [ThreadStates.closed].
  bool get isLive => !ThreadStates.isClosed(state);
}

/// One asserted state of a [Thread] – history, never edited except for
/// filling in an unknown [eventAt] of the current row (`thread_update`
/// action `dated`).
///
/// `@Sync()`: the history replicates with its thread.
@Entity()
@Sync()
class ThreadState {
  @Id()
  int id = 0;

  /// The thread (contract §4: ToOne for ownership; indexed automatically).
  final thread = ToOne<Thread>();

  /// One of [ThreadStates.all].
  String state;

  /// When the state became true; null = unknown (never defaulted to now).
  @Property(type: PropertyType.dateUtc)
  DateTime? eventAt;

  /// When this row was written (always set).
  @Property(type: PropertyType.dateUtc)
  DateTime recordedAt;

  /// The pause date asserted together with this state (audit copy).
  @Property(type: PropertyType.dateUtc)
  DateTime? pausedUntil;

  /// '' by default; cap `_sourceRefMaxLen` (write path).
  String sourceRef;

  /// Set once at write time, never changed: true for late information
  /// dated before the current state – stored as history only, never the
  /// current row.
  bool asHistory;

  ThreadState({
    this.id = 0,
    required this.state,
    this.eventAt,
    required this.recordedAt,
    this.pausedUntil,
    this.sourceRef = '',
    this.asHistory = false,
  });
}

/// Thread ↔ entry membership – a link entity (contract §4) because the
/// edge carries metadata ([attachedAt], [via]) and both directions are
/// single indexed queries ("entries of thread T", "threads of entry E").
///
/// `@Sync()`: membership replicates with the thread and the entry.
@Entity()
@Sync()
class ThreadEntry {
  @Id()
  int id = 0;

  final thread = ToOne<Thread>();
  final entry = ToOne<MemoryEntry>();

  @Property(type: PropertyType.dateUtc)
  DateTime attachedAt;

  /// How it was attached: [ThreadVia.all].
  String via;

  ThreadEntry({this.id = 0, DateTime? attachedAt, required this.via})
    : attachedAt = attachedAt ?? DateTime.now().toUtc();
}

/// Values of [ThreadEntry.via].
abstract final class ThreadVia {
  /// The status report `thread_update` stored from its `note`.
  static const note = 'note';

  /// `thread_update` `attachEntryIds`.
  static const attach = 'attach';

  /// `remember(threadId)`.
  static const remember = 'remember';

  /// Carried from the replaced entry by `supersede`.
  static const supersede = 'supersede';

  static const all = [note, attach, remember, supersede];
}

/// Idempotency record of one `thread_update` call with an
/// `idempotencyKey`: a retry with the same key and the same arguments
/// returns [resultJson] instead of writing again.
///
/// LOCAL-ONLY, deliberately not `@Sync()`: a per-device retry trace
/// (how-to-use-objectbox.md §8 "per-device traces"), which also allows a
/// fail-on-conflict unique key (same as [MemoryIndex.sourceKey]). Rows
/// older than 30 days are pruned by `thread_update`.
@Entity()
class ThreadOp {
  @Id()
  int id = 0;

  /// The caller's idempotency key. Value-indexed, not hash – see "Unique
  /// value index" above.
  @Unique()
  @Index(type: IndexType.value)
  String key;

  /// Plain (device-local) id of the thread – never a relation across the
  /// sync boundary (contract §7, [MemoryIndex.entryId] pattern).
  int threadId;

  /// The thread's version after the call.
  int version;

  /// sha256 of the canonicalized call arguments (minus the key): the same
  /// key with different arguments is rejected, not replayed.
  String argsHash;

  /// The result map returned to the caller – archival only, never queried
  /// (contract §2 allows JSON there).
  String resultJson;

  @Index()
  @Property(type: PropertyType.dateUtc)
  DateTime createdAt;

  ThreadOp({
    this.id = 0,
    required this.key,
    required this.threadId,
    required this.version,
    required this.argsHash,
    required this.resultJson,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now().toUtc();
}

// ---------------------------------------------------------------------------
// Local-only retrieval index (the ONE canonical ANN index)
// ---------------------------------------------------------------------------

/// The single canonical ANN retrieval index (objectbox-capabilities.md §6:
/// "one canonical ANN index for each semantic retrieval use case").
///
/// Deliberately NOT `@Sync()`-annotated: embeddings are large, device-local
/// and fully recomputable from [MemoryEntry.text] (+ a local Ollama model),
/// so per contract §7/§8 this stays a local-only cache. It references the
/// synced [MemoryEntry] via plain [entryId] + [sourceKey] — never via a
/// relation, which would blur the sync/local boundary
/// (objectbox-capabilities.md §7: "do not blur sync boundaries with
/// accidental relations"). Local object IDs are safe here precisely because
/// this entity never leaves the device.
@Entity()
class MemoryIndex {
  /// Fixed HNSW dimensionality of the schema. OBX_MEMORY_DIMS must match;
  /// changing the embedding model to different dims requires a schema
  /// change here plus a full `reindex`.
  static const int hnswDimensions = 768;

  /// Synthetic unique identity key, `memory:<entryId>` — enforces "one
  /// index row per entry" in the schema (how-to-use-objectbox.md §3:
  /// synthetic unique keys instead of comment-only contracts). Value-indexed,
  /// not hash – see "Unique value index" above (2026-09-23, 0.3.1).
  @Unique()
  @Index(type: IndexType.value)
  String sourceKey;

  @Id()
  int id = 0;

  /// Plain (device-local) id of the indexed [MemoryEntry]; see class docs
  /// for why this is not a relation.
  @Index()
  int entryId;

  /// The embedding vector. Cosine distance: range 0.0 (same direction) to
  /// 2.0 (opposite), lower = more similar.
  @HnswIndex(
    dimensions: MemoryIndex.hnswDimensions,
    distanceType: VectorDistanceType.cosine,
  )
  @Property(type: PropertyType.floatVector)
  List<double>? embedding;

  /// Model that produced [embedding]; recall refuses to silently mix
  /// models (contract §6: explicit stale detection via embedding model).
  String embedModel;

  int dims;

  /// Copy of MemoryEntry.contentHash at indexing time; a mismatch on recall
  /// marks this row stale (contract §6: stale detection via text hash).
  String textHash;

  @Property(type: PropertyType.dateUtc)
  DateTime indexedAt;

  /// One of [IndexStatus.all].
  @Index()
  String status;

  MemoryIndex({
    this.id = 0,
    required this.sourceKey,
    required this.entryId,
    this.embedding,
    required this.embedModel,
    required this.dims,
    required this.textHash,
    DateTime? indexedAt,
    this.status = IndexStatus.ok,
  }) : indexedAt = indexedAt ?? DateTime.now().toUtc();

  /// Canonical [sourceKey] for an entry id.
  static String sourceKeyFor(int entryId) => 'memory:$entryId';
}
