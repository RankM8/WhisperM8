---
status: aktiv
updated: 2026-10-17
description: Regressions-Oracle der Agent-Laufzeit auf Stand a8e0f35 — neue und korrigierte Einträge gegenüber dem Juli-Inventar (Hook-Bridge, Send-Guard, Queue, Crash-Recovery, Background-Agents, Subagent-Jobs, Terminal).
---

# Regressions-Oracle: Agent-Laufzeit (Stand a8e0f35)

## Leseregel

Das Oracle beschreibt Verhalten, das kein Fix unbeabsichtigt ändern darf. Die Einträge des Juli-Inventars (`AC-24` bis `AC-44`) gelten weiter, sofern sie hier nicht ersetzt werden; ein „(aktualisiert)"-Eintrag ersetzt die Juli-Fassung vollständig. Einstiegspunkte sind `pfad:zeile` auf `a8e0f35` (Pfade relativ zu `WhisperM8/`). „Befund-Bezug" nennt die LR-IDs aus `findings.jsonl`; ein Befund ist ein bekannter Fehler, kein Soll-Verhalten. Nicht ersetzte Juli-Einträge (u. a. `AC-24`, `AC-26`, `AC-27`, `AC-31` bis `AC-36`, `AC-38`, `AC-40`, `AC-43`) sind stichprobenhaft gegen den Code geprüft und inhaltlich unverändert; nur ihre Zeilennummern sind verschoben (z. B. `AgentSessionRuntimeWatcher.watch` jetzt bei 145, `AgentTerminalRegistry.startController` bei 371).

## Aktualisierte Juli-Einträge

### AC-30 (aktualisiert) · Terminal-Endsnapshot entfällt

- **Funktion:** Es gibt keinen Terminal-Endsnapshot und keinen Offline-Fallback aus einem Plaintext-Sidecar mehr. `TerminalSnapshotStore`, `TerminalSnapshotView` und der Terminal-Modus sind gelöscht; der Verlauf kommt ausschließlich aus dem Transcript (`TranscriptTextRenderer`, `TranscriptTextView`).
- **Einstiegspunkt:** `Views/AgentTerminalView.swift:432` (`captureAllSnapshotsForAppQuit`, historischer Name), `Views/AgentTerminalView.swift:963` (`captureSnapshotForAppQuit`). Beide tun nur noch graceful Ctrl+C und `flushPendingOutput`, sie speichern nichts.
- **Sichtbares Verhalten:** Nach Stop oder Quit zeigt ein Chat seinen Verlauf aus dem JSONL. Das Verzeichnis `TerminalSnapshots/` wird einmalig von `LegacyDataCleanup` entfernt (Flag `terminalSnapshotsPurged`).
- **Erhaltungsinvarianten:** Das App-Quit-Anhalten (2x Ctrl+C mit gemeinsamer Wartezeit, dann Flush gepufferter PTY-Bytes) bleibt, damit die TUI ihren Resume-Hinweis und den letzten JSONL-Flush schafft. Der im Juli offene Privacy-/Retention-Punkt (Plaintext-Sidecars) ist mit dem Wegfall des Sidecars erledigt und darf nicht durch einen neuen Buffer-Auslese-Pfad zurückkehren.
- **Befund-Bezug:** `LR-DOK-006` (Doku beschreibt abgelöste Transcript-Pfade); `LR-TRM-001` (Quit/Alle-stoppen blockiert den Main Thread).

### AC-37 (aktualisiert) · Takeover eines Codex-Jobs in einen interaktiven PTY

