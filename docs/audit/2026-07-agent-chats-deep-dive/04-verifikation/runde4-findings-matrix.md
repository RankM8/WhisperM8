---
status: abgeschlossen
updated: 2026-07-19
description: Adversariale Runde-4-Verifikation der Findings-Matrix mit Fokus auf kritische und hohe Befunde.
---

# Runde 4: Verifikation der Findings-Matrix

## Einzelurteile

### Commit-Belege für als teilgefixt markierte Einträge

- **R3-MIX-G07 — Commit-Beleg vorläufig bestätigt:** `0bdff8f` führt den Managed Installer ein; `c6ac557`, `e445b65` und `1bd655f` ändern bzw. testen denselben Installer. Die Stat-Belege tragen damit die Matrixaussage einer Installer-Härtung; der offene Restvertrag wird unten am Code geprüft.
- **R3-LIVE-G01 — Commit-Beleg vorläufig bestätigt:** `17f76dc` ändert `AgentCommandBuilder.swift`, Präferenzen und passende Tests für das 272k-Kontextfenster. Die Stat-Belege decken genau den behaupteten Ebene-1-Teilfix ab; der offene Usage-Vertrag wird unten abgegrenzt.
- **Review-Fix-Abgleich:** `f50847e` betrifft ausschließlich Statusline-Installation/-UI, `9e4b9f4` und `0476181` den Headless-I/O-Pfad, `c6ac557`/`e445b65`/`1bd655f` primär den Managed Installer. Ihre Stats liefern keinen Beleg, dass andere C/N/G-Invarianten pauschal geschlossen wurden.

### Runde 1: vollständige Prüfung kritisch/hoch

| ID | Matrix-Schwere | Runde-4-Urteil | Selbst gelesener Beleg |
|---|---:|---|---|
| C01 | kritisch | **bestätigt** | Der Recordability-Guard endet vor Converter-, Datei- und Tap-Aufbau (`WhisperM8/Services/Dictation/AudioRecorder.swift:108-120`); unmittelbar vor `engine.start()` erfolgt keine erneute Formatprüfung (`WhisperM8/Services/Dictation/AudioRecorder.swift:146-159`). |
| C02 | hoch | **bestätigt** | Nach den Retry-/`await`-Punkten wird das einmal ermittelte `inputFormat` weiterverwendet; Tap-Installation und Neustart folgen ohne Revalidierung (`WhisperM8/Services/Dictation/AudioRecorder.swift:286-335`). |
| C04 | hoch | **widerlegt als offener Hoch-Defekt** | Zwar existiert die lokale Zeichenersetzung (`WhisperM8/Services/AgentChats/AgentSessionTranscript.swift:318-331`), aber ein Schema-Drift ist ausdrücklich durch einen Fallback abgefangen: Bei Direktmiss werden alle Projektordner geprüft und Treffer zusätzlich gegen das erwartete CWD validiert (`WhisperM8/Services/AgentChats/AgentSessionTranscript.swift:348-388`). Die Matrix verschweigt diesen Gegenbeleg. |
| C05 | hoch | **bestätigt, eng begrenzt** | Auto-Naming startet Claude weiterhin mit `-p` und ohne sichtbares Nicht-Persistenz-Argument (`WhisperM8/Services/AgentChats/AgentSessionAutoNamer.swift:132-146`). Die Headless-I/O-Fixes ändern diesen Aufrufvertrag nicht. |
| C06 | hoch | **bestätigt** | `spawn` bietet keinen Account-Profil-/Environment-Parameter (`WhisperM8/Services/AgentChats/BackgroundAgentSpawner.swift:78-88`); der Default-Runner baut stattdessen stets das allgemeine Login-Shell-Environment (`WhisperM8/Services/AgentChats/BackgroundAgentSpawner.swift:252-258`). |
| C10 | hoch | **teilbestätigt** | Der `@MainActor`-Registry-Pfad schläft beim App-Quit synchron 80 ms und 180 ms (`WhisperM8/Views/AgentTerminalView.swift:322-323,385-400`) und wird synchron aus `applicationShouldTerminate` aufgerufen (`WhisperM8/WhisperM8App.swift:359-367`). Das Main-Thread-Blocking ist bestätigt; ein konkret verlorener letzter Output ist an dieser Stelle nicht selbst belegt. |
| C12 | hoch | **bestätigt** | Innerhalb von `mutateWorkspace` werden für Indexeinträge wiederholt lineare Suchen in `workspace.sessions` und `workspace.projects` ausgeführt (`WhisperM8/Services/AgentChats/AgentSessionStore.swift:748-779,798-815`). |
| C13 | hoch | **bestätigt** | SwiftUI ruft den Refresh auf `onAppear`/`onChange` auf (`WhisperM8/Views/ProjectDetailPanel.swift:103-108`); der Initializer startet drei Git-Prozesse (`WhisperM8/Services/AgentChats/GitProjectStatus.swift:13-29`), jeweils mit synchronem `waitUntilExit()` (`WhisperM8/Services/AgentChats/GitProjectStatus.swift:34-45`). |

