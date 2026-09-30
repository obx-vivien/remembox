# Changelog

## 0.3.1

**Bug fix – back up `~/.remembox` first, as with any upgrade.** A write could fail permanently with an error like `Entity unavailable for indexed ID 225` (`DbFileCorruptException`, `OBX_ERROR` 10502), and the tag, project or area name involved became unusable forever – every later attempt to store that exact name failed the same way. Cause: unique string properties (tag names, project names, area names, and a few internal identity keys) were indexed as a 32-bit hash instead of by their real value; a write's uniqueness check on a hash index has to look up the matching bucket and load each candidate row by id, and if that row was already gone – a stale index entry – the load failed and took the whole write down with it.

Fixed by switching every `@Unique` string property to a value index, which keeps the real value in the index, so the uniqueness check should no longer need the by-id lookup that failed (our reading of the mechanism – ObjectBox does not document the value-index path); with replace-on-conflict a genuine match is still found and replaced. No manual step is needed: opening an existing store with 0.3.1 rebuilds the affected indexes, because their type changed. That rebuild is not documented by ObjectBox; it was observed on objectbox 5.3.2 / macOS arm64, where opening an affected store once with 0.3.1 removed the stale entries – hence the backup advice above. No data was lost in that test. One caveat for the rare case of a store that already holds two rows sharing one of these values: rebuilding a unique index is expected to refuse the store open (not tested) instead of repairing it – restore the backup and report it.

**If you use Sync, or otherwise run more than one remembox process against the same store:** every open rebuilds these indexes to match whichever build opened the store last – an old (0.3.0) build reopening after a new (0.3.1) build rebuilds them back to the hash index, and a 0.3.1 build reopening after that rebuilds them to the value index again, in either direction. Quit every running client (Claude Code, Desktop, Cowork, any daemon) before installing 0.3.1, and re-run `tool/sync-server/run.sh` so a sync server picks up the new model file, so only the new build opens the store afterwards – the same rule as any other upgrade, just worth repeating here since old and new builds would otherwise keep flipping the index type back and forth on every open.

- The Claude skill now lives in the repo at `skill/SKILL.md` (previously assembled only at release time from a maintainer-local file) and covers the 0.3.0 areas, facts and tags tools alongside the original recall-first / remember-after loop.

## 0.3.0

**Upgrade note – read before updating.** 0.3.0 adds four entities to the database. As soon as a 0.3.0 server has opened your store, a 0.2.x server can no longer open it (ObjectBox refuses with "DB's last entity ID … is higher than … from model"). So: back up `~/.remembox` first; quit every Claude window (and stop any daemon) before the first 0.3.0 start, so no 0.2.x process is still attached; a downgrade is only possible by restoring that backup. With Sync, upgrade every device and restart the sync server together. After the update, run `reindex` once (registers existing projects) and `tags_normalize` once (dryRun first).

Adds areas and facts on top of free-form memories.

- **New tools:** `area_set` / `project_set` (create or update an area, or a
  project's description, status and area membership), `areas_list` /
  `project_merge` (inspect the registry and its health, merge a duplicate
  project name into another), `fact_set` / `fact_get` / `fact_query` /
  `fact_forget` (exact, structured values keyed by project + subject +
  attribute, with automatic history).
- **`area` filter** added to `recall`, `list_recent` and `fact_query` –
  matches every project assigned to that area.
- **`stats`** gained a `facts` block and an `byArea` breakdown alongside the
  existing `byProject`.
- Schema change is additive only: four new entities (`ProjectScope`, `Area`,
  `AreaMembership`, `Fact`); every existing entity is unchanged.

### Upgrade steps

1. Restart all Claude sessions (Claude Code, Desktop, Cowork) after updating
   so they pick up the new binary and tool list.
2. Run `reindex` once – besides its usual vector-index repair, it also
   registers every project name already used on existing entries and facts
   that has no registry row yet, so `areas_list` and area filtering see the
   full picture from the start.
3. If you use Sync: upgrade all devices and restart the sync server before
   relying on the new entities across more than one device – a device still
   on the 0.2.0 model does not know about `ProjectScope`/`Area`/
   `AreaMembership`/`Fact` and cannot write them.

- Date and time arguments (`expiresAt`, `docCreatedAt`, and the fact tools' `valueDate`, `validFrom`, `at`, `validUntil`) are parsed strictly: a bare date (`YYYY-MM-DD`) means UTC midnight, a date-time must carry `Z` or an explicit offset, and a date that does not exist (e.g. `2030-02-30`) is rejected instead of being rolled over.
- Fact history never overlaps: a new value closes every value that would still be valid at its start; a value cannot be inserted before an existing or scheduled one (the error names the scheduled fact and how to cancel it).
- **Tag discipline:** `remember`/`supersede` now normalize every tag to camelCase (`apps-script` -> `appsScript`), drop tags redundant with the entry's project/kind/area (with a warning), and warn (without rejecting) about near-duplicates of an existing tag, more than five tags on one entry, and identifier/version-shaped tags – the tool result's `warning` always says what changed. **New tools:** `tags_list` (usage counts, variant groups, unused count – check before inventing a new tag), `tag_merge` / `tag_remove` (bulk tag-graph cleanup, both `dryRun`-capable and idempotent).
- **New tool `entries_move`:** moves selected memory entries (by id) into a different project, to split a catch-all project – `project_merge` moves a whole project, `entries_move` moves only the ids you name. Pulls each id's full supersede chain along by default (`includeChain: false` to move only the given ids), never touches facts, and is `dryRun`-capable like `project_merge`.
- **Tag write path now rejects control characters outright:** a raw tag containing any control character (`U+0000`-`U+001F`, `U+007F`) is dropped before normalization, with a warning – it used to survive normalization and be stored with the raw control bytes intact (only the log line was sanitized).
- **Tag normalization fixes:** digit-led tags now normalize in one stable pass (`2026 Q3` -> `2026q3`, `3 D Printing` -> `3dPrinting`), and an acronym pluralized with a trailing `s` normalizes as one word instead of being mangled (`APIs` -> `apis`, not `apIs`) – both are idempotent, re-normalizing the stored form changes nothing.
- **New tool `tags_normalize`:** a one-shot upgrade helper for stores written before 0.3.0 – merges every tag whose stored spelling predates today's camelCase rule (e.g. `apps-script` -> `appsScript`, `KPI` -> `kpi`, `APIs` -> `apis`, `2026 Q3` -> `2026q3`) into its normalized form, in one pass. `dryRun: true` first, like `tag_merge`/`tag_remove`; safe to re-run (a second run finds nothing left to change).

## 0.2.0

HTTP daemon mode (`--serve`) for sharing one store across several Claude
sessions over local HTTP, plus store-permission and lock hardening.