- **Funktion:** Überführt einen ruhenden Job in den normalen Codex-Resume-Pfad der App.
- **Einstiegspunkt:** `Views/AgentChatsView+Subagents.swift:19` (`takeOverSubagentJob`), `Services/AgentChats/AgentJobStore.swift:176` (`transition`), `Services/AgentChats/AgentJobState.swift:130` (`canTransition`), `Services/AgentChats/AgentCommandBuilder.swift:407` (`codexCommand`).
- **Sichtbares Verhalten:** „Übernehmen" öffnet den Job als interaktiven Codex-Chat im Job-cwd (bei Worktree-Jobs im Worktree); der Disk-State wird `takenOver` und bleibt terminal.
- **Erhaltungsinvarianten:** Der Vorcheck existiert jetzt: aktive Jobs (`spawning`/`running`) werden vor dem Übergang mit `invalidTransition` abgewiesen, die Übergangstabelle verweigert zusätzlich bei parallelem `agent send`. Reale Codex-Thread-ID und gültiges cwd sind Voraussetzung; nach Takeover startet kein `agent send` mehr. Die Session-Felder werden erst NACH dem Disk-Übergang repariert — scheitert die Reparatur, bleibt der Job `takenOver` ohne spiegelnde Session-Felder; das ist Ist-Verhalten, kein Soll.
- **Befund-Bezug:** `LR-AK-024`, `LR-AK-031` (Zustandsüberschreibungen), `LR-AU-001`.

### AC-39 (aktualisiert) · Launch-spezifische Claude-Settings (Hooks plus Fragmente)

- **Funktion:** Erzeugt pro lokaler Session EINE 0600-Settings-Datei und eine Event-JSONL und injiziert `--settings <pfad>` in Claude-Starts bzw. vor `--bg`. Die Datei enthält nicht mehr nur Hooks, sondern das Merge aus: Hook-Fragment, Send-Guard (zweiter `UserPromptSubmit`-Eintrag), GPT-Modellkatalog, Worker-Env (nur interne Aufrufer) und für Zusatzprofile das Memory-Fragment `autoMemoryDirectory`.
- **Einstiegspunkt:** `Services/AgentChats/AgentSessionStatusCoordinator.swift:198` (`prepareLaunchSettings`), `Services/AgentChats/ClaudeHookBridge.swift:86` (`prepareSettingsFile`), `Services/AgentChats/ClaudeHookSettingsBuilder.swift:42` (`makeSettings`), `:114` (`merged`), `:137` (`write`), `Services/AgentChats/AgentCommandBuilder.swift:751` (`backgroundSpawnArguments`).
- **Sichtbares Verhalten:** Status, Eingabebedarf und reale Claude-ID kommen ohne Polling. Ist die Hook-Bridge abgeschaltet (`claudeHooksEnabled`), entsteht trotzdem eine Datei, sofern Fragmente vorliegen (`includeHooks: false`); sind beide Teile leer, wird nichts geschrieben und der Launch läuft ohne `--settings`.
- **Erhaltungsinvarianten:** Registriert sind genau `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PermissionRequest`, `Stop`; `Notification` bleibt aus. Claude nimmt nur ein `--settings`: Fragmente werden tief gemergt, ein vom Nutzer übergebenes `--settings` wird beim `--bg`-Spawn durch die interne Datei ersetzt. Die Event-Datei wird bei jedem Prepare leer neu angelegt (0600). Bei IO-Fehler fällt der Launch auf „ohne Bridge" zurück, nie auf Abbruch. Agent View, Terminal und Background-Attach bekommen keine zweite Bridge.
- **Befund-Bezug:** `LR-AK-017`/`LR-SH-011` (andere Schreiber globaler Claude-Dateien), `LR-AK-020` (Fork-Events über dieselbe Datei).

### AC-28 / AC-41 (Hinweis, unverändert gültig, Lücken weiter offen)

- `AC-28`: Ein gestarteter Claude-Chat ohne gebundene ID startet weiterhin ohne `--resume` frisch (`Services/AgentChats/AgentCommandBuilder.swift:561-578`, `:704-707`; `Views/AgentSessionDetailView.swift:532-545`) — Befund `LR-AK-021`, kein Soll-Verhalten.
- `AC-41`: `bindExternalSessionID` (`Services/AgentChats/AgentSessionStatusCoordinator.swift:706`) prüft weiterhin nicht, ob dieselbe externe ID schon an eine andere lokale Zeile gebunden ist (alt `C07`). Ein künftiger Fix muss `binding_fork_ignored`/`binding_postponed` und `ClaudeExternalIDRecovery` (`Services/AgentChats/ClaudeExternalIDRecovery.swift:13`) erhalten.

