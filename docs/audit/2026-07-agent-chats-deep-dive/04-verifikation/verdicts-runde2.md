# Verdicts Runde 2

Adversarial verifizierte Behauptungen aus der zweiten Audit-Runde (neue Findings N01–N16) sowie die Plan-Verifikation der Roadmap-Maßnahmen. Alle Urteile stammen aus einzelnen Verifikations-Jobs (siehe `jobId` je Eintrag); nichts hier ist ungeprüft übernommen.

## Teil A — Neue adversarial geprüfte Behauptungen (Runde 2)

| ID | Titel | Schweregrad | Urteil | Fundort |
|---|---|---|---|---|
| N01 | Veraltete Terminal-PID kann fremden Prozess beenden | kritisch | BESTAETIGT | `WhisperM8/Views/AgentTerminalView.swift:352-369,775-795,969-980` |
| N02 | App-Quit verliert laufende Diktataufnahmen | hoch | BESTAETIGT | `WhisperM8/WhisperM8App.swift:343-361` |
| N03 | Doppelte Output-Mode-ID löst Fatal Error aus | hoch | BESTAETIGT | `WhisperM8/Services/Dictation/OutputModeStore.swift:118-134,145-165` |
| N04 | Ein inkompatibler Eintrag kann alle Custom-Modi und Templates löschen | hoch | BESTAETIGT | `WhisperM8/Services/Dictation/OutputModeStore.swift:64-69,118-134` |
| N05 | Downgrade überschreibt neuere AgentSessions-Daten | hoch | BESTAETIGT | `WhisperM8/Services/AgentChats/AgentWorkspaceRepository.swift:33-47` |
| N06 | Fehlgeschlagene Keychain-Migration löscht den einzigen API-Key | hoch | BESTAETIGT | `WhisperM8/Services/Shared/KeychainManager.swift:10-35,37-69` |
| N07 | Detach-Supervisor bleibt vom Waiter-Prozessbaum abhängig | kritisch | BESTAETIGT | `WhisperM8/Services/AgentChats/AgentSupervisorLauncher.swift:30-60` |
| N08 | Unvollständiger Codex-Turn wird als Erfolg gespeichert | kritisch | BESTAETIGT | `WhisperM8/Services/AgentChats/CodexTurnExecutor.swift:83-120` |
| N09 | Agent-Prozesse erben fremde Secrets aus dem Parent-Environment | hoch | BESTAETIGT | `WhisperM8/Services/Shared/LoginShellEnvironment.swift:91-137` |
| N10 | Claude-OAuth-Secret steht beim Profil-Rename in argv | hoch | BESTAETIGT | `WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:326-342,363-377` |
| N11 | Auto-Paste kann vertrauliches Diktat in den falschen Chat senden | hoch | BESTAETIGT | `WhisperM8/Services/Dictation/PasteService.swift:69-92` |
| N12 | Veraltete Orphan-Korrektur kann fertigen Job überschreiben | hoch | BESTAETIGT | `WhisperM8/Services/AgentChats/AgentJobStore.swift:133-180,249-275` |
| N13 | UI-Composer kann running wieder auf spawning zurücksetzen | hoch | BESTAETIGT | `WhisperM8/Views/SubagentJobDetailView.swift:461-503` |
| N14 | Frühes Stop-Signal geht vor Prozessregistrierung verloren | hoch | BESTAETIGT | `WhisperM8/Services/AgentChats/AgentJobSupervisor.swift:44-57,133-166` |
| N15 | Parallele Tool-Ergebnisse werden falschen Aufrufen zugeordnet | hoch | BESTAETIGT | `WhisperM8/Services/AgentChats/TranscriptTimelineBuilder.swift:98-99,228-251` |
| N16 | Aktuelle Codex-Events verschwinden ohne Hinweis aus Transkripten | hoch | BESTAETIGT | `WhisperM8/Services/AgentChats/CodexTranscriptReader.swift:95-107,112-199` |

Keine der 16 neuen Behauptungen in Runde 2 wurde als Fehlalarm widerlegt — alle 16 sind bestätigt (2× kritisch, 14× hoch).

### N01 — Veraltete Terminal-PID kann fremden Prozess beenden