### Runde 2: vollständige Prüfung kritisch/hoch

| ID | Matrix-Schwere | Runde-4-Urteil | Selbst gelesener Beleg |
|---|---:|---|---|
| N01 | kritisch | **nicht bestätigt** | Der Controller exponiert `shellPid` (`WhisperM8/Views/AgentTerminalView.swift:630-633`), doch `terminate()` sendet über das konkrete Terminalobjekt und ruft dessen `terminate()` auf, nicht `kill(processID)` (`WhisperM8/Views/AgentTerminalView.swift:820-840`). Die gefundenen PID-Verwendungen dienen Ressourcenanzeige und Parent-Zuordnung (`WhisperM8/Views/AgentChatsView.swift:427-434`; `WhisperM8/Services/AgentChats/AgentJobWorkspaceSync.swift:119-123`). Aus den gelesenen Stellen folgt keine Fremdprozess-Terminierung. |
| N02 | hoch | **bestätigt** | Der früheste Quit-Hook sichert nur Terminal-Snapshots und antwortet sofort `.terminateNow`; ein Recorder-Finalisierungsgate ist dort nicht vorhanden (`WhisperM8/WhisperM8App.swift:359-367`). |
| N03 | hoch | **bestätigt** | `normalized` konstruiert weiterhin `Dictionary(uniqueKeysWithValues:)` direkt aus potenziell persistierten IDs (`WhisperM8/Services/Dictation/OutputModeStore.swift:145-162`); doppelte Schlüssel precondition-failen. |
| N04 | hoch | **bestätigt** | Ein einzelner Decode-Fehler fällt kollektiv auf `[]` zurück (`WhisperM8/Services/Dictation/OutputModeStore.swift:118-133`), worauf `modes` sämtliche geladenen Daten durch Built-ins ersetzt (`WhisperM8/Services/Dictation/OutputModeStore.swift:64-69`). |
| N05 | hoch | **bestätigt** | Das Repository decodiert, migriert und speichert jede veränderte Generation ohne Future-Version-Guard (`WhisperM8/Services/AgentChats/AgentWorkspaceRepository.swift:50-64`). Die Migration setzt sogar bedingungslos `currentSchemaVersion = 1` (`WhisperM8/Models/AgentChat.swift:602-605`; `WhisperM8/Services/AgentChats/AgentSessionStore.swift:1182-1186`). |
| N06 | hoch | **bestätigt** | `save` meldet Fehlschlag nur per Log und liefert keinen Erfolg zurück (`WhisperM8/Services/Shared/KeychainManager.swift:10-35`); der Migrationspfad löscht danach den UserDefaults-Wert ohne Readback (`WhisperM8/Services/Shared/KeychainManager.swift:61-66`). |
| N07 | kritisch | **teilbestätigt** | Der Launcher startet den Prozess und gibt unmittelbar dessen PID zurück; eine Acceptance-/Ready-Bestätigung oder explizite Detach-Grenze fehlt (`WhisperM8/Services/AgentChats/AgentSupervisorLauncher.swift:30-59`). Dass daraus tatsächlich ein hängender Waiter-Prozessbaum entsteht, ist aus dieser Stelle allein nicht bewiesen. |
| N08 | kritisch | **bestätigt** | Nach Stall-, `turn.failed`- und Exitcode-Prüfung wird jeder Exit 0 als `.done` abgebildet, auch ohne `lastMessage` oder explizite Turn-Finalität (`WhisperM8/Services/AgentChats/CodexTurnExecutor.swift:83-119`). |
| N09 | hoch | **bestätigt** | `processEnvironment` beginnt mit dem vollständigen Parent-Environment und entfernt nur `CLAUDE_CODE_*`, `CLAUDECODE` und `CLAUDE_CONFIG_DIR`; sonstige Secrets bleiben erhalten (`WhisperM8/Services/Shared/LoginShellEnvironment.swift:91-121`). |
| N10 | hoch | **bestätigt** | Das gelesene Keychain-Secret wird als Wert nach `-w` in das argv des `security`-Prozesses übernommen (`WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:363-377`). |
| N11 | hoch | **bestätigt** | Paste bindet ausschließlich an das zuvor erfasste App-Objekt, aktiviert dieses nach Delays und postet Cmd+V; ein Fenster-/Chat-/Intent-Identitätscheck fehlt (`WhisperM8/Services/Dictation/PasteService.swift:69-92`). |
| N12 | hoch | **bestätigt** | Orphan-Korrektur mutiert einen zuvor gelesenen Vollsnapshot und schreibt ihn best-effort ohne Lock/Transition-Guard zurück (`WhisperM8/Services/AgentChats/AgentJobStore.swift:249-273`). |
| N13 | hoch | **bestätigt** | Nach dem gelockten Claim wird der Supervisor gestartet und die PID per separatem `mutateState` gesetzt (`WhisperM8/Views/SubagentJobDetailView.swift:480-496`); `mutateState` ist ein ungeschütztes Vollsnapshot-Read-modify-write (`WhisperM8/Services/AgentChats/AgentJobStore.swift:133-142`), sodass ein parallel geschriebenes `running` überschrieben werden kann. |
| N14 | hoch | **bestätigt** | `requestStop` setzt zwar einen Supervisor-Latch, doch `runner.terminate()` ist ohne publizierten Prozess ein No-op (`WhisperM8/Services/AgentChats/AgentJobSupervisor.swift:44-56`; `WhisperM8/Services/AgentChats/CodexExecRunner.swift:327-335`). Der Prozess wird erst nach `run()` publiziert, ohne den Stop-Latch erneut anzuwenden (`WhisperM8/Services/AgentChats/CodexExecRunner.swift:276-286`). |
| N15 | hoch | **bestätigt** | Tool-Ergebnisse werden unabhängig von `blockID` stets dem ersten offenen Tool-Schritt zugeordnet (`WhisperM8/Services/AgentChats/TranscriptTimelineBuilder.swift:228-235`); parallele/interleavte Resultate können dadurch vertauschen. |
| N16 | hoch | **bestätigt** | Unbekannte Eventtypen enden kommentarlos in `default: return nil` (`WhisperM8/Services/AgentChats/CodexTranscriptReader.swift:186-199`) und werden durch `compactMap` ohne Parse-Outcome entfernt (`WhisperM8/Services/AgentChats/CodexTranscriptReader.swift:95-106`). |