## Neue Einträge seit Juli

### F-AC-09 · Wiederaufnahme laufender Chats nach Absturz

- **Funktion:** Stirbt die App unsauber (Absturz, SIGKILL), enden alle PTY-Chats per SIGHUP. Ein Marker führt die Sessions mit laufendem PTY; beim nächsten Start werden sie zur Wiederaufnahme vorgemerkt.
- **Einstiegspunkt:** `Services/AgentChats/AgentCrashRecovery.swift:23` (Marker), `:59` (`beginRun`), `:106` (Planer), `:129` (`AgentCrashRecoveryCoordinator.start`), `WhisperM8App.swift:336` (Start), `:428-432` (`applicationShouldTerminate` ruft `endRunCleanly`), `Views/AgentTerminalView.swift:353` (`onRunningSetChanged`).
- **Sichtbares Verhalten:** Nach einem Absturz tragen die damals laufenden, nicht archivierten Chats `shouldLaunchOnOpen` und starten, sobald ihr Tab angezeigt wird (wie `chats resume`); fehlende Tabs kommen ohne Auswahlwechsel zurück. Cmd+Q, Menü „Beenden", `make dev`/`make kill` (SIGTERM über `NSApp.terminate`) zählen als sauber und lassen keinen Marker liegen. Log `crash_recovery_resumed`.
- **Erhaltungsinvarianten:** Marker `running-sessions.json` enthält PID, Session-IDs, Zeitstempel. Lebt die PID eines vorhandenen Markers (zweite Instanz), bleibt er unangetastet und `beginRun` liefert nichts. Nach `endRunCleanly` legen späte `record`-Aufrufe (PTY-Exits während des Quits) den Marker nicht neu an. Nur `chat` und `backgroundChat` werden wieder aufgenommen, nie `agentView`, `terminal` oder `subagentJob`. Gestoppte Chats stehen nicht im Marker. Kill-Switch `agentCrashRecoveryEnabled` (Default an) verwirft die Wiederaufnahme, übernimmt den Marker aber weiter.
- **Befund-Bezug:** keiner direkt; berührt `LR-TRM-001` (Quit-Pfad) und `LR-AK-021` (Resume ohne gebundene ID).

### F-AC-10 · Send-Guard gegen doppelt zugestellte Prompts

- **Funktion:** Verhindert, dass die Claude-CLI einen bereits zugestellten `[via whisperm8 chats]`-Prompt nach einem ESC-Abbruch aus dem Composer erneut abschickt (Vorfall 17.08.2026).
- **Einstiegspunkt:** `Services/AgentChats/SendDeliveryTokenStore.swift:82` (`stage`), `:104` (`consume`), `:159` (`ChatsPromptGuard.decide`), `:205` (`PromptGuardRetryProbe`), `Services/AgentChats/ClaudeHookSettingsBuilder.swift:87` (`promptGuardCommand`), `Services/AgentChats/ClaudeHookBridge.swift:107-115` (Einbau, Kill-Switch), `CLI/ChatsPromptGuardCommand.swift:35-60` (Hook-Prozess), `Services/AgentChats/AgentSessionStatusCoordinator.swift:371` (`handlePromptGuardBlock`), Stage-Aufrufer `Services/AgentChats/AgentControlRequestHandler.swift:196` und `Services/AgentChats/AgentPromptQueueDelivery.swift:69`.
- **Sichtbares Verhalten:** Eine legitime Erst-Zustellung läuft durch. Eine Wiedervorlage ohne frisches Token wird mit Exit 2 geblockt (Begründung auf stderr); die App nimmt das irrtümliche „working" zurück (`turnAborted`) und leert nach ~0,5 s den Composer (Ctrl+C). Ein Retry nach nachgewiesenem Modellfehler („Prompt is too long") passiert ohne Token.
- **Erhaltungsinvarianten:** Hook läuft NACH dem Append-Hook, damit das Event-Tracking auch für geblockte Prompts vollständig bleibt. Token = Hash des whitespace-normalisierten Prompts, TTL 30 min, Uhr-Drift-Kappe 60 s, Dateien 0600 in `send-tokens/`. Nur Prompts mit dem Präfix `[via whisperm8 chats` werden geprüft; alles andere und jeder Parse-/IO-Fehler im Hook ist Exit 0 (fail-open). Der Transcript-Tail der Probe ist auf 256 KB begrenzt. Nur Claude (Codex hat keine Hooks). Kill-Switch `chatsPromptGuardEnabled` (Default an) lässt den Guard-Hook weg.
- **Befund-Bezug:** `LR-AK-026` (Token-IO-Fehler blockiert eine Erstzustellung, widerspricht Fail-open), `LR-AK-027` (Token mehrfach konsumierbar), `LR-AK-018` (Queue-Zustellung nutzt denselben Token-Pfad).

