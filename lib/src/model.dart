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
  @Unique(onConflict: ConflictStrategy.replace)
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

  @Unique(onConflict: ConflictStrategy.replace)
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
  /// [MemoryEntry.contentHash].
  @Unique(onConflict: ConflictStrategy.replace)
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
  /// synthetic unique keys instead of comment-only contracts).
  @Unique()
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
