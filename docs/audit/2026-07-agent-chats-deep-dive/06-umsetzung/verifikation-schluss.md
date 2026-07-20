---
status: historischer-pruefstand
updated: 2026-07-20
description: Historische Schlussverifikation und Eingang der Gates G0–G4; aktueller P0-/Freigabestatus steht in freigabe-gates-g0-g6.md.
---

# Schlussverifikation Workflow 3

## 0. Auftrag, Methode und Urteilsskala

Geprüft wurden:

- `identitaetsmodell-spec.md`
- `verlorene-chats-spec.md`
- `feature-inventar-diktat.md`
- `feature-inventar-agentchats.md`
- `test-specs-welle0-1.md`

Die Prüfung erfolgte gegen den aktuellen produktiven Swift-Code, die vorhandenen XCTest-Konventionen und die lokal installierte Claude-Code-CLI 2.1.214. Es wurden keine Builds, Tests oder Produktprozesse gestartet. Die CLI-Prüfung war auf `claude --version` und `claude --help` beschränkt. Der Help-Contract bestätigt `--resume`, `--fork-session`, `--session-id`, `--settings`, `--bg` und `--no-session-persistence`; er bestätigt jedoch **nicht**, dass `--session-id <child> --resume <parent> --fork-session` in dieser Kombination fehlerfrei funktioniert oder welche ID ein früher Fork-Hook meldet.

Prioritäten:

- **P0:** Vor Produktumsetzung auflösen; sonst drohen falsche Bindung, Datenverlust oder ein nicht testbarer Vertrag.
- **P1:** Vor Abnahme der betroffenen Welle korrigieren.
- **P2:** Präzisierung beziehungsweise Inventarvollständigkeit; kein unmittelbarer Umsetzungsblocker.

## 1. Gesamturteil

**Urteil: noch nicht umsetzungsreif.** Die Dokumente bilden den realen Problemraum weitgehend richtig ab und verletzen den CLI-Host-Constraint nicht. Fünf P0-Lücken verhindern jedoch einen sicheren Start der Identitäts-/Recovery-Umsetzung:

1. `identitaetsmodell-spec.md` schreibt den nicht vorgegebenen Weg B verbindlich fest, während `verlorene-chats-spec.md` als Ziel Weg A mit vorab vergebener `--session-id` vorsieht. Das ist kein Detail, sondern bestimmt Persistenzschema, Launch-Intent und Fork-Commit.
2. Beide Identitätsspezifikationen verlangen eine Prüfung derselben `launchID`, definieren aber nicht, wie diese Identität den Hook erreicht. Der Hook-Payload enthält keine WhisperM8-`launchID`; die Bridge korreliert heute nur über die langlebige lokale Chat-UUID (`WhisperM8/Services/AgentChats/ClaudeHookEventStore.swift:36-46`, `WhisperM8/Services/AgentChats/ClaudeHookBridge.swift:27-41`, `WhisperM8/Services/AgentChats/ClaudeHookBridge.swift:218-229`).
3. Das Soll-Modell spezifiziert Start-Resume und Start-Fork, aber keinen vollständigen Laufzeitübergang für `/branch` beziehungsweise `/rewind`, obwohl ein PTY dadurch ohne Relaunch den Claude-Zweig wechseln kann. Der aktuelle Eventtyp verwirft außerdem `SessionStart.source` vollständig (`WhisperM8/Services/AgentChats/ClaudeHookEventStore.swift:121-136`).
4. Das Agent-Chats-Inventar enthält falsche „Erhaltungsinvarianten“ zur ID-Eindeutigkeit, Merge-Eindeutigkeit und Snapshot-Fallback-Semantik. Es ist damit noch kein verlässliches Regressions-Oracle (`WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:345-363`, `WhisperM8/Services/AgentChats/AgentSessionStore.swift:825-850`, `WhisperM8/Views/AgentSessionDetailView.swift:201-225`).
5. `test-specs-welle0-1.md` lässt mehrere explizite Welle-1-Verträge und gerade C07 aus, obwohl W0.1 C07 ausdrücklich als Oracle verlangt (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:49-61`, `docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:141-184`).

Empfohlener Freigabestatus nach Dokument:

| Dokument | Urteil |
|---|---|
| `identitaetsmodell-spec.md` | **Revision erforderlich; nicht implementieren** |
| `verlorene-chats-spec.md` | **P0.1/P0.2 fachlich startbar, P0.3/P0.4 erst nach Identitätsrevision** |
| `feature-inventar-diktat.md` | **Nahezu freigabefähig; kleine reale Lücken ergänzen** |
| `feature-inventar-agentchats.md` | **Breit, aber als Oracle noch nicht freigabefähig** |
| `test-specs-welle0-1.md` | **Neu schneiden und W0/W1 vollständig abdecken** |

## 2. Stichproben der Ist-Zustand-Aussagen

### 2.1 Bestätigte Stichproben

| Aussage | Ergebnis der Codeprüfung |
|---|---|
| Die lokale Session-Row trägt UI-, Provider-, externe und Launch-Identität gemeinsam. | Bestätigt: `AgentChatSession` enthält lokale `id`, `projectID`, `externalSessionID`, Status, Launchmarker, Fork-Quelle, Profil und Backend-Stempel in derselben Struktur (`WhisperM8/Models/AgentChat.swift:225-242`, `WhisperM8/Models/AgentChat.swift:281-307`). |
| Ein Fork erhält eine neue lokale UUID, zunächst keine externe ID und die Quell-ID in `forkSourceSessionID`. | Bestätigt (`WhisperM8/Views/AgentChatsView+SessionLifecycle.swift:78-112`). |
| Der Builder startet den ungebundenen Fork per `--resume <source> --fork-session` und einen gebundenen Fork später per eigener ID. | Bestätigt; die aktuelle Stelle liegt wegen GPT-Erweiterungen bei `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:366-415`. |
| Fresh Claude erhält aktuell keine vorgegebene `--session-id`. | Bestätigt (`WhisperM8/Views/AgentChatsView+SessionLifecycle.swift:41-46`, `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:384-389`). |
| Hook-Payloads liefern Session-ID, Transcriptpfad und cwd. | Bestätigt (`WhisperM8/Services/AgentChats/ClaudeHookEventStore.swift:121-136`). |
| Die produktive Hook-Bindung übernimmt jede nichtleere ID und prüft weder Fork-Parent noch Kollision, Config-Root oder Transcriptpfad. | Bestätigt (`WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:345-363`). |
| Der Lazy-Indexer-Fallback hat nur eine Zeituntergrenze und nimmt den jüngsten Kandidaten. | Bestätigt (`WhisperM8/Services/AgentChats/AgentSessionStore.swift:623-633`). |
| Der Merge verwendet ein echtes ±5-Sekunden-Fenster, wählt bei mehreren lokalen Kandidaten aber den zeitlich nächsten. | Bestätigt (`WhisperM8/Services/AgentChats/AgentSessionStore.swift:825-850`). |
| Der cwd-Encoder lässt Swift-Unicode-`isLetter`/`isNumber` durch. | Bestätigt (`WhisperM8/Services/AgentChats/AgentSessionTranscript.swift:318-332`). |
| Der globale Transcript-Fallback akzeptiert nur den ersten gefundenen cwd-Record. | Bestätigt: Die Schleife kehrt beim ersten Record mit `cwd` unmittelbar mit true oder false zurück (`WhisperM8/Services/AgentChats/AgentSessionTranscript.swift:403-419`). |
| Auto-Namer und Summarizer starten Claude-Printläufe ohne `--no-session-persistence`. | Bestätigt (`WhisperM8/Services/AgentChats/AgentSessionAutoNamer.swift:132-146`, `WhisperM8/Services/AgentChats/AgentSessionSummarizer.swift:27-40`). |
| Der Headless-Runner setzt kein cwd. | Bestätigt (`WhisperM8/Services/AgentChats/AgentHeadlessCLI.swift:28-43`). |
| Worktree- und alte ungebundene Sessions werden heute normalisiert/pruned. | Bestätigt (`WhisperM8/Services/AgentChats/AgentSessionStore.swift:1103-1133`, `WhisperM8/Services/AgentChats/AgentSessionStore.swift:1172-1186`). |
| Terminal-Snapshots werden atomar als Plaintext-Sidecar mit 2.000-Zeilen-Grenze gespeichert. | Bestätigt (`WhisperM8/Services/AgentChats/TerminalSnapshotStore.swift:14-29`, `WhisperM8/Services/AgentChats/TerminalSnapshotStore.swift:75-106`). |
| Der GPT-Router wird für Claude-PTYs per Environment eingeschaltet und GPT-gestempelte Sessions erhalten zusätzliche Tuning-Variablen. | Bestätigt (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:267-307`, `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:423-425`). |
| Das Repo verwendet Closure-DI, kleine Protokolle und lokale Spies. | Bestätigt: beispielsweise Closure-DI im Auto-Namer (`WhisperM8/Services/AgentChats/AgentSessionAutoNamer.swift:118-146`), das kleine `ProcessRunner`-Protokoll (`WhisperM8/Services/AgentChats/BackgroundAgentSpawner.swift:217-234`) und ein testlokaler Spy (`Tests/WhisperM8Tests/BackgroundAgentLifecycleTests.swift:241-265`). |

