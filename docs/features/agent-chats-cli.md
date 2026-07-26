---
status: aktiv
stand: 2026-07-19
feature: whisperm8 chats (Agent-Chats-CLI / Jarvis)
---

# Agent-Chats-CLI (`whisperm8 chats`)

Jeder Claude-Code-Chat kann über die `whisperm8 chats`-CLI alle anderen
WhisperM8-Agent-Sessions sehen und verwalten — das „Jarvis"-Supervisor-Feature,
umgesetzt als CLI + Skill statt als UI. Plan-Dokumentation (Konzept, Mockups):
`docs/plans/whisperm8-chats-cli/`.

## Zwei Pfade

- **Lese-Pfad, app-unabhängig:** Die CLI ist das App-Binary (argv0-Multiplex in
  `CLIEntryPoint`). Sie liest `AgentSessions.json` read-only
  (`ChatsWorkspaceReader` → `AgentWorkspaceRepository.load`, kein Store, keine
  Schreib-Nebenwirkung) und leitet den Runtime-Status one-shot aus den
  Transcripts ab (`ChatsStatusProbe` mit denselben puren Bausteinen wie der
  `AgentSessionRuntimeWatcher`: `AgentTranscriptLocator` → stat → Tail →
  `AgentTranscriptParser` → `AgentTranscriptStatusDecider`). Funktioniert auch
  bei geschlossener App (`live: false`, Status geschätzt).
- **Schreib-/Live-Pfad, nur mit App:** Mutationen und Live-Status laufen über
  einen BSD-Unix-Domain-Socket (`AgentControlServer`, gestartet in
  `applicationDidFinishLaunching`). Die App bleibt Single Writer für den
  Workspace — die CLI schreibt nie selbst an `AgentSessions.json`.

## Befehle

| Befehl | Klasse | Pfad |
|---|---|---|
| `list`, `overview`, `show`, `tail`, `wait`, `audit`, `archived` | Lesen | Disk (+ optionaler Live-Merge) |
| `send`, `interrupt`, `open`, `close`, `reopen`, `pin`/`unpin`, `move`, `window list`, `resume`, `new`, `rename`, `group`, `archive`, `unarchive`, `workspace …` | Handeln | Socket → App |

`overview` = `list --sort attention --format board`. Alle Befehle mit `--json`
(schemaVersion 1). Referenzen: `projekt/titel`, UUID-Präfix ≥ 8, `@self`.
Exit-Codes: 0 ok, 1 usage, 3 nicht gefunden/mehrdeutig, 4 Guard-Konflikt, 5 App
unerreichbar, 124 wait-Timeout, 130 unterbrochen.

## Control-Socket

- **Sicherheit:** Ordner `control/` 0700, Socket 0600, `getpeereid`-Prüfung
  (Peer-EUID == App-EUID), `flock` gegen Doppelstart, sichere Stale-Socket-
  Reklamation (nur eigener toter Socket), `sun_path`-104-Byte-Prüfung mit
  Fallback nach `/private/tmp/whisperm8-<uid>/`. Discovery-Datei
  `control/socket-path`.
- **Protokoll:** NDJSON, ein Request/eine Response pro Verbindung, 1-MiB-Limit,
  `protocolVersion`-Handshake. Typen in `ChatsControlProtocol` (geteilt CLI ↔
  App), Codec `ChatsControlCodec`.
