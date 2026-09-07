# How to Use ObjectBox Correctly

Practical rules for ObjectBox usage in this repo.

This document is intentionally binding-agnostic where possible and written for
agent prompts as well as humans. Use the exact syntax of the current binding in
this repo instead of guessing API names.

## Core stance

Use ObjectBox as the primary structured data layer.

That means:
- model real entities and relations instead of treating the DB as a JSON bucket
- let the schema carry important invariants where possible
- let ObjectBox handle the things it is good at: queries, observers, sync, and vector search
- keep failure handling explicit; do not silently repair or silently degrade

---

## 1. Store lifecycle

- Open at most one store per store directory per isolate, and reuse it for
  the process lifetime wherever possible.
- Do not open two stores for the same store directory in the same isolate.
- Keep store initialization centralized.
- Treat the generated model JSON as sync-critical source code. Commit it. Do not delete/regenerate it to "fix" problems.

**Narrowed 2026-09-01 / precise unit 2026-09-07 (see `objectbox-capabilities.md`
§1):** `lib/src/store_gate.dart`'s `StoreMode.gated` is a deliberate,
documented exception to "reuse it for the process lifetime" –
`StoreGate.gated`'s `withStore` opens the store, does one request's worth of
work, closes it, and repeats – many times over the process lifetime. This
does not violate the actual invariant this section protects (no two stores
open on the same store directory at once – `store.lock` makes that
structurally impossible, see `StoreGate`'s doc comment); persistent mode (the
default, unchanged) still opens its store once at startup and holds it for
the process lifetime.

The binding itself enforces "at most one Store instance per store directory
per isolate" – "Cannot create multiple Store instances for the same
directory in the same isolate" (objectbox-5.3.2,
`lib/src/native/store.dart:472-477`) – not "per process". Several processes
opening the same directory are not covered by the binding's guard at all;
that is what `store.lock` in gated mode is for.

---

## 2. Model entities as entities, not JSON blobs

Prefer:
- typed `@Entity` classes
- real relations where the binding supports them
- normalized child/link entities when the relationship carries metadata
- queryable scalar fields for things you filter, sort, count, or aggregate

Avoid using JSON strings as the main representation for:
- tags
- failure modes
- command lists
- verification summaries
- file lists
- document references
- structured retrieval inputs

JSON is acceptable only when the field is truly archival/debug-only and is not a query surface.

### Good patterns

Use normalized entities when:
- order matters
- counts/frequencies matter
- the relationship itself has metadata
- items need independent filtering or aggregation
- you need referential integrity or cleanup

Examples:
- `MemoryLink` is better than `linkedEntryIdsJson`
- `Tag` is better than `tagsJson`
- `SourceDocument` is better than `sourceMetadataJson`

If a structure is semantically important, model it so ObjectBox can query it.

---

## 3. Put invariants in the schema, not only in comments

Comment-level contracts such as:
- "one row per task"
- "one index row per entry"
- "singleton row"
- "one profile per provider/model"

must not rely only on service-layer discipline.

### Preferred pattern: synthetic unique keys

ObjectBox indexes are per-property. When you need composite uniqueness, create a deterministic synthetic identity field and enforce uniqueness on it.

Examples:
- singleton: `singletonKey = 'singleton'`
- one tag per name: `tagKey = '<name>'`
- one profile per provider/model: `profileKey = '<provider>:<model>'`
- one index row per entry: `sourceKey = 'entry:<id>'`
- one link per entry pair: `linkKey = '<fromId>:<toId>:<linkType>'`

### Required write-path behavior

For any identity-bearing entity:
- use transaction-safe query-or-create / upsert helpers
- detect duplicates explicitly
- repair duplicates deterministically if possible
- log the repair with enough context to debug later
- do not assume "the query returns one row"

### Do not rely on silent replace semantics

Do not use `ConflictStrategy.replace` on root identity entities or relation-owning entities unless there is a very strong, documented reason.

Why:
- replacement can create a new object ID
- that is risky for backlinks/relations
- it hides identity mistakes instead of making them explicit

Preferred approach:
- query existing row by unique key
- update in place inside a write transaction
- create only if missing