### 2.2 Zitierdrift

Mehrere Aussagen sind sachlich noch auffindbar, aber ihre angegebenen Zeilenbereiche sind durch die aktuelle GPT-Backend-Erweiterung verschoben. Besonders betroffen sind Verweise auf den Claude-Block in `AgentCommandBuilder.swift`: Fork-/Resume-Auswahl liegt aktuell bei Zeile 366 ff., der tatsächliche Flag-Append bei Zeile 410 ff. (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:353-415`). Vor Übergabe an Implementierer müssen die Specs einmal automatisiert oder manuell gegen den finalen Branch nachgezogen werden. Ein Bereich, der nur einen Kommentar oder den Anfang einer Funktion trifft, ist für einen Schlussvertrag nicht ausreichend.

## 3. `identitaetsmodell-spec.md`

### 3.1 Bestätigte Punkte

1. **Die Dreiteilung ist fachlich richtig.** Lokale Chat-UUID, PTY-/Prozessinkarnation und Claude-Branch sind heute tatsächlich nicht als getrennte persistente Entitäten modelliert. Die Registry besitzt Controller pro lokaler UUID (`WhisperM8/Views/AgentTerminalView.swift:323-364`), während der Controller zusätzlich eine flüchtige eigene UUID und PID besitzt (`WhisperM8/Views/AgentTerminalView.swift:613-633`).
2. **Resume und Fork dürfen nicht dasselbe Binding-Verhalten haben.** Der Builder setzt die offiziellen CLI-Flags bereits verschieden (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:366-415`).
3. **Config-Root gehört zur Claude-Identität.** Der Launch setzt `CLAUDE_CONFIG_DIR` profilbezogen und kann beim Resume dem realen Transcript-Root folgen (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:259-265`, `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:391-408`).
4. **Persistierter `transcriptPath` ist ein sinnvoller autoritativer Anker.** Der Hook parser liefert ihn bereits, das Sessionmodell besitzt das Feld aber nicht (`WhisperM8/Services/AgentChats/ClaudeHookEventStore.swift:36-46`, `WhisperM8/Models/AgentChat.swift:225-307`).
5. **Der Parent-ID-Guard ist notwendig.** Der aktuelle Binder überschreibt auch eine bereits vorhandene ID, solange sie nur abweicht (`WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:345-355`).
6. **Writer-Lease pro gescoptem Claude-Key ist korrekt.** Die Registry verhindert nur Doppelcontroller derselben lokalen UUID, nicht zwei lokale Rows mit derselben externen ID (`WhisperM8/Views/AgentTerminalView.swift:329-364`).
7. **Compact muss identitätsneutral bleiben.** Der heutige Reducer kennt `compact` bereits als In-Place-Reason (`WhisperM8/Services/AgentChats/AgentSessionStateMachine.swift:222-235`, `WhisperM8/Services/AgentChats/AgentSessionStateMachine.swift:275-278`).

### 3.2 Mängel

#### P0 — Weg A und Weg B widersprechen sich

`identitaetsmodell-spec.md:61-65,82-84` macht „Claude vergibt Child/Fresh-ID selbst“ zur verbindlichen Invariante. `verlorene-chats-spec.md:413-467` erklärt dagegen die vorab reservierte `--session-id` für Fresh und Fork zum Zielbild. Der aktuelle Code implementiert Weg B (`WhisperM8/Views/AgentChatsView+SessionLifecycle.swift:41-46`, `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:384-389`).

**Erforderliche Korrektur:** Ein gemeinsamer Launch-Strategie-Vertrag mit zwei expliziten Capability-Zuständen:

- `hostAssignedUnsupported`: Child-ID kommt ausschließlich aus validiertem Hook/JSONL.
- `hostAssignedVerified`: Child-ID ist vorab reserviert, CLI-Probe und Hook müssen exakt dieselbe ID bestätigen.

Persistenzschema, Transitionen und Tests müssen beide Zustände benennen. Ein absolutes „nie `--session-id`“ und ein gleichzeitiges Ziel „später immer `--session-id`“ können nicht gemeinsam Freigabegrundlage sein.

#### P0 — `launchID` ist gefordert, aber nicht transportiert

Die Spec verlangt, dass Hook-/Indexer-Entscheidungen dieselbe `launchID` prüfen (`identitaetsmodell-spec.md:47-50,54-64`). Der reale Hook enthält aber nur Claude-Felder; WhisperM8s Prozessinkarnation steht nicht im Payload (`WhisperM8/Services/AgentChats/ClaudeHookEventStore.swift:36-46`, `WhisperM8/Services/AgentChats/ClaudeHookEventStore.swift:121-136`). Die Bridge hält als Korrelationsschlüssel nur `localSessionID`, und die Eventdatei ist ebenfalls nur nach dieser langlebigen UUID benannt (`WhisperM8/Services/AgentChats/ClaudeHookBridge.swift:27-41`, `WhisperM8/Services/AgentChats/ClaudeHookSettingsBuilder.swift:142-148`).

**Erforderliche Korrektur:** Den Mechanismus festschreiben, beispielsweise:

- pro Launch eine neue Eventdatei und Settingsdatei unter `<chatID>/<launchID>.*`;
- die Bridge-Entry trägt `(chatID, launchID, expectedConfigRoot, launchedAt)` und envelopt jedes gelesene Claude-Event damit;
- nur die aktuelle Generation darf claimen;
- der alte FD/Settingspfad wird vor Spawnwechsel geschlossen, späte Events alter Dateien werden verworfen und diagnostisch protokolliert.

Eine bloße Prüfung eines Feldes, das Claude nicht mitsendet, ist nicht implementierbar.

#### P0 — Laufzeit-Branchwechsel fehlt

Die Spec erwähnt `/branch` und `/rewind` als Grund für die Trennung (`identitaetsmodell-spec.md:28`), definiert danach aber nur Start-Resume, Start-Fork und Compact. Das ist unvollständig: Ein bereits laufender PTY kann seine aktive Claude-ID wechseln, ohne dass eine neue WhisperM8-Prozessinkarnation entsteht. Der aktuelle Reducer behandelt `SessionStart` zudem statusneutral in laufenden Turns und der Eventparser verwirft `source` (`WhisperM8/Services/AgentChats/AgentSessionStateMachine.swift:183-193`, `WhisperM8/Services/AgentChats/ClaudeHookEventStore.swift:121-136`).

**Erforderliche Korrektur:** Eigene Transition `activeBranchChange` mit altem und neuem gescoptem Key, Source, Transcriptpfad, cwd und Lineage. Festlegen, ob der lokale Chat auf den neuen Zweig umgebunden wird, ob der alte Zweig als eigener Workspace-Chat materialisiert wird und wie Tabs/Unread/Auto-Naming reagieren.

#### P1 — „Parent-Lineage“ des JSONL-Fallbacks ist nicht operationalisiert

Die Spec verlangt beim stummen Fork eine eindeutige neue JSONL mit passender Parent-Lineage (`identitaetsmodell-spec.md:63`). Der aktuelle Indexer extrahiert aber nur Session-ID, erstes cwd, Titel und Zeiten; eine Eltern-Session-ID wird weder gelesen noch geliefert (`WhisperM8/Services/AgentChats/ClaudeSessionIndexer.swift:112-169`). `parentUuid` in Claude-Records ist eine Nachrichtenverkettung und in diesem Indexpfad kein definierter Branch-Parent-Beleg.

**Erforderliche Korrektur:** Zulässige Lineage-Evidenz exakt definieren. Wenn die CLI kein autoritatives Parent-Session-Feld liefert, darf „Parent-Lineage passt“ nicht als prüfbare Bedingung behauptet werden. Dann muss der Fallback auf gescopte Neuheit, Launchfenster, Dateiidentität, cwd und eindeutigen Claim begrenzt und als schwächere Recovery-Evidenz markiert werden.

#### P1 — Der gemeldete Fork-Fehler wird zu stark als deterministisch belegt

Der Code beweist die **Fehlerkette unter der Bedingung**, dass ein früher `SessionStart` die Parent-ID liefert: Binder übernimmt sie, Retry stoppt bei nicht-nil, nächster Launch resumiert ohne Fork (`WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:345-363`, `WhisperM8/Views/AgentSessionDetailView.swift:700-725`, `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:366-415`). Weder der Code noch `claude --help` beweisen jedoch, dass Claude Code 2.1.214 bei einem echten Fork tatsächlich zuerst die Parent-ID emittiert. `identitaetsmodell-spec.md:34-36` muss daher zwischen bestätigtem WhisperM8-Defekt und noch zu reproduzierender CLI-Ereignisfolge unterscheiden.

#### P1 — `SessionStart.source` ist nicht nur „nicht persistiert“, sondern wird verworfen

`identitaetsmodell-spec.md:73` formuliert zu schwach. `ClaudeHookEvent` besitzt kein `source`-Feld und der Parser liest es nicht (`WhisperM8/Services/AgentChats/ClaudeHookEventStore.swift:36-46`, `WhisperM8/Services/AgentChats/ClaudeHookEventStore.swift:121-136`). Für `startup`, `resume`, `clear` und `compact` ist das eine notwendige Eingangsinformation der Identitäts-State-Machine.

## 4. `verlorene-chats-spec.md`

### 4.1 Bestätigte Punkte

1. **U1 ist korrekt kartiert.** Encoder-Drift, fehlender persistierter Transcriptpfad und First-cwd-Return sind real (`WhisperM8/Services/AgentChats/AgentSessionTranscript.swift:318-419`, `WhisperM8/Models/AgentChat.swift:225-307`).
2. **U2 ist korrekt kartiert.** Claude-Headless-Aufrufe persistieren derzeit Sessions, der Runner setzt kein cwd, und der Indexer schneidet global nach Aktivität ab (`WhisperM8/Services/AgentChats/AgentSessionAutoNamer.swift:132-146`, `WhisperM8/Services/AgentChats/AgentSessionSummarizer.swift:27-40`, `WhisperM8/Services/AgentChats/AgentHeadlessCLI.swift:28-43`, `WhisperM8/Services/AgentChats/ClaudeSessionIndexer.swift:38-50`).
3. **U3 ist korrekt kartiert.** Lazy-Binding schließt belegte IDs und Mehrdeutigkeit nicht aus; Hook-Binding hat ebenfalls keinen Claim (`WhisperM8/Services/AgentChats/AgentSessionStore.swift:600-649`, `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:345-363`).
4. **U4 ist erreichbar.** Nach erfolgreichem Start wird der Marker gesetzt und der Prompt geleert; ohne Binding baut der nächste Claude-Launch keinen Resume-Block (`WhisperM8/Views/AgentSessionDetailView.swift:633-650`, `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:366-420`).
5. **U6/U7 sind echte destruktive Normalisierungen.** Worktree-Zeilen und alte ungebundene Zeilen werden entfernt (`WhisperM8/Services/AgentChats/AgentSessionStore.swift:1103-1133`, `WhisperM8/Services/AgentChats/AgentSessionStore.swift:1172-1186`).
6. **P0.1 ist ein sinnvoller isolierter Sofortfix.** Die installierte CLI führt `--no-session-persistence` ausdrücklich als Print-only-Flag; die produktiven Hilfsläufe sind Printläufe (`WhisperM8/Services/AgentChats/AgentSessionAutoNamer.swift:138-146`, `WhisperM8/Services/AgentChats/AgentSessionSummarizer.swift:31-40`).
7. **P0.2 ist regressionsarm.** Der aktuelle Resume-Guard bewahrt eine bekannte externe ID bereits bei negativer Evidenz und stoppt sichtbar; dieselbe konservative Semantik auf nil-Binding und Prunes auszuweiten ist konsistent (`WhisperM8/Services/AgentChats/AgentSessionStore.swift:703-715`, `WhisperM8/Views/AgentSessionDetailView.swift:579-607`).
8. **P0.4 gehört unter denselben Store-Lock.** Workspace-Mutationen laufen bereits über den serialisierten Kern (`WhisperM8/Services/AgentChats/AgentSessionStore.swift:1221-1225`, `WhisperM8/Services/AgentChats/AgentWorkspaceStore.swift:110-129`).

### 4.2 Mängel

#### P0 — P0.3 wiederholt die ungelöste Hook-Korrelation

`verlorene-chats-spec.md:308-342` verlangt Validierung von Prozessinkarnation, Config-Root und Launchmodus, definiert aber keinen per-Launch Hook-Kanal. Die aktuelle Eventdatei wird beim Prepare zwar geleert (`WhisperM8/Services/AgentChats/ClaudeHookBridge.swift:79-96`), bleibt jedoch nach lokaler Chat-UUID benannt und transportiert keine `processIncarnationID` (`WhisperM8/Services/AgentChats/ClaudeHookSettingsBuilder.swift:142-148`). Ein alter und ein neuer Prozess derselben lokalen Row können deshalb nicht allein aus dem Payload unterschieden werden.

Die P0.3-Implementierung darf erst beginnen, nachdem der in Abschnitt 3.2 geforderte Event-Envelope-/Dateipfad-Vertrag feststeht.

#### P0 — P2 kollidiert mit dem Identitätsdokument

`verlorene-chats-spec.md:413-467` ist als capability-gegateter Spike vernünftig, aber als verbindliches Ziel nicht mit `identitaetsmodell-spec.md:61-65,82-84` vereinbar. Die Kombination `--session-id child --resume parent --fork-session` ist durch den installierten Help-Text nicht als gültiger Kombinationsvertrag bestätigt. Der vorgeschlagene Scratch-Root-Probe-Gate ist daher notwendig, darf aber erst nach einheitlicher Strategie als Produktpfad spezifiziert werden.

#### P1 — Config-Root-Prüfung braucht eine konkrete kanonische Regel

Der Hook liefert keinen Config-Root, sondern `transcript_path` (`WhisperM8/Services/AgentChats/ClaudeHookEventStore.swift:121-136`). P0.3 muss festlegen, wie aus dem Pfad sicher und symlink-/standardisierungsfest der erwartete Profilroot abgeleitet wird. Der bestehende Code besitzt dafür bereits `profileName(forTranscriptPath:)`, verwendet ihn aber erst im Builder/Indexer-Kontext (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:399-407`, `WhisperM8/Services/AgentChats/ClaudeSessionIndexer.swift:166-169`).