### F-AUT-01 (Laufzeit-Teil) · Prompt-Queue für Folgeaufträge

- **Funktion:** Vormerken von Folgeaufträgen je Chat, die am Turn-Ende zugestellt werden (Verwaltungsbefehle liegen im ausgeklammerten `CLI/Chats*`).
- **Einstiegspunkt:** `Services/AgentChats/AgentPromptQueueStore.swift:49` (`enqueue`), `:68` (`reserveNext`), `:81` (`markDelivered`), `:92` (`markFailed`), `:124` (`reconcileOnLaunch`), `:149` (`read`), `Services/AgentChats/AgentPromptQueue.swift:93` (reine Logik), `Services/AgentChats/AgentPromptQueueDelivery.swift:29` (`deliverNext`), `:40` (`deliverNow`), `Services/AgentChats/AgentSessionStatusCoordinator.swift:596` (Aufruf bei `turnCompleted`), `WhisperM8App.swift:333` (Reconcile beim Start).
- **Sichtbares Verhalten:** Nach dem Turn-Ende wartet die Queue ~0,6 s, prüft Session, laufende PTY und Status `idle`, pastet den Auftrag mit Marker-Zeile und submittet ihn. Ist der Chat nicht bereit, bleibt der Auftrag mit Fehlertext und `retry` in der Queue.
- **Erhaltungsinvarianten:** Höchstens einmal: `delivering` wird vor dem Paste persistiert; nach App-Ende dazwischen wird der Auftrag beim Start `unknown` (kein Auto-Retry, bleibt sichtbar). Reservierung, Guards und Paste laufen in einem MainActor-Durchlauf ohne `await`. Kein Zustellen bei `awaitingInput` (sonst würde der Auftrag als Antwort auf die Rückfrage gelesen). FIFO nach monotoner `sequence`, nie nach Uhr; `nextDeliverable` liefert nichts, solange ein Auftrag `delivering` ist. Abgeschlossene Aufträge werden nach einer Stunde entfernt, `unknown` bleibt. Jede Zustellung schreibt `queue-deliver` ins Audit-Log. Datei: `agent-prompt-queue.json`.
- **Befund-Bezug:** `LR-AK-018` (Persistenzfehler werden nicht gemeldet, Decode-Fehler wird als leere Queue zurückgeschrieben), `LR-AK-020` (Fork-Stop kann eine Zustellung auslösen).

### F-AC-06 (Ergänzung zu AC-42) · Heilung eines hängenden „working"

