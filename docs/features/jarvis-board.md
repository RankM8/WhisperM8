# Plugin `whisperm8` und Jarvis-Board

Stand: 08.10.2026. Plan, Prototyp-Messwerte und Entscheidungen:
`docs/plans/whisperm8-plugin.md`.

## Was es ist

- **Plugin `whisperm8`:** Ein Claude-Code-Plugin mit allen Agent-Skills der
  App (`whisperm8:whisperm8-chats`, `whisperm8:jarvis`,
  `whisperm8:codex-subagent`, `whisperm8:gpt-coworker`,
  `whisperm8:gpt-workflow`, `whisperm8:whisperm8-transcription`,
  `whisperm8:callout`) und der Mod „Jarvis-Board“ samt Voice-Callouts
  (`docs/features/speech-callouts.md`) und Task-Zähler (§ Task-Anzeige). Jede Claude-Session, die die App startet, lädt es, in jedem
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
| User | `/board` klappt das Band ein und aus, `/board zu` / `auf` gezielt, `/board an` / `aus` |
| User: Tab öffnen | Im Band ist der Name jeder Zeile ein Knopf (`1:` bis `9:`): die Ziffer im **leeren** Prompt (ohne Enter) öffnet den Tab des Chats (`chats open`, direkt aus der Mod, kein Turn von Jarvis). |

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
  nach einer Warnung aus und wiederholte nur das Band.
- **Kein Detail-Panel mehr (seit 23.10.2026):** Früher hat `/board` ein Pane
  mit Ziel, Meilensteinen und Knöpfen geöffnet. In App-Sessions zeigt Claude so
  ein Pane aber nicht daneben, sondern als zweiten Kasten über dem Band. Alle
  Chats standen dann doppelt da, der Kasten war abgeschnitten und blieb teils im
  Verlauf hängen. Zwei der Knöpfe ließen sich ohne Maus gar nicht bedienen. Ziel,
  Arbeitspaket und Meilensteine stehen in der Notiz-Karte am Kachelkopf. Wer den
  Stand eines Chats wissen will, fragt Jarvis.

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

## Task-Anzeige (seit 21.10.2026)

Im Terminal bleibt Claude Codes eigene Task-Liste (ctrl+t) die einzige Liste. Sie
kürzt („… +8 completed“, lange Titel abgeschnitten) und kennt keine Links; die
volle Liste mit Links zeigt die Notiz-Karte der App. Die Mod ergänzt im Chat nur
einen Zähler und erklärt dem Modell die Links.

- **Wahrheit:** Claudes Dateien `<config-dir>/tasks/<liste>/<id>.json`
  (`id`, `subject`, `description`, `activeForm`, `status`, `owner`,
  `blockedBy`, `metadata`). Nur gelesen. **Der Ordner heißt nach dem
  Teamnamen der Session**, nicht verlässlich nach der Session-ID: mit
  `--session-id` gestartet war er im Test `session-412eed50` statt
  `session-a96985f9`. Claude nennt ihn nur im Hook `TaskCreated`/
  `TaskCompleted` (`team_name`) bzw. im Ergebnis eines `TaskCreate`.
- **Links:** `metadata.links` (`[{label, url}]`, `{label: url}` oder URLs) und
  http(s)-/file-URLs aus Titel und Beschreibung, höchstens sechs. Die Mod
  ergänzt die Beschreibung von `TaskCreate`/`TaskUpdate` (`tool.describe`), damit
  das Modell Links an die Task hängt statt sie in jeder Antwort zu wiederholen.

### Im Chat: Mod-Teil `hooks/tasks.tsx`

Eigene Datei, von `register.tsx` nur eingebunden (`registerTasks`, `startTasks` im
einzigen `session.start`). Die Engine folgt `on` und `$` über einen Import nur in
**Funktions-Deklarationen** (`export function`), nicht in Pfeil-Konstanten; zwei
`session.start` ohne Matcher lehnt sie ab.

- **Zähler:** „Tasks 1 aktiv · 4 offen“ am Ende der Hinweiszeile unter dem
  Prompt (`PromptHint.tail`, nicht `$.ui.status` — davor setzt Claude „⚠“).