#### P1 — Externe History-Migration kollidiert mit der Repo-Leitplanke

P1.2 erlaubt einen bestätigten Copy+Verify-Workflow in Claude-History. Die Repository-Leitplanke erklärt `~/.claude/` und `~/.codex/` dagegen grundsätzlich read-only (`CLAUDE.md:114`). Der aktuelle Code besitzt bereits zwei Ausnahmen, die diese Leitplanke faktisch unterlaufen: Account-Move verschiebt JSONL/Subagent-Ordner (`WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:412-481`) und Theme-Sync schreibt `~/.claude/settings.json` (`WhisperM8/Services/AgentChats/ClaudeThemeWriter.swift:83-158`).

Das ist kein SDK-/Eigen-UI-Verstoß, aber vor P1.2 muss die Datenhoheit explizit entschieden werden: Entweder bleibt Relink rein logisch und read-only, oder die Repo-Leitplanke wird bewusst auf eng bestätigte, backup-/rollback-gesicherte User-Aktionen erweitert.

#### P1 — Recovery-Zustände benötigen Persistenz- und UI-Vertrag

`recoveryRequired`, `missing` und `worktreeDetached` werden genannt, aber weder als Enum-/Schema-Migration noch mit zulässigen Übergängen, Archiv-/Sidebar-Sichtbarkeit und Retry-Ownership spezifiziert (`verlorene-chats-spec.md:287-306`). Das heutige Modell hat nur den allgemeinen Sessionstatus und keine Recovery-Felder (`WhisperM8/Models/AgentChat.swift:225-307`). Vor Implementierung ist eine kleine State-Machine samt Future-Schema-Kompatibilität erforderlich.

