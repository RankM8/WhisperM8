# Plugin `whisperm8` und Jarvis-Board

Stand: 14.11.2026 (Kasten nach WM8-99). Plan, Prototyp-Messwerte und Entscheidungen:
`docs/plans/whisperm8-plugin.md`.

## Was es ist

- **Plugin `whisperm8`:** Ein Claude-Code-Plugin mit allen Agent-Skills der
  App (`whisperm8:whisperm8-chats`, `whisperm8:jarvis`,
  `whisperm8:codex-subagent`, `whisperm8:gpt-coworker`,
  `whisperm8:gpt-workflow`, `whisperm8:whisperm8-transcription`,
  `whisperm8:callout`) und der Mod „Jarvis-Board“ samt Voice-Callouts
  (`docs/features/speech-callouts.md`) und Task-Zähler (§ Task-Anzeige). Jede Claude-Session, die die App startet, lädt es, in jedem
  Profil und ohne `claude plugin install`.
- **Jarvis-Board:** Ein Kasten über dem Prompt der Jarvis-Session. Jeder
  Chat, der auf den User wartet, hat darin eine Zeile, alle anderen stehen
  zusammen in einer Sammelzeile. Jarvis pflegt die Liste, die App hält sie,
  die Mod zeigt sie an und weckt Jarvis, wenn ein Board-Chat auf den User
  wartet oder fertig ist.

```
╭─ Jarvis · 3 warten auf dich ─────────────────────────────────────────╮
│ ● Ida  AKQ     Frage: Wie läuft das Aufräumen?                       │
│ ● Nia  DS      Ja zu den Projekten in Linear                         │
│ ● Jon  WM8-81  Drei Handgriffe am Ticket-Board                       │
│ läuft Ole · fertig Vic · ruht Kai, Fin, Mia                          │
╰──────────────────────────────────────────────────────────────────────╯
```

Seit WM8-99 (14.11.2026) gilt für das Aussehen:

- **Rahmen:** rund, seine Farbe ist die Gesamtampel. Rot, sobald ein Chat
  wartet; grün, wenn keiner wartet und einer fertig ist; sonst grau. Der Kopf
  („Jarvis · 3 warten auf dich“) steht in der oberen Rahmenlinie und kostet
  keine Zeile.
- **Wartende Chats** (Ampel `needsYou`) haben je genau eine Zeile: Punkt,
  Rufname, Ticket oder Bereich, Anliegen. Rufname und Ticket kommen aus dem
  Chat-Titel („WM8-81 Jon · Ticket-Board“). Ohne Ticket steht der Bereich da,
  der Teil des Themas vor dem Doppelpunkt („Vic · Neustart: Gesamt-Review“ →
  „Neustart“); endet er auf ein Team-Kürzel, gilt das Kürzel („Produkt AKQ“ →
  „AKQ“). Ein Thema ohne Doppelpunkt ist nur als einzelnes Wort ein Bereich
  („Kai · Umzug“ → „Umzug“), ein Satz nicht; die Spalte bleibt dann leer.
  Ohne „·“ ist der ganze Titel der Name. Die Spalten sind so breit wie ihr
  längster Wert, höchstens 12 und 10 Zeichen (ist der Kasten schmaler als 64
  Spalten, 8 und 7). Was nicht passt, endet auf „…“; umbrochen wird nichts.
- **Alle anderen** stehen in einer einzigen Sammelzeile, nur mit Rufnamen:
  „läuft“ (Ampel `running`), „fertig“ (`done`, Abnahme offen) und „ruht“
  (`parked`). Leere Gruppen fehlen. Passt die Zeile nicht, gibt die Gruppe
  mit den meisten Namen hinten welche ab; der Rest steht als „+n“. Ein ⚑ vor
  einem Namen heißt, dass der Chat selbst gerade auf eine Antwort wartet
  (Status `awaitingInput`), auf dem Board aber nicht als wartend steht. Solche
  Namen stehen in ihrer Gruppe vorn und fallen zuletzt in „+n“.
- **Ohne wartende Chats** steht nur die Sammelzeile im Rahmen, ohne Kopf.
  Ein leeres Board zeichnet nichts.
