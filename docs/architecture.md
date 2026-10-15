# Architecture & development

RememBox is also intended as a showcase of exemplary ObjectBox usage; the
binding rules it follows live verbatim in [docs/contract/](contract/).

## Architecture

```
             MCP (stdio, JSON-RPC)                 ObjectBox store
Claude ◄──────────────────────────► RememboxServer ┌───────────────────────────┐
                                        │          │ @Sync  MemoryEntry ─┬─ ToMany → Tag
                              MemoryService        │ @Sync  SourceDocument ◄──┘ ToOne
                                │       │          │ @Sync  MemoryLink (typed edges)
                       Embedder │       │          │ @Sync  ProjectScope, Area
                     (Ollama /api/embed)│          │ @Sync  AreaMembership (name-keyed link)
                                        │          │ @Sync  Fact ─ToOne→ MemoryEntry (explainedBy)
                                        │          │ @Sync  TagDefinition (name-keyed, no relation)
                                        │          │ @Sync  TagAlias (alias -> tag name, no relation)
                                        │          │ @Sync  TagRetirement, AttributeDefinition,
                                        │          │        AttributeValue (name-keyed)
                                        │          │ @Sync  Thread ◄─ToOne─ ThreadState (history)
                                        │          │ @Sync  ThreadEntry ─ToOne→ Thread, MemoryEntry
                                        │          │ local  ThreadOp (idempotency, plain threadId)
                                        │          │ ─────────────────────────
                                        └────────► │ local  MemoryIndex        │
                                                   │        (HNSW 768, cosine) │
                                                   └───────────────────────────┘
```

Two design decisions carry the whole model (see `lib/src/model.dart` for the
contract citations):

- **Rich domain entities are the source of truth; ONE canonical ANN index
  owns all vectors.** `MemoryIndex` is the only entity with an `@HnswIndex`
  and the only box nearest-neighbor queries run against. Retrieval hydrates
  `MemoryEntry` rows afterwards. No second vector path exists
  (contract: objectbox-capabilities.md §6).
