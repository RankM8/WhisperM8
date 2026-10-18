---
status: aktiv
updated: 2026-10-17
description: Lagebild der Shared-Infrastruktur (Logger, Keychain, Login-Shell-Umgebung, Absturz- und Stall-Schutz, Performance-Messung, Speech-Callouts, Debug-Kanal, CLI-Einstieg, Statusline-/Skill-/Plugin-Installation, AppPreferences) auf Stand a8e0f35.
---

# Lagebild Shared-Infrastruktur

Ausgeklammert (Delta-Lauf): Agent-Chats-UI, AgentWindowStore, Jarvis-Board, Control-Server (`AgentControl*`), `WhisperM8/CLI/Chats*`, `WhisperM8/Resources/claude-plugin/`. Dieses Lagebild beschreibt nur den Rest von `Services/Shared/`, `Support/AppPreferences.swift` und die Einstiegs-CLIs.

## Zweck

Die Querschnittsschicht, auf der Diktat und Agent-Chats aufsetzen, ohne selbst ein sichtbares Feature zu sein:

- **Ein Binary, zwei Modi:** `CLIEntryPoint` entscheidet beim Start zwischen GUI und `whisperm8`-CLI (gleiches signiertes Binary, damit die CLI denselben Keychain-Eintrag ohne Prompt liest).
- **Prozessumgebung:** `LoginShellEnvironment` liefert allen gespawnten Kindprozessen (Chat-PTYs, Codex-Nachbearbeitung, `which`) einen brauchbaren `PATH` und bereinigt geerbte Claude-/Proxy-Variablen.
- **Absturz- und Stillstandsschutz:** `SigpipeGuard`, `ObjCException`, `MainThreadStallMonitor` + `StallWatchdog`.
- **Messung:** `PerformanceSignposts` (Budgets), `PerformanceCounters` (dichte Pfade), `GridPerformanceTracker`.
- **Geheimnisse und Logs:** `KeychainManager` (API-Keys), `Logger` (os_log + optionales Datei-Log).
- **Eingriffe in fremde Konfiguration:** `StatuslineInstaller`, `CLISkillExporter`, `WhisperM8ClaudePlugin`, `CLISymlinkInstaller` schreiben nach `~/.claude/` und `~/.local/bin/`.
- **Ausgabe und Testkanal:** `SpeechCallouts` (gesprochene Ansagen), `DebugControl` (Debug-Socket-Methoden).

## Datenfluss

```
 App-Start (WhisperM8EntryPoint.main)
   |-- CLIModeDetector: argv0 == whisperm8 oder 1. Token in recognizedCommands?
   |      ja  -> CLIRuntime.runBlocking -> CLICommand.run -> transcribe | agent | chats | debug | speak
   |      nein-> GUILaunchGuard (kein .app-Bundle => Exit 64) -> SigpipeGuard.install -> WhisperM8App.main
   v
 applicationDidFinishLaunching
   |-- SIGTERM-Handler (leer + DispatchSource) -> NSApp.terminate
   |-- ClaudePluginBootstrap.run -> WhisperM8ClaudePlugin.install (versions/<hash>, Symlink per rename)
   |-- MainThreadStallMonitor.start (+StallWatchdog), PerformanceCounters.startIfEnabled
   |-- detached: CLISymlinkInstaller.installIfNeeded, LoginShellEnvironment.path (Prewarm)
   v
 Chat-/Codex-Launch:  LoginShellEnvironment.processEnvironment -> PTY/Process
                      ClaudePluginBootstrap.launchEnvironment -> CLAUDE_CODE_PLUGIN_DIRS

 whisperm8 speak/debug ---Unix-Socket (Control-Server, ausgeklammert)---> AgentControlRequestHandler
        |                                                                   +Speak -> SpeechCalloutCenter -> AVSpeechSynthesizer
        |                                                                   +Debug -> DebugControl / DebugJobStore (nur mit debugControlEnabled)
 Einstellungen "CLI & Skills" -> StatuslineInstaller / CLISkillExporter -> ~/.claude/{skills,statusline-*.sh,settings.json}
```