- **Wenig Platz:** Der Kasten bleibt in jeder Höhe innerhalb der Zeilen, die
  Claude Code ihm gibt (`maxRows`), sonst hinterlässt der Hauptbildschirm
  Reste. Voll braucht er zwei Zeilen Rahmen, je Wartendem eine Zeile und die
  Sammelzeile. Reicht das nicht, weicht zuerst der Rahmen (der Kopf wird dann
  eine eigene Zeile), danach die Sammelzeile (ihre Zahlen stehen dann im
  Kopf), zuletzt von hinten die Wartenden (der Kopf zählt sie: „+1 nicht
  gezeigt“). Wer den User braucht, weicht nie dem Schmuck. Ohne Wartende hat
  die Sammelzeile ab drei Zeilen ihren Rahmen. Ist der Kasten schmaler als 24
  Spalten, hat er nie einen.
- **Unbekannte Ampel:** Ein Eintrag mit einem Ampelwert, den die Mod nicht
  kennt (neuere CLI), steht unter „ruht“ statt zu verschwinden.
- **Als Ticket** gelten nur die bekannten Schlüssel (WM8, DS, DEAL, DEA, AKQ,
  PRB, FBT, LISTM8).

Was von WM8-88 bleibt: Der Kasten zeigt einzeln nur, was den User braucht.
Ziffern zum Springen, Kurz-Kennung, Alter und Bedien-Hinweis gibt es nicht,
auch keinen Takt, der nach der Uhr neu zeichnet. Der Kasten bleibt so niedrig
und ändert sich selten; der Hauptbildschirm zeichnet den Bereich über dem
Prompt bei jeder Änderung neu, hohe Kästen hinterlassen dort Reste. Den
Fortschritt („4/7“) aus `progress` zeigt der Kasten seit WM8-99 nicht mehr,
die Sammelzeile nennt nur Rufnamen. Zwischen WM8-88 und WM8-99 (wenige
Stunden am 14.11.2026) hatte der Kasten keinen Rahmen und zeigte das Anliegen
als umbrochenen Satz in einer zweiten Zeile.

**Für Supervisoren:** Das Anliegen (`needs`) in wenigen Wörtern schreiben. Ist
der Kasten 50 Spalten breit, bleiben dafür etwa 30 Zeichen, bei 72 Spalten
etwa 50.

## Bedienung

| Wer | Wie |
|---|---|
| Jarvis (automatisch) | Laden des Skills `whisperm8:jarvis` schaltet das Board der Session ein (`skill.prompt`-Hook, hängt nicht am Modell). |
| Jarvis (Modell) | Tool `mcp__whisperm8__board` (`set`, `milestone`, `remove`, `clear`, `activate`, `deactivate`, `read`) oder `whisperm8 chats board …`; Lesehilfe `whisperm8 chats show <ref> --recap` |
| User | `/board` klappt den Kasten auf eine Zeile ein und wieder auf („▸ Jarvis · 2 warten auf dich · 2 laufen · 1 fertig · 1 ruht“), `/board zu` / `auf` gezielt, `/board an` / `aus` |
| Einstellung | `/config` → Plugin `whisperm8` → „Jarvis wecken“: `turn` (Standard: Hinweis und Prompt an Jarvis), `toast`, `aus` |

Ampeln: `needsYou` (User muss entscheiden), `done` (Abnahme offen),
`running`, `parked` (bewusst angehalten). Innerhalb einer Gruppe steht der
älteste Eintrag zuerst. Bis WM8-88 gab es Ziffern-Knöpfe zum Öffnen der Tabs;
eine Ziffer im leeren Prompt fängt die Mod nicht mehr ab. Eingeklappt steht
eine Zeile ohne Rahmen mit den Zahlen der Gruppen.

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
- **Anzeige (seit WM8-99):** Aufbau oben unter „Was es ist“. Was im Kasten
  steht, rechnet `layoutBox` rein aus Einträgen, Breite und Höhe aus
  (`waitingLines` für die Spalten, `summaryLine` für die Sammelzeile); der
  `ui.render`-Hook setzt das Ergebnis nur noch in Box und Text um. Den Rahmen
  zieht die Box (`borderStyle="round"`, ein Zeichen Innenabstand), der Inhalt
  ist deshalb vier Spalten schmaler als der Kasten. Jede Zeile ist schon
  vorher auf diese Breite gekürzt, nach Codepoints, damit kein Emoji halbiert
  wird; Steuerzeichen und Zeilenumbrüche aus dem Board fallen vorher weg.
  Breite Zeichen (Emoji, CJK) kürzt zusätzlich das Terminal selbst
  (`wrap="truncate-end"`), der Rahmen bleibt dabei gerade.