### Runde 3: vollständige Prüfung kritisch/hoch

| ID | Matrix-Schwere | Runde-4-Urteil | Selbst gelesener Beleg |
|---|---:|---|---|
| R3-DEF-G01 | hoch | **bestätigt** | Der Exporter legt das generische Zielverzeichnis an und überschreibt `SKILL.md` atomar, ohne Ownership-Marker, Fremddatei-Guard oder Backup (`WhisperM8/Services/Shared/CLISkillExporter.swift:151-176`). |
| R3-PROXY-G01 | hoch | **bestätigt** | Nur `ensureRunning` hält `ensureLock` (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:218-225`); `stopIfSelfStarted` prüft getrennt unter `processLock`, stoppt Router und ersetzt den Handle (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:286-300`). Beide Sequenzen können interleaven. |
| R3-PROXY-G02 | hoch | **bestätigt** | Der produktive Serve-Launcher erzeugt lediglich einen Handle mit `isRunning`/`terminate` und installiert keinen Exit-Callback (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:550-567`). Ownership wird nur bei explizitem Replace/Discard bereinigt (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:454-475`). |
| R3-PROXY-G03 | hoch | **bestätigt** | Der Background-Pfad bereitet Settings vor und ruft unmittelbar `BackgroundAgentSpawner.spawn` auf, ohne Proxy-Guard oder Ready-Ticket (`WhisperM8/Views/AgentChatsView+BackgroundAgents.swift:73-95`); der Spawner besitzt zudem keinen Profil-/Environment-Parameter (`WhisperM8/Services/AgentChats/BackgroundAgentSpawner.swift:78-88`). |
| R3-PROXY-G04 | hoch | **bestätigt** | Backend-Enabled und Port werden vor der Detached-Arbeit gelesen und `ensureRunning` wird dort ausgeführt (`WhisperM8/Views/AgentSessionDetailView.swift:414-430`); zurück auf dem MainActor wird nur Existenz/Archivstatus der Session geprüft, nicht Toggle/Port/Generation (`WhisperM8/Views/AgentSessionDetailView.swift:453-465`). |
| R3-SEC-G01 | hoch | **bestätigt** | Reachability akzeptiert allein Loopback-HTTP 200, JSON-Content-Type und `{ "ok": true }` (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:482-524,527-547`). PID, Startzeit, Runtime-ID oder Challenge fehlen; ein kompatibel antwortender Fremdlistener erfüllt die Probe. |
| R3-SEC-G02 | hoch | **bestätigt** | Jede angenommene Verbindung wird ohne Client-Credential in `connections` registriert und gestartet (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:403-423`); Requests werden samt gefilterten Headern an den gewählten Upstream weitergereicht (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:534-575`). |
| R3-MIX-G01 | hoch | **nicht lokal bestätigt** | Der lokale Code belegt nur den Known-Good-Pin `0.1.21` (`WhisperM8/Services/AgentChats/ClaudeCodeProxyBinaryInstaller.swift:13-22`), nicht den behaupteten Verlust inkompatibler Thinking-Historie. Ohne Proxy-Quellcode oder lokale Fixture ist der Hoch-Befund gegen HEAD nicht eigenständig reproduzierbar; die Matrix sollte ihn als extern verifiziert statt als lokalen Codebeleg kennzeichnen. |
| R3-MIX-G03 | hoch | **nicht lokal bestätigt** | Auch für die behauptete `/count_tokens`-Unterschätzung belegt die angeführte Stelle ausschließlich den Versions-Pin `0.1.21` (`WhisperM8/Services/AgentChats/ClaudeCodeProxyBinaryInstaller.swift:13-22`). Im lokalen Router findet sich keine Usage-/Token-Übersetzung; damit fehlt ein selbst lesbarer lokaler Wirkbeleg. |
| R3-LIVE-G01 | hoch | **Teilfix bestätigt, Rest offen** | GPT-Tuning setzt nun `CLAUDE_CODE_AUTO_COMPACT_WINDOW` auf den konfigurierten Wert (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:328-344`). Im lokalen MixRouter existiert keine `usage`-/Token-Verarbeitung; die Codebasis belegt daher nur den deklarierten Fenster-Workaround, nicht einen geschlossenen Usage-Merge-/Golden-Test-Vertrag. |
| R3-TERM-G01 | hoch | **bestätigt, Duplikat** | App-Quit blockiert den `@MainActor` mit zwei `usleep`-Pausen (`WhisperM8/Views/AgentTerminalView.swift:322-323,385-400`). Das ist mechanisch C10 und kein zusätzlicher eigenständiger Defekt. |
| R3-TERM-G02 | hoch | **bestätigt** | Pro Session werden bis zu 2.000 Plaintext-Zeilen persistiert (`WhisperM8/Services/AgentChats/TerminalSnapshotStore.swift:14-29,48-60`); `save` hat weder TTL noch globales Byte-/Dateibudget (`WhisperM8/Services/AgentChats/TerminalSnapshotStore.swift:75-91`). |
| R3-TERM-G03 | hoch | **bestätigt, präzisiert** | Session-/Projekt-Löschung stößt Sidecar-Löschung tatsächlich asynchron an (`WhisperM8/Services/AgentChats/AgentSessionStore.swift:474-480,490-507`), doch `delete` verschluckt jeden I/O-Fehler und bietet weder Retry noch Tombstone (`WhisperM8/Services/AgentChats/TerminalSnapshotStore.swift:109-117`). Der Aufruf fehlt also nicht; nur die Garantie fehlt. |