BESTAETIGT, allerdings nur über ein Race: Im stabilen Endzustand wählt die UI `.start` statt `.restart` (`WhisperM8/Views/AgentChatsView.swift:2615-2641`). Entsteht `.restart` jedoch noch während `isRunning == true` und beendet sich der Prozess vor der Verarbeitung in `WhisperM8/Views/AgentSessionDetailView.swift:372-379`, ruft `restartTerminal()` ungeprüft `terminate()` auf der Registry auf (Zeilen 563-565), die immer den Controller-`terminate()` aufruft (`WhisperM8/Views/AgentTerminalView.swift:367-369) — ohne erneute Prüfung, ob die zwischenzeitlich vergebene PID noch demselben Prozess gehört.

### N02 — App-Quit verliert laufende Diktataufnahmen

BESTAETIGT. Der jederzeit verfügbare Quit-Button ruft direkt `terminate(nil)` auf (`WhisperM8/Views/MenuBarView.swift:113-116`); der App-Delegate sichert dabei nur Agent-Terminal-Snapshots und antwortet sofort mit `.terminateNow` (`WhisperM8/WhisperM8App.swift:343-351`), während `applicationWillTerminate` lediglich Audio-Ducking beendet und den Fensterzustand flusht (`WhisperM8/WhisperM8App.swift:354-360`). Eine laufende Aufnahme landet als temporäre M4A-Datei (`WhisperM8/Services/Dictation/AudioRecorder.swift:132-150`), wird aber nicht vor dem Quit gesichert oder abgeschlossen.

### N03 — Doppelte Output-Mode-ID löst Fatal Error aus

BESTAETIGT: `OutputMode.init(from:)` übernimmt jede ID ohne arrayweite Eindeutigkeitsprüfung (`WhisperM8/Models/OutputMode.swift:98-117`), während `loadModes()` das vollständige Array unverändert dekodiert und zurückgibt (`WhisperM8/Services/Dictation/OutputModeStore.swift:126-134`). Die anschließende Normalisierung übergibt alle nicht stillgelegten Einträge ungeprüft an `Dictionary(uniqueKeysWithValues:)` (`OutputModeStore.swift:64-69`) — bei doppelter ID ist das ein garantierter Laufzeitabsturz.

### N04 — Ein inkompatibler Eintrag kann alle Custom-Modi und Templates löschen

BESTAETIGT: `OutputModeStore` dekodiert das komplette `[OutputMode]`-Array als eine Einheit und liefert bei jedem Decoding-Fehler `[]` zurück; dieser leere Wert wird sofort durch die Built-in-Modi ersetzt (`WhisperM8/Services/Dictation/OutputModeStore.swift:64-69,126-134`). Jede folgende Moduseinstellung speichert diesen bereinigten Ersatzbestand zurück (`WhisperM8/Views/Settings/Models/OutputModesViewModel.swift:204-212`) und überschreibt die Datei atomar, aber ohne Backup (`OutputModeStore.swift:81-90`) — ein einziger inkompatibler Eintrag reißt damit alle Custom-Modi und zugehörigen Templates mit.

### N05 — Downgrade überschreibt neuere AgentSessions-Daten

BESTAETIGT: `AgentWorkspace` akzeptiert jede ganzzahlige `schemaVersion` ohne Obergrenzenprüfung; Root- und Session-Decoder werten ausschließlich ihre bekannten `CodingKeys` aus, ein unbekannter `kind` wird sogar explizit zu `nil` (`WhisperM8/Models/AgentChat.swift:83-89,305-337,405-441,577-603`). Der produktive Store injiziert `migratedWorkspace`, das die Version ohne Future-Schema-Guard stets auf `currentSchemaVersion == 1` setzt (`WhisperM8/Services/AgentChats/AgentWorkspaceStore.swift:32ff`) — ein Downgrade auf eine ältere App-Version liest eine neuere Datei klaglos ein und kann sie beim nächsten Save mit Datenverlust überschreiben.

### N06 — Fehlgeschlagene Keychain-Migration löscht den einzigen API-Key

BESTAETIGT: `KeychainManager.save` ist `Void` und behandelt jeden erfolglosen Security-Status ausschließlich per Log, ohne Fehlerkanal an den Aufrufer (`WhisperM8/Services/Shared/KeychainManager.swift:10,30-34`). Der Migrationspfad ruft `save` auf, entfernt den Legacy-Wert danach bedingungslos und gibt ihn trotzdem zurück (`KeychainManager.swift:61-66`); der In-Memory-Cache wird nur bei erfolgreichem Speichern gesetzt (`KeychainManager.swift:30-31`). Kein Aufrufer fängt diesen stillen Fehlschlag ab — schlägt `save` fehl, ist der API-Key nach der Migration weg.

### N07 — Detach-Supervisor bleibt vom Waiter-Prozessbaum abhängig

BESTAETIGT: `AgentSupervisorLauncher.swift:44-59` startet `agent-supervise` als direktes `Process`-Kind und gibt sofort nach `process.run()` dessen PID zurück, ohne Ready- oder Detach-Handshake. Der Aufrufer persistiert diese PID bereits als erfolgreichen Start (`AgentCLICommand.swift:515-535`) und beginnt den Wait-Poll (`AgentCLICommand.swift:451-459`), während das Kind `setsid()` erst deutlich später erreicht — nach Entry-Point, Async-Bridge und Dispatch (`CLIEntryPoint.swift:53-64,91-96`, `AgentSuperviseCommand.swift`). Bis dahin hängt der Supervisor faktisch am Prozessbaum des Waiters und stirbt mit, wenn dieser vorzeitig endet.

### N08 — Unvollständiger Codex-Turn wird als Erfolg gespeichert

BESTAETIGT: Der Runner übernimmt nur `terminationStatus`, nicht `terminationReason` (`WhisperM8/Services/AgentChats/CodexExecRunner.swift:267-271`); `turn.completed` wird zwar an den Sink weitergereicht, aber im Ergebniszustand nicht persistiert, weil dieser nur Thread-ID und `turn.failed` aus den Events erfasst (`CodexExecRunner.swift:379-386,493-500`). Der Executor liefert nach `stalled == false`, fehlendem `turn.failed` und Exit-Code 0 bedingungslos `.done` — selbst wenn `lastMessage == nil` ist (`WhisperM8/Services/AgentChats/CodexTurnExecutor.swift:83-120`). Ein abgebrochener, aber sauber terminierter Turn ohne finale Nachricht wird damit als Erfolg gebucht.

### N09 — Agent-Prozesse erben fremde Secrets aus dem Parent-Environment

BESTAETIGT: `LoginShellEnvironment.processEnvironment` kopiert das vollständige Basis-Environment und entfernt nur `CLAUDE_CODE_*`, `CLAUDECODE`, `CLAUDE_CONFIG_DIR` sowie `NO_COLOR`; Cloud-Credentials und `SSH_AUTH_SOCK` bleiben unangetastet (`WhisperM8/Services/Shared/LoginShellEnvironment.swift:91-137`, belegt durch `Tests/WhisperM8Tests/LoginShellEnvironmentTests.swift:45-50,118-158`). `AgentTerminalController.start` übergibt dieses Environment unverändert an Claude, Codex oder jeden anderen gespawnten Prozess — Secrets aus dem Elternprozess (z. B. AWS/GCP-Tokens, SSH-Agent-Socket) sickern damit in jede Agent-Session durch.

### N10 — Claude-OAuth-Secret steht beim Profil-Rename in argv

BESTAETIGT, Fundort leicht verschoben gegenüber der Ursprungsangabe: Der Runner in `WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:326-342` sammelt stdout; der Rename liest das Keychain-Secret tatsächlich in Zeile 363-367 mit `find-generic-password ... -w`. Bei erfolgreichem, nichtleerem Ergebnis wird `trimmedSecret` in Zeile 371-377 direkt hinter `-w` in ein Argument-Array eingesetzt; der Runner überträgt dieses Array in Zeile 328-336 unverändert nach `Process.arguments`, ohne Umweg über stdin und ohne Redaction. Das OAuth-Secret ist damit für jeden Prozess, der die Argumentliste einsehen kann (z. B. `ps`), im Klartext sichtbar. Der einzige UI-Guard verhindert nur laufende Sessions während des Renames, adressiert die argv-Exposition aber nicht.

### N11 — Auto-Paste kann vertrauliches Diktat in den falschen Chat senden

BESTAETIGT: Die ursprüngliche Agent-Session wird beim Aufnahmestart ins Context-Bundle übernommen und beim Stop eingefroren (`WhisperM8/Services/Dictation/RecordingCoordinator.swift:125,174,289`), aber die tatsächliche Auslieferung verwendet nur `OverlayController.previousApp`, eine prozessweite, zum Auslieferungszeitpunkt aktuelle `NSRunningApplication` (`WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:84`). Wechselt der Nutzer während der Transkription/Nachbearbeitung den Fokus auf ein anderes Fenster/eine andere Chat-Session, landet das Diktat dort statt im ursprünglich adressierten Kontext.

### N12 — Veraltete Orphan-Korrektur kann fertigen Job überschreiben

BESTAETIGT: `correctIfOrphaned` arbeitet mit einem zuvor gelesenen Vollsnapshot und schreibt ihn nach der PID-Prüfung direkt als `failed` zurück (`WhisperM8/Services/AgentChats/AgentJobStore.swift:243-263`); `writeState` ersetzt dabei das gesamte JSON per Rename, ohne Re-Read oder Compare-and-Swap (`AgentJobStore.swift:118-130`). Der advisory `flock` schützt zwar den Folgeturn-Claim (`AgentJobStore.swift:161-180`, `WhisperM8/CLI/AgentCLICommand.swift:178-186`), wird aber weder von der Orphan-Korrektur noch von der parallel möglichen erfolgreichen Fertigstellung des Jobs respektiert — ein zwischenzeitlich echt abgeschlossener Job kann so rückwirkend auf `failed` überschrieben werden.

### N13 — UI-Composer kann running wieder auf spawning zurücksetzen

BESTAETIGT: Der UI-Pfad reserviert den Folgeturn nur innerhalb des Locks (`WhisperM8/Views/SubagentJobDetailView.swift:481-484`), startet danach das Kind und setzt die PID außerhalb des Locks (Zeilen 492-496). `mutateState` liest und schreibt dabei einen vollständigen Snapshot ohne eigenen Lock (`WhisperM8/Services/AgentChats/AgentJobStore.swift:133-142`), während das gestartete Kind seinerseits `running` samt eigener PID unter Lock persistiert (`WhisperM8/Services/AgentChats/AgentJobSupervisor.swift:77-87`). Der sichere CLI-Schwesterpfad schützt diese Sequenz korrekt — der UI-Composer-Pfad nicht, wodurch ein Lost-Update den Status `running` auf `spawning` zurücksetzen kann.

### N14 — Frühes Stop-Signal geht vor Prozessregistrierung verloren

BESTAETIGT: SIGTERM führt zu `requestStop`, das nur `stopRequested` setzt und `terminate()` aufruft (`WhisperM8/CLI/AgentSuperviseCommand.swift:20-33`, `WhisperM8/Services/AgentChats/AgentJobSupervisor.swift:44-57`); ist `process` zu diesem Zeitpunkt noch nicht veröffentlicht, kehrt `terminate()` wirkungslos zurück (`WhisperM8/Services/AgentChats/CodexExecRunner.swift:327-335`). Auslöseszenario: Nach Veröffentlichung von Running-State und Supervisor-PID (`AgentJobSupervisor.swift:81-87`), aber noch vor der Zuweisung `self.process = process`, geht ein in diesem Fenster eintreffendes Stop-Signal folgenlos verloren — der Job läuft trotz Stop-Anforderung weiter.

### N15 — Parallele Tool-Ergebnisse werden falschen Aufrufen zugeordnet

BESTAETIGT: Die gemeinsamen Block-Typen speichern für Tool-Aufruf und Tool-Resultat keine Korrelations-ID (`WhisperM8/Models/AgentChatTranscript.swift:96-103`). Der Claude-Reader ignoriert `tool_use.id` und `tool_result.tool_use_id` (`WhisperM8/Services/AgentChats/ClaudeTranscriptReader.swift:173-177,211-214`), der Codex-Reader ignoriert `call_id` (`WhisperM8/Services/AgentChats/CodexTranscriptReader.swift:153-170) — obwohl reale Fixtures diese Felder enthalten (`Tests/WhisperM8Tests/AgentTestSupport.swift:53-56`). Ohne diese IDs werden Ergebnisse bei parallelen Tool-Aufrufen positionsbasiert zugeordnet, was bei Interleaving zu falschen Zuordnungen in der Timeline-Darstellung führt.