## Schlüsseldateien

- `WhisperM8/CLI/CLIEntryPoint.swift` — `@main`-Multiplexer, `CLIModeDetector`, `GUILaunchGuard`, Befehls-Dispatch und Hilfetext.
- `WhisperM8/CLI/SpeakCLICommand.swift` — `whisperm8 speak`, sendet `speech.speak` an die App; Exit 5 bei unerreichbarer App.
- `WhisperM8/CLI/DebugCLICommand.swift` — `whisperm8 debug state|open|snapshot|dictate|job`, pollt Diktat-Aufträge.
- `WhisperM8/Support/AppPreferences.swift` — Wrapper über UserDefaults mit allen Kill-Switches (`boolWithDefault`), 85 Schlüssel.
- `WhisperM8/Services/Shared/KeychainManager.swift` — API-Key-Speicher mit Prozess-Cache und Migration aus UserDefaults.
- `WhisperM8/Services/Shared/Logger.swift` — os_log-Kategorien; `debug` schreibt optional in `~/Library/Logs/WhisperM8/WhisperM8-debug.log`.
- `WhisperM8/Services/Shared/LoginShellEnvironment.swift` — Login-Shell-PATH (gecacht), Fallback-PATH, Env-Bereinigung, TERM/COLORTERM.
- `WhisperM8/Services/Shared/FileEventSource.swift` — vnode-Wrapper (O_EVTONLY, O_CLOEXEC) für den Transcript-Watcher.
- `WhisperM8/Services/Shared/SigpipeGuard.swift` — leerer `sigaction`-Handler statt `SIG_IGN` (auch für SIGTERM) plus Log `sigpipe_suppressed`.
- `WhisperM8/Services/Shared/ObjCException.swift` — Swift-Hülle um den ObjC-`@try/@catch`-Shim für AVFoundation.
- `WhisperM8/Services/Shared/MainThreadStallMonitor.swift` — 100-ms-Timer auf dem Main Thread, misst Verspätung mit `DispatchTime`.
- `WhisperM8/Services/Shared/StallWatchdog.swift` — Beobachter auf eigener Queue, meldet laufende Blockaden gestaffelt (1 s, 2 s, 4 s …).
- `WhisperM8/Services/Shared/PerformanceSignposts.swift` — `PerfBudgets`, Stufen `always`/`detail`, Gate `PerfDetailGate`.
- `WhisperM8/Services/Shared/PerformanceCounters.swift` — Ereigniszähler (~4 ns), Sekundentakt-Ausgabe nur bei Detail-Stufe.
- `WhisperM8/Services/Shared/GridPerformanceTracker.swift` — generationsgebundene Messung von `grid.build`/`grid.focusSwitch`.
- `WhisperM8/Services/Shared/SpeechCallouts.swift` — Textregeln, Systemstimme, Warteschlange `SpeechCalloutCenter`.
- `WhisperM8/Services/Shared/DebugControl.swift` — Ziel-Parser, Fensterauswahl, `DebugJobStore`, Diktat ohne Mikrofon.
- `WhisperM8/Services/Shared/StatuslineInstaller.swift` — Statusline-Skripte, Install-Stempel, `settings.json`-Einträge aller Profile.
- `WhisperM8/Services/Shared/CLISkillExporter.swift` — Skill-Installation nach `~/.claude/skills` mit Hash-Stempel und Fremd-/Symlink-Schutz.
- `WhisperM8/Services/Shared/WhisperM8ClaudePlugin.swift` — Plugin-Ablage (versioniert + Symlink), Skill-Migration, Launch-Variable.
- `WhisperM8/Services/Shared/CLISymlinkInstaller.swift` — `~/.local/bin/whisperm8` auf das App-Binary.
- `WhisperM8/Services/AgentChats/AgentControlRequestHandler+Speak.swift` und `+Debug.swift` — Socket-Dispatch (Teil des ausgeklammerten Servers, aber Einstieg der beiden CLIs).

