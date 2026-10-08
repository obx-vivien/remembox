> Deutsche Version: [docs/quickstart.de.md](quickstart.de.md)

# RememBox in 15 minutes: give Claude a lasting memory

This guide is for everyone – **no programming required**. By the end,
Claude will be able to remember things across sessions: your projects, your
preferences, decisions you've made.

Everything runs **locally on your Mac**. Your memories never leave your
machine.

> **What you need:** a Mac with Apple Silicon (M1/M2/M3/…), about 15
> minutes, and roughly 1 GB of free disk space. The pre-built ZIP is built
> and tested for Apple Silicon. On an Intel Mac or under Linux, RememBox
> only runs if you build it yourself from source (see the
> [README](https://github.com/obx-vivien/remembox#quick-start-macos-apple-silicon),
> "build from source" section) – that path is untested, and this
> step-by-step guide assumes the pre-built ZIP.

---

## Step 1: Install Ollama

Ollama is a small, free program that RememBox uses in the background to
make your memories "understandable" (it turns text into something you can
search by meaning – not just by keyword).

1. Open in your browser: **https://ollama.com/download**
2. Click **Download for macOS** and open the downloaded file.
3. Drag **Ollama** into the **Applications** folder, like any app.
4. Start Ollama once (double-click it in Applications). A small llama icon
   🦙 appears in the menu bar at the top – that means Ollama is running.

Ollama now starts automatically with your Mac. You never have to think
about it again.

## Step 2: Load the language model

Now Ollama needs the small model RememBox works with. For this we'll use
the **Terminal** briefly – don't worry, it's just a window where you type
one command.

**How to open the Terminal:**
Press `⌘ + Space` (this opens Spotlight search), type `Terminal`, and
press `Enter`. A plain window with a blinking cursor opens.

Type (or paste) this line into it and press `Enter`:

```bash
ollama pull embeddinggemma
```

Ollama now downloads the model (about 600 MB, takes a few minutes
depending on your internet connection). When the blinking cursor reappears
and the last line reads `success`, it's done.

(If you skip this step, RememBox tries to pull the missing model itself on
first start – but that only works while Ollama is running, and it makes
the very first use take longer.)

## Step 3: Download RememBox

1. Download the latest release here:
   **https://github.com/obx-vivien/remembox/releases/latest**
   Pick the macOS (Apple Silicon) ZIP file, e.g.
   `remembox-0.2.0-macos-arm64.zip` – the exact version number in the
   filename changes with every release.
2. Double-click the ZIP file – this creates a `remembox` folder.
3. Put this folder in a **permanent location**, one that will stay put –
   e.g. directly in your home folder. Important: do **not** leave it in
   your Downloads folder, which tends to get cleaned out, and then Claude
   can no longer find its memory.

Remember where you put it. For the rest of this guide, we'll assume the
folder sits directly in your home folder, i.e. at `~/remembox` (the tilde
`~` is shorthand for your home folder).

## Step 4: Connect RememBox to Claude

Several Claude windows can share the same memory without any extra setting
– register RememBox the plain way and it just works.

**If you use Claude Code** (Claude in the terminal):

Type this line in the Terminal and press `Enter` – replace the path if
your folder lives somewhere else:

```bash
claude mcp add remembox --scope user -- ~/remembox/dist/remembox
```

That's it. The message should confirm that `remembox` was added.

**If you use the Claude Desktop app:**

In the app, open **Settings → Developer → Edit Config** (depending on the
app version, this may instead be under Extensions → Advanced settings). A
file named `claude_desktop_config.json` opens. Add the following:

```json
{
  "mcpServers": {
    "remembox": {
      "command": "/path/to/remembox/dist/remembox"
    }
  }
}
```

Replace `/path/to/remembox` with the full path to the folder from Step 3
(the JSON config needs the full path, not the `~` shorthand). If you're not
sure what that is: change into the folder in the Terminal and type `pwd` –
that prints the full path you need.

If the file already has other entries under `"mcpServers"`, add only the
`"remembox"` block inside the existing braces (separated by a comma) –
don't replace the whole file, or the other entries will be lost.

Save, then fully quit and reopen Claude Desktop (`⌘Q`, not just closing
the window).

**Optional: let the server enforce your project names and tags.** By
default a new project name is registered on first write (logged) and a
new tag is simply created – nothing is rejected, warnings only for
near-duplicates and merged project names. In strict registry mode RememBox rejects a write with a
project or tag you haven't registered yet (with `project_set` or
`tag_define`), so no session can invent a new spelling. To turn it on,
add the setting to the registration – for Claude Code (if RememBox is
already registered, remove it first:
`claude mcp remove remembox --scope user`, then):