## 5. `feature-inventar-diktat.md`

### 5.1 Bestätigte Punkte

Das Dokument ist deutlich näher an einem brauchbaren Regressions-Oracle als die übrigen Specs:

- Hotkey-/Tap-Semantik ist korrekt festgehalten: KeyDown startet, ein KeyUp unter 0,3 Sekunden wird absichtlich ignoriert (`WhisperM8/WhisperM8App.swift:101-112`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:244-271`).
- Recorder, Ducking, Kontext-Capture, visuelle Anhänge, Output-Modi, Post-Processing, Clipboard/Auto-Paste, Failure-Retry, Reports, Onboarding, Berechtigungen und Quit-Risiko sind jeweils separat erfasst.
- Die Datei-CLI ist nicht nur als „ein Befehl“, sondern mit Videoextraktion, Chunking, Segmentformaten, Dry-Run, Provider-/Key-Priorität und stdout/stderr-Vertrag erfasst (`WhisperM8/CLI/CLITranscribe.swift:17-41`, `WhisperM8/CLI/CLITranscribe.swift:84-200`, `WhisperM8/CLI/CLITranscribe.swift:270-309`).
- Die Querschnittsinvarianten trennen Aufnahme-Intent, Quell-App, Agent-Kontext und Paste-Ziel zutreffend (`WhisperM8/Services/Dictation/RecordingCoordinator.swift:118-178`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:61-101`).