Root identity entities such as entries, links, documents, and canonical retrieval-index rows should use explicit query-or-create/update semantics.

---

## 4. Relations and ownership

Use relations for ownership graphs and use link entities when the relationship has meaning of its own.

Prefer:
- `ToOne` / backlinks for clear ownership
- typed link entities when the edge carries metadata like rank, reason, weight, or impact type

Examples of good link-entity patterns:
- memory entry -> linked memory entry (via `MemoryLink`)
- memory entry -> source document (via `MemoryEntry.source`)
- memory entry -> tag (via `MemoryEntry.tags`)

Avoid duplicated or manually mirrored foreign keys unless they are truly necessary and clearly documented.

If the app has sync/local-only boundaries and relations cannot safely cross that boundary, use a stable synthetic key or clearly documented plain-ID strategy. Do not leave ambiguous references that only work by accident.

---

## 5. Query-first reads, not bulk loading

Do not materialize entire boxes and then filter/count/aggregate in memory unless there is a proven reason.

Prefer:
- `count()` for counts
- ordered and filtered queries for slices
- relation-aware filtering where supported
- targeted hydration after narrow queries

Good:
- query active memory entries directly
- count tagged entries directly
- query latest memory links for a small result set

Bad:
- `getAll()` on entries/tags/links and then building dashboard counts in app code

For long-running processes:
- close short-lived queries
- reuse long-lived queries only in repository/data-access code where it is deliberate and safe

---

## 6. Reactive updates: observers over polling

Use ObjectBox observers/subscriptions for live UI and worker wakeups.

Allowed:
- query subscriptions / data observers
- box/type change subscriptions
- subscription-driven worker wakeups
- low-frequency timers only for lease deadlines, orphan recovery, or inter-process safety fallback

Forbidden:
- polling/tick loops as the primary way to detect DB changes
- repeated `find()` / `getAll()` loops used as invalidation
- background timers whose main purpose is "refresh the database"

---

## 7. Vector search: one canonical ANN index

ObjectBox vector search is a feature to showcase clearly, not ambiguously.

### Rule: choose one canonical vector-search path

Do not keep two active ANN search systems for the same retrieval use case.

Bad pattern:
- a generic embedding/index entity with HNSW
- plus HNSW vectors directly on several domain entities
- plus retrieval code that may query one, the other, or both

That creates:
- duplicate vector storage
- stale drift
- unclear ownership of re-embedding
- unclear retrieval logs
- a weaker ObjectBox demo story

### Preferred architecture

Use one canonical retrieval/index entity for semantic search.

Recommended design:
- rich domain entities remain the business source of truth
- one local-only retrieval-index entity owns:
  - `sourceType`
  - `sourceId`
  - `sourceKey`
  - searchable text
  - summary/preview
  - vector
  - `embeddingModel`
  - `textHash`
  - timestamps/status
- semantic nearest-neighbor queries run against that one box only
- retrieval then hydrates the typed domain entities

If vectors already exist directly on domain entities, either:
- remove them, or
- keep them only as a temporary migration bridge and stop writing/querying them

### Stale detection must be explicit

The canonical index owner must detect and handle:
- missing index row
- changed searchable text
- changed embedding model/version
- missing source entity
- duplicate index rows for one source key

None of these may fail silently.

### Retrieval logging must match the architecture

Retrieval logs/hits must make it obvious which canonical index rows were returned and accepted.
Do not keep a logging model that hides whether hits came from one index, several indexes, or an in-memory fallback.

---

## 8. Sync boundaries

Be explicit about which entities are synced and which are local-only.

Use local-only entities for:
- large/recomputable indexes and caches
- per-device traces
- temporary projections
- debug-only artifacts

Use synced entities for:
- durable business records that matter across devices
- user-visible decisions/outcomes that must replicate

Rules:
- do not blur sync/local boundaries with accidental relations
- if a local-only entity references synced data, use a stable strategy and document it
- if vectors are large and recomputable, prefer local-only canonical retrieval indexes while keeping source entities synced where appropriate
- if logs reference local-only retrieval rows, keep those logs local-only too or store stable source keys instead of device-local IDs

---

## 9. Sync setup

Use ObjectBox Sync as the replication mechanism.