### N16 — Aktuelle Codex-Events verschwinden ohne Hinweis aus Transkripten

BESTAETIGT: Die Switches im Codex-Reader akzeptieren nur `event_msg`/`response_item`, darin jeweils nur zwei bzw. vier bekannte Typen; alle anderen Fälle liefern per Default `nil` (`WhisperM8/Services/AgentChats/CodexTranscriptReader.swift:112-145,151-199`). `readTail` entfernt diese `nil`-Werte per `compactMap` ohne jede Telemetrie; der Voll-Reader zählt `skipped` nur bei ungültigem JSON, nicht bei erkannten, aber unbehandelten Event-Typen (`CodexTranscriptReader.swift:65-84,95-107`). Weder Cache, Timeline noch UI bieten einen Ersatzmechanismus oder eine Warnung — neuere/geänderte Codex-Event-Typen verschwinden lautlos aus dem angezeigten Transkript.

## Teil B — Plan-Verifikation der Roadmap-Maßnahmen

| ID | Maßnahme | Welle | Urteil |
|---|---|---|---|
| P0.1+P0.2 | ObjC-Exception-Trampolin und Format-Re-Check einführen sowie Configuration-Change-Handler nach jedem await re-validieren | Welle 1 — Crash & Quick Wins | NACHBESSERN |
| P0.3 | AudioRecorder isolieren und Geräte-Snapshots sowie Observable-Mutationen threadsicher machen | Welle 2 — Datenintegrität & Claude-Erlebnis | NACHBESSERN |
| P0.4 | Headless-Junk-Sessions verhindern, Scratch-cwd setzen und vorhandene Root-Sessions migrieren | Welle 2 — Datenintegrität & Claude-Erlebnis | NACHBESSERN |
| P0.5 | Claude-Projektpfad-Encoding korrigieren und gecachten Glob-Fallback für Unicode- und Langpfade ergänzen | Welle 1 — Crash & Quick Wins | NACHBESSERN |
| P0.6+P1.3+P1.4 | Session-Bindung durch Zeitfenster, Eindeutigkeit, Row-Dedup und vorab vergebene Session-ID deterministisch machen sowie Bindungsverlust sichtbar melden | Welle 2–3 — Datenintegrität, Claude-Erlebnis, Performance & Bindung | NACHBESSERN |
| P0.7+P1.12 | PTY-Teardown asynchron nach Exit-Output ausführen und Terminal mit Scrollback, Eskalation sowie SwiftTerm-Rebase härten | Welle 2–4 — Datenintegrität bis Struktur | NACHBESSERN |
| P0.8 | Workspace-Save-Debounce um eine harte maximale Speicherfrist ergänzen | Welle 1 — Crash & Quick Wins | VERWERFEN |
| P1.1+P1.2 | Account-Profile in alle Spawn- und Lifecycle-Pfade durchreichen und Background-Status mit dem Supervisor reconciliaten | Welle 2 — Datenintegrität & Claude-Erlebnis | NACHBESSERN |
| P1.5+P1.8 | Session-Merge indizieren und vom MainActor lösen sowie Body-Evaluation, Workspace-Indizes und Sidebar-Projektionen optimieren | Welle 3 — Performance & Bindung | NACHBESSERN |
| P1.6+P1.7+P1.9 | Git-Status asynchron laden, WindowStore-Mutationen diff-gaten und Codex-Transcript-Lookups cachen | Welle 1 — Crash & Quick Wins | NACHBESSERN |
| P1.10 | Formatter cachen, Index-Läufe koordinieren, Scan-Gründe priorisieren, Scroll-Monitor teilen, Workspace vorwärmen und Change-Callbacks revisionssicher machen | Welle 3 — Performance & Bindung | NACHBESSERN |
| P1.11 | JSONL-Parser mit Schema-Drift-Telemetrie, versionierten Golden Files, Degradations-Matrix sowie Tests für cd und Resume-ID-Rotation härten | Welle 4 — Struktur | FEHLER (kein Verifikations-Ergebnis vorhanden) |
| P2.1+P2.2 | Terminal-Registry und Controller nach Services verschieben sowie Background-Dispatch und Index-Refresh aus View-Extensions extrahieren | Welle 3–4 — Performance & Bindung sowie Struktur | NACHBESSERN |
| P2.3+P2.4 | AgentSessionStore durch UIStateStore und pure Merge-Planung entlasten sowie Indexer auf gemeinsamen JSONL-Scanner und Date-Parser konsolidieren | Welle 4 — Struktur | NACHBESSERN |
| P2.5+P2.6 | SwiftPM schrittweise in Foundation und AgentChatsKit modularisieren sowie Singleton-Zuwachs durch AppPreferences-Injektions-Seams stoppen | Welle 4–5 — Struktur sowie Modularisierung & Produkt-Backlog | NACHBESSERN |
| P2.7 | LOC-Budget, aktualisiertes Refactoring-Audit, Werte-Hierarchie und einheitlichen PhpStormLauncher als Guardrails etablieren | Welle 4 — Struktur | NACHBESSERN |
| P2.8a | Worktree-Task-Flow, Remote-Signal bei Eingabebedarf und aggregierte Diff-Sicht pro Session produktisieren | Welle 5 — Modularisierung & Produkt-Backlog | NACHBESSERN |
| P2.8b | AUHAL-Recorder und lokale Transkription evaluieren sowie Clipboard-Snapshot, Paste-Fallback und Dateisystem-als-Registry-Grundsatz umsetzen | Welle 5 — Modularisierung & Produkt-Backlog | NACHBESSERN |