## Zustände und Persistenz

- **Keychain**, Service `com.whisperm8.app`, Konto = Schlüsselname (z. B. `groq_apikey`); Schreiber: `KeychainManager.save`, aufgerufen aus Onboarding und Settings. Prozess-Cache mit `NSLock`.
- **UserDefaults** (`com.whisperm8.app`): alle Schalter aus `AppPreferences`, u. a. `claudePluginEnabled`, `claudePluginSkillMigrationDone` (Einmal-Flag), `speechCalloutsEnabled` (Default an), `speechCalloutsMuted`, `debugControlEnabled` (Default aus), `debugFileLoggingEnabled`, `agentPerfDetailEnabled`, `agentEventDrivenWatchEnabled`.
- **Application Support** `WhisperM8/claude-plugin/`: `versions/<hash>/whisperm8` (bis zu 5 Stände) und Symlink `whisperm8`; Schreiber nur `WhisperM8ClaudePlugin.install`.
- **`~/.claude/`** (extern, von uns beschrieben): `statusline-command.sh`, `subagent-statusline.sh`, `.whisperm8-statusline-state.json`, `settings.json` aller Profile (Statusline-Einträge, daneben der Theme-Schreiber), `skills/<name>/` mit Install-Stempel, `skills/.whisperm8-backup/<zeit>/`.
- **`~/.local/bin/whisperm8`**: Symlink auf das laufende Binary (legt nur an oder ersetzt Symlinks, nie reguläre Dateien).
- **Logs:** `~/Library/Logs/WhisperM8/WhisperM8-debug.log` (nur bei Schalter); `~/Library/Application Support/WhisperM8/debug-snapshots/` (PNG-Fenster, nur Debug-Kanal).
- **Flüchtig:** Login-Shell-PATH-Cache, `DebugJobStore` (höchstens parallele Diktate begrenzt, fertige Aufträge zeitlich beschränkt), Speech-Warteschlange (höchstens 4), Stumm-Zustand im Center.

## Externe Abhängigkeiten

- **CLIs:** `/bin/zsh -l -c 'echo $PATH'` (Login-Shell), `claude` und `codex` (nur über `LoginShellEnvironment`-PATH), `ffmpeg` für `transcribe` (außerhalb dieses Bereichs).
- **Netz:** keines in diesem Bereich; `debug dictate` nutzt den Transkriptionsweg des Diktats (OpenAI/Groq/ChatGPT-Abo).
- **Systemdienste:** Security.framework (Keychain), `AVSpeechSynthesizer` (Systemstimmen, lokal), `os_log`/`os_signpost`, BSD-Signale.
- **TCC-Rechte:** keines eigenständig; der Debug-Snapshot rendert eigene Fenster (ob dafür Bildschirmaufnahme nötig ist, wurde nicht geprüft).
- **Dateisystem:** Schreibzugriff auf `~/.claude/`, `~/.local/bin/` und Application Support.

## Invarianten, die jeder Umbau erhalten muss

