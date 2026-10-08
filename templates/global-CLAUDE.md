> **Copy to `~/.claude/CLAUDE.md` and replace the example project/area
> names with your own** (then delete this note). Keep personal values out
> of that file – they belong in RememBox. Claude Code reads it at the
> start of every session; the other Claude clients do not (they get the
> short block from `templates/instructions-for-claude.md` instead). Put
> that short block at the top of the file too, then these rules below it.

# Global rules (all projects)

## Continuity: cockpit, RememBox, skills

- **At the start of every session, read the cockpit first:**
  `<full path to your cockpit.md>` – the current state of all open topics
  (template: `templates/cockpit.md`).
- After a session with a notable result:
  1. Overwrite the topic's line in the cockpit – the cockpit is "now".
  2. Add a dated status entry to RememBox (`kind: fact` + tag `status`),
     append-only – RememBox is the history.
  3. Store decisions additionally as their own entry with `kind: decision`.
- Never create a second cockpit or status files next to it. If the
  cockpit file is not reachable, say so.
- On a conflict: cockpit = current state, RememBox = history, skills =
  rules.

## Persistent memory (MCP server `remembox`)

- **Recall first:** at the start of any non-trivial task, call `recall`
  with the topic (optionally with a `project` filter) – and again mid-task
  whenever an earlier decision might matter ("have we decided this
  already?").
- **Store without asking** with `remember`: decisions with their reasons
  (`kind: decision`), preferences and working rules (`kind: preference`),
  facts about projects, systems, people (`kind: fact`), episodes with a
  lesson (`kind: episode`), pointers to outside resources
  (`kind: reference`). These five are the only kinds – anything else is
  rejected. A status snapshot is `kind: fact` + tag `status`.
- **Dead ends matter most:** "approach X dropped because Y" as
  `kind: episode` with tag `deadEnd`. Before a new attempt at a known
  problem, `recall` the earlier attempts first, and never re-investigate
  something stored as done or failed without citing that entry.
- **Always fill provenance:** `sourceType` (chat/file/url/note),
  `sourceRef` (session, file path or URL), `project`, `tags`.
- **Never store** secrets, passwords, tokens or credentials, and nothing
  trivial or purely session-local.
- **Corrections via `supersede`**, never by deleting – the old entry stays
  linked as history. `forget` only when explicitly asked (a hard delete
  only when that is asked for explicitly too).

## Projects and areas

- `project` is required on every write. Two rules, pick consistently:
  - **Coding work inside a repository:** the repository's top-level
    directory name (e.g. `my-app`).
  - **Everything else:** a name from your fixed list. Example – the same
    names as in the short block, grouped into areas:
    - area `work` – projects `company1`, `company2`
    - area `home` – projects `family`, `private`, `cats`
    - area `money` – project `finances`
- Never free text, never an abbreviation, never blank: `recall` filters
  by `project` only (plus optional `kind`/`sourceType`) – tags are not a
  filter. An entry without a project shows up everywhere and is found
  nowhere.

## Register rule: look up, register, use

1. **Look up:** `areas_list` (projects with area and description),
   `tags_list` (tags with description and aliases). If a name fits, use it.
2. **Register** only when nothing fits, with a one-sentence description:
   a project with `project_set` (`name`, `description`, `addAreas` – create
   the area with `area_set` first if it does not exist yet; `project_set`
   rejects unknown areas), a tag with `tag_define` (`name`, `description`;
   old names, synonyms and spelling variants as `aliases` or
   `addAliases`).
3. **Use** the registered name. Never invent variants (`notes` next to
   `note`, `Company1` next to `company1`).

An alias is resolved to its tag automatically, in every mode – the result's
`warning` says so.

The server enforces the rule when it runs with
`OBX_MEMORY_REGISTRY_MODE=strict` (set in the `env` of the RememBox MCP
server in each client's configuration): writes with an unknown project or
tag are rejected, and the error names the closest registered names. See
"Strict registry mode" in RememBox's `docs/usage-guide.md`.

## Tags

- Cross-cutting labels that group ACROSS projects: people (`partner`,
  `kid1`), recurring themes (`taxes`, `hiring`), work markers (`status`,
  `todo`, `deadEnd`, `learning`).
- camelCase, singular, 3–5 per entry. Reuse before inventing: `tags_list`
  first.
- Never a project, area or kind name, and never an identifier or version
  (`t42`, `2.1.0`) – those belong in the text.
- The server normalizes tags to camelCase and drops one that repeats the
  project, a kind or an area; near-duplicates and identifier-like tags are
  kept with a `warning`. Read it.

## Linking is mandatory

After every `remember` or `supersede`, read the `related` list in the
result (or run a quick `recall`): an older state of the same thing →
`supersede`; something that belongs with it → `link` (`related`,
`derivedFrom`, `contradicts`, `parent`/`child`), or pass `links` (`toId`,
`type`, `note`) in the `remember` call itself. People, cases and objects
that already have entries are always linked.

## Three kinds of "new state" – nothing is lost

- **State that changes** (a rent, an address, a stage): `fact_set` – the
  old value stays in the history with its dates.
- **Measurements** (KPIs): never replaced – each value its own point with
  date and period. Until RememBox supports facts per period (check the
  current docs), store them as prose with `remember`.
- **Narrated status:** `supersede` – the old entry stays linked as history.

## `fact_set` or `remember`?

Rule of thumb: what will be looked up or calculated exactly is a fact;
what will be told is a memory. A fact is `project` + `subject` +
`attribute` + exactly one value: `valueText`, `valueNumber` (with an
optional `unit`) or `valueDate`. Yes/no becomes text, a list becomes
several facts. Reuse the attribute vocabulary – run `fact_query` with the
attribute before inventing a new one. Link a fact to the memory that
explains it with `explainedByEntryId`.

## Maintenance tools

`project_merge`, `entries_move`, `tag_merge`, `tag_remove` and
`tags_normalize` rewrite stored data – only when the user explicitly asks,
and with `dryRun: true` first.