Allowed:
- one sync client lifecycle per store
- sync event listeners for status/UX
- per-project sync server datasets for demo repos
- unique host ports per demo repo

Forbidden:
- custom pull/update loops when sync is enabled
- manual replication jobs that duplicate sync
- polling the sync server for changes

Operational rules:
- after schema changes, regenerate ObjectBox code and refresh the sync-server model file
- never reuse another project’s sync-server dataset in a demo repo
- do not create a sync client when sync is disabled
- do not start a real sync client in tests unless the test explicitly needs it

### Undocumented native behavior: write-activation for `@Sync()` entities

ObjectBox refuses `put()` on `@Sync()`-annotated entities until a sync
client has been both created AND started for the store (OBX_ERROR 10001,
the generic "illegal state" code – not a dedicated "sync not activated"
code). A client on a URL that can never connect (e.g. the reserved port
`ws://127.0.0.1:0`) still activates local writes without ever replicating
anything. Neither `obx_sync_create`/`obx_sync_start` in `objectbox-sync.h`
nor docs.objectbox.io documents this side effect – it is undocumented
native behavior, pinned locally by `test/sync_annotation_test.dart`, and
must be re-verified on every ObjectBox upgrade.

---

## 10. Code generation and schema hygiene

After any entity or relation change:
- run the binding’s ObjectBox code generation step
- commit the generated model JSON
- update any demo sync-server model copy if your repo uses one
- rerun analysis/tests

Never paper over stale generated code with hand fixes.

---

## 11. No silent failures

This is mandatory.

Replace silent ambiguity with explicit behavior.

Examples:
- if a status update is rejected, return false or a typed failure and log it
- if a supposed singleton has duplicates, repair deterministically and log what was removed/kept
- if retrieval indexing is stale or missing, backfill explicitly and log it
- if a referenced source entity is missing, surface it as a warning/error and exclude it explicitly
- if migration of legacy JSON data fails, log entity id/key and field name

Good persistence code is noisy when invariants are broken.
Bad persistence code quietly continues.

---

## 12. Migration and cleanup

When moving from poor modeling to better modeling:
- support one clear migration path
- read old data once
- convert to the new representation
- persist the new representation
- stop writing the legacy representation
- document when a field/entity is transitional or deprecated

If duplicates or legacy rows already exist:
- clean them deterministically
- log the cleanup
- add tests for repair behavior

Do not leave permanent dual-write or dual-read paths unless there is a compelling reason.

---

## 13. What exemplary ObjectBox usage looks like

An exemplary ObjectBox-based app should demonstrate all of the following:

1. One store per store directory per isolate (see §1 for the gated-mode exception).
2. Typed entities and real relations/link entities.
3. Important invariants enforced by schema + transactional upserts.
4. Query-first reads instead of whole-box scans.
5. Reactive subscriptions instead of polling.
6. One clean vector-search architecture with one canonical ANN index.
7. Clear sync/local-only boundaries.
8. Minimal JSON blobs; structured/queryable data is modeled properly.
9. Explicit logging/repair for invariant violations.
10. Docs that explain the model and failure behavior clearly.

---

## 14. Short prompt contract for agents

When ObjectBox is in scope, include this in the prompt:

- Read `objectbox-capabilities.md` before coding.
- Treat it as hard constraints.
- Do not re-implement ObjectBox features in app code.
- Use schema-enforced identity and transaction-safe upserts.
- Do not use `ConflictStrategy.replace` on root identity entities.
- Do not store semantically queryable structures primarily as JSON blobs.
- Use one canonical ANN index for semantic retrieval.
- Make repair and failure behavior explicit; do not fail silently.

---

## 15. Quick anti-pattern checklist

Do not do these in production code:
- polling loops for DB change detection
- manual cosine scans over all rows
- dual active vector-search/index paths for the same retrieval use case
- `getAll()` + in-memory dashboard aggregation when direct queries would do
- root identity upserts via silent replace semantics
- comment-only singleton/uniqueness contracts
- storing queryable tags/lists/links as JSON strings by default
- silent duplicate repair with no logging
- silent fallback from one retrieval path to another

Use ObjectBox directly and visibly. That is the point.