- **Identität:** Die App injiziert beim PTY-Spawn (`AgentTerminalController.start`)
  `WHISPERM8_SESSION_ID` + ein Zufalls-`WHISPERM8_SESSION_TOKEN`
  (`AgentSessionTokenRegistry`). Das Token beweist dem Server, dass der Aufruf
  aus dieser PTY stammt (Selbst-Send-Schutz, „(du)"-Markierung, Audit). Ehrlich:
  Rechenschaft + Versehens-Schutz, keine Boundary gegen einen absichtlich
  bösartigen Prozess desselben Users.
- **Kill-Switch:** `defaults write com.whisperm8.app agentControlServerEnabled -bool NO`.

## Send-Pipeline (TOCTOU-frei)

`session.send` prüft alle Guards und pastet in EINEM synchronen
`MainActor.run`-Block (kein `await` zwischen Status-Check und Paste):
① existiert + nicht archiviert → ② Ziel ≠ Actor (Selbst-Send, nie überstimmbar)
→ ③ laufende PTY → ④ Status ∈ `--if-status` (Default `awaitingInput,idle`;
`--force` überstimmt) → ⑤ Prompt nicht leer. Danach Bracketed Paste
(`ESC[200~ … ESC[201~`, Pflicht gegen Newline-Auto-Submit) + CR nach 80 ms.
Idempotenz-Cache (requestID, 60 s) verhindert Doppel-Paste bei Retry. Jeder Send
bekommt die Marker-Zeile `[via whisperm8 chats · von <actor> · HH:MM]`
vorangestellt (Ein-Hop-Regel im Skill).

## close (Tab-Management)

`chats close <ref> [<ref>…]` schließt AUSSCHLIESSLICH offene UI-Tabs — die
bewusst schwache Schwester von `archive`. Contract:

- **Nur UI:** `AgentWindowStore.closeTabInHostingWindow` entfernt den Tab aus
  dem Fenster, das ihn hält (eine Session lebt in genau einem Fenster, daher
  keine `--window`-Optionen). Session-Status, PTY-Prozess, Pin, Grid-Slot-
  Mitgliedschaft und Transcript bleiben unangetastet; erneutes Öffnen attached
  an denselben Terminal-Controller inkl. Scrollback.
- **Ohne `--stop` kein Guard:** auch working/awaitingInput-Ziele dürfen
  geschlossen werden — es geht nur die Ansicht zu. Die Response meldet
  `ptyRunning`/`runtimeStatus`/`isPinned` zur Information.
- **`--stop`: Tab zu + Agent beenden.** Die einzige Stufe zwischen „nur
  Ansicht" und `archive`. Der Server terminiert das PTY über
  `AgentTerminalRegistry.terminate` (graceful: 2× Ctrl+C → Snapshot → Kill,
  damit der letzte JSONL-Flush und der `--resume`-Hinweis erhalten bleiben)
  und stuft den Session-Status von `.running` auf `.closed` herunter. NICHT
  archiviert, nichts gelöscht, Pin bleibt — `resume` fährt die Session wieder
  hoch. Response: `stopped` pro Ziel plus `stoppedCount`. Ein Ziel ohne
  offenen Tab meldet `alreadyClosed` und trotzdem `stopped: true`, wenn dort
  ein Prozess lief.
- **Schutz arbeitender Agenten (`--stop` ohne `--force`):** ist auch nur EIN
  Ziel `working`, scheitert der GESAMTE Request mit `conflict`/Exit 4, bevor
  ein Tab schließt oder ein Prozess stirbt — kein Teilzustand. Die Entscheidung
  liegt im puren, unit-getesteten `ChatsCloseStopGuard`; die Meldung nennt die
  blockierenden Ziele und die drei Auswege (warten, `interrupt`,
  `--stop --force`). `--force` ohne `--stop` lehnt schon der Parser ab: ohne
  Stop gibt es nichts zu erzwingen.
- **Batch, alles-oder-nichts bei der Auflösung:** die CLI löst ALLE Refs vor
  dem Request auf (mehrdeutig/unbekannt → Exit 3, nichts wird geschlossen).
  Der Server verarbeitet alle Ziele in EINEM synchronen MainActor-Block
  (`session.close`, `targetSessionIDs`-Array) — ein konsistenter Snapshot,
  keine Cross-Window-Races. Pro Ziel ein Outcome: `closed`, `alreadyClosed`
  (idempotent, kein Fehler) oder `notFound` (Server-autoritativ, z. B.
  Debounce-Race). Exit 0, sofern kein `notFound`.
- **Auswahl-Fallback:** war der geschlossene Tab selektiert, rückt die
  Selektion auf den vorherigen Tab (sonst den neuen ersten); die Session
  verlässt zudem die ephemere Multi-Auswahl des Fensters. Wird ein
  Sekundärfenster leer, schließt es sich über den bestehenden reaktiven
  Pfad (`onChange(of: openTabIDs)` → `closeWindowIfEmptyAndSecondary`).
- **Kein pauschales `--all`:** die Kandidatenauswahl für „schließe alle, die
  ich nicht brauche" trifft der Aufrufer (Jarvis) über `list --open --json`
  (liefert `isOpen`/`isPinned`/`isSelf`/Status) + Batch-Bestätigung — die
  CLI schließt nur explizit benannte Refs.
- **Relative Modi:** `close --others <ref>` schließt alle anderen Tabs im
  Fenster des Ankers, `close --right <ref>` die Tabs rechts davon (genau
  eine Anker-Ref; Opferliste wird im selben MainActor-Block bestimmt wie
  geschlossen — der Anker kann zwischendurch nicht das Fenster wechseln).
  Anker ohne offenen Tab → Exit 4.

## Weitere Tab-/Fenster-Befehle

- **`reopen`** stellt den zuletzt geschlossenen Tab wieder her (LIFO, Cap 20).
  Die History lebt ephemer im `AgentWindowStore` (bewusst nicht persistiert —
  App-Neustart leert sie) und wird von `closeTab` UND der
  `setOpenTabIDs`-View-Bridge gefüttert (X-Button/⌘W/Bulk); Fenster-Close mit
  Tabs und die Workspace-GC zeichnen nicht auf. Inzwischen archivierte/
  gelöschte oder wieder geöffnete Sessions werden übersprungen; existiert das
  Ursprungsfenster nicht mehr, landet der Tab im Primärfenster.
- **`pin <ref> [<ref>…]` / `unpin …`** setzen den Sidebar-Pin idempotent
  (Batch wie close; Outcomes `pinned`/`unpinned`/`unchanged`/`notFound`).
- **`move <ref> --window <primary|id>`** verschiebt einen Tab in ein anderes
  BESTEHENDES Fenster (`AgentUIState.moveTab`-Semantik: nicht-offene Tabs
  werden im Ziel geöffnet). Fenster-Refs: `primary` oder ID/-Präfix ≥ 8 aus
  `window list`. Neue Fenster kann nur die App-UI öffnen (SwiftUI-Scene) —
  CLI-detach bleibt Backlog.
- **`workspace add <ws> <ref> [--slot N]` / `workspace remove <ws> <ref>`**
  ändern NUR die Grid-Slot-Mitgliedschaft (`WorkspaceSlotOps`-Semantik; voller
  Workspace → Exit 4). `--slot` ist 1-basiert. Tab und Prozess bleiben —
  identisch zur Sidebar-Aktion.

## Archiv: Suche + gezieltes Reaktivieren

Strikte Aktions-Trennung (Produktsemantik, nie stillschweigend vermischt):

| Aktion | Wirkung | Wirkung NICHT |
|---|---|---|
| `close` | UI-Tab zu | archiviert/löscht/stoppt nichts |
| `archive` | Markierung `.archived` + `archivedAt`; laufendes Terminal wird terminiert (mit Guard/`--force`) | löscht keine Daten |
| `unarchive` | NUR Markierung weg (`restoreSession`: Status `.closed`, `archivedAt` = nil) | öffnet keinen Tab, startet nichts |
| `resume` | startet/verbindet eine NICHT archivierte Session | reaktiviert nie aus dem Archiv (Exit 4 + Hinweis) |

- **`archived [query] [--project] [--group] [--provider] [--since D] [--until D]
  [--content "text"] [--limit N] [--json]`** — Archiv-Browser, app-unabhängig
  von Disk. `query` sucht normalisiert (Diakritika-/Trenner-tolerant) über
  Projekt/Titel/Gruppe; Zeitraum gegen `archivedAt` (Alt-Daten ohne Feld:
  `lastActivityAt`), `D` = `yyyy-MM-dd` oder relativ (`14d`, `8w`). Sortiert
  neueste zuerst. Jeder Treffer zeigt die Transcript-Verfügbarkeit
  (stat-billig, `ChatsStatusProbe`) — `⚠︎ kein Transcript` heißt: extern
  verschoben/bereinigt, ein Resume startet eine frische CLI-Session ohne
  Verlauf.
- **`--content`** durchsucht das rohe Transcript-JSONL case-/diakritika-
  insensitiv — erst NACH den Metadaten-Filtern (nur Kandidaten werden
  gelesen). Dateien über dem 64-MB-Cap werden nur im Tail-Fenster durchsucht;
  Treffer/Nicht-Treffer sind dann als `hitTruncated`/`missTruncated` markiert
  (kein Beweis für Abwesenheit).
- **`unarchive <ref> [--resume|--open]`** — Ref-Auflösung inkl. Archiv
  (`includeArchived`), mehrdeutig → Exit 3 mit Kandidaten (nie raten). Der
  Compound ist explizit: `--resume` = danach Auto-Launch + Fokus
  (`session.resume`-Semantik), `--open` = danach nur Tab fokussieren.
  Alles-oder-nichts: ist die Session-Art nicht resumebar (Terminal/agentView),
  passiert bei `--resume` GAR NICHTS (auch kein Unarchive). Nicht archivierte
  Ziele sind idempotenter Erfolg (`alreadyActive`); ein angefordertes
  `--resume`/`--open` läuft dann trotzdem. Kein Pfad löscht Daten.

### Backlog Tab-/Session-Management (Gap-Analyse 2026-07-19)

Runde 2 (gleicher Tag) hat die Prioritäten 1–4 umgesetzt: `pin`/`unpin`,
`close --others/--right`, `reopen`, `move` + `window list`,
`workspace add/remove`. Verbleibend:

| Kandidat | Status |
|---|---|
| CLI-detach in ein NEUES Fenster | offen — braucht einen Scene-Open-Request (`openWindow` gehört SwiftUI); Workaround: in der App per Drag |
| Dry-Run/`--plan` für Batch-Aktionen | nicht nötig — `list --open --json` IST der Plan-Schritt |
| Pauschales `close --all` | bewusst nie (gefährlicher Pfad; Kandidaten immer explizit) |

## Agentenvertrag (`snapshot` / `since` / `watch`)

Die CLI ist primär für Agenten. `--json` ist der Vertrag; die Textausgabe der
Agentenbefehle ist ausdrücklich nur Diagnosehilfe **ohne** Stabilitätszusage
und darf nicht geparst werden. Kein Terminal-Dashboard.

**Warum ein eigener Befehl statt einer Option an `overview`:** `overview` und
`list` haben einen etablierten Vertrag, auf den Skill und Skripte bauen.
`snapshot` erlaubt das saubere Schema `wm8.overview/1`, ohne bestehende
Aufrufer zu brechen.

- **`chats snapshot`** (`wm8.overview/1`) — kompaktes Lagebild über ALLE
  Sessions. Gemessener Anlass: `overview --json` lieferte 868.379 Zeichen für
  920 Sessions, von denen fünf relevant waren; `snapshot` liefert dieselbe
  Lage in ~2.200 Zeichen. `counts` deckt **immer** den vollen Bestand ab, auch
  wenn `sessions` gekürzt ist (`coverage.countsComplete`). Gekürzt wird in
  dieser Reihenfolge: erst Auszüge bei nicht handlungsbedürftigen Zeilen, dann
  Sessions vom Ende — und jede Auslassung erscheint in `coverage.omitted`.
  Idle-Sessions nur mit `--include idle`.
- **`chats since --cursor <c>`** (`wm8.changes/1`) — Änderungen seit einem
  Cursor. Kosten proportional zur Änderung statt zum Bestand. **`gap: true`**
  heißt: Der Cursor stammt aus einer älteren Journal-Generation, es fehlen
  Ereignisse — der Aufrufer MUSS einen frischen `snapshot` ziehen. Ein stilles
  Fortfahren „ab jetzt" wäre der gefährlichste Fehler, weil eine Lücke sonst
  wie „nichts passiert" aussieht.
- **`chats watch`** — NDJSON-Strom derselben Ereignisse, eine Zeile pro
  Ereignis mit Cursor. Für Sidecars und Skripte; ein LLM nutzt besser `since`.
  Ausdrücklich **kein zweiter Ereignisweg**: Bricht der Strom ab, holt der
  Cursor die Ereignisse nach.

### Zustandsachsen

Vier unabhängige Achsen statt eines gemischten Status (`ChatsSessionAxes`):

| Achse | Werte | Bedeutung |
|---|---|---|
| `catalog` | `active \| inactive \| archived` | Aufbewahrung, **keine** Prozessaussage |
| `execution.worker` | `alive \| exited \| missing \| unknown` | der echte Agent |
| `execution.attachment` | `attached \| detached \| none` | nur die Anzeige |
| `conversation.state` | `launching \| ready \| working \| needsInput \| turnDone \| stopped \| errored` | |
| `conversation.reason` | `permission \| question \| planApproval` | nur bei `needsInput` |
| `evidence.quality` | `observed \| inferred` | Hook/App belegt vs. Transcript geschätzt |

`launching` ist ein **eigener** Wert und wird nicht auf `idle` abgebildet — das
war die Wurzel des Start-Race. Bei Hintergrund-Agenten ist `attachment` kein
Beleg für `worker`: Das PTY ist dort nur ein `claude attach`.

### Sichere Send-Semantik

`send` an eine Session in `launching` scheitert mit `notReady` (Exit 4) statt
still Erfolg zu melden. Belegt am 2026-07-26: `resume` + sofortiges `send`
meldete „delivered", während die Transcript-Revision 30 Sekunden unverändert
blieb — der Paste landete in einer noch nicht bereiten TUI und ging je nach
Timing verloren oder kam beim Retry doppelt an. `sendPrompt` schreibt blind in
die PTY; ein Erfolg belegt nur den Schreibvorgang, nicht die Verarbeitung.
Wer Zustellung braucht, nutzt `enqueue` (höchstens einmal, bei bestätigtem
Turn-Ende). `snapshot` bietet in `launching` konsequent kein `send` als Aktion an.

### Anomalien und Kompatibilität

Anomalien (`wm8.anomaly/1`) werden **nie** in einen Gesamtstatus eingerechnet;
sie stehen mit `severity`, `evidence` und `recommendedAction` daneben. Ein
Hintergrund-Agent ohne Tab und ohne PTY ist ausdrücklich **keine** Anomalie —
das ist der Normalfall von `claude --bg`.

Kompatibilität: Additive Felder ändern das Schema nicht; Agenten MÜSSEN
unbekannte Felder ignorieren. Entfernen, Umbenennen oder Umdeuten eines Feldes
erzwingt `/2`. Cursor sind opak und nur innerhalb derselben Generation gültig.

## wait

`ChatsWaitEngine`: pro Transcript ein `DispatchSourceFileSystemObject`
(`O_EVTONLY`, `.write/.extend/.delete/.rename`), 300-ms-Debounce, 10-s-Fallback-
Poll (Missed-Event-Netz), Re-Locate bei delete/rename (Kompaktierung), Timeout
124 / SIGINT 130. `--since REV` (Transcript-Bytes als Revision) schließt die
Lücke zwischen zwei wait-Aufrufen.

## Audit

`ChatsAuditLog` (`chats-audit.jsonl`, Rotation 5 MB): jede Socket-Mutation mit
Actor, Methode, Ziel, Ergebnis, Prompt-Länge + 80-Zeichen-Kopf (kein Volltext —
Privacy-Default). Nur die App schreibt; `chats audit` liest.

## Skill

`whisperm8-chats` (`skills/whisperm8-chats/SKILL.md`): macht aus Befehlen
Verhalten. Autonomie-Stufen (Beobachten/Zuarbeiten/Supervisor), Send-Gate über
AskUserQuestion, Ein-Hop-Regel, Batch-Aufräumen, Supervisor-Loop
(`overview → wait → tail → berichten`). Interrupt nur nach expliziter
User-Freigabe.

## Zentrale Dateien

- CLI: `WhisperM8/CLI/AgentChatsCLICommand.swift`, `ChatsWorkspaceReader.swift`,
  `SessionRefResolver.swift`, `ChatsStatusProbe.swift`, `ChatsAttentionModel.swift`,
  `ChatsTailFormatter.swift`, `ChatsOutput.swift`, `ChatsControlProtocol.swift`,
  `ChatsControlClient.swift`, `ChatsLiveCommands.swift`, `ChatsLiveMerge.swift`,
  `ChatsWaitEngine.swift`.
- App: `Services/AgentChats/AgentControlServer.swift`,
  `AgentControlRequestHandler.swift`, `AgentSessionTokenRegistry.swift`,
  `ChatsAuditLog.swift`; Änderungen in `AgentTerminalView.swift` (Env-Injektion,
  `sendPrompt`/`sendInterrupt`), `AgentChatLaunchService.swift`
  (`openChatViaControl`), `WhisperM8App.swift` (Server-Start).
- Tests: `Tests/WhisperM8Tests/ChatsCLITests.swift`, `ChatsControlTests.swift`,
  `ChatsWaitEngineTests.swift`, `TestControlSocket.swift`.