### 5.2 Mängel

#### P1 — Installierbarer Transkriptions-Skill und CLI-Installation fehlen als Feature

DI-44 inventarisiert die Transkriptions-CLI, aber nicht die sichtbare Installation des `~/.local/bin/whisperm8`-Links und den gebündelten `whisperm8-transcription`-Skill. Beides ist produktive UI: Settings zeigen Installationsstatus/Aktion und Skill-Karten (`WhisperM8/Views/Settings/Pages/CLISkillsSettingsPage.swift:5-43`, `WhisperM8/Views/Settings/Pages/CLISkillsSettingsPage.swift:99-115`). Der Exporter installiert `SKILL.md` unter `~/.claude/skills/whisperm8-transcription/` (`WhisperM8/Services/Shared/CLISkillExporter.swift:26-35`, `WhisperM8/Services/Shared/CLISkillExporter.swift:102-118`, `WhisperM8/Services/Shared/CLISkillExporter.swift:145-170`).

**Ergänzung:** Eigene DI-45 für CLI-Link/Status und DI-46 für Skill-Install/Update/Export, inklusive „reguläre Fremddatei am Symlink-Ziel nie überschreiben“ (`WhisperM8/Services/Shared/CLISymlinkInstaller.swift:18-38`).

#### P2 — Scope der geteilten App-Shell explizit abgrenzen

Das Dokument beansprucht die „gesamte Diktat-Hälfte“, lässt aber bewusst geteilte Features wie App-Update, Theme und Launch-at-Login aus. Das ist akzeptabel, wenn README/Inventar festhält, dass ein drittes Querschnittsinventar diese App-Shell schützt. Ohne eine solche Abgrenzung bleiben reale Ship-Gates zwischen beiden Inventaren unbesetzt.

## 6. `feature-inventar-agentchats.md`

### 6.1 Bestätigte Punkte