Ergebnis: Von 18 geprüften Maßnahmen-Paketen 16× NACHBESSERN, 1× VERWERFEN (P0.8), 1× FEHLER — für P1.11 liegt kein verwertbares Verifikations-Ergebnis vor (leere `begruendung`, leere `jobId`); dieses Paket muss separat nachverifiziert werden. Kein Paket wurde als uneingeschränkt TRAGFAEHIG bestätigt.

### P0.1+P0.2 — ObjC-Exception-Trampolin und Format-Re-Check einführen sowie Configuration-Change-Handler nach jedem await re-validieren

NACHBESSERN: Beide Probleme sind real: Der Format-Snapshot aus `AudioRecorder.swift:107-120` bleibt bis `installTap`/`engine.start` in Zeilen 155-159 unverifiziert, und `handleConfigurationChange` arbeitet nach den awaits in Zeilen 271, 287 und 339 ohne erneute Session-/Engine-Prüfung weiter; `AudioFormatDecision.swift:19-21` und Commit 90c4fab bestätigen nur den bisherigen 0-Hz-Spezialfall. P0.1 ist überversprochen: Die angegebene `WM8CatchException(void(^)(void))`-Signatur besitzt keinen Fehlerkanal für eine `throws`-Brücke, ein synchroner Trampolin schützt nicht die später ausgeführte Tap-Closure und deren Converter-/Datenpfad.

