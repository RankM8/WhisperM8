---
status: aktiv
updated: 2026-10-17
description: Regressions-Oracle Shared-Infrastruktur auf Stand a8e0f35 — neue Einträge seit Juli (F-APP-06/08, F-AUT-04, F-DEV-01, Statusline-/Skill-/Plugin-Installation, Prozessumgebung, Keychain) plus Bestandsprüfung von AC-23 und AC-43.
---

# Regressions-Oracle Shared-Infrastruktur

## Leseregel

Dieses Oracle beschreibt Verhalten, das kein Fix unbeabsichtigt ändern darf. Die Einträge der Juli-Inventare (`DI-…`/`AC-…`) gelten weiter, sofern sie hier nicht ausdrücklich durch einen Eintrag „(aktualisiert)“ ersetzt werden. „Befund-Bezug“ nennt die LR-IDs aus `findings.jsonl`, deren Fix das Verhalten berühren würde: Ein Fix darf den Defekt beseitigen, aber nicht die hier genannten Invarianten brechen. Alle Zeilenangaben gelten für Commit a8e0f35.

Bestandsprüfung (Juli-Einträge dieses Bereichs): AC-23 (Grid-Streaming-Messung, `GridPerformanceTracker`) und AC-43 (Transcript-Watcher mit `FileEventSource`) sind inhaltlich unverändert gültig; nur Zeilennummern der Einstiegspunkte sind verschoben (Tracker jetzt `GridPerformanceTracker.swift:16`, `FileEventSource.swift:38`). Zu AC-43 neu zu beachten: `FileEventSource` ist `@MainActor` und `nonisolated static defaultOpenFile` setzt `O_EVTONLY | O_CLOEXEC` (siehe F-APP-08).

### F-APP-06 · CLI-Symlink `whisperm8` und Multiplex-Binary

- **Funktion:** Legt beim App-Start `~/.local/bin/whisperm8` als Symlink auf das laufende Binary an; dasselbe Binary läuft als CLI, wenn argv0 `whisperm8` heißt oder das erste Argument ein bekannter Befehl ist.
- **Einstiegspunkt:** `WhisperM8/Services/Shared/CLISymlinkInstaller.swift:12` (Aufruf `WhisperM8/WhisperM8App.swift:304`, detached, Priorität background); `WhisperM8/CLI/CLIEntryPoint.swift:13` (`WhisperM8EntryPoint.main`), `WhisperM8/CLI/CLIEntryPoint.swift:59` (`CLIModeDetector.shouldRunCLI`).
- **Sichtbares Verhalten:** `whisperm8 …` funktioniert aus Terminal und Claude Code und liest denselben Keychain-Eintrag ohne Prompt. Ohne Bundle verweigert der GUI-Start mit Meldung und Exit 64, die CLI bleibt nutzbar (`swift run WhisperM8 chats list`).
- **Erhaltungsinvarianten:** Erkennung case-sensitiv (`whisperm8` = CLI, `WhisperM8` = GUI); erkannte Befehle: transcribe, modes, help/--help/-h, --version/-v, agent, agent-supervise, chats, debug, speak. Ein bereits korrekter Symlink bleibt unberührt, ein Symlink auf anderes Ziel wird ersetzt, eine reguläre Datei am Pfad wird nie überschrieben. `SigpipeGuard.install()` läuft nur im GUI-Zweig. `GUILaunchGuard` prüft Bundle-Endung `.app` und Bundle-Identifier. Unbekannter Befehl liefert Fehler statt GUI-Start.
- **Befund-Bezug:** LR-BR-001 (Symlink bleibt nach `brew uninstall --zap` zurück und zeigt ins Leere; ein Cleanup darf nur den eigenen Symlink entfernen), LR-BR-005.

### F-APP-08 · Absturzschutz, Stall-Watchdog und Perf-Messung