1. **Die Hauptfläche ist breit erfasst.** Shell, Domain-/UI-Persistenz, Sidebar, Projekte, Archiv, Tabs, Multi-Select, Drag-and-drop, Multi-Window und Grid sind als getrennte Verträge beschrieben.
2. **Der Native-PTY-Vertrag ist korrekt zentral.** Launch, Registry/Reparenting, Keyboardprofile und Link-Interceptor werden als echte CLI-/Terminalfunktionen bewahrt (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:164-180`, `WhisperM8/Views/AgentTerminalView.swift:613-715`, `WhisperM8/Views/AgentTerminalLinkInterceptor.swift:20-70`).
3. **Background- und Codex-Subagent-Systeme sind getrennt inventarisiert.** Das entspricht dem realen Code: Claude wird per `--bg`/`attach` vom externen Supervisor gehostet, Codex-Jobs besitzen einen WhisperM8-Supervisor (`WhisperM8/Services/AgentChats/BackgroundAgentSpawner.swift:78-114`, `WhisperM8/Services/AgentChats/AgentJobSupervisor.swift:59-123`).
4. **GPT-Backend ist inzwischen als eigener Bereich AC-57 bis AC-61 vorhanden.** Settings/Login, Proxy-Ownership, In-Process-Router, Launch-Environment/Fallback und verwalteter nativer `gpt`-Agent sind nicht mehr vollständig ausgelassen (`WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:4-88`, `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:218-283`, `WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:268-307`, `WhisperM8/Services/AgentChats/ClaudeGPTAgentDefinition.swift:3-70`).
5. **Terminal-Snapshots sind inzwischen als AC-30/AC-55 vorhanden.** Capture auf Stop, Selbst-Exit und App-Quit ist im Code real (`WhisperM8/Views/AgentTerminalView.swift:775-836`, `WhisperM8/Views/AgentTerminalView.swift:969-979`, `WhisperM8/WhisperM8App.swift:343-351`).

### 6.2 Mängel

#### P0 — AC-41 behauptet eine nicht implementierte ID-Eindeutigkeit

AC-41 erklärt „bereits belegte externe IDs dürfen nicht parallel an zwei lokale Rows gebunden werden“ zur Erhaltungsinvariante (`feature-inventar-agentchats.md:350-356`). Der Binder prüft ausschließlich `old != newID` in derselben Row und schreibt dann (`WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:345-363`). Das ist ein **Soll-Fix**, kein korrektes Ist-Verhalten. Als Regressions-Oracle würde es einen heute roten Test fälschlich als Charakterisierungstest deklarieren.

**Korrektur:** In „heutige Lücke / Soll-Gate“ verschieben und ausdrücklich als C07-Bugtest markieren.

#### P0 — AC-52 behauptet eindeutige Adoption, der Merge wählt bei Mehrdeutigkeit

AC-52 sagt, Adoption erfolge „bei eindeutiger Zuordnung“ (`feature-inventar-agentchats.md:442-448`). Der Code filtert mehrere ungebundene Kandidaten im ±5-s-Fenster und nimmt per `min` den zeitlich nächsten (`WhisperM8/Services/AgentChats/AgentSessionStore.swift:825-850`). Das Identitätsdokument beschreibt den Code an dieser Stelle zutreffender.

**Korrektur:** Aktuelles Verhalten und gewünschte Eindeutigkeitsregel trennen. „Hook/Scan-Reihenfolge endet in genau einer kanonischen Row“ darf erst nach P0.4 als Soll-Gate gelten.

#### P0 — AC-30s Fallback-Invariante ist im Ist-Code falsch

AC-30 sagt, ein kaputter oder neuer Sidecar dürfe den JSONL-Fallback langfristig nicht blockieren (`feature-inventar-agentchats.md:258-264`). Der Displaypfad deferiert das Transcript aber schon bei bloßer Dateiexistenz (`WhisperM8/Views/AgentSessionDetailView.swift:219-225`), während `load` bei kaputtem Header oder unbekannter Version nil liefert (`WhisperM8/Services/AgentChats/TerminalSnapshotStore.swift:94-106`). Nach dem asynchronen nil-Resultat wird kein erneuter Transcript-Load ausgelöst (`WhisperM8/Views/AgentSessionDetailView.swift:201-216`). Damit kann ein kaputter Sidecar im Terminalmodus den JSONL-Fallback tatsächlich dauerhaft blockieren.

**Korrektur:** Entweder vor Defer den Header validieren oder nach `terminalSnapshot = nil` den Transcript-Load triggern. Das Inventar muss den Ist-Bug als Soll-Test ausweisen, nicht als erhaltene Eigenschaft.

#### P1 — Snapshot-Privacy und Retention sind unvollständig beschrieben

Der Snapshot ist kein garantiert output-only Mitschnitt. Er persistiert den kompletten normalen Terminalbuffer (`WhisperM8/Views/AgentTerminalView.swift:808-819`); darin können auch vom TUI gerenderte Eingaben, Prompts oder Secrets stehen. Der Sidecar wird als Plaintext geschrieben und setzt im Gegensatz zu Hookdateien keine expliziten 0600-Rechte (`WhisperM8/Services/AgentChats/TerminalSnapshotStore.swift:75-90`; Hookvergleich: `WhisperM8/Services/AgentChats/ClaudeHookBridge.swift:87-92`). Löschung erfolgt nur über explizites Session-/Projekt-Delete (`WhisperM8/Services/AgentChats/AgentSessionStore.swift:453-499`); Normalisierungs-Prunes kennen den Sidecar nicht (`WhisperM8/Services/AgentChats/AgentSessionStore.swift:1103-1133`).

AC-30/Querschnittspunkt 10 muss daher festhalten:

- Normalbuffer kann sichtbar gerenderte Eingabe enthalten;
- Dateirechte, Retention und Orphan-Cleanup sind Teil des Vertrags;
- „Input wird nicht separat aufgezeichnet“ ist keine hinreichende Privacy-Garantie.

#### P1 — Codex-Job-Worktree fehlt als eigenständiges Feature

`whisperm8 agent run --worktree` erstellt einen Branch `subagent/<id>` im Jobverzeichnis; `agent rm` verweigert die Entfernung eines dirty Worktrees (`WhisperM8/CLI/AgentCLICommand.swift:119-133`, `WhisperM8/CLI/AgentCLICommand.swift:415-425`, `WhisperM8/Services/AgentChats/AgentWorktreeManager.swift:39-68`). AC-34/AC-35 erwähnen dieses sichtbare Opt-in, Branch-/Pfadmodell und den Schutz vor Datenverlust nicht.

**Ergänzung:** Eigener AC-Punkt oder explizite Erweiterung von AC-34/35 mit Create, Fortsetzung im Worktree, UI-Anzeige, Takeover-cwd und dirty-remove-Guard.

#### P1 — Sidebar-Usage fehlt

Die Sidebar besitzt getrennte Claude- und ChatGPT/Codex-Usage-Popovers. Claude lädt alle eingeloggten Profile, Codex zeigt primäre/sekundäre/scoped Limits (`WhisperM8/Views/AgentUsagePopovers.swift:3-49`, `WhisperM8/Views/AgentUsagePopovers.swift:129-215`, `WhisperM8/Views/AgentUsagePopovers.swift:220-255`). AC-46 erwähnt nur profilbezogene Usage in den Account-Settings; die produktive Sidebar-Funktion und der Codex-Fallback fehlen.

#### P1 — Agent-Chats-Settings sind nur indirekt inventarisiert

Nutzer können Fertig-/Awaiting-Benachrichtigungen, Completion-Sound und Terminal-Bell (`WhisperM8/Views/Settings/Pages/AgentChatsSettingsPage.swift:178-270`), Claude-/Codex-Extra-Args (`WhisperM8/Views/Settings/Pages/AgentChatsSettingsPage.swift:390-435`) sowie Hook-Bridge, externe Hook-Diagnose und Hook-Preview (`WhisperM8/Views/Settings/Pages/ClaudeHooksSettingsPage.swift:5-105`) steuern. AC-39/44 beschreiben Runtime-Verhalten, aber nicht vollständig die sichtbaren Einstellungen und ihre Defaults/Previews. Diese Settings sind bei Environment-, Hook- und Modulrefactors reale Regressionstore.

#### P1 — Claude-Theme-Sync fehlt und widerspricht der Read-only-Abgrenzung

Themewechsel synchronisieren Claudes Theme debounced in `~/.claude/settings.json` (`WhisperM8/Support/ThemeManager.swift:67-90`, `WhisperM8/Services/AgentChats/ClaudeThemeWriter.swift:83-158`). Das Inventar behauptet als Querschnittsinvariante externe Claude-Daten seien read-only und nennt nur Account-Move als Ausnahme (`feature-inventar-agentchats.md:524-528`). Entweder muss Theme-Sync als bewusst gesicherte Ausnahme mit Backup/Parse-Fail-Guard inventarisiert oder aus dem Produkt entfernt werden; als aktuelles Inventar ist die Aussage unvollständig.

#### P2 — GPT-Kontextfenster ist nur als Nebeninvariante erfasst

Die GPT-Settings besitzen inzwischen ein sichtbares, persistiertes `CLAUDE_CODE_AUTO_COMPACT_WINDOW`-Feld (`WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:195-208`, `WhisperM8/Support/AppPreferences.swift:298-309`) und der Builder setzt es nur bei GPT-gestempelter Hauptsession (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:299-307`). AC-60 erwähnt den Environment-Wert, aber nicht die Nutzerfunktion, Validierung und Scope-Semantik. Das sollte als Teil von AC-57/60 explizit werden.