- **Funktion:** Ein ESC-Interrupt feuert keinen Stop-Hook; vor dem ersten Output fehlt auch der Transcript-Marker. Zwei Stufen verhindern ein dauerhaftes „working".
- **Einstiegspunkt:** `Services/AgentChats/AgentSessionStatusCoordinator.swift:458` (`suspectTurnAborted`), `:474` (`verifyAbortSuspicion`), `:431`/`:440` (`hookSilentHealSeconds`, `shouldHealSilentHookWorking`), `:123` (`abortVerifySeconds`), Auslöser ESC im Terminal `Views/AgentChatsView+Shortcuts.swift:59` (ausgeklammert).
- **Sichtbares Verhalten:** Nach ESC oder `chats interrupt` wird nach 5 s auf „ruhig" gesetzt, wenn weder ein Hook-Event kam noch die Transcript-mtime wuchs. Zusätzlich heilt ein stilles Netz: Decider meldet idle, Zustand working und mehr als 180 s ohne Hook-Event ergibt `turnAborted`.
- **Erhaltungsinvarianten:** Ein ESC mit anderer TUI-Bedeutung (Menü zu, Rewind-Picker) bleibt folgenlos, weil der Verdacht nur bei fehlender Aktivität bestätigt wird. `awaitingInput` wird nie geheilt (Permission-Dialoge sind legitim still). Nur hook-live Sessions im Zustand working werden verdächtigt.
- **Befund-Bezug:** `LR-AK-019` (Watcher nach ID-Umbindung am alten Transcript, beeinflusst die mtime-Prüfung), `LR-AK-020`.

### F-AC-06 (Ergänzung) · Alarm-Stufen der Sidebar überlagern Ton und Mitteilungen

- **Funktion:** Eine dreistufige Glocken-Einstellung (alles an, Ton aus, alles aus) überlagert Fertig-Ton, Mitteilungen und Voice-Callouts, ändert aber nie die gespeicherten Einstellungen und nie die Status-Erkennung.
- **Einstiegspunkt:** `Services/AgentChats/AgentAlertLevel.swift:8` (Enum), `:36` (`applied(to:)`), `Services/AgentChats/AgentSessionStatusCoordinator.swift:12` (`AgentStatusPreferences.current`), `:582` (`perform(_:sessionID:)`).
- **Sichtbares Verhalten:** Bei „Ton aus" schweigen Fertig-Ton und Callouts, Mitteilungen bleiben; bei „alles aus" zusätzlich Mitteilungen (Fertig, Rückfrage, Subagent) und Terminal-Glocke.
- **Erhaltungsinvarianten:** Hooks bleiben unberührt; Effekte entstehen nur aus Zustandswechseln (keine Doppelmeldung je Übergang); „Ton aus" wird übersprungen, wenn es nichts stumm zu schalten gibt.
- **Befund-Bezug:** keiner.

### F-AUT-05 · Claude-Hooks-Einstellungen und Fremd-Hook-Erkennung

