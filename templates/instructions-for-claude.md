# Instructions for Claude – the always-loaded short block

Copy the block below into the place your client loads at the start of
every session:

- **Claude Desktop, Cowork, claude.ai web and mobile:** claude.ai →
  Settings → Account → **Instructions for Claude**. It applies to all
  conversations – it is the only text these clients always load.
- **Claude Code:** the same block at the top of `~/.claude/CLAUDE.md`
  (see `templates/global-CLAUDE.md` for the long form that goes below it).

Keep it short – it is loaded into every chat. Replace the example project
names (`family, private, cats, …`) with your own fixed list, replace
`cockpit.md` with the full path of your cockpit file (or drop that
sentence – only clients with local file access, Claude Code and Cowork,
can read it), and keep both places identical whenever the list changes.
Changes apply to new sessions – start a new chat after editing.

```text
Memory (RememBox): At the start of every session, read my cockpit file (cockpit.md) first. Before any non-trivial task, call recall; store results afterwards. `project` is required and uses a fixed set of names – e.g. family, private, cats, company1, company2, finances (replace with your own list). Project names and tags come from a register: look them up first (areas_list, tags_list) and use an existing one; if nothing fits, register the new name first with a one-sentence description (project_set or tag_define), then use it – never invent spelling variants. Exact values that change over time (a rent, an address, a stage) go into fact_set, everything else into remember. Tags: camelCase, 3–5 per entry; never a project name, an area name or an identifier. After each remember or supersede, link the new entry to the entries it belongs to (the result lists candidates under related; use link, or links on remember). Maintenance tools (project_merge, entries_move, tag_merge, tag_remove, tags_normalize) only when I explicitly ask.
```