- **Kopf in der Rahmenlinie:** Die Box der Mod-Schnittstelle kennt keinen
  Titel im Rahmen. Der Kopf ist deshalb eine eigene Box mit
  `position="absolute"` (`top={0}`, `left={2}`), die als Geschwister NACH der
  gerahmten Box steht und so über deren obere Linie malt, ohne etwas zu
  verschieben. Als Kind der gerahmten Box (mit `top={-1}`) übermalt ihn der
  Rahmen; beides ist an der laufenden CLI ausprobiert (2.1.325, 14.11.2026).
  Ein zu langer Kopf überschriebe die rechte Ecke; der Plan kürzt ihn so, dass
  rechts „─╮“ stehen bleibt. Ändert eine spätere Claude-Code-Version das
  Übermalen, fehlt schlimmstenfalls der Kopf in der Linie; die Zeilen darunter
  hängen nicht daran.
- **Nicht im Kasten:** Die Blockade eines laufenden Chats steht in der
  Notiz-Karte. Keine Statuszeile: Claude Code setzt „⚠“ vor jede
  Plugin-Statuszeile, sie sah nach einer Warnung aus und wiederholte nur den
  Kasten.
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
  Teamnamen der Session**, nicht nach der Session-ID: Jeder Prozessstart legt
  ein neues Team `session-<8 Zeichen einer frischen ID>` an (`teams/<name>/
  config.json`, `leadSessionId`), auch bei `--resume`. Befund 23.10.2026
  (v2.1.309): Chat `ab7a103f…`, Liste in `session-31af24ce`, im Transcript fünf
  Teams aus fünf Starts. Der Hook `TaskCreated`/`TaskCompleted` liefert
  `team_name` in v2.1.309 nicht mit.
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
  Konten — kein Polling. **Ordner eines laufenden Chats** (seit 23.10.2026,
  `AgentChatTaskDirectory.liveDirectory`): Registry-Eintrag der Session
  (`sessions/<pid>.json`, `startedAt`, `cwd`) gegen die Teams des Kontos — das
  zeitlich nächste Team innerhalb von 15 s mit gleichem Ordner des `team-lead`
  (gemessen: Team entsteht 0,9–1,3 s vor `startedAt`). Neu aufgelöst bei jedem
  `TaskCreated`/`TaskCompleted` ohne `team_name` und 2 s nach `SessionStart`
  (neuer Prozess = neue, leere Liste). Nennt ein Hook `team_name`, gilt der.
  Der Ordner wird je Claude-Session-ID in
  `Application Support/WhisperM8/agent-task-lists.json` gemerkt (höchstens 400),
  damit die Liste nach dem Prozessende bleibt. Läuft der Chat nicht und ist
  nichts gemerkt: Vermutung `session-<8>` im Konfig-Ordner des Transcripts. Die
  Hooks kommen nur im reduzierten Satz (`ClaudeHookSettingsBuilder.registryModeEventNames`,
  Claude Code ≥ 2.1.302); kein Status-Signal, der Coordinator reicht sie direkt
  an den Store.
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

**Wie eine geänderte Mod ankommt:** `make skills` genügt, ohne Build und ohne
Neustart der App. Es legt das Plugin als neuen Stand ab und stellt den Symlink
um. Sehen tun es Chats, die danach starten oder fortgesetzt werden; ein
laufender Chat behält seinen Stand, Jarvis' Chat muss also einmal beendet und
fortgesetzt werden. Dauerhaft ist die Änderung erst, wenn auch die App sie
enthält (`make dev` aus einem Stand mit der Änderung): Beim Start legt die App
das Plugin aus ihrem eigenen Paket ab und stellt den Symlink darauf. Eine
ältere App holt so den alten Stand zurück.

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