- **Links:** `tool.describe` von `TaskCreate`/`TaskUpdate` erklärt `metadata.links`.
- **Ordner:** `CLAUDE_CODE_TASK_LIST_ID`, sonst der beim ersten `TaskCreate`
  gefundene (`$.state.taskDir`, je Session-ID in `$.store.taskDirs` für
  `--resume`), sonst die Vermutung `session-<8>`. Gelesen nach jedem
  `TaskCreate`/`TaskUpdate` und alle 5 s (Teammates anderer Prozesse); nur
  geänderte Dateien (mtime/Größe).
- **Abschalten:** `userConfig` `taskzaehler` (dann liest die Mod gar nicht).
- **Keine eigene Liste mehr (22.10.2026):** Bis dahin hat die Mod die ganze
  Liste selbst gezeigt (`/t` mit Aus · Normal · Alle, im Vollbild als Pane, sonst
  als Band über dem Prompt). In App-Sessions zeichnet Claude den Bereich über dem
  Prompt bei jeder Änderung neu. Bei einer hohen Liste blieben dabei Rahmen und
  doppelte Zeilen im Verlauf stehen. Außerdem ging das Pane auch in App-Sessions
  auf, weil sich die Mod „zuletzt Vollbild“ für alle Sessions gemerkt hat.
  Claudes eigene Liste bleibt klein und hat das Problem nicht. Wer die Liste
  zurückholen will, muss das zuerst lösen. Die alten Store-Schlüssel `taskMode`
  und `taskFullscreen` liest die Mod nicht mehr.

### In der App: Tasks in der Notiz-Karte