### P0.3 — AudioRecorder isolieren und Geräte-Snapshots sowie Observable-Mutationen threadsicher machen

NACHBESSERN — das Kernproblem ist real: `AudioRecorder.startRecording()` (`AudioRecorder.swift:33`) läuft nonisolated auf dem globalen Executor und liest `availableDevices` an den Zeilen 82/94 gegen den Main-Actor-Write in `AudioDeviceManager.swift:173-175`; Zeile 302 ist dagegen bereits durch `handleConfigurationChange()` (Zeile 251) main-isoliert. Die Maßnahme übersieht den wichtigeren indirekten Read über `AudioRecorder.swift:68` → `AudioDeviceManager.selectedDeviceID` → `AudioDeviceManager.swift:71` sowie den CoreAudio-Callback-Race auf `currentDefaultDeviceID` (Zeilen 28/30 gegen Zeile 33). Ein pauschales `@MainActor` würde weitere Hot-Path-Blockaden erzeugen und muss selektiver angesetzt werden.

### P0.4 — Headless-Junk-Sessions verhindern, Scratch-cwd setzen und vorhandene Root-Sessions migrieren

NACHBESSERN — der Befund ist real: Auto-Namer und Summarizer persistieren Claude- und Codex-Hilfsläufe (`AgentSessionAutoNamer.swift:139-146`, `AgentSessionSummarizer.swift:32-39`), während `AgentHeadlessCLI.swift:28-37` kein cwd setzt und die Indexer diese Läufe importieren. Der aktuelle Bestand ist bereits von 495 auf 496 Root-Rows gewachsen; die in der Roadmap genannte Zahl ist damit nur eine Momentaufnahme. Der pauschal vorgeschlagene `/`-Prune würde legitime Root-Projekte regressieren, die über `AgentChatsView+ProjectManagement.swift:29-40` ausdrücklich erlaubt sind, und widerspricht der eigentlich geforderten signaturbasierten Migration.