- **Synced vs local-only is explicit.** The domain entities are
  `@Sync()` (they are the durable knowledge that replicates); the index is
  deliberately NOT – embeddings are large, device-local and recomputable, so
  it references entries by plain id/sourceKey instead of a relation across
  the sync boundary (contract §7/§8). After a sync delivers entries from
  another device, an ObjectBox **observer** (`store.entityChanges`) wakes a
  debounced, INCREMENTAL sweep that bulk-diffs entries against index rows
  (two box-wide reads, not one query per entry) and embeds/repairs only
  actual discrepancies – no polling, and no full reindex on every change.
  The service suppresses its OWN writes from re-triggering this sweep (e.g.
  `recall`'s access-count bump), since ObjectBox's change observer cannot
  tell apart a local write from one that arrived via sync. `reindex` (the
  MCP tool) remains the thorough, full-repair path.

Other invariants live in the schema, not in comments: `contentHash` is
unique (dedup), `Tag.name` is unique, `MemoryIndex.sourceKey`
(`memory:<entryId>`) enforces one index row per entry. Every repair,
duplicate, fallback and exclusion is logged to stderr; tool results carry
explicit `warnings`.

For how the store itself is opened (once per process vs. once per tool
call, and how that is derived automatically) and what that means
operationally, see the README's
[One store, multiple Claude windows](../README.md#one-store-multiple-claude-windows)
section.

## Areas and facts (0.3.0)

Four entities were added on top of the original four: `ProjectScope` (one
row per project name, holding its description/status), `Area` (a named
group), `AreaMembership` (which project belongs to which area) and `Fact`
(an exact, structured value with history). All four are `@Sync()` – they
are durable, user-visible records, same rationale as the original domain
entities.

**Membership is a link entity keyed by names, not a `ToMany`.** The
obvious design – `ProjectScope.areas` as a `ToMany<Area>` – breaks under
Sync: ObjectBox Sync requires `@Unique(onConflict: ConflictStrategy.replace)`
on every unique property of a synced entity, so a cross-device replace of
`ProjectScope.name` or `Area.name` mints a new local id, silently dropping
every relation row that pointed at the old one. `AreaMembership` avoids
this by keying itself on `area + <sep> + project` (`AreaMembership.key`,
`kFactKeySep` as the separator) and resolving `area`/`project` by name,
never by id. A cross-device replace of an identical key changes nothing
semantically – same area, same project, new local row id, membership
intact.

**Facts have no embeddings.** `Fact` deliberately carries no vector: exact
access by (project, subject, attribute) is the whole point, so an ANN
index would give poor neighbours for short EAV strings, cost an Ollama
call per write, and either add a second vector path (forbidden – see the
canonical-index rule above) or mix a second source kind into the one
`MemoryIndex`. A `Fact` can instead point (`explainedBy`, `ToOne<MemoryEntry>`)
at a `MemoryEntry` carrying the prose explanation, which `recall` can find.

**The `area` filter resolves in three steps:** `AreaMembership` rows
matching the area name are queried for their `project` property only (a
property projection, not full entity hydration); those project names are
then used as a case-sensitive `oneOf(...)` condition against
`MemoryEntry.project` / `Fact.project`. No relation traversal is involved,
consistent with membership being name-keyed rather than id-keyed.

**`Fact.factKey` is intentionally not `@Unique`.** It is the deterministic
`project + <sep> + subject + <sep> + attribute` string that groups a
fact's history, but a `@Unique(replace)` index on it would mean a
Sync-mandated replace on every new value for the same key – which would
delete the previous row instead of closing it, destroying history on the
very first correction. The "at most one current row per key" invariant is
therefore enforced by the write path (query-first inside one write
transaction), not by the schema; concurrent cross-device `fact_set` calls
on the same key can transiently produce two current rows, which the write
path detects and repairs explicitly, never silently.

## Tag registry and strict registry mode

`TagDefinition` (one row per registered tag name, with a description)
was added after 0.3.1, again additive-only – every earlier entity is
byte-identical (pinned by `test/model_compat_test.dart` against the frozen
0.3.1 model). Like `AreaMembership` it is keyed by name and has no
relation to `Tag`: a cross-device replace on a unique name mints a new
local id, which would leave a `ToOne` dangling. It stores no derived loose
key (unlike `ProjectScope.nameKey`), because the tag loose key has changed
more than once; the registry is small enough to page through.

`TagAlias` (one row per alternative name of a registered tag: `name`
unique, `tag` the canonical `TagDefinition.name`) ships with it and
follows the same rules – name-keyed, no relation. `_prepareTags`
resolves an alias to its tag on every write, in both modes, before the
redundancy and strict steps; it only looks when any alias exists.
Projects have no alias entity: a merged `ProjectScope` tombstone already
plays that role.

`OBX_MEMORY_REGISTRY_MODE` (per process, not stored) decides what the
write paths do with names that are not registered. `open` (default)
registers a new project name on first write (logged) and simply creates a
new tag; nothing is rejected, warnings only for near-duplicates and
merged project names. `strict` rejects the write instead: the project must
have a `ProjectScope` row that is not a `merged` tombstone (checked by
`_requireWritableProject`), and every tag that survives `_prepareTags`'
redundancy step must have a `TagDefinition` row. Both checks run inside
the caller's write transaction, before anything is put, embedded or
logged as written, so a rejection leaves nothing behind and cannot race
the write. Read tools behave the same in both modes; `reindex` still
registers every project name already in use, which is the migration path
into strict mode.

## Retired tags, attribute values and in-place edits (0.5.0)

Three entities were added after 0.4.0, additive-only again – the eleven
earlier entities are byte-identical (pinned by `test/model_compat_test.dart`
against the frozen 0.4.0 model):

- `TagRetirement` – one row per retired tag name (`name` unique, `hint`,
  `aliasOf` = the retired tag for an alternative name retired with it,
  `''` for the tag itself).
- `AttributeDefinition` – one row per registered fact attribute (`name`
  unique = exactly `Fact.attribute`, `description`).
- `AttributeValue` – one row per allowed value (`key` unique =
  attribute + `<sep>` + value, `attribute`, `value`, `position`).

**Why new entities, not new properties.** Retirement could have been a
flag on `TagDefinition`, the allowed values a list on it. But a property
added to a shipped entity changes that entity's model, and a Sync peer
still running an older binary drops the field it does not know – silently.
New entities leave every shipped entity untouched; an older binary refuses
the store outright (higher last entity id) instead of half-reading it. All
three are `@Sync()`, name-keyed and relation-free, like `TagAlias` and
`AreaMembership`, for the same cross-device-replace reason.

**One place per rule.** `_prepareTags` checks retirements (Step 1a,
before alias resolution, only when any retirement exists);
`_checkAttributeValue` checks a `fact_set` value against the register
(inside the write transaction, before anything is written, a no-op while
no attribute is registered). Strict mode rejects through `_rejectStrict`,
open mode warns – so a store without retirements or attribute
definitions behaves exactly as before.

**Kinds and links are constants, not entities.** The three new kinds
(`snapshot`, `lesson`, `deadEnd`) and the new link type `partOf` are
values of the existing `kind`/`linkType` strings. How a link reads from
each end (`partOf`/`hasPart`, …) is computed on read
(`LinkType.relationFrom`); nothing about it is stored.

**In-place edits never touch content.** `entries_update` and
`kind_migrate` change only `MemoryEntry.kind` and the tags relation. Kind
and tags are not part of `contentHash` or of the embedded text, so the
index row stays valid – no re-embedding, no stale row.

## Threads (0.5.0)

Four more entities, additive-only again (pinned by
`test/model_compat_test.dart`): `Thread` (title, `titleKey`, project, the
denormalized current state, `pausedUntil`, `version`), `ThreadState` (one
row per asserted state: `eventAt` – null when unknown, never defaulted –
`recordedAt`, `asHistory`), `ThreadEntry` (thread ↔ entry, with
`attachedAt` and `via`) and `ThreadOp` (one row per `thread_update` call
with an `idempotencyKey`).

**A link entity, not a `ToMany`.** "Entries of thread T" and "threads of
entry E" are each one indexed query on a `ThreadEntry` ToOne, the edge
carries metadata, `forget(hard)` removes an entry's rows with one
`query.remove()` like it does for `MemoryLink`, and `lastRelationId` stays
untouched.

**Sync.** `Thread`, `ThreadState` and `ThreadEntry` are `@Sync()` and have
no `@Unique` property, so there is no Sync-mandated replace hazard. "At
most one live thread per (project, title)" is therefore a write-path rule
(query-first inside the one write transaction of `thread_update`), exactly
like "one current fact per key": two devices can still create the same
title independently – a call by title then sees two live rows and is
rejected with both ids, `thread_list` shows both. `version` is a
per-device optimistic check; across devices the last write wins, as for
every other synced row. A `ThreadEntry` can dangle after a cross-device
`MemoryEntry` replace – the same hazard as `MemoryLink`; `thread_get`
reports such rows instead of hiding them. `ThreadOp` is local-only (a
per-device retry trace, contract §8), references the thread by plain id,
and may therefore carry a fail-on-conflict `@Unique` key; rows older than
30 days are pruned by `thread_update`.

**The current state** is the newest `ThreadState` row by (`recordedAt`,
id) that is not `asHistory`; `Thread.state`/`stateEventAt`/
`stateRecordedAt` are a copy, recomputed on every `thread_update`
(`thread_get` is read-only and reports a disagreement; the next
`thread_update` repairs it). `recordedAt` is taken inside the write
transaction, under `store.lock`, and a new current row is recorded at
least 1 ms after every earlier one – so the call that commits last is
current, and a result never reports a state that did not become current.
Late information dated before the latest known state date is written
with `asHistory: true` – it never becomes current. Whether a thread is
live is always read from its history, never from the stored copy alone
(a by-title call resolves by it). The allowed states are a fixed set
(`ThreadStates`), not the attribute register: filters, closed-detection
and the cockpit symbols depend on them.

**The cockpit sync** (`remembox cockpit-sync`, `lib/src/cockpit_sync.dart`)
is a short-lived CLI process, not an MCP tool – the server has no tool that
writes files. It is a second sanctioned opener of the store: one gated
lending behind `store.lock` (never a second open store next to a
lending), no embedder, through the same `readThreadRows` projection
`thread_list` uses.

## Ranking

```
score = similarity + W_RECENCY * exp(-ageDays/30) + W_FREQUENCY * min(accessCount, 10)/10
similarity = 1 - cosineDistance / 2        # distance ∈ [0, 2], lower = closer
```

Similarity always dominates; the boosts are small tie-breakers (v0
heuristic – expect to tune). The active formula is logged at startup, and
every hit reports `distance`, `similarity`, `recencyBoost`, `frequencyBoost`
and `score` separately, so weight tuning (`OBX_MEMORY_RANK_W_*`, see
[Configuration](configuration.md)) is data-driven.

## Development notes

- `lib/objectbox-model.json` and `lib/objectbox.g.dart` are **committed**
  (the model file is schema source-of-truth – never delete/regenerate it to
  "fix" issues; see [docs/contract/](contract/)). After entity changes:
  `dart run build_runner build` and commit both.
- Tests use temp-dir stores and a deterministic `FakeEmbedder` (exact cosine
  angles via plane vectors) – `dart test` needs no network.
- `dart analyze` must stay clean; sources are `dart format`ted.
- The store holds YOUR memories: `~/.remembox` is never committed.
- See [CLAUDE.md](../CLAUDE.md) for the full set of engineering ground
  rules (persistence contract, platform gotchas, common tasks) followed
  when developing RememBox itself.