## 7. `test-specs-welle0-1.md`

### 7.1 Bestätigte Punkte

1. **Die Grundkonvention passt.** Closure-DI, kleine Protokolle, pure Mapper/Reducer, Temp-Verzeichnisse und testlokale Spies entsprechen dem Repo (`WhisperM8/Services/AgentChats/AgentSessionAutoNamer.swift:118-146`, `WhisperM8/Services/AgentChats/BackgroundAgentSpawner.swift:217-234`, `Tests/WhisperM8Tests/AgentSessionStatusCoordinatorTests.swift:9-68`).
2. **Cold-Load statt Registry-Scheinroundtrip ist richtig.** `AgentWorkspaceRepository` ist die passende Naht für einen echten Disk-Roundtrip (`WhisperM8/Services/AgentChats/AgentWorkspaceRepository.swift:29-47`, `WhisperM8/Services/AgentChats/AgentWorkspaceRepository.swift:82-102`).
3. **ManualClock/Sleeper und kontrollierbare Prozess-/PTY-Ereignisse sind für die Race-Tests notwendig.** Wanduhr-Sleeps würden B02, B07, B09 und B15 nicht deterministisch machen.
4. **Die Rot→Grün-Trennung ist richtig.** N03/N04/N05/N06 dürfen nicht als Charakterisierung des fehlerhaften Ist-Zustands eingefroren werden.
5. **B08, B13, B15, B16 und B17 formulieren beobachtbare Zustands-/Parserverträge statt UI-Pixeltests.** Das passt zur vorhandenen Trennung aus purem Reducer/Parser und manueller SwiftUI-/PTY-QA.
6. **A06 nutzt vorhandene Proxy-Closure-DI statt unnötig einen globalen Helper einzuführen.** Das entspricht der vorhandenen Proxy-Suite.

### 7.2 Mängel

#### P0 — Der Titel „Welle 0/1“ stimmt nicht mit der Abdeckung überein

Das Dokument enthält zahlreiche Welle-2/3-Tests B06–B17, lässt aber drei explizite Welle-1-Pakete vollständig oder weitgehend aus:

- `P1.1` Child-Environment/Profile/Secret-Canary (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:141-156`),
- `P0.4a` Headless-`--no-session-persistence`/Scratch-cwd/Profile für Auto-Namer und Summarizer (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:158-170`),
- `P1.6/P1.7/P1.9` Git-Stale-Result, WindowStore-Diff-Sideeffects und Transcript-Cache Hit/Miss/Move/Profile (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:172-184`).

A06 zum GPT-Proxy ist wertvoll, ersetzt diese Welle-1-Gates aber nicht.

**Erforderliche Korrektur:** Dokument entweder ehrlich in „Test-Specs Wellen 0–3, Teilmenge“ umbenennen oder vor Freigabe um mindestens B18–B22 für die fehlenden Welle-1-Verträge ergänzen.

#### P0 — C07-Oracle aus W0.1 fehlt

W0.1 verlangt C07 ausdrücklich (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:51-53`). A02 prüft nur den Happy-Path einer einzelnen `SessionStart`-Bindung. Es fehlen:

- zwei parallele lokale Launches mit vertauschter Hook-/Scan-Reihenfolge;
- bereits belegte externe ID;
- zwei Kandidaten im Zeitfenster;
- Fork-Parent-ID vor Child-ID;
- altes Launch-Event nach neuer Prozessinkarnation;
- gleiche nackte UUID in zwei Config-Roots.

Diese Fälle treffen genau die produktiven Lücken in Hook-Binder und Lazy-Binding (`WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:345-363`, `WhisperM8/Services/AgentChats/AgentSessionStore.swift:600-649`). Ohne sie ist der wichtigste Identitätsrefactor nicht test-first abgesichert.

#### P0 — H3 ist kein kompatibel definierter `ProcessRunnerSpy`

H3 soll Environment, Prozessidentität, Ready/Exit, Signale und Output beobachten (`test-specs-welle0-1.md:21`). Das vorhandene `ProcessRunner`-Protokoll besitzt aber nur executable, arguments, workingDirectory, timeout und ein fertiges Resultat; es exponiert weder Environment noch Handle oder Signale (`WhisperM8/Services/AgentChats/BackgroundAgentSpawner.swift:217-230`). Ein einzelner „vollständiger ProcessRunnerSpy“ kann daher B06/B07/B15 nicht gegen den bestehenden Vertrag ausführen.

**Erforderliche Korrektur:** Nicht das kleine vorhandene Protokoll zum God-Interface aufblasen. Zwei Nähte definieren:

- `OneShotProcessRunning` für argv/cwd/env/fertiges Resultat;
- `ControllableChildProcess` beziehungsweise Launcher-Closure für spawn identity, ready, exit und TERM/KILL.

Jeder Produktionspfad bekommt nur die minimale benötigte Naht.

#### P1 — A02 mischt normale und Background-Session

Das Setup beschreibt eine normale lokale Claude-Session, die Assertion verlangt aber zusätzlich, dass `SessionEnd` bei Background-Sessions den Watcher beendet (`test-specs-welle0-1.md:44-50`). Der Code führt diesen Watcher-Abschluss nur aus, wenn die konkrete Session ein Background-Chat ist und der Reducer wirklich `stopped` meldet (`WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:216-225`). Der Watcher ist im Coordinator zudem derzeit hart instanziiert und nicht injizierbar (`WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:47-52`, `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:71-92`).

**Korrektur:** Zwei Tests/Fixtures: normaler Chat mit `clear|resume|compact|other`-Matrix und Background-Chat mit Watcher-Spy. Dazu ein kleines Watcher-Protokoll oder minimale Closure-Nähte.

#### P1 — A03 friert zwei Ctrl-C als fachliche Invariante ein