### P0.5 — Claude-Projektpfad-Encoding korrigieren und gecachten Glob-Fallback für Unicode- und Langpfade ergänzen

NACHBESSERN — der Kernbefund ist real: `encodeClaudeCwd` akzeptiert Unicode (`AgentSessionTranscript.swift:320-331`), Claude 2.1.214 verwendet jedoch ASCII, und der Watcher deaktiviert den rettenden Fallback (`AgentSessionRuntimeWatcher.swift:372-385`). Der vorgeschlagene ASCII-Fix ist korrekt, aber ein buchstäblich einmaliger Glob-Versuch kann vor Dateierzeugung verpuffen; zudem laufen erste Auflösungen aktuell synchron auf dem MainActor (`AgentSessionRuntimeWatcher.swift:157-159,178-182`), während ein positiver URL-Cache bereits existiert (Zeilen 339-363,397). Unvollständig behandelt bleibt insbesondere der Account-Umzug-Fall.

### P0.6+P1.3+P1.4 — Session-Bindung durch Zeitfenster, Eindeutigkeit, Row-Dedup und vorab vergebene Session-ID deterministisch machen sowie Bindungsverlust sichtbar melden

NACHBESSERN: Die referenzierten Kernprobleme sind real: Der Retry-Binder hat nur eine Untergrenze, keinen Belegtheits-/Ambiguitätscheck (`AgentSessionStore.swift:621-636`), und Claude startet bei `hasLaunchedInitialPrompt` ohne ID leer statt zu stoppen (`AgentCommandBuilder.swift:290-345`). P0.6 selbst ist teilweise veraltet: Merge-Fenster von ±5s und Index-Input-Dedup existieren bereits (`AgentSessionStore.swift:749-785,823-847`), aber persistierte Doppel-Rows bleiben bestehen (Zeilen 803-889); außerdem ist `createdAt` kein echter Launch-Zeitpunkt (Zeile 622, `AgentSessionDetailView.swift:583-600`), was die vorgeschlagene Zeitfenster-Logik unterläuft.

### P0.7+P1.12 — PTY-Teardown asynchron nach Exit-Output ausführen und Terminal mit Scrollback, Eskalation sowie SwiftTerm-Rebase härten

NACHBESSERN: Das zugrundeliegende Problem ist real: `terminate()` blockiert den MainActor 260 ms und snapshotet vor den wartenden Exit-Bytes (`AgentTerminalView.swift:775-820`; SwiftTerm `LocalProcess.swift:124-150`); App-Quit blockiert ebenfalls (`WhisperM8App.swift:343-352`), Stop-all sogar N×260 ms, und die referenzierten Fix-Commits f448e02/a26d29f sind korrekt gegengeprüft. Der vorgeschlagene Fix greift aber zu kurz: Ein bloßes `Task.sleep` oder Capture in `processTerminated` reicht nicht, da Exit-Callback und PTY-Drain nicht geordnet sind — `terminal.terminate()` schließt I/O, sendet bereits SIGTERM und cancelt den Exit-Monitor (`LocalProcess.swift:515-523,540ff`), was eine sauberere Sequenzierung als geplant erfordert.

### P0.8 — Workspace-Save-Debounce um eine harte maximale Speicherfrist ergänzen

VERWERFEN in der vorliegenden Form: Der Produktions-Store nutzt bereits `.debounced(0.5)` (`AgentWorkspaceStore.swift:324-333`) und begrenzt jede Dirty-Periode bereits über `firstDirtyAt` auf 2 Sekunden (Zeilen 48-52, 258-273); die zugrundeliegende Behauptung aus `swiftui-architektur.md:87,97-98` ist damit veraltet. Zutreffend sind nur die Quit-Pfade (`AgentWorkspaceStore.swift:79-98,189-205`); eine reale Restlücke ist der fehlende automatische Retry nach Persistenzfehlern (Zeilen 235-240). P0.8 sollte höchstens als kleinere Härtung neu formuliert werden (Deadline per Policy injizierbar machen, Fehler-Retry ergänzen), nicht als eigenständige Maßnahme bestehen bleiben.

### P1.1+P1.2 — Account-Profile in alle Spawn- und Lifecycle-Pfade durchreichen und Background-Status mit dem Supervisor reconciliaten

NACHBESSERN — das Problem ist real: Background-Stubs verlieren den Profilstempel (`AgentChatsView+BackgroundAgents.swift:47-59`), `ProcessRunner` kennt keine Overrides (`BackgroundAgentSpawner.swift:223-258`), und Lifecycle/Health-Check sowie Auto-Namer/Summarizer laufen mit bereinigtem Main-Environment (`BackgroundAgentLifecycle.swift:124-171`, `AgentSessionAutoNamer.swift:132-146`, `AgentSessionSummarizer.swift:27-40`), während der PTY-Pfad korrekt merged (`AgentTerminalView.swift:758-765`). P1.1 ist aber unvollständig: Die Profil-Roots müssen auch durch `SupervisorJobReader.swift:34-38` und die Active-Background-Agent-Pfade durchgereicht werden — die Maßnahme deckt derzeit nicht alle betroffenen Stellen ab.