```bash
claude mcp add remembox --scope user -e OBX_MEMORY_REGISTRY_MODE=strict -- ~/remembox/dist/remembox
```

For the Desktop app, add an `env` entry next to `command`, then fully
quit and reopen Claude Desktop (`⌘Q`):

```json
"remembox": {
  "command": "/path/to/remembox/dist/remembox",
  "env": { "OBX_MEMORY_REGISTRY_MODE": "strict" }
}
```

With strict mode on, Claude registers the project (`project_set`) before
the first save – that extra step is expected. Use the same setting in
every app you connect. On a brand-new memory you
can switch it on right away; for an existing one, follow the checklist in
the [usage guide](usage-guide.md#strict-registry-mode) first.

## Step 5: Make the rules load in every session

This step is what makes RememBox work reliably, so please don't skip it.
Claude only follows RememBox's usage rules if it gets them at the start of
**every** session. Without them, sessions tend to invent a new spelling of
the same project name, use one name in one app and another in the next, or
tidy up your memory when nobody asked. The skill from Step 7 can't do this
alone: a skill is only loaded when the topic seems to match, so it is not
guaranteed to be there.

Where the text goes depends on the app – it has to be a place that is
loaded every time:

- **Claude Desktop, Cowork, claude.ai in the browser, and the mobile app:**
  open claude.ai → **Settings → Account** and paste the block below into
  the field **Instructions for Claude**. Claude applies it to all
  conversations, so it is there at the start of every chat and every
  Cowork session. (In some app versions the field appeared as
  "personal preferences"; Cowork's former "Global instructions" now live
  here too.)
- **Claude Code:** paste the same block into the file
  `~/.claude/CLAUDE.md` (create it if it doesn't exist). Claude Code reads this
  file at the start of every session, and the other apps don't read it –
  so if you use both, paste the block in both places.

```text
Memory (RememBox): At the start of every session, read my cockpit file (cockpit.md) first. Before any non-trivial task, call recall; store results afterwards. `project` is required and uses a fixed set of names – e.g. family, private, cats, company1, company2, finances (replace with your own list). Project names and tags come from a register: look them up first (areas_list, tags_list) and use an existing one; if nothing fits, register the new name first with a one-sentence description (project_set or tag_define), then use it – never invent spelling variants. Exact values that change over time (a rent, an address, a stage) go into fact_set, everything else into remember. Tags: camelCase, 3–5 per entry; never a project name, an area name or an identifier. After each remember or supersede, link the new entry to the entries it belongs to (the result lists candidates under related; use link, or links on remember). Maintenance tools (project_merge, entries_move, tag_merge, tag_remove, tags_normalize) only when I explicitly ask.
```

Replace the project list (`family, private, …`) with your own – short,
stable names for the areas of your life or work you want to keep apart.
The first sentence refers to a small `cockpit.md` with the current state
of your topics (the "Now" layer in the
[usage guide](usage-guide.md#1-the-cockpit-what-matters-right-now)) –
drop it if you don't keep one.
Keep the block short, because it is loaded into every chat, and keep both
places identical whenever you change the list. Changes reliably apply to
new sessions – start a new chat after editing. The
[usage guide](usage-guide.md#6-making-the-rules-load-every-time) explains
the details.

Ready-made files are in the `templates` folder of the unzipped `remembox`
folder: `instructions-for-claude.md` (this block),
`global-CLAUDE.md` (a fuller version for `~/.claude/CLAUDE.md`, Claude
Code only) and `cockpit.md` (an example cockpit to adapt). Save your
cockpit somewhere permanent and replace `cockpit.md` in the block with its
full path. Clients with local file access (Claude Code, Cowork) then read
it at the start of every session; the web and mobile apps cannot.

## Step 6: Test it 🎉

1. Start a **new** Claude session and say:
   > Remember that my favorite project is X.
   (fill in anything for X, e.g. "my garden blog")
   Claude should confirm that it saved this.
2. End the session and start **another new** session. Ask:
   > What's my favorite project?
3. If Claude answers correctly: done – Claude now has a lasting memory. ✅

The very first time, RememBox may briefly need to pull the language model
(if you skipped Step 2) – that takes a moment. Claude might also offer you
a short get-to-know-you interview. It's worth doing: the more Claude knows
about you, the more useful the memory becomes.

## Step 7 (optional): Add the detailed skill

The downloaded `remembox` folder already includes a skill file
(`skill/SKILL.md`) with the long version of the rules – looking things up
at the start of a session and saving what matters at the end, plus the
details on facts, areas and tags. It supplements the block from Step 5; it
doesn't replace it.

For Claude Code, install it with two lines in the Terminal:

```bash
mkdir -p ~/.claude/skills/remembox-memory
cp ~/remembox/skill/SKILL.md ~/.claude/skills/remembox-memory/SKILL.md
```

(Adjust the path as usual if your folder lives elsewhere.)

The memory works without this step too – Claude then has only the short
block from Step 5 to go on, without the details. (Claude Desktop and Cowork
take the same file as a personal skill upload in the app's skill
settings.)

---

## If something doesn't work (Troubleshooting)

Every one of these messages is normal and usually fixed in a minute or
two.

**"Ollama isn't running" / an error mentioning "connection refused" or
"11434"**
Ollama isn't currently started. Check the menu bar at the top right: if
the llama icon 🦙 is missing, open Ollama from the Applications folder and
try again.

**"Model missing" / an error mentioning "embeddinggemma" or "model not
found"**
The model from Step 2 is still missing (or the download was interrupted).
Open the Terminal and run the command again:
`ollama pull embeddinggemma` – it resumes where it left off.

**macOS blocks the program** – "RememBox" (or "remembox") can't be opened
because it is from an unidentified developer", or similar.
This is macOS's "Gatekeeper" protection – it's naturally suspicious of
programs downloaded from the internet. Two ways to fix it:

- **Terminal command (recommended):** Open the Terminal and type (adjust
  the path if needed):
  ```bash
  xattr -dr com.apple.quarantine ~/remembox
  ```
  Important: this command clears the quarantine flag on the **entire**
  RememBox folder, not just the program itself – that's needed because the
  bundled native library (`libobjectbox.dylib`) would otherwise get
  blocked separately.
- **Without the Terminal:** In Finder, right-click (or ctrl-click) the
  `remembox` file inside the `dist/` folder and choose **Open** – confirm
  **Open** again in the dialog that follows. This only clears that one
  file; if you then hit the same problem with the library, do the same
  right-click on the `.dylib` file in `dist/lib/`, or just use the
  Terminal command above.
- **Alternatively, via System Settings:** **System Settings → Privacy &
  Security**, scroll down, and click **Open Anyway** next to the RememBox
  message.

Then repeat the test from Step 6.

**Claude says it doesn't know a tool for remembering, or "Failed to
connect"**
Usually Claude wasn't restarted after Step 4, or RememBox was updated in
the meantime (see below). Fully quit Claude (Desktop app: `⌘Q`, not just
closing the window; Claude Code: close the terminal window or end the
session) and start it again. Also check the path: does the entry from
Step 4 really point to where the folder lives now? If you moved or
replaced the folder after setup (e.g. because of an update), fully quit
**all** open Claude windows and restart them – otherwise already-running
connections keep holding on to the old version.

**Claude says "project is required" or similar**
This is **not a bug** – it's intentional: RememBox requires every memory
to have a project, so later searches can filter by it precisely. With the
block from Step 5, Claude sets this automatically; without it,
just tell Claude which project the memory belongs to (e.g. "...
project: my garden blog").

**Something else?**
Copy the exact error message and ask Claude about it – or open an issue:
**https://github.com/obx-vivien/remembox/issues**.
No error message is too trivial; that's exactly what the page is for.

---

## Good to know

- **Where are my memories stored?** In the hidden folder `~/.remembox` on
  your Mac – nowhere else. For a backup, it's enough to back up this
  folder (Time Machine, for example, already covers it).
- **Forgetting on request:** Just tell Claude "forget the memory about
  …" – there's a dedicated tool for that.
- **After updating RememBox:** If you downloaded a newer version and
  replaced the `remembox` folder, fully quit **all** open Claude windows
  and restart them – otherwise already-running connections keep holding on
  to the old version (see "Failed to connect" above).
- **For advanced users:** several Claude windows already share the memory
  without any setup. If you want to sync across devices too, see
  [docs/sync.md](https://github.com/obx-vivien/remembox/blob/main/docs/sync.md)
  – the daemon mode described there is for Sync users who also want several
  windows at once.
