# Plugin `whisperm8` und Jarvis-Board

Stand: 08.10.2026. Plan, Prototyp-Messwerte und Entscheidungen:
`docs/plans/whisperm8-plugin.md`.

## Was es ist

- **Plugin `whisperm8`:** Ein Claude-Code-Plugin mit allen Agent-Skills der
  App (`whisperm8:whisperm8-chats`, `whisperm8:jarvis`,
  `whisperm8:codex-subagent`, `whisperm8:gpt-coworker`,
  `whisperm8:gpt-workflow`, `whisperm8:whisperm8-transcription`,
  `whisperm8:callout`) und der Mod „Jarvis-Board“ samt Voice-Callouts
  (`docs/features/speech-callouts.md`). Jede Claude-Session, die die App startet, lädt es, in jedem
  Profil und ohne `claude plugin install`.
- **Jarvis-Board:** Ein Band über dem Prompt der Jarvis-Session. Es zeigt die
  Chats, die Jarvis aktiv betreut, mit Ampel, Anliegen oder nächstem Schritt
  und Alter. Jarvis pflegt die Liste, die App hält sie, die Mod zeigt sie an
  und weckt Jarvis, wenn ein Board-Chat auf den User wartet oder fertig ist.

```
╭──────────────────────────────────────────────────────────────────────────────────╮
│ Jarvis · Board  ● 2 wartet  ● 2 läuft  ● 1 fertig           Ziffer = Tab öffnen │
│ ● 1: Akquise Import     Freigabe: 500 Leads importieren                      12m │
│ ● 2: Outreach Copy-Rev… Entscheidung: Opener-Schluss A oder B                 4m │
│ ● 3: Tab-Switcher Revi… fertig · Ergebnis prüfen                              2m │
│ ● 4: ListM8 Lead-Run    Qualifizierung 40/150                                18m │
╰──────────────────────────────────────────────────────────────────────────────────╯
```

## Bedienung

| Wer | Wie |
|---|---|
| Jarvis (automatisch) | Laden des Skills `whisperm8:jarvis` schaltet das Board der Session ein (`skill.prompt`-Hook, hängt nicht am Modell). |
| Jarvis (Modell) | Tool `mcp__whisperm8__board` (`set`, `milestone`, `remove`, `clear`, `activate`, `deactivate`, `read`) oder `whisperm8 chats board …`; Lesehilfe `whisperm8 chats show <ref> --recap` |
| User | `/board` Details (Panel, öffnet mit Fokus, Escape schließt), `/board an` / `aus`, `/board zu` / `auf` (einklappen) |
| User: Tab öffnen | Im Band ist der Name jeder Zeile ein Knopf (`1:` bis `9:`): die Ziffer im **leeren** Prompt (ohne Enter) öffnet den Tab des Chats (`chats open`, direkt aus der Mod, kein Turn von Jarvis). Im Panel `[ 1 Tab öffnen ]` je Chat, ebenfalls per Ziffer. |

**Kein Klick in der App:** Claude Code meldet Mausklicks nur im
Vollbild-Terminal. App-Sessions laufen im Main-Screen, dort landet ein Klick
beim Terminal der App (Textauswahl). Deshalb trägt der Kopf rechts einen
Bedien-Hinweis statt Knöpfen: Buchstaben-Hotkeys wie früher „z: zu“ greifen
nur nach `ctrl+x tab`, eine Ziffer im leeren Prompt dagegen immer.
| Einstellung | `/config` → Plugin `whisperm8` → „Jarvis wecken“: `turn` (Standard: Hinweis und Prompt an Jarvis), `toast`, `aus` |

Ampeln: `needsYou` (rot, User muss entscheiden), `done` (grün, Abnahme
offen), `running` (gelb), `parked` (grau, bewusst angehalten). Der Rahmen
trägt die Gesamtampel. Reihenfolge: wartet, fertig, läuft, geparkt;
innerhalb einer Ampel steht der älteste Eintrag oben.

## Wie es funktioniert

### Verteilung (S1)

1. `ClaudePluginBootstrap.run()` in `applicationDidFinishLaunching`, vor dem
   ersten PTY-Spawn.
2. `WhisperM8ClaudePlugin.assembleFiles()` liest `Resources/claude-plugin/`
   (Manifest flach als `plugin.json`, weil SwiftPM Punkt-Ordner nicht
   verlässlich kopiert) und die Skill-Ressourcen
   (`CLISkillExporter.SkillDefinition.plugin`). Die Mod-Tests werden nicht
   ausgeliefert.
