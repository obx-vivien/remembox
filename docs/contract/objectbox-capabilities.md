# ObjectBox capabilities contract

This repo uses ObjectBox as the primary data layer.
Do not re-implement ObjectBox features in app code.
Treat the rules below as hard constraints.

## 1) Store lifecycle

Use:
- AT MOST ONE store open per store directory per isolate
- centralized store bootstrap
- committed generated model JSON

Do not:
- have TWO stores open on the same store directory in the same isolate
- treat the DB as a JSON bucket
- regenerate/delete the model file to "fix" schema issues

**Narrowed 2026-09-01 (Store-Gate feature, the 2026-09-01 store-gate
engineering log (internal), plan §0 finding F4):** this rule used to read
"one store per process, opened once" – `lib/src/store_gate.dart`'s
`StoreMode.gated` is a
deliberate, explicit, documented exception to the "opened once" half:
`StoreGate.gated`'s `withStore` opens the store, does one request's worth of
work, closes it, and repeats – many times over the process lifetime. This
does NOT violate the actual invariant this section protects (no two stores
open on the same store directory at once – `store.lock` makes that
structurally impossible, see `StoreGate`'s doc comment); it only violates the
"opened once" wording, which was tighter than the real constraint required.
Every other store-bootstrap site in this repo (persistent mode, the default,
unchanged) still opens its store exactly once at startup and holds it for
the process lifetime – gated mode is the one named exception, not a general
license to reopen stores elsewhere.

**Precise unit (2026-09-07):** the binding enforces at most one open Store
per store directory per isolate – "Cannot create multiple Store
instances for the same directory in the same isolate" (objectbox-5.3.2,
`lib/src/native/store.dart:472-477`) – not "per process". Several processes
opening the same directory are not covered by the binding's guard at all;
that is what `store.lock` in gated mode is for (see `StoreGate`'s doc
comment).

## 2) Modeling

Use:
- typed `@Entity` classes
- real relations and typed link entities
- queryable scalar fields for things you filter/count/sort
- normalized child entities when the relationship carries metadata

Do not:
- default to JSON-string bags for semantically important data
- hide important structure in opaque blobs when it should be queryable

Examples of data that should usually not live primarily in JSON strings:
- tags
- failure modes
- file lists
- command lists
- verification outcomes
- retrieval inputs / injected memory refs

## 3) Identity and invariants

Important invariants must be enforced by schema and write paths, not comments alone.

Use:
- synthetic unique identity keys when composite uniqueness is needed
- transaction-safe query-or-create / upsert helpers
- deterministic duplicate repair with explicit logging

Do not:
- rely on “there should only be one row” comments
- assume queries return one row without checking
- use silent replace semantics for root identity entities

Specifically:
- do not use `ConflictStrategy.replace` on repo/project/plan/root identity rows unless the reason is explicit and documented
- prefer update-in-place semantics inside a transaction

## 4) Queries

Use:
- direct ObjectBox queries for counts, slices, and ordering
- relation-aware filtering where supported
- narrow hydration after targeted queries

Do not:
- bulk-load whole boxes and compute dashboards/statistics in memory when direct queries can do the job
- use `getAll()` as the default read pattern

## 5) Reactive updates

Use:
- ObjectBox observers / subscriptions
- subscription-driven queue wakeups and UI updates

Do not:
- implement polling/tick loops as the primary DB change detector
- use repeated queries as invalidation
- rely on timers except for low-frequency safety/recovery cases

## 6) Vector search

Use:
- ObjectBox vector search with HNSW
- one canonical ANN index for each semantic retrieval use case
- explicit stale detection via text hash / embedding model / source identity

Do not:
- ship brute-force cosine scans in production
- keep two active vector-search systems for the same retrieval flow
- query several ANN boxes and merge results unless there is a very strong, documented reason

Preferred pattern:
- rich domain entities remain source-of-truth
- one canonical retrieval-index entity owns vectors and ANN queries
- retrieval hydrates source entities after nearest-neighbor search
- logs/hits reflect that one canonical path

## 7) Sync boundaries

Use:
- explicit synced vs local-only modeling
- local-only entities for caches, traces, and recomputable indexes when appropriate
- stable references across sync/local boundaries

Do not:
- blur sync boundaries with accidental relations
- create misleading references to device-local rows from synced entities
- hide sync/local decisions in comments only

**Undocumented native behavior (2026-09-07):** `@Sync()`-annotated entities
refuse `put()` with OBX_ERROR 10001 (the generic "illegal state" code, not a
dedicated "sync not activated" code) until a sync client has been both
created AND started for the store. A client on a URL that can never connect
(e.g. a reserved port such as `ws://127.0.0.1:0`) still activates local
writes without ever replicating anything. Neither `obx_sync_create`/
`obx_sync_start` (`objectbox-sync.h`) nor docs.objectbox.io documents this
write-activation side effect. Pinned locally by
`test/sync_annotation_test.dart`; re-verify on every ObjectBox upgrade.

## 8) Failure handling

Use:
- explicit logging and repair when invariants are broken
- typed failures/results where operations can be rejected
- deterministic cleanup for duplicates or stale projection/index rows

Do not:
- fail silently
- silently degrade from one retrieval path to another
- ignore rejected state transitions or broken references

## 9) Agent instruction

Before coding:
1. Read `objectbox-capabilities.md`.
2. Treat it as hard constraints.
3. If you think a requirement cannot be met cleanly with ObjectBox, propose the smallest fallback and justify it explicitly.
4. Do not introduce duplicate active persistence/indexing paths unless explicitly asked.