- **Funktion:** Verhindert wortlose Prozessenden (SIGPIPE, ObjC-Exceptions, SIGTERM ohne Flush), erkennt Main-Thread-Stillstand und misst Hot-Paths mit Budgets.
- **Einstiegspunkt:** `WhisperM8/Services/Shared/SigpipeGuard.swift:34` (`install`), `:64` (`installNoOpHandler(for:)`); `WhisperM8/WhisperM8App.swift:230` (SIGTERM → `NSApp.terminate`); `WhisperM8/Services/Shared/ObjCException.swift:24` (`catching`); `WhisperM8/Services/Shared/MainThreadStallMonitor.swift:80` (`start`, Aufruf `WhisperM8/WhisperM8App.swift:265`); `WhisperM8/Services/Shared/StallWatchdog.swift`; `WhisperM8/Services/Shared/PerformanceSignposts.swift:44` (`PerfDetailGate`), `:184` (`PerfBudgets`); `WhisperM8/Services/Shared/PerformanceCounters.swift:29`; `WhisperM8/Services/Shared/FileEventSource.swift:34` (`defaultOpenFile`).
- **Sichtbares Verhalten:** Kein sichtbares UI. Die App stirbt nicht an SIGPIPE; `make dev`/`kill` (SIGTERM) löst einen regulären Quit mit Terminate-Flushes aus; Stillstand ab 1 s erscheint als `main_thread_blocked_ongoing` im Log, Budgetüberschreitungen als `perf_budget_exceeded`; bei Schalter `agentPerfDetailEnabled` zusätzlich Zähler im Sekundentakt.
- **Erhaltungsinvarianten:** Leerer `sigaction`-Handler mit `SA_RESTART`, nie `SIG_IGN` (Kinder erben Ignorieren über `execve`); zusätzlich Dispatch-Signalquelle mit Log `sigpipe_suppressed`. Monitor: 100-ms-Tick, 100-ms-Stillstandsschwelle, 1-s-Freeze-Schwelle, Uhr `DispatchTime` (nicht `Date`, wegen Schlaf und Zeitsprüngen); Watchdog prüft viermal pro Sekunde auf eigener Queue und meldet erst bei Verdopplung der Dauer erneut. Zwei Messstufen: `.always` nur an seltenen Ereignissen, `.detail` nur nach App-Neustart mit Schalter; Zähler statt Signposts für dichte Pfade. Violation-Pfad nutzt ausschließlich `os.Logger`. `FileEventSource` öffnet mit `O_EVTONLY | O_CLOEXEC`, bei `.delete/.rename` baut es die Source selbst ab und ruft `onFileGone`.
- **Befund-Bezug:** LR-SH-007 (blockierender Login-Shell-Aufruf wird vom Stall-Monitor nur nachträglich sichtbar; der Fix muss Watchdog und Prewarm erhalten). Kein offener Befund gegen die Schutzmechanismen selbst.

### F-AUT-04 · Voice-Callouts (`whisperm8 speak`)

- **Funktion:** Ein Chat lässt am Turn-Ende eine kurze Ansage von der App vorlesen; die Warteschlange gilt für alle Sessions.
- **Einstiegspunkt:** `WhisperM8/CLI/SpeakCLICommand.swift:42` (`run`); `WhisperM8/Services/AgentChats/AgentControlRequestHandler+Speak.swift:12` (`speechRequest`); `WhisperM8/Services/Shared/SpeechCallouts.swift:164` (`SpeechCalloutCenter`), `:226` (`enqueue`), `:259` (`setMuted`), `:278` (`holdForRecording`); Aufnahme-Kopplung `WhisperM8/Services/Dictation/RecordingCoordinator.swift:128`; Stumm-Schalter `WhisperM8/Views/MenuBarView.swift:98`; Schalter `WhisperM8/Support/AppPreferences.swift:497`.
- **Sichtbares Verhalten:** `whisperm8 speak "<text>"` (oder `-` für stdin) kehrt sofort zurück und liefert JSON mit `status` = queued | replaced | muted | debounced. Exit 0 angenommen (auch stumm/entprellt), 1 Aufruf oder abgeschaltet, 5 App nicht erreichbar. Gesprochen wird mit der besten installierten deutschen Systemstimme (keine Eloquence-Stimmen), davor der Chat-Name („Jarvis: …“).
- **Erhaltungsinvarianten:** Default an (`speechCalloutsEnabled`), Kill-Switch per `defaults write … -bool NO`; höchstens 280 Zeichen nach Säubern (Satzende, sonst Wortende); 20 s Entprellung je Session; höchstens 4 wartende Ansagen, eine neuere Ansage derselben Session ersetzt die wartende; nie zwei gleichzeitig; Aufnahme-Start bricht die laufende Ansage ab und blockiert bis Aufnahme-Ende plus 1,5 s Gnadenzeit, danach von vorn; Stumm verwirft die Warteschlange und bricht still ab. Sprechername nur bei gültigem Session-Token (`AgentSessionTokenRegistry.verify`), sonst Text ohne Namen. Ansagetexte nie im Log und nie im Audit-Log (nur Länge/Status); leere Texte liefern `invalid`.
- **Befund-Bezug:** keiner offen. Der Transportweg (Socket, Peer-Prüfung) gehört zum Delta-Lauf (Control-Server).