3. `install()` schreibt nur bei neuem Inhalt nach
   `Application Support/WhisperM8/claude-plugin/versions/<hash>/whisperm8`
   (Staging-Ordner, dann ein `moveItem`) und biegt den Symlink
   `claude-plugin/whisperm8` per `rename(2)` um. Die fünf jüngsten Stände
   bleiben liegen.
4. `AgentCommandBuilder` gibt jedem Claude-Launch (Chat, Resume, Attach,
   Agents-View) `CLAUDE_CODE_PLUGIN_DIRS=<Symlink>` mit; der
   Background-Spawn ebenso.
5. Einmalig (`claudePluginSkillMigrationDone`) wandern die losen Kopien aus
   `~/.claude/skills` nach `~/.claude/skills/.whisperm8-backup/<zeit>/`. Lokal
   geänderte Skills und Symlinks bleiben liegen.

**Warum der Symlink:** Claude Code überwacht den Plugin-Ordner und lädt
JEDE laufende Session neu, sobald sich darin etwas ändert (im Prototyp mit
zwei parallelen Sessions belegt). Ein verlinkter Ordner wird am Ziel
überwacht: Ein Update ändert nur den Link, laufende Sessions behalten ihren
Stand, neue Sessions bekommen den neuen.

### Board in der App (S2)

`whisperm8 chats board` liest direkt von der Platte
(`Application Support/WhisperM8/jarvis-board.json`, Schema `wm8.board/1`).
Ändern geht nur über den Socket an die laufende App, die einziger Schreiber
ist. Jede Änderung ist ein Journal-Ereignis, das `chats since` und
`chats watch` als `"kind": "board"` mitliefern. Ein Board gehört einer
Jarvis-Session (`owner` = deren WhisperM8-Session-ID). Ein Chat darf auf
mehreren Boards stehen (`otherOwners`).

### Mod (S3/S4)

`Resources/claude-plugin/hooks/register.tsx`:

- **An und Aus:** Ohne `WHISPERM8_SESSION_ID` oder ohne aktives Board
  zeichnet die Mod nichts und startet keinen Prozess. Das Tool steht dann
  nur hinter ToolSearch (`isDeferred: true`), bei aktivem Board direkt in
  der Liste.
- **Live:** Ein Kindprozess `whisperm8 chats watch --cursor <c>` für die
  Session. Endet er, setzt die Mod mit Backoff (2 s bis 60 s) und frischem
  Stand neu an; bei `session.end` hört sie auf.
- **Wecken:** Ein Board-Chat geht auf `awaitingInput` oder beendet seinen
  Turn (`working → idle`). Daraufhin kommt ein Hinweis (bewusst ohne Ton), und je nach
  Einstellung ein Prompt `[Board] <Name> (<ref>): …` an Jarvis. Gebündelt
  über 5 s, höchstens ein Prompt je Minute, einmal je Chat und Zustand, bis
  der Chat wieder arbeitet. Geparkte Chats wecken nicht.
- **Anzeige:** Band nach den gemessenen Breiten: ab 90 Spalten mit Ref und
  breiter Altersangabe, darunter knapper. Der Kopf kürzt nach Platz: erst
  wird der Hinweis rechts kürzer, dann fällt „· Board“ weg, dann der
  Hinweis, zuletzt jedes Wort außer „wartet“ (live geprüft bei 50, 58, 72
  und 120 Spalten; feste Stufen ließen ihn bei 72 umbrechen). Keine
  Statuszeile: Claude Code setzt „⚠“ vor jede Plugin-Statuszeile, sie sah
  nach einer Warnung aus und wiederholte nur das Band. `/board` öffnet
  das Panel; dessen Knöpfe legen Jarvis eine Frage in den Prompt. Das
  Umräumen des Aktiv-Workspaces bleibt bei Jarvis, der seine Slot-Regeln
  kennt.

## Notiz-Karte im Grid (Jarvis-Randnotizen, seit 17.10.2026)

Plan und Entscheidungen: `docs/plans/jarvis-randnotizen.md`, klickbarer
Entwurf: `docs/design/randnotiz-karte.html`.