- **Funktion:** Schalter und Diagnose für die Hook-Bridge; erkennt Nutzer-Hooks, die auf denselben Events feuern und nach Aktivierung der App-Mitteilungen doppelt melden würden.
- **Einstiegspunkt:** `Views/Settings/Pages/ClaudeHooksSettingsPage.swift:5` (Seite), `Support/AppPreferences.swift:722` (`claudeHooksEnabled`), `Services/AgentChats/ExternalClaudeHooksInspector.swift:27` (`inspectUserSettings`), `:48` (`overlappingHooks`), `Services/AgentChats/AgentSessionStatusCoordinator.swift:5` (`hooksEnabled` im Snapshot).
- **Sichtbares Verhalten:** Statuszeile „Session hooks active/disabled", Schalter „Use session hooks" (Wirkung erst nach Chat-Neustart), Legende der Statusfarben, Liste überlappender Fremd-Hooks, Erklärtext. Ohne Hooks fällt der Status auf das Transcript zurück (gröber, keine Rückfrage-Erkennung, keine Mitteilungen).
- **Erhaltungsinvarianten:** Die globale `~/.claude/settings.json` und `settings.local.json` werden nur gelesen, nie verändert; Fremd-Hooks werden nur angezeigt. Fehlende oder inkompatible Dateien ergeben keine Funde statt Fehler.
- **Befund-Bezug:** `LR-AK-017`/`LR-SH-005` (andere Schreiber derselben Fremddateien widersprechen dem Versprechen „stays untouched" der Seite).

### F-AC-11 (Ergänzung zu AC-31 bis AC-33) · Resume-Attach-Fallback für Background-Agents

- **Funktion:** Läuft das Resume-Ziel einer normalen Claude-Session gerade als Background-Agent beim Supervisor (z. B. per `/background`), baut der Builder statt `--resume` ein `claude attach <short-id>`.
- **Einstiegspunkt:** `Services/AgentChats/AgentCommandBuilder.swift:170` (`backgroundWorkerShortIDResolver`), `:670-700` (Fallback, Log `resume_attach_fallback`), `Services/AgentChats/SupervisorRosterReader.swift:36` (`activeWorkerShortID`), `:54` (`workers(fromRosterData:)`), `:76` (`defaultIsProcessAlive`).
- **Sichtbares Verhalten:** Der Chat öffnet sich am laufenden Worker statt mit Fehler „currently running as a background agent" abzubrechen. Die Hook-Bridge wird dabei nicht gestartet.
- **Erhaltungsinvarianten:** Quelle ist `<config-dir>/daemon/roster.json` des passenden Profils, der Worker gilt nur bei lebender PID; solche Sessions haben KEIN `jobs/`-Verzeichnis, `SupervisorJobReader` sieht sie nicht. `--resume --fork-session` bleibt für Background-Sessions erlaubt (Forks bleiben Forks). Der Fallback entfernt die GPT-Kontext-Env-Schlüssel wie der reguläre Attach. Fremdformat-Lesen ist profilbewusst und muss bei fehlender oder kaputter Datei lautlos auf `--resume` zurückfallen.
- **Befund-Bezug:** `LR-AK-022` (Background-Logs blockieren am Pipe-Puffer), `LR-AK-020`.

### F-AC-12 (Ergänzung zu AC-34, schließt Inventarlücke) · Worktree-Jobs

- **Funktion:** `whisperm8 agent run --worktree` führt den Job in einem frischen Git-Worktree statt in-place.
- **Einstiegspunkt:** `CLI/AgentCLICommand.swift:122-133` (Anlage im Job-Ordner `worktree/`), `:415-425` (`rm` mit Dirty-Guard), `Services/AgentChats/AgentWorktreeManager.swift:41` (`createWorktree`), `:54` (`isClean`), `:62` (`removeWorktree`), `Services/AgentChats/AgentJobState.swift:25` (`Worktree`), `Services/AgentChats/AgentJobSupervisor.swift:100-104` (effektives cwd), `Services/AgentChats/CodexExecRunner.swift:533` (`CodexGitWritableRoot`).
- **Sichtbares Verhalten:** Fortsetzung (`send`) und Takeover laufen im Worktree; `agent rm` verweigert bei ungesichertem Zustand des Worktrees und entfernt ihn sonst mit dem Job.
- **Erhaltungsinvarianten:** Das effektive cwd ist `worktree.path ?? cwd`; bei `workspace-write` muss das Haupt-`.git` (aus der `.git`-Datei des Linked Worktrees) beschreibbar sein, sonst scheitern Commits. Der Pfad liegt unter dem Job-Verzeichnis und wird gegen Ausbruch aus dem Root validiert (`jobPathOutsideRoot`).
- **Befund-Bezug:** `LR-AK-023`/`LR-AK-032` (Stop vor Prozessregistrierung), `LR-SH-001` (Env des Codex-Kindes).

### F-AC-12 (Ergänzung zu AC-36) · Retention der Subagent-Spiegel

- **Funktion:** Workspace-Spiegel abgeschlossener Codex-Jobs verschwinden nach 7 Tagen ohne Aktivität; das Rollout wird vorher archiviert.
- **Einstiegspunkt:** `Services/AgentChats/SubagentJobRetention.swift:20` (Policy), `:48` (`expiredSessions`), `:86`/`:108` (Archiver), `Services/AgentChats/AgentJobWorkspaceSync.swift:236` (`runRetentionIfDue`, Takt 6 h), `:284` (`protectedSessionIDs`), `:294` (Workspace-Backup), `Support/AppPreferences.swift:599`/`:616` (Kill-Switch, Frist).
- **Sichtbares Verhalten:** Alte Subagent-Zeilen verschwinden aus der Sidebar; der erste Lauf nach dem Update räumt einmalig alle verwaisten Altlasten ohne Frist ab (`subagentJobRetentionInitialPurgeDone`); ab einer Schwelle wird die Workspace-Datei vorher gesichert.
- **Erhaltungsinvarianten:** Fällig ist nur, was auf Disk ohnehin weg ist (Job-Verzeichnis fehlt); solange es lebt, bleibt der Eintrag. Laufende Jobs, sichtbare/geschützte Sessions bleiben in jedem Fall. Rollout-Archivierung VOR dem Löschen, sonst sammelt der Indexer den Thread als normalen Codex-Chat wieder ein. Job-Ordner räumt weiterhin nur `agent rm`. Kill-Switch `subagentJobRetentionEnabled`, Frist `subagentJobRetentionDays` (0 oder negativ = 7).
- **Befund-Bezug:** `LR-AK-012` (Schutz-Snapshot nach `await` veraltet).

### F-AC-02 (Ergänzung zu AC-24) · Bereinigte Prozessumgebung und Theme-Abgleich

- **Funktion:** Alle Chat-, Shell- und Subagent-Spawns nutzen eine bereinigte Umgebung; zusätzlich hält die App das Claude-Theme in der Nutzerdatei synchron.
- **Einstiegspunkt:** `Services/Shared/LoginShellEnvironment.swift:91-155` (`processEnvironment`, Entfernen von `CLAUDE_CODE_*`/`CLAUDECODE`, `CLAUDE_CONFIG_DIR`, `ANTHROPIC_CUSTOM_HEADERS`, `CCP_CONFIG_DIR`), `Views/AgentTerminalView.swift:870-912` (`start`, Overrides, Removals, Session-ID/Token), `Services/AgentChats/CodexExecRunner.swift:208-211`, `Services/AgentChats/ClaudeThemeWriter.swift:71` (`syncIfNeeded`), `:83` (`performWrite`), `Support/ThemeManager.swift:80-90`.
- **Sichtbares Verhalten:** `claude`/`codex`/`git`/`npm`/`mise` werden gefunden, TUIs rendern farbig, jeder gestartete Agent ist eine saubere Top-Level-Session ohne geerbtes Profil. Beim Hell/Dunkel-Wechsel ändert die App das `theme` in der Claude-Nutzerdatei (debounced, mit Erst-Backup).
- **Erhaltungsinvarianten:** PATH aus der Login-Shell (einmal abgefragt, mit Fallback-Liste inkl. `~/.local/bin`), `TERM`/`COLORTERM`/`CLICOLOR`/Locale gesetzt, `NO_COLOR` entfernt. Das Entfernen geerbter `CLAUDE_CONFIG_DIR`/`CCP_CONFIG_DIR`/`ANTHROPIC_CUSTOM_HEADERS` ist tragend für die Konto-Isolation (Vorfälle 13.07. und 23.09.2026) und darf bei einer Allowlist-Umstellung nicht verloren gehen. Ausdrückliche Per-Launch-Overrides (Profil, Plugin-Verzeichnis, Router) gewinnen gegen Basis-Einträge; Session-Identität (`WHISPERM8_SESSION_ID`/`TOKEN`) wird zuletzt gesetzt.
- **Befund-Bezug:** `LR-SH-001` (zusammengelegt mit `LR-SH-006/010`: Secrets werden ungefiltert vererbt), `LR-AK-017` (zusammengelegt mit `LR-SH-002/005/011`: Theme-Writer verliert konkurrierende Schreibvorgänge), `LR-SH-007` (Login-Shell-Abfrage blockiert potenziell den Hauptthread).

### F-AC-02 (Ergänzung zu AC-25/AC-26) · Terminal-Beenden, Feed-Drosselung und Link-Proxy

- **Funktion:** Graceful Stop einzelner und mehrerer Chats, Bündelung des PTY-Outputs von Hintergrund-Panes und Absicherung der Terminal-Delegate.
- **Einstiegspunkt:** `Views/AgentTerminalView.swift:396` (`terminate(sessionID:)`), `:405` (`terminate(sessionIDs:)`), `:432` (`terminateAll`/Quit-Pfad), `:914-947` (`terminate`, `terminateAfterInterrupt`, Reaper), `:1099` (`processTerminated`), `Views/TerminalFeedBatcher.swift:18`, `Views/AgentTerminalLinkInterceptor.swift:31`/`:41`/`:74`.
- **Sichtbares Verhalten:** Stop sendet zweimal Ctrl+C (80 ms und 180 ms Pause) und beendet dann hart; mehrere Chats teilen EINE Wartezeit. Hintergrund-Panes zeigen Output gebündelt (~80 ms, phasenversetzt), die fokussierte Pane unmittelbar.
- **Erhaltungsinvarianten:** Gepufferte Bytes werden vor Terminate, Teardown und Pane-Abbau geflusht (kein Byte-Verlust, FIFO). Nach `terminate` wird das Kind per `ChildProcessReaper` abgeholt, sonst Zombie; nach natürlichem Ende nicht (PID-Wiederverwendung). Natürlicher Exit behält den Controller für den Scrollback, explizites Stoppen entfernt ihn; `onRunningSetChanged` meldet jede Änderung an den Crash-Marker. Der Link-Proxy bleibt auch mit SwiftTerm 1.15 nötig, weil er `clipboardRead` (OSC 52) verweigert. Im heißen `dataReceived`-Pfad nur Zähler, nie Signposts.
- **Befund-Bezug:** `LR-TRM-001` (linearer Main-Thread-Block beim Stoppen mehrerer Chats).

### F-AC-12 (Ergänzung zu AC-34/AC-35) · Codex-Turn-Ergebnis und Stop-Vertrag

- **Funktion:** Ein Job-Turn endet als `done`, `failed` oder `stopped`; Stop und Idle-Timeout beenden den `codex exec`-Prozess.
- **Einstiegspunkt:** `Services/AgentChats/AgentJobSupervisor.swift:46` (`requestStop`), `:61` (`superviseCurrentTurn`), `:133` (`finalize`), `Services/AgentChats/CodexTurnExecutor.swift:83` (`mapOutcome`), `Services/AgentChats/CodexExecRunner.swift:192` (`run`), `:329` (`terminate`), `:343` (`markStalled`), `CLI/AgentCLICommand.swift:624` (`exitCode(for:lastMessage:)`), `CLI/AgentCLIArguments.swift:8` (`AgentCLIExit`).
- **Sichtbares Verhalten:** Exit-Codes 0 ok, 1 Usage, 2 Job fehlgeschlagen (auch bei `done` mit Report-Status failure), 3 Zustandskonflikt, 4 Umgebung. Der Report hängt über ein festes Schema (`CodexReportSchema`) am Job.
- **Erhaltungsinvarianten:** Der Übergang nach `running` samt eigener PID geschieht atomar unter dem Job-Lock; ein spät eintreffender Supervisor setzt keinen übernommenen Job zurück. Ein Stop muss den Turn auch dann beenden, wenn er VOR der Prozessregistrierung eintrifft (Soll). Der Idle-Watchdog ist ein Stille-Timeout, kein Gesamt-Timeout.
- **Befund-Bezug:** `LR-AK-023`/`LR-AK-032` (Stop-Latch ohne Start-Vertrag), `LR-AK-028`/`LR-AK-030` (Exit 0 ohne bestätigtes Turn-Ende gilt als Erfolg), `LR-AK-024`/`LR-AK-031`, `LR-AU-001`, `LR-AK-006` (Statusparser versteht das Codex-Rollout-Format nicht).