### P1.5+P1.8 — Session-Merge indizieren und vom MainActor lösen sowie Body-Evaluation, Workspace-Indizes und Sidebar-Projektionen optimieren

NACHBESSERN — das Problem ist real: Der MainActor umfasst den Merge in `AgentScanCoordinator.swift:138-143`, während `AgentSessionStore.swift:765-767,791,803,823-847` wiederholt linear sucht und `AgentWorkspaceStore.swift:121-147` dabei den globalen Lock hält. P1.5 muss alle Aufrufer berücksichtigen, insbesondere den Diktat-Hotpath in `RecordingCoordinator+Transcription.swift:238-245`; ein Off-Main-Merge darf zudem erst nach der in P1.10 geplanten geordneten Store-Revision erfolgen, sonst kann `AgentWorkspaceUIModel.swift`/`AgentWorkspaceStore.swift:292-304` einen veralteten Snapshot veröffentlichen.

### P1.6+P1.7+P1.9 — Git-Status asynchron laden, WindowStore-Mutationen diff-gaten und Codex-Transcript-Lookups cachen

NACHBESSERN: Alle drei Teilprobleme sind real: Synchrone Git-Spawns blockieren den MainActor (`ProjectDetailPanel.swift:105-131`, `GitProjectStatus.swift:13-45`), No-op-Mutationen publizieren und speichern `state` unnötig (`AgentWindowStore.swift:901-905`; Trigger `AgentChatsView+RuntimeServices.swift:75-94`), und Codex-Lookups laufen rekursiv im Diktatpfad (`CodexTranscriptReader.swift:36-53,90-92`, `RecordingCoordinator.swift:279-282`). P1.6 braucht zusätzlich pfad-/generation-geprüfte Ergebnisse, sofortiges Leeren alten Status und sicheres Drainage-/Timeout-Verhalten; sonst kann ein langsamer alter Task einen neueren Status überschreiben.

### P1.10 — Formatter cachen, Index-Läufe koordinieren, Scan-Gründe priorisieren, Scroll-Monitor teilen, Workspace vorwärmen und Change-Callbacks revisionssicher machen

NACHBESSERN: Die Teilmaßnahmen (a), (c), (d) und (f) adressieren reale Probleme in `ClaudeSessionIndexer.swift:209-213`, `CodexSessionIndexer.swift:130-134`, beiden Transcript-Readern, `AgentScanCoordinator.swift:78-99` und `AgentTerminalView.swift:218-319`; beim Formatter-Fix müssen zwei statische Formatter mit und ohne Fractional-Seconds erhalten bleiben. Teilmaßnahme (b) ist veraltet: Der einzige aktive Load→Index→Save-Pfad steht in `AgentScanCoordinator.swift:131-136`; `AgentChatsView+RuntimeServices.swift:107-155` hat keinen Aufrufer mehr, und `AgentSessionDetailView.swift:407-414,642-666` speichert den lokal erweiterten Cache bereits ausdrücklich anders als in der Maßnahme beschrieben.

### P1.11 — JSONL-Parser mit Schema-Drift-Telemetrie, versionierten Golden Files, Degradations-Matrix sowie Tests für cd und Resume-ID-Rotation härten

FEHLER: Für dieses Maßnahmen-Paket liegt kein Verifikations-Ergebnis vor — weder Begründung noch Job-ID wurden übermittelt. Das Urteil ist damit nicht belastbar; P1.11 muss in einem eigenen Verifikations-Lauf nachgeholt werden, bevor es in die Roadmap-Bewertung einfließen kann.

### P2.1+P2.2 — Terminal-Registry und Controller nach Services verschieben sowie Background-Dispatch und Index-Refresh aus View-Extensions extrahieren

NACHBESSERN — P2.1 adressiert eine reale Schichtenverletzung; die Referenzen `AgentTerminalView.swift:323,614` sind zutreffend, aber neben den vier genannten Service-Dateien hängt auch `AgentCommandBuilder.swift:12` an einem View-definierten Typ, und nur drei Zugriffe besitzen bereits Closure-Seams. Der vorgeschlagene Move ist so nicht target-tauglich: `AgentTerminalController` hängt weiterhin an `QuietableTerminalView`, KeyboardHandler, ScrollGuard, LinkInterceptor, Palette und Grid-Fokus (`AgentTerminalView.swift:617-624,674-714,736-741,874-896`) — bleiben diese unter Views, scheitert die geplante Trennung; werden sie mitverschoben, entstehen neue Kopplungsprobleme, die die Maßnahme nicht adressiert.

### P2.3+P2.4 — AgentSessionStore durch UIStateStore und pure Merge-Planung entlasten sowie Indexer auf gemeinsamen JSONL-Scanner und Date-Parser konsolidieren