1. **SIGPIPE/SIGTERM werden gefangen, nie ignoriert** (`SigpipeGuard`): `SIG_IGN` erbt jedes `forkpty`+`execve`-Kind, ein abgefangenes Signal setzt `execve` zurück. Der CLI-Pfad bleibt beim Default (`| head` muss enden).
2. **Kein `installTap` ohne `ObjCException.catching`**; Pipes nur mit `write(contentsOf:)`.
3. **`FileEventSource` und alle Locks/Sockets sind close-on-exec** (`O_CLOEXEC`), sonst erben Chat-Prozesse FDs.
4. **Der Stall-Watchdog bleibt unabhängig vom Main Thread** (eigene Queue, Zeit per `DispatchTime`, gestaffelte Meldung); `MainThreadStallMonitor` allein erkennt endlose Blockaden nicht.
5. **Nie pro Byte/Zeichen/Zeile messen:** dort Zähler; Signposts im Violation-Pfad nur über `os.Logger`, nie `Logger.debug`.
6. **Geerbtes `CLAUDE_CODE_*`, `CLAUDECODE`, `CLAUDE_CONFIG_DIR`, `ANTHROPIC_CUSTOM_HEADERS`, `CCP_CONFIG_DIR` werden entfernt**; Konto-Routing läuft nur über explizite Per-Launch-Overrides. Jeder gespawnte Agent ist eine Top-Level-Session.
7. **Plugin-Ablage nie in den laufenden Ordner kopieren:** neuer Stand in eigenem Hash-Ordner, Symlink per `rename(2)`; alte Stände bleiben (5), damit laufende Sessions nicht entladen werden. Scheitert das Ablegen, keine Variable und keine Migration.
8. **Fremde Dateien nie ohne ausdrückliche Bestätigung ersetzen** (Statusline-Skript/-Eintrag getrennt entscheidbar, Skills mit Stempel/Hash, Symlink-Ziele abgelehnt; reguläre Datei am CLI-Symlink-Pfad bleibt).
9. **Speech:** Texte nie ins Log (nur Längen), Sprechername nur mit gültigem Session-Token, nie während der Aufnahme, 20 s Entprellung je Session, Stumm verwirft die Warteschlange.
10. **Debug-Kanal Default aus**, jeder Aufruf außer `debug.job` im Audit-Log, Hinweistext nennt den Aktivierungsbefehl.
11. **`GUILaunchGuard`:** GUI startet nur aus einem `.app`-Bundle (Exit 64), CLI bleibt ohne Bundle nutzbar.
12. **Keychain-Cache nur nach bestätigtem Schreiben befüllen**; Legacy-Werte aus UserDefaults wandern in den Schlüsselbund (siehe Risiko LR-SH-003).

## Top-Risiken (Verweis auf `findings.jsonl`)

- **LR-SH-003 / LR-SH-009 (P0, Duplikate):** Fehlgeschlagene Keychain-Migration löscht die einzige UserDefaults-Kopie des API-Keys; `save` hat keinen Erfolgsvertrag, UI zeigt trotzdem „vorhanden" (siehe auch LR-ONB-007).
- **LR-SH-001 / LR-SH-006 / LR-SH-010 (P0, Duplikate):** `processEnvironment` reicht das gesamte Parent-Environment (Cloud-/Dienst-Secrets) an `which`, jeden Agenten und Codex weiter.
- **LR-SH-002 / LR-SH-005 / LR-SH-011 (P0, Duplikate):** Statusline-Installer und Theme-Schreiber überschreiben sich und fremde Änderungen an `settings.json` (Lost Update trotz atomarer Einzelwrites).
- **LR-SH-004 (P0):** Nicht-UTF-8-Statusline-Skript des Nutzers wird ohne Fremddatei-Bestätigung und ohne Backup überschrieben.
- **LR-SH-007 (P1):** Login-Shell-Abfrage ohne Timeout, stderr nie gelesen; wegen Prewarm-Lücke kann der Main Thread beim ersten Chat dauerhaft blockieren.
- **LR-PJ-001 (P1):** Erststart-Migration räumt fremde, ungestempelte Skills (`unknownDrift`) automatisch weg.
- **LR-PJ-002 (P1):** `processEnvironment` entfernt `CLAUDE_CODE_PLUGIN_DIRS`, bevor der Bootstrap den Wert erhalten will; fremde Plugin-Pfade gehen verloren.
- **LR-BR-001 (P1) und LR-BR-005 (P1):** `brew uninstall --zap` lässt Statuslines, Settings-Einträge, Skills und den CLI-Symlink zurück.
- **LR-ONB-017 (P1):** Codex-Login-Skript quotiert den Binary-Pfad nicht (Leerzeichen).
- **LR-SH-008 (P2):** Fehlerhafte Transkriptionsantworten loggen bis zu 500 Zeichen diktierten Text als `public`.
- Querverweis ohne eigenen Eintrag in `findings.jsonl`: Debug-Socket-Transportsicherheit liegt beim Delta-Lauf (Control-Server).