- **Was:** Jeder Claude-Chat mit laufenden oder offenen Tasks bekommt im Grid die
  Notiz-Karte am Kachelkopf, auch ohne Jarvis. Mit Jarvis-Notiz stehen die Tasks
  als Abschnitt „TASKS“ darunter. Erledigte hinter „▸ N erledigt“. Links sind
  klickbar (Browser bzw. bei file:// die zugehörige App). Auf/zu, Pfeil und Fokus
  wie bei den Jarvis-Notizen; der Schalter „Notizen auf/zu“ zählt Chats mit Tasks mit.
- **Technik:** `AgentChatTasksStore` (MainActor, Publisher je Session wie
  `JarvisNotesStore`) liest auf einer Utility-Queue (`AgentChatTaskDirectory`,
  Parser `AgentChatTaskParser`) und hört per FSEvents auf die `tasks`-Ordner der
  Konten — kein Polling. Den Ordner lernt er aus den Hooks `TaskCreated`/
  `TaskCompleted` (`ClaudeHookSettingsBuilder.registryModeEventNames`, nur im
  reduzierten Satz, also Claude Code ≥ 2.1.302; kein Status-Signal, der
  Coordinator reicht sie direkt an den Store) und merkt ihn je Claude-Session-ID
  in `Application Support/WhisperM8/agent-task-lists.json` (höchstens 400).
  Ohne Hook: Vermutung `session-<8>` im Konfig-Ordner des Transcripts.
- **Einstellung:** Labs › Jarvis & Callouts › „Show chat tasks in notes“;
  `defaults write com.whisperm8.app agentChatTasksInNotesEnabled -bool NO`.

## Entwickeln und prüfen

```bash
make plugin-test   # claude plugin validate + claude plugin test auf die Mod
make skills        # Plugin aus dem Repo ablegen (ohne App-Build); neue Sessions sehen es
swift test --filter "WhisperM8ClaudePluginTests|JarvisBoard|ChatsBoard|JarvisNotes|JarvisNoteExpansion|HangingNoteShape|ClaudeRecap|AgentChatTasks"
make snapshots ONLY=jarvis-notiz   # Karte hell + dunkel ansehen
make snapshots ONLY=notiz-tasks    # Karte mit Tasks (allein und unter einer Notiz)
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
- App-Sessions laufen im Main-Screen (`tui: default`): Ein Pane erscheint
  dort immer inline über dem Prompt, nie als Seitenleiste. Deshalb hat die Mod
  keine Panes mehr (Board und Tasks), nur Band und Hinweiszeile.

## Betriebswissen aus CLAUDE.md

*Am 19.10.2026 wörtlich aus der Projekt-CLAUDE.md übernommen (LR-DOK-008); dort stehen nur noch die Arbeitsregeln. Beim nächsten Überarbeiten dieser Seite in den Fließtext einarbeiten.*

- **Claude-Code-Plugin `whisperm8` + Jarvis-Board** (seit 08.10.2026, Doku `docs/features/jarvis-board.md`, Plan `docs/plans/whisperm8-plugin.md`): Alle Agent-Skills (inkl. `jarvis`, jetzt im Repo als `Resources/whisperm8-jarvis-skill.md`) kommen als Plugin `whisperm8` (`/whisperm8:<skill>`), nicht mehr lose aus `~/.claude/skills`. `WhisperM8ClaudePlugin` setzt es beim App-Start aus `Resources/claude-plugin/` (Manifest, Mod, Typvertrag) plus den Skill-Ressourcen zusammen und legt es unter `Application Support/WhisperM8/claude-plugin/versions/<hash>/whisperm8` ab; der Symlink `claude-plugin/whisperm8` wird per `rename(2)` umgebogen. **Grund (Prototyp gemessen):** Claude Code lädt jede laufende Session neu, sobald sich ihr Plugin-Ordner ändert — Kopieren in den laufenden Ordner würde alle Chats mitten im Turn umladen; ein verlinkter Ordner wird am Ziel überwacht, laufende Sessions behalten ihren Stand. Jeder Claude-Launch bekommt `CLAUDE_CODE_PLUGIN_DIRS` (`AgentCommandBuilder.claudePluginEnvironmentResolver`, ein User-Wert bleibt vorne erhalten). Beim ersten Start wandern die losen Skill-Kopien nach `~/.claude/skills/.whisperm8-backup/<zeit>/` (lokal geänderte und Symlinks bleiben). `make skills` legt im Plugin-Modus denselben Aufbau aus dem Repo ab, `make plugin-test` prüft die Mod (`claude plugin validate` + `test`). Das **Jarvis-Board** (`whisperm8 chats board …`, App einziger Schreiber, `jarvis-board.json`, Ereignisse `kind: "board"` in `since`/`watch`) zeigt die Mod `hooks/register.tsx` als Band über dem Prompt (nur in der Session, deren Board aktiv ist; der Skill `whisperm8:jarvis` schaltet es per `skill.prompt`-Hook ein), weckt Jarvis über `chats watch` (gebündelt, höchstens 1 Prompt/min, einmal je Chat+Zustand) und bietet das Tool `mcp__whisperm8__board`. App-Sessions laufen im Main-Screen (`tui: default`), ein Pane erscheint dort immer inline. Kill-Switches: `defaults write com.whisperm8.app claudePluginEnabled -bool NO` (keine Variable, kein Ablegen), `jarvisBoardEnabled -bool NO` (Board-Befehle).
- **Jarvis-Randnotizen** (seit 17.10.2026, Doku `docs/features/jarvis-board.md` § Notiz-Karte, Plan `docs/plans/jarvis-randnotizen.md`): Im Grid hängt an jedem Chat auf dem Board einer **laufenden** Jarvis-Session eine Karte am Kachelkopf (umgedrehte `ChromeTabShape`, Overlay über dem Terminal, kein PTY-Resize): Arbeitspaket (`work`), Eingriff (`needs`), Blockade (`blocker`), Ziel (`mission`), drei Meilensteine. Board-Eintrag additiv erweitert: `work` löst `next` ab (**beide werden gleich geschrieben** — Vertrag mit der Mod: Felder nur ergänzen), `milestones` über `whisperm8 chats board milestone`. Jarvis schreibt nur bei echten Änderungen, nie Einzelschritte; Lesehilfe `whisperm8 chats show <ref> --recap` (Claudes eigene `away_summary`-Einträge, Rückwärtssuche nach dem Merkmal — ein festes Tail-Fenster verfehlte sie, gemessen 1,1 MB vor dem Ende einer 172-MB-Datei). Schalter „Notizen auf/zu" in der Workspace-Leiste bzw. ⌥⌘N (Standard App-weit), Pfeil am Kopf klappt einzeln, Fokus klappt die eigene Karte zu, sonst keine Automatik. `JarvisNotesStore` liefert Notizen und Handklicks per Publisher je Session (kein `@Observable` im Grid-Body). Kill-Switch: `defaults write com.whisperm8.app jarvisNotesEnabled -bool NO`.