- **Was:** Jeder Chat auf dem Board einer **laufenden** Jarvis-Session bekommt
  im Grid-Workspace eine Karte, die am Kachelkopf hängt (Form: umgedrehte
  `ChromeTabShape`, Grau des Kopfes läuft in die Karte). Inhalt: Arbeitspaket
  (`work`, fett, mit Alter), Eingriff (`needs`, rot), Blockade (`blocker`,
  bernstein), Ziel (`mission`), die drei neuesten Meilensteine (ältere per
  „▸ N ältere") und „Aktualisiert HH:MM · Jarvis". Ohne laufenden Jarvis gibt
  es keine Karten; die App erzeugt nie eigene Notizen.
- **Felder im Board:** `work` löst `next` ab (beide werden gleich geschrieben,
  alte Dateien mit nur `next` lesen sich als `work`), dazu `blocker` und
  `milestones` (`{at, text}`, neueste zuerst, 20 bleiben, `whisperm8 chats board
  milestone`). Inhaltsregeln für Jarvis: Skill `whisperm8:jarvis`, Abschnitt 6.
- **Auf/zu:** Schalter „Notizen auf/zu" in der Workspace-Leiste neben dem
  Kapazitäts-Picker (sichtbar, sobald ein Chat des Workspaces eine Notiz hat),
  dazu ⌥⌘N im Grid. Er setzt den Standard für alle Karten (App-weit,
  `jarvisNotesDefaultOpen`) und löscht die Handklicks dieses Fensters. Der
  Pfeil neben dem Konto-Badge klappt eine einzelne Karte. In der Kachel, in
  der der User arbeitet (Fokus), ist die eigene Karte zu; ein Fokuswechsel
  verwirft den Handklick der verlassenen und der betretenen Kachel. Mehr
  Automatik gibt es bewusst nicht (auch kein Selbst-Aufklappen bei „wartet").
- **Technik:** `JarvisNotesStore` (MainActor) hält die Projektion
  (`JarvisNotesProjection`: nur aktive Boards, nur lebende Owner, bei mehreren
  Boards der neueste Eintrag) und die flüchtigen Handklicks je Fenster, beides
  über Publisher je Session wie `statusPublisher(for:)` — die Kachelköpfe sind
  Funktionen im Body von `AgentChatsView`, eine Observable-Property dort würde
  das ganze Grid neu auswerten. Gefüttert beim Start
  (`setupRuntimeServicesIfNeeded`) und nach jeder erfolgreichen Board-Mutation
  im Socket-Handler; die App ist einziger Schreiber, ein Datei-Beobachter ist
  nicht nötig. Die Karte liegt als Overlay über dem Terminal (kein PTY-Resize),
  ist so hoch wie ihr Inhalt (max. 60 % der Kachel, darüber scrollt sie) und
  setzt die Deckkraft des Kopf-Graus fort. Ein Klick in die Karte fokussiert
  die Kachel nicht (`hoveredNoteCardID`), sonst klappte sie sofort zu.
- **Kill-Switch:** `defaults write com.whisperm8.app jarvisNotesEnabled -bool NO`
  (keine Karten, kein Schalter; das Board bleibt unberührt).

## Entwickeln und prüfen

```bash
make plugin-test   # claude plugin validate + claude plugin test auf die Mod
make skills        # Plugin aus dem Repo ablegen (ohne App-Build); neue Sessions sehen es
swift test --filter "WhisperM8ClaudePluginTests|JarvisBoard|ChatsBoard|JarvisNotes|JarvisNoteExpansion|HangingNoteShape|ClaudeRecap"
make snapshots ONLY=jarvis-notiz   # Karte hell + dunkel ansehen
```

## Kill-Switches

```bash
defaults write com.whisperm8.app claudePluginEnabled -bool NO   # keine Variable, kein Ablegen
defaults write com.whisperm8.app jarvisBoardEnabled -bool NO    # Board-Befehle aus
```

Ist das Plugin aus, lassen sich die Skills wieder über die Einstellungen
nach `~/.claude/skills` installieren. Die Sicherung der Migration liegt unter
`~/.claude/skills/.whisperm8-backup/`.

## Grenzen

- Sessions außerhalb der App sehen das Plugin nicht. Optional kann der
  Plugin-Ordner später als lokaler Marketplace dienen.
- Ob Background-Agents (`claude --bg`, vom Supervisor-Daemon gehostet) die
  Umgebung erben, ist nicht belegt.
- App-Sessions laufen im Main-Screen (`tui: default`): Das Panel erscheint
  dort immer inline über dem Prompt, nie als Seitenleiste.