### Mittlere/niedrige Findings und Fix-Stichproben

- **Nur gezählt:** 20 mittlere und 1 niedriges Finding. Gemäß Prüfauftrag wurden davon genau zwei inhaltlich geöffnet.
- **R3-MIX-G07 (mittel, teilgefixt) — Teilfix bestätigt:** Managed Download pinnt Version und SHA-256 (`WhisperM8/Services/AgentChats/ClaudeCodeProxyBinaryInstaller.swift:4-31`), aber der Manager bevorzugt weiterhin jedes gefundene PATH-Binary (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:318-329`). Die Stats von `0bdff8f`, `c6ac557`, `e445b65` und `1bd655f` betreffen den behaupteten Installer-Vertrag; „teilgefixt“ ist korrekt, nicht „geschlossen“.
- **R3-SEC-G03 (niedrig, offen) — bestätigt:** Das Proxy-Environment stammt aus dem allgemeinen Parent-basierten Resolver und entfernt beim Start `CCP_TRAFFIC_LOG` nicht (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:235-249`); der Basis-Resolver übernimmt das vollständige Parent-Environment (`WhisperM8/Services/Shared/LoginShellEnvironment.swift:91-107`).

### Zufallsstichprobe von acht offenen Einträgen

Reproduzierbare Auswahl mit Seed `40719`, ausschließlich aus ohnehin vollständig zu prüfenden kritischen/hohen offenen Einträgen: **R3-PROXY-G02, C04, N09, C02, N06, N01, N14, N16**. Die Detailurteile stehen in den Tabellen oben. Ergebnis: sechs bestätigt (R3-PROXY-G02, N09, C02, N06, N14, N16), zwei widerlegt/nicht bestätigt (C04, N01). Damit zeigt gerade die Gegenprobe, dass der Matrixstatus „offen“ nicht ungeprüft übernommen werden darf.

