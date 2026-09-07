> English version: [docs/quickstart.md](quickstart.md)

# RememBox in 15 Minuten: Claude ein dauerhaftes Gedächtnis geben

Diese Anleitung ist für alle – man muss **nichts programmieren können**.
Am Ende kann sich Claude Dinge über Sitzungen hinweg merken: deine Projekte,
deine Vorlieben, was du beschlossen hast.

Alles läuft **lokal auf deinem Mac**. Deine Erinnerungen verlassen deinen
Rechner nicht.

> **Was du brauchst:** einen Mac mit Apple Silicon (M1/M2/M3/…), etwa
> 15 Minuten und ca. 1 GB freien Speicherplatz. Das fertige ZIP-Paket ist
> für Apple Silicon gebaut und getestet. Auf einem Intel-Mac oder unter
> Linux läuft RememBox nur, wenn du es selbst aus dem Quellcode baust
> (siehe [README](https://github.com/obx-vivien/remembox#quick-start-macos),
> Abschnitt „build from source") – das ist ungetestetes Terrain, diese
> Schritt-für-Schritt-Anleitung setzt das fertige ZIP voraus.

---

## Schritt 1: Ollama installieren

Ollama ist ein kleines Gratis-Programm, das RememBox im Hintergrund nutzt,
um deine Erinnerungen „verstehbar" zu machen (es verwandelt Text in etwas,
worin man nach Bedeutung suchen kann – nicht nur nach Stichwörtern).

1. Öffne im Browser: **https://ollama.com/download**
2. Klicke auf **Download for macOS** und öffne die heruntergeladene Datei.
3. Ziehe **Ollama** in den Ordner **Programme**, so wie bei jeder App.
4. Starte Ollama einmal (Doppelklick im Programme-Ordner). Oben in der
   Menüleiste erscheint ein kleines Lama-Symbol 🦙 – das heißt: Ollama läuft.

Ollama startet ab jetzt automatisch mit deinem Mac. Du musst nie wieder
daran denken.

## Schritt 2: Das Sprachmodell laden

Jetzt braucht Ollama noch das kleine Modell, mit dem RememBox arbeitet.
Dafür benutzen wir einmal kurz das **Terminal** – keine Sorge, das ist nur
ein Fenster, in das man einen Befehl eintippt.

**So öffnest du das Terminal:**
Drücke `⌘ + Leertaste` (das öffnet die Spotlight-Suche), tippe `Terminal`
und drücke `Enter`. Es öffnet sich ein schlichtes Fenster mit blinkendem
Cursor.

Tippe (oder kopiere) dort diese Zeile hinein und drücke `Enter`:

```bash
ollama pull embeddinggemma
```

Jetzt lädt Ollama das Modell herunter (ca. 600 MB, dauert je nach Internet
ein paar Minuten). Wenn wieder der blinkende Cursor erscheint und in der
letzten Zeile `success` steht, ist alles fertig.

(Falls du diesen Schritt vergisst: RememBox versucht, das fehlende Modell
beim ersten Start selbst nachzuladen – das klappt aber nur, wenn Ollama
läuft, und dauert dann beim ersten Gebrauch entsprechend länger.)

## Schritt 3: RememBox herunterladen

1. Lade die neueste Version hier herunter:
   **https://github.com/obx-vivien/remembox/releases/latest**
   Wähle die ZIP-Datei für macOS (Apple Silicon), z. B.
   `remembox-0.2.0-macos-arm64.zip` – die genaue Versionsnummer im Namen
   ändert sich mit jedem Release.
2. Doppelklicke die ZIP-Datei – es entsteht ein Ordner `remembox`.
3. Lege diesen Ordner an einen **festen Ort**, an dem er dauerhaft bleiben
   kann – z. B. direkt in deinen Benutzerordner. Wichtig: **nicht** im
   Downloads-Ordner liegen lassen (der wird gern mal aufgeräumt, und dann
   findet Claude sein Gedächtnis nicht mehr).

Merke dir den Ort. Im Rest der Anleitung nehmen wir als Beispiel an, der
Ordner liegt direkt in deinem Benutzerordner, also unter `~/remembox`
(die Tilde `~` ist die Kurzform für deinen Benutzerordner).

## Schritt 4: RememBox mit Claude verbinden

Wir registrieren RememBox gleich im Modus „gated": Im Standardmodus
verweigert ein **zweites** Claude-Fenster den Start von RememBox (nur ein
Prozess darf den Speicher gleichzeitig halten) – im gated-Modus können
beliebig viele Fenster ihn sich gefahrlos teilen.

**Wenn du Claude Code benutzt** (Claude im Terminal):

Tippe im Terminal diese Zeile und drücke `Enter` – ersetze den Pfad, falls
dein Ordner woanders liegt:

```bash
claude mcp add remembox --scope user -e OBX_MEMORY_STORE_MODE=gated -e OBX_LOG_LEVEL=error -- ~/remembox/dist/remembox
```

Das war's. Die Meldung sollte bestätigen, dass `remembox` hinzugefügt wurde.

`OBX_LOG_LEVEL=error` gehört zwingend dazu, nicht optional: ohne diese
Einstellung können im gated-Modus interne Protokollzeilen der ObjectBox-
Bibliothek den Antwortkanal stören, und Claude wirkt dann, als würde es
hängen – dabei ist der Eintrag ganz normal gespeichert.

**Wenn du die Claude Desktop App benutzt:**

Öffne in der App **Einstellungen → Entwickler → Konfiguration bearbeiten**
(je nach App-Version auch unter Erweiterungen → Erweiterte Einstellungen
zu finden). Es öffnet sich eine Datei namens `claude_desktop_config.json`.
Trage dort Folgendes ein:

```json
{
  "mcpServers": {
    "remembox": {
      "command": "/pfad/zu/remembox/dist/remembox",
      "env": {
        "OBX_MEMORY_STORE_MODE": "gated",
        "OBX_LOG_LEVEL": "error"
      }
    }
  }
}
```

Ersetze `/pfad/zu/remembox` durch den **vollständigen** Pfad zu dem Ordner
aus Schritt 3 (die JSON-Konfiguration braucht den vollen Pfad, nicht die
Kurzform mit `~`). Falls du dir unsicher bist, wie der volle Pfad lautet:
im Terminal in den Ordner wechseln und `pwd` eintippen – das zeigt den
vollständigen Pfad an.

Falls in der Datei schon andere Einträge unter `"mcpServers"` stehen: nur
den `"remembox"`-Block innerhalb der bestehenden geschweiften Klammern
ergänzen (mit Komma getrennt) – nicht die ganze Datei ersetzen, sonst
gehen die anderen Einträge verloren.

Speichern, dann Claude Desktop **komplett beenden und neu starten**
(`⌘Q`, nicht nur das Fenster schließen).

## Schritt 5: Funktionstest 🎉

1. Starte eine **neue** Claude-Sitzung und schreibe:
   > Merk dir: Mein Lieblingsprojekt ist X.
   (setze für X irgendetwas ein, z. B. „mein Gartenblog")
   Claude sollte bestätigen, dass es das gespeichert hat.
2. Beende die Sitzung und starte eine **weitere neue** Sitzung. Frage:
   > Was ist mein Lieblingsprojekt?
3. Wenn Claude korrekt antwortet: Geschafft – Claude hat jetzt ein
   dauerhaftes Gedächtnis. ✅

Beim allerersten Mal kann RememBox noch kurz das Sprachmodell nachladen
(falls Schritt 2 übersprungen wurde) – das dauert einen Moment. Claude
bietet dir vielleicht auch ein kurzes Kennenlern-Interview an. Das lohnt
sich: je mehr Claude über dich weiß, desto nützlicher wird das Gedächtnis.

## Schritt 6 (optional): Claude das Erinnern zur Gewohnheit machen

Im heruntergeladenen `remembox`-Ordner liegt bereits eine Skill-Datei
(`skill/SKILL.md`), die Claude beibringt, das Gedächtnis von sich aus zu
nutzen – am Anfang jeder Sitzung nachzuschlagen und am Ende Wichtiges zu
speichern, ohne dass du extra danach fragen musst.

Für Claude Code installierst du sie mit zwei Zeilen im Terminal:

```bash
mkdir -p ~/.claude/skills/remembox-memory
cp ~/remembox/skill/SKILL.md ~/.claude/skills/remembox-memory/SKILL.md
```

(Pfad wie immer anpassen, falls der Ordner woanders liegt.)

Auch ohne diesen Schritt funktioniert das Gedächtnis – Claude nutzt es dann
nur weniger von allein.

---

## Wenn etwas nicht klappt (Troubleshooting)

Jede dieser Meldungen ist normal und in der Regel in ein bis zwei Minuten
behoben.

**„Ollama läuft nicht" / Fehler mit „connection refused" oder „11434"**
Ollama ist gerade nicht gestartet. Schau in die Menüleiste oben rechts:
Fehlt das Lama-Symbol 🦙, öffne Ollama aus dem Programme-Ordner und
versuche es noch einmal.

**„Modell fehlt" / Fehler mit „embeddinggemma" oder „model not found"**
Das Modell aus Schritt 2 fehlt noch (oder der Download wurde unterbrochen).
Öffne das Terminal und führe den Befehl erneut aus:
`ollama pull embeddinggemma` – er macht dort weiter, wo er aufgehört hat.

**macOS blockiert das Programm** – „RememBox" (oder „remembox") kann
nicht geöffnet werden, da es von einem nicht verifizierten Entwickler
stammt", oder Ähnliches.
Das ist die macOS-Schutzfunktion „Gatekeeper" – sie ist bei aus dem
Internet geladenen Programmen erst einmal misstrauisch. Zwei Wege, das
zu lösen:

- **Terminal-Befehl (empfohlen):** Öffne das Terminal und tippe (Pfad ggf.
  anpassen):
  ```bash
  xattr -dr com.apple.quarantine ~/remembox
  ```
  Wichtig: Der Befehl gibt den **kompletten** RememBox-Ordner frei, nicht
  nur das Programm selbst – das ist nötig, weil auch die mitgelieferte
  Programmbibliothek (`libobjectbox.dylib`) sonst separat blockiert
  würde.
- **Ohne Terminal:** Im Finder mit der rechten Maustaste (oder
  ctrl-Klick) auf die Datei `remembox` im Ordner `dist/` klicken und
  **Öffnen** wählen – im folgenden Dialog noch einmal **Öffnen**
  bestätigen. Das gibt nur diese eine Datei frei; bei Problemen mit der
  Bibliothek zusätzlich denselben Rechtsklick-Weg auf die `.dylib`-Datei
  in `dist/lib/` anwenden, oder direkt den Terminal-Befehl oben nutzen.
- **Alternativ über die Systemeinstellungen:** **Systemeinstellungen →
  Datenschutz & Sicherheit**, dort nach unten scrollen und bei der
  RememBox-Meldung auf **Dennoch erlauben** klicken.

Danach den Funktionstest aus Schritt 5 wiederholen.

**Claude sagt, es kenne kein Werkzeug zum Merken, oder „Failed to
connect"**
Meist wurde Claude nach Schritt 4 nicht neu gestartet, oder RememBox wurde
zwischenzeitlich aktualisiert (siehe unten). Beende Claude **komplett**
(Desktop-App: `⌘Q`, nicht nur das Fenster schließen; Claude Code: das
Terminalfenster schließen oder die Sitzung beenden) und starte es neu.
Prüfe außerdem den Pfad: Zeigt der Eintrag aus Schritt 4 wirklich genau
dorthin, wo der Ordner jetzt liegt? Wenn du den Ordner nach der
Einrichtung verschoben oder ersetzt hast (z. B. durch ein Update),
beende **alle** offenen Claude-Fenster komplett und starte sie neu –
bereits laufende Verbindungen halten sonst weiter die alte Version fest.

**Claude meldet „project is required" oder Ähnliches**
Das ist **kein Fehler**, sondern Absicht: RememBox verlangt zu jeder
Erinnerung ein Projekt, damit spätere Suchen gezielt danach filtern
können. Mit der Skill-Datei aus Schritt 6 setzt Claude das automatisch;
ohne Skill sag Claude einfach dazu, zu welchem Projekt die Erinnerung
gehört (z. B. „... Projekt: mein Gartenblog").

**Etwas anderes?**
Kopiere die genaue Fehlermeldung und frag Claude selbst – oder eröffne ein
Issue: **https://github.com/obx-vivien/remembox/issues**.
Keine Fehlermeldung ist zu banal; genau dafür ist die Seite da.

---

## Gut zu wissen

- **Wo liegen meine Erinnerungen?** Im versteckten Ordner `~/.remembox`
  auf deinem Mac – nirgendwo sonst. Für ein Backup genügt es, diesen
  Ordner zu sichern (z. B. läuft Time Machine ohnehin mit).
- **Vergessen auf Wunsch:** Sag Claude einfach „Vergiss die Erinnerung
  über …" – dafür gibt es ein eigenes Werkzeug.
- **Nach einem Update von RememBox:** Wenn du eine neuere Version
  heruntergeladen und den `remembox`-Ordner ersetzt hast, beende
  **alle** offenen Claude-Fenster komplett und starte sie neu – bereits
  laufende Verbindungen halten sonst weiter die alte Version fest (siehe
  auch „Failed to connect" oben).
- **Für Fortgeschrittene:** Wer regelmäßig mehrere Claude-Fenster parallel
  offen hat oder RememBox auf mehreren Geräten teilen will, findet im
  [README](https://github.com/obx-vivien/remembox#modes) die Abschnitte
  „Modes" (u. a. den Daemon-Modus) und „Sync across devices" –
  empfohlen für Fortgeschrittene, aber für den Einstieg nicht nötig.