NACHBESSERN — beide Probleme sind real: `AgentSessionStore.swift:29-126` enthält fremdes UI-Sidecar-I/O, und `:598-890,909-1040,1187-1217` umfangreiche Binding-/Merge-/Repair-Policies; die Indexer-Schleifen `ClaudeSessionIndexer.swift:53-100` und `CodexSessionIndexer.swift:29-78` sind strukturell dupliziert, aber nicht wortgleich. P2.3 muss atomare Anwendung garantieren: Ein außerhalb des Locks aus `current` berechneter `[Mutation]`-Plan könnte parallele Änderungen verlieren, entgegen der Lock-Disziplin in `AgentWorkspaceStore.swift:111-149` und dem Regressionstest `AgentWorkspaceStoreTests.swift:114-152`; ohne diese Absicherung ist die Entlastung nicht risikofrei umsetzbar.

### P2.5+P2.6 — SwiftPM schrittweise in Foundation und AgentChatsKit modularisieren sowie Singleton-Zuwachs durch AppPreferences-Injektions-Seams stoppen

NACHBESSERN — das Problem ist real, aber die Zählung in `refactor-roadmap.md:372` ist falsch: Es existieren 28 echte `static … shared =`-Deklarationen; der im Audit genannte Wert 29 zählt `ClaudeAccountProfiles.swift:230` (`sharedItems`) fälschlich mit, während die versteckten Preference-Abhängigkeiten in `AgentSessionStore.swift:521-522,733-734,913-914` und `AgentSessionStatusCoordinator.swift:12-20` korrekt belegt sind. P2.5 ist in der vorgeschlagenen Form nicht buildfähig: `Logger.swift:32-34` hängt an `AppPreferences`, `AgentCommandBuilder.swift:39-58` an `CodexStatusProbe` aus dem Dictation-Modul (`CodexSupport.swift:152`) — die geplante Modultrennung müsste diese Cross-Modul-Abhängigkeiten zuerst auflösen.

### P2.7 — LOC-Budget, aktualisiertes Refactoring-Audit, Werte-Hierarchie und einheitlichen PhpStormLauncher als Guardrails etablieren

NACHBESSERN — die vier Teilprobleme sind real: `AgentChatsView.swift` umfasst inzwischen 3070 LOC statt der nach Phase 2 erwarteten 2426, das Refactoring-Audit ist mit 30.736 LOC/115 Dateien veraltet (`docs/refactor/REFACTORING-AUDIT.md:8,20`), eine Wertehierarchie fehlt, und `openInPhpStorm` dupliziert den vorhandenen Launcher (`AgentChatsView.swift:2760-2790`; `PhpStormLauncher.swift:8-49`). Ein sofortiger CI-Fail über 2500 LOC würde jede laufende Pipeline sofort brechen; keine frühere Maßnahme entfernt vorab die nötigen ~570 Zeilen, und `PerfBudgets` warnt bislang nur, statt hart zu blocken (`PerformanceSignposts.swift:62-69,117-119`) — ein CI-Gate braucht daher eine vorgeschaltete Reduktionsphase.

### P2.8a — Worktree-Task-Flow, Remote-Signal bei Eingabebedarf und aggregierte Diff-Sicht pro Session produktisieren

NACHBESSERN — das Problem ist real, aber die Maßnahme ist zu grob geschnitten: Der Codex-Subagent-Pfad erzeugt bereits Worktree und Branch (`AgentWorktreeManager.swift:39`, `AgentCLICommand.swift:119`), arbeitet im Worktree (`AgentJobSupervisor.swift:100`), zeigt bereits einen Diff-Zähler (`SubagentJobDetailView.swift:402`) und schützt Dirty-Cleanup (`AgentCLICommand.swift:415`); Setup-Hook und Merge-/PR-Pfad fehlen tatsächlich noch. Claudes separater `isolation: worktree`-Flow muss dabei erhalten bleiben und darf durch die Vereinheitlichung nicht kollabiert werden — die Maßnahme sollte in klar getrennte Teilschritte zerlegt werden.

### P2.8b — AUHAL-Recorder und lokale Transkription evaluieren sowie Clipboard-Snapshot, Paste-Fallback und Dateisystem-als-Registry-Grundsatz umsetzen

NACHBESSERN — AUHAL, lokales STT und Clipboard-Schutz adressieren reale Lücken (`AudioRecorder.swift:101-176,219-345`, `TranscriptionProvider.swift:5-83`, `PasteService.swift:90-117`), der Registry-Teil beschreibt dagegen keinen belegten Defekt: `AgentJobStore.swift:229-247`, `AgentSessionIndexer.swift:71-109` und `TranscriptRunReportStore.swift:274-299` rekonstruieren bereits aus Primärdaten. Die Maßnahme sollte in separate Tickets zerlegt werden: AUHAL zunächst hinter einem `AudioRecordingBackend`-Interface prototypisieren (mit Prüfung von AAC-Ausgabe, Pegel, Ducking, Gerätewahl und Gerätewechsel während laufender Aufnahme) statt als Einzelmaßnahme neben den bereits funktionierenden Registry-Grundsätzen zu bündeln.