## Abschließende Urteilstabelle

| Klasse | Anzahl | Runde-4-Ergebnis | IDs |
|---|---:|---|---|
| Kritisch | 4 | 2 bestätigt, 1 teilbestätigt, 1 nicht bestätigt | bestätigt: C01, N08; teilbestätigt: N07; nicht bestätigt: N01 |
| Hoch | 33 | 28 bestätigt, 2 teilbestätigt, 3 widerlegt/nicht lokal bestätigt | teilbestätigt: C10, R3-LIVE-G01; widerlegt/nicht bestätigt: C04, R3-MIX-G01, R3-MIX-G03; alle übrigen Hoch-IDs bestätigt |
| Mittel | 20 | 1 Stichprobe teilgefixt bestätigt; 19 nur gezählt | C03, C07, C08, C09, C11, C14, C15, C16; R3-DEF-G02, R3-DEF-G03, R3-DEF-G04; R3-PROXY-G05; R3-SEC-G04; R3-MIX-G02, R3-MIX-G04, R3-MIX-G05, R3-MIX-G06, **R3-MIX-G07 geprüft**; R3-TERM-G04, R3-TERM-G05 |
| Niedrig | 1 | 1 Stichprobe bestätigt | **R3-SEC-G03 geprüft** |
| Gesamt | 58 | 37 kritisch/hoch vollständig geprüft; 21 mittel/niedrig gezählt, davon 2 geprüft | — |

## Die drei wichtigsten bestätigten Punkte

1. **Unauthentifizierte lokale OAuth-Capability:** Der Router nimmt Clients ohne Credential an und forwardet deren Requests an Upstreams (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:403-423,534-575`). Das bleibt ein Security-Ship-Blocker (R3-SEC-G02).
2. **API-Key-Migration kann die einzige Kopie löschen:** Ein Keychain-Writefehler wird nicht an den Aufrufer signalisiert, trotzdem wird der UserDefaults-Wert entfernt (`WhisperM8/Services/Shared/KeychainManager.swift:10-35,61-66`) (N06).
3. **Recorder-Start bleibt rennanfällig:** Recordability wird vor Converter-/Tap-Aufbau geprüft, aber nicht unmittelbar vor `engine.start()` (`WhisperM8/Services/Dictation/AudioRecorder.swift:108-120,146-159`) (C01).

## Gesamturteil

Die Matrix ist überwiegend belastbar, aber nicht unverändert freigabefähig: **C04** ist durch den CWD-validierten Glob-Fallback als offener Hoch-Defekt widerlegt, **N01** ist an den angegebenen Stellen nicht belegt, und **R3-MIX-G01/G03** verweisen lokal nur auf einen Versions-Pin statt auf den behaupteten Wirkmechanismus. **C10/N07** sind nur teilweise belegt. Die beiden als teilgefixt markierten Einträge haben passende Commit- und Codebelege; keiner ist vollständig geschlossen.
