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

  static const all = [fact, decision, preference, episode, reference];

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
abstract final class LinkType {
  static const parent = 'parent';
  static const child = 'child';
  static const related = 'related';
  static const contradicts = 'contradicts';
  static const derivedFrom = 'derivedFrom';

  static const all = [parent, child, related, contradicts, derivedFrom];

  static bool isValid(String value) => all.contains(value);
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