A03 will richtigerweise keine 80/180-ms-Wartezeiten konservieren, fordert aber „genau zwei graceful Interrupt-Versuche“ (`test-specs-welle0-1.md:52-58`). Zwei Ctrl-C sind aktuelle Implementierung (`WhisperM8/Views/AgentTerminalView.swift:775-794`), nicht der Kernvertrag. B09 soll diesen Pfad gerade durch einen expliziten Exit-/Drain-Automaten ersetzen.

**Korrektur:** Charakterisierung auf „graceful Exit wird vor Eskalation versucht; keine Signale nach bestätigtem Exit; Snapshot nach finalem Drain genau einmal“ formulieren. Die Anzahl Ctrl-C nur dann exakt prüfen, wenn sie bewusst als Produktvertrag beschlossen wird.

#### P1 — B10 modelliert AppKit-Terminationsantwort falsch

B10 fordert nach `.terminateLater` einen späteren „Reply `.terminateNow`“ (`test-specs-welle0-1.md:182-190`). `applicationShouldTerminate` liefert einmalig `NSApplication.TerminateReply`; die spätere Bestätigung erfolgt über einen Bool-Reply an AppKit, nicht durch einen zweiten Rückgabewert derselben Methode. Der aktuelle Einstieg liefert direkt `.terminateNow` (`WhisperM8/WhisperM8App.swift:343-351`).

**Korrektur:** Spy-Vertrag `deferTermination()` plus `replyToTermination(shouldTerminate: Bool)` modellieren; Assertion: einmal `.terminateLater`, danach genau ein positives AppKit-Reply.

#### P1 — Test-first-Reihenfolge für harte Frameworktypen ist zu optimistisch

`AgentTerminalController` erzeugt `QuietableTerminalView` konkret und besitzt keine PTY-Injektion (`WhisperM8/Views/AgentTerminalView.swift:613-668`). `AgentSessionStatusCoordinator` erzeugt den Runtime-Watcher konkret (`WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:71-92`). H5/H6/H10 können daher nicht ohne verhaltensneutrale Produktnaht eingesetzt werden. Die Einführungsregel erwähnt das allgemein, sollte aber pro Test den vorausgehenden Seam-Change explizit benennen und separat reviewen.

#### P2 — `AgentTestSupport` nicht zum Sammelbecken machen

Der heutige Helper enthält geteilte Codex-Fixtures und zwei Temp-Helfer (`Tests/WhisperM8Tests/AgentTestSupport.swift:4-10`, `Tests/WhisperM8Tests/AgentTestSupport.swift:73-86`). H5 Audio, H7 Keychain und H8 Paste sind keine Agent-Chats-Helfer. Generische Temp-/Clock-Helfer können gemeinsam leben; subsystemnahe Spies sollten dateilokal oder in thematischen Test-Support-Dateien bleiben. Das erhält die bestehende Konvention kleiner, bedarfsgerechter Testnähte.

## 8. CLI-Host-Constraint

### 8.1 Ergebnis

**Keine der Kernempfehlungen verlangt einen SDK-Runtime- oder Eigen-UI-Ersatz der Claude-Code-CLI.** Die Sollpfade bleiben:

- echte Claude-/Codex-Prozesse im SwiftTerm-PTY (`WhisperM8/Views/AgentTerminalView.swift:749-771`),
- offizielle CLI-Flags über `AgentCommandBuilder` (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:164-180`, `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:353-430`),
- offizielle Claude-Hooks über launchspezifische `--settings` (`WhisperM8/Services/AgentChats/ClaudeHookSettingsBuilder.swift:3-7`, `WhisperM8/Services/AgentChats/ClaudeHookBridge.swift:65-96`),
- tolerantes read-only Discovery/Parsing der providerseitigen JSONL für History/Recovery.

Die GPT-Integration bleibt ebenfalls ein CLI-Host: Claude Code läuft weiter als echte CLI; WhisperM8 setzt nur Router-Environment und Modellflag (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:267-307`, `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:353-430`).

### 8.2 Abgrenzung

Die in Vergleichsdokumenten erwähnten Agent-SDKs dienen als Vertragsquelle, nicht als empfohlene Runtime. Das ist zulässig. Kritisch, aber **kein CLI-Host-Verstoß**, sind nur die vorgeschlagenen Schreiboperationen in externe Claude-History; sie sind eine Datenhoheits-/Repo-Leitplankenfrage und wurden in Abschnitt 4.2 separat markiert.

## 9. Verbindliche Nacharbeit vor „Go“

1. Ein gemeinsames Identitätsdokument mit capability-gegaterter Weg-A/Weg-B-State-Machine erstellen; die widersprüchlichen absoluten Aussagen entfernen.
2. Per-Launch Hook-Envelope/Eventpfad, Generation-Guard, Config-Root-Ableitung und Claim-API konkret spezifizieren.
3. `/branch`, `/rewind`, `/clear`, `/resume` und `/compact` als vollständige Laufzeit-Übergangsmatrix ergänzen; `SessionStart.source` parsen und testen.
4. JSONL-Fallback-Evidenz ohne erfundene Parent-Lineage definieren.
5. Agent-Inventar korrigieren: AC-41, AC-52 und AC-30 als aktuelle Lücken statt Ist-Invarianten; Snapshot-Privacy/Retention ergänzen.
6. Agent-Inventar um Worktree-Jobs, Sidebar-Usage, Agent-Chats-Settings, Theme-Sync und das sichtbare GPT-Kontextfenster ergänzen; Diktat-Inventar um CLI-Link und Skills ergänzen.
7. Test-Specs neu schneiden: W0/W1 vollständig, insbesondere C07, Child-Environment, Headless-Prävention und die drei Quick Wins; W2/3 separat kennzeichnen.
8. H3/H6/H10 als minimale Protokolle/Closures statt als universelle Spies präzisieren; A02, A03 und B10 korrigieren.
9. Sämtliche `Datei:Zeile`-Verweise nach Abschluss der laufenden GPT-Änderungen gegen den finalen Branch nachziehen.

Erst danach ist die Identitäts-/Recovery-Welle regressionsarm implementierbar. P0.1 „Headless-Junk stoppen“ und der nichtdestruktive Teil von P0.2 können als kleine, separat getestete Vorab-Changes vorbereitet werden; die eigentliche Bindungsarchitektur P0.3/P0.4 sollte bis zur Auflösung der P0-Punkte nicht begonnen werden.
