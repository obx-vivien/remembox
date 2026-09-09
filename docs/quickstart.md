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
> [README](https://github.com/obx-vivien/remembox#quick-start-macos),
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

## Step 5: Test it 🎉

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

## Step 6 (optional): Make remembering a habit for Claude

The downloaded `remembox` folder already includes a skill file
(`skill/SKILL.md`) that teaches Claude to use the memory on its own –
looking things up at the start of every session and saving what matters at
the end, without you having to ask.

For Claude Code, install it with two lines in the Terminal:

```bash
mkdir -p ~/.claude/skills/remembox-memory
cp ~/remembox/skill/SKILL.md ~/.claude/skills/remembox-memory/SKILL.md
```

(Adjust the path as usual if your folder lives elsewhere.)

The memory works fine without this step too – Claude will just use it less
on its own.

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

Then repeat the test from Step 5.

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
skill file from Step 6, Claude sets this automatically; without the
skill, just tell Claude which project the memory belongs to (e.g. "...
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