### F-DEV-01 · Debug-Steuerkanal, Datei-Logging, Perf-Detail

- **Funktion:** Interner Steuerkanal für UI-Tests ohne Computer Use: Zustand lesen, Fenster öffnen, Fenster-PNGs erzeugen, Diktat aus Audiodatei auslösen.
- **Einstiegspunkt:** `WhisperM8/CLI/DebugCLICommand.swift:101` (`run`), `:139` (`dictate` mit Poll); `WhisperM8/Services/AgentChats/AgentControlRequestHandler+Debug.swift:12` (`debugMethods`), `:15` (`debugRequest`, Gate Zeile 18); `WhisperM8/Services/Shared/DebugControl.swift:12` (`DebugControl`), `:172` (`DebugJobStore`); Schalter `WhisperM8/Support/AppPreferences.swift:590`; Datei-Log `WhisperM8/Services/Shared/Logger.swift:61` (`debug`), Schalter `WhisperM8/Support/AppPreferences.swift:79`.
- **Sichtbares Verhalten:** Ohne `defaults write com.whisperm8.app debugControlEnabled -bool YES` antwortet jede Methode mit `unsupported` und dem Aktivierungsbefehl; mit Schalter wirkt er sofort ohne Neustart. `open` holt die App nach vorn (Ziele `settings`, `settings/<seite>`, `agent-chats`, `onboarding`, unbekannte Seiten werden abgelehnt); `snapshot` legt PNGs unter `Application Support/WhisperM8/debug-snapshots/` ab; `dictate` fügt nichts ein und lässt die Zwischenablage in Ruhe.
- **Erhaltungsinvarianten:** Default aus. Jeder Aufruf außer `debug.job` landet im Audit-Log. `debug.dictate` ist ein Hintergrundauftrag (der Socket bricht Requests nach 10 s ab), Abfrage über `debug.job`; gleichzeitige Aufträge sind begrenzt, fertige werden bereinigt. Diktat nutzt denselben Zugangs-Gate und dieselbe Service-Factory wie das Hotkey-Diktat, ohne Nachbearbeitung und ohne `AppState`. Anbieter `chatgpt` wird bei Kill-Switch `chatGPTTranscriptionEnabled` abgelehnt. `Logger.info` ist persistent, `Logger.debug` nur im Stream (Datei-Log nur mit Schalter).
- **Befund-Bezug:** LR-SH-008 (Logger markiert Nachrichten als `public`; ein Fix darf die Persistenz von `Logger.info` für Absturzdiagnose nicht abschalten). Security des Debug-Sockets: Delta-Lauf.

### F-APP-03 (Teil) · Statusline-Installation und Skill-Export (Seite „CLI & Skills“)

