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
                       Embedder │       │          │ ─────────────────────────
                     (Ollama /api/embed)│          │ local  MemoryIndex        │
                                        └────────► │        (HNSW 768, cosine) │
                                                   └───────────────────────────┘
```

Two design decisions carry the whole model (see `lib/src/model.dart` for the
contract citations):

- **Rich domain entities are the source of truth; ONE canonical ANN index
  owns all vectors.** `MemoryIndex` is the only entity with an `@HnswIndex`
  and the only box nearest-neighbor queries run against. Retrieval hydrates
  `MemoryEntry` rows afterwards. No second vector path exists
  (contract: objectbox-capabilities.md §6).
- **Synced vs local-only is explicit.** The four domain entities are
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
[One store, any number of windows](../README.md#one-store-any-number-of-windows)
section.

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