- **Funktion:** Installiert die gebündelten Statusline-Skripte nach `~/.claude/` und trägt sie in die `settings.json` des Hauptkontos und aller Profile ein; installiert Agent-Skills lose nach `~/.claude/skills`.
- **Einstiegspunkt:** `WhisperM8/Services/Shared/StatuslineInstaller.swift:14` (Typ), `:167` (`status`), `:259` (`install`); `WhisperM8/Services/Shared/CLISkillExporter.swift:314` (`installState`), `:341` (`installForClaudeCode`); UI `WhisperM8/Views/Settings/Pages/CLISkillsSettingsPage.swift`.
- **Sichtbares Verhalten:** Karten zeigen Zustand (nicht installiert, aktuell, veraltet, lokal geändert, per Repo-Sync, fremd). Ersetzen fremder Skripte und fremder Statusline-Einträge sind getrennte, einzeln bestätigte Entscheidungen.
- **Erhaltungsinvarianten:** Marker `managed-by: whisperm8-statusline` unterscheidet eigene von fremden Skripten; ein Skript ohne Marker wird nur mit `replaceForeignScript` ersetzt, ein fremder `statusLine`-Befehl nur mit `replaceForeignSettings`; übrige Schlüssel in `settings.json` bleiben unangetastet; Skripte liegen genau einmal im Haupt-Config-Dir, Profile referenzieren denselben `~`-Pfad; Install-Stempel mit Hashes (`bundle`/`resources`) erkennt lokale Änderungen und `make skills`-Syncs. Skill-Export lehnt Symlink-Ziele und ungültige Asset-Pfade ab und verlangt Bestätigung beim Ersetzen modifizierter Dateien.
- **Befund-Bezug:** LR-SH-004 (nicht dekodierbares Fremdskript wird überschrieben), LR-SH-005 / LR-SH-002 / LR-SH-011 (Lost Update gegen den Theme-Schreiber), LR-BR-001 (kein Rückbau beim Zap). Fixes müssen Marker-Logik, getrennte Bestätigungen und das Erhalten fremder Schlüssel bewahren.

### F-AUT-02 (Installationsanteil) · Plugin-Ablage, Skill-Migration, Launch-Variable

- **Funktion:** Legt das Claude-Code-Plugin `whisperm8` versioniert ab und gibt es jeder Claude-Session mit; räumt einmalig die losen Skill-Kopien weg.
- **Einstiegspunkt:** `WhisperM8/Services/Shared/WhisperM8ClaudePlugin.swift:156` (`install`), `:236` (`launchEnvironment`), `:262` (`ClaudePluginSkillMigration`), `:363` (`ClaudePluginBootstrap.run`), `:385` (`ClaudePluginBootstrap.launchEnvironment`); Aufruf `WhisperM8/WhisperM8App.swift:238`; Kill-Switch `WhisperM8/Support/AppPreferences.swift:524`.
- **Sichtbares Verhalten:** In App-Chats stehen alle Skills als `/whisperm8:<name>` bereit, ohne `claude plugin install`; beim ersten Start mit Plugin verschwinden lose Kopien (in Sicherung, nicht gelöscht).
- **Erhaltungsinvarianten:** Neuer Stand immer in `versions/<hash>/whisperm8`, Umschalten per atomarem `rename(2)` auf den Symlink; die letzten 5 Stände bleiben; gleicher Inhalt = gleicher Ordner, nichts neu geschrieben. Scheitert das Ablegen, gibt es keine Variable und keine Migration. Die Variable fehlt, wenn Plugin aus oder Manifest nicht vorhanden; unser Pfad kommt hinten, ein bereits gesetzter eigener Wert bleibt vorn und wird dedupliziert. Wirksam nur im echten App-Prozess (`com.whisperm8.app`), nicht unter `swift test`. Migration läuft einmalig (`claudePluginSkillMigrationDone`), lässt Symlinks und `modifiedLocally` liegen und sichert alles andere nach `~/.claude/skills/.whisperm8-backup/<zeit>/`. Skill-Karten kennen drei Modi (legacy, viaPlugin, duplicate).
- **Befund-Bezug:** LR-PJ-001 (ungestempelte Fremdskripte, `unknownDrift`, werden mitgenommen), LR-PJ-002 (`CLAUDE_CODE_PLUGIN_DIRS` wird vorher entfernt, Erhalt wirkungslos), LR-BR-001. Die Mod selbst (`Resources/claude-plugin/`) liegt im Delta-Lauf.

### F-APP-08 (Teil) · Prozessumgebung der Kindprozesse (`LoginShellEnvironment`)

- **Funktion:** Liefert Chat-PTYs, Codex-Nachbearbeitung und Hilfsprozessen einen Login-Shell-`PATH` und eine bereinigte Umgebung.
- **Einstiegspunkt:** `WhisperM8/Services/Shared/LoginShellEnvironment.swift:60` (`path`), `:91` (`processEnvironment`), `:150` (`terminalEnvironmentArray`), `:174` (`queryLoginShellPath`); Prewarm `WhisperM8/WhisperM8App.swift:314`; Nutzung `WhisperM8/Views/AgentTerminalView.swift:879`, `WhisperM8/Services/Dictation/CodexPostProcessor.swift:83`, `WhisperM8/CLI/CLIAudioExtractor.swift:264`.
- **Sichtbares Verhalten:** Gestartete `claude`/`codex`/`git`/`npm`/mise-Binaries werden gefunden; TUIs rendern farbig; Chats sind saubere Top-Level-Sessions mit dem für sie gewählten Konto.
- **Erhaltungsinvarianten:** PATH einmalig per `/bin/zsh -l -c 'echo $PATH'` ermittelt, gecacht (Lock), mit Fallback-Liste zusammengeführt (Reihenfolge: `~/.local/bin`, `~/bin`, Homebrew arm64/Intel, System); schlägt die Abfrage fehl, gilt der Fallback und `login_shell_path_query_failed` wird geloggt. Entfernt werden `CLAUDE_CODE_*`, `CLAUDECODE`, `CLAUDE_CONFIG_DIR`, `ANTHROPIC_CUSTOM_HEADERS`, `CCP_CONFIG_DIR`; gesetzt werden `TERM=xterm-256color` (nur wenn leer/dumb), `COLORTERM=truecolor`, `CLICOLOR=1`, Locale-Default; `NO_COLOR` wird entfernt. Prewarm läuft off-main beim Start; ein Chat-Start darf nie ohne Cache blockieren müssen (Zielzustand).
- **Befund-Bezug:** LR-SH-001 / LR-SH-006 / LR-SH-010 (Parent-Secrets werden vollständig vererbt), LR-SH-007 (kein Timeout, ungeleerte Pipes, blockierender Cache-Miss), LR-PJ-002. Ein Fix muss PATH-Qualität, TERM/Farbe und die genannten Entfernungen erhalten und darf Konto-Routing nicht auf geerbtes Env umstellen.

### F-DIK-02 (Infrastrukturanteil) · API-Key-Speicher (`KeychainManager`)

- **Funktion:** Speichert API-Keys im macOS-Schlüsselbund (Service `com.whisperm8.app`) und migriert alte UserDefaults-Werte.
- **Einstiegspunkt:** `WhisperM8/Services/Shared/KeychainManager.swift:10` (`save`), `:37` (`load`), `:72` (`exists`), `:100` (`delete`); Aufrufer `WhisperM8/Views/Settings/Pages/TranscriptionSettingsPage.swift:107`, `WhisperM8/Views/OnboardingView.swift:635`.
- **Sichtbares Verhalten:** Gespeicherter Key bleibt über Neustarts erhalten und ist für App und CLI (gleiches Binary) lesbar, ohne erneute Abfrage.
- **Erhaltungsinvarianten:** Update-vor-Add (`SecItemUpdate`, bei `errSecItemNotFound` `SecItemAdd`); Prozess-Cache wird nur bei `errSecSuccess` gesetzt; `load` bevorzugt Cache, dann Keychain, dann Migration aus UserDefaults; leere Werte zählen als nicht vorhanden. Gleicher Service-Name und Kontoschlüssel müssen stabil bleiben, sonst verlieren Bestandsnutzer ihren Key.
- **Befund-Bezug:** LR-SH-003 / LR-SH-009 (Legacy-Wert wird nach fehlgeschlagenem Schreiben dennoch gelöscht), LR-ONB-007 (UI meldet vorhandenen Zugang trotz Fehlschlag), LR-ONB-006.
