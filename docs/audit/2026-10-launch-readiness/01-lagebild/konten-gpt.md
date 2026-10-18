---
status: aktiv
updated: 2026-10-17
description: Lagebild Konten und GPT-Backend (Claude-Konten, Kontowechsel, Memory/MCP-Angleich, Proxy, Mix-Router, ChatGPT-Konten, Abo-Transkription) auf Stand a8e0f35.
---

# Lagebild · Konten und GPT-Backend

Stand: Commit a8e0f35, Worktree `launch-readiness`. Ausgeklammert (Delta-Lauf): Agent-Chats-UI, Jarvis-Board, Control-Server, `Chats*`-CLI, Plugin-Ressourcen. Nur die Berührungspunkte dieser Teile mit Konten/GPT sind genannt.

## Zweck

Zwei Power-User-Hälften, beide Klasse „Erweitert" (Claude-Konten, F-KO-01…05) bzw. „Labs" (GPT-Backend, F-GPT-01…03, F-DIK-03):

1. **Claude-Konten:** Mehrere Claude-Logins als getrennte `CLAUDE_CONFIG_DIR`-Profile unter `~/.claude-profiles/<name>/`; `main` ist das Default-Verzeichnis `~/.claude`. Chats sind per Profil-Stempel (`claudeProfileName`) an ein Konto gebunden. Dazu: Chats zwischen Konten verschieben (auch laufende, nach dem Turn), Hauptkonto tauschen, Memory und MCP-Server über Konten angleichen, Nutzungsanzeige je Konto.
2. **GPT-Backend:** Claude Code spricht über einen lokalen In-Process-Router (Mix-Router) wahlweise mit Anthropic oder mit dem nachgeladenen Fremdbinary `claude-code-proxy` (ChatGPT-Abo, inoffizieller Upstream). Mehrere ChatGPT-Konten laufen als eigene Proxy-Instanzen. Derselbe Proxy bedient die Diktat-Transkription „ChatGPT-Abo".

## Datenfluss

```
Chat-Start (AgentCommandBuilder)
  |- Profil-Stempel --> CLAUDE_CONFIG_DIR (nur Zusatzprofil; main ohne Variable)
  |- GPT-Backend an --> ANTHROPIC_BASE_URL=127.0.0.1:<routerPort>
  |                     ANTHROPIC_CUSTOM_HEADERS = X-WhisperM8-GPT-Profile: <konto|main>
  v
claude (PTY) --HTTP--> ClaudeGPTMixRouter (NWListener, 127.0.0.1)
                         model "gpt-*" ? --ja--> Proxy-Instanz des Kontos (main-Port oder Profil-Port)
                                          |        --> chatgpt.com (Codex-Upstream, OAuth des Kontos)
                                          '--nein--> api.anthropic.com (Header unverändert)

ClaudeCodeProxyManager: ensureRunning(port|profile) --> Binary (Installer, SHA-256) --> serve --port N
   Waisen-Schutz beim Start --> Health-Probe /healthz --> Router starten --> gpt.md-Agent syncen

Diktat (Provider "chatgpt"):  ChatGPTSubscriptionTranscriptionService
   --multipart--> Proxy-Instanzport des aktiven GPT-Profils /v1/audio/transcriptions   (nicht über den Router)

Kontowechsel:  Menü/CLI --> AccountMovePlanner --> AccountSwitchPlanner (jetzt | nach Turn | blockiert)
   --> AccountSwitchCoordinator (2-s-Timer, nur bei Vormerkungen) --> AccountMoveService
   --> ClaudeAccountProfiles.moveTranscript + Stempelwechsel + AccountMoveJournal (Undo)

Nutzung:  ClaudeAccountUsageFetcher (Keychain-Token --> api.anthropic.com/api/oauth/usage)
          ClaudeAccountLimitPinger (claude -p "ok" --model haiku, wenn Token abgelaufen)
          CodexUsageFetcher (Codex-CLI-/Proxy-Token --> chatgpt.com/backend-api/wham/usage)
```

## Schlüsseldateien

Claude-Konten (`WhisperM8/Services/AgentChats/`):
- `ClaudeAccountProfiles.swift` – Profil-Discovery, `.active`, Env-Override, Anlegen, Umbenennen inkl. Keychain-Umzug, Transcript-Locator/-Move.
- `ClaudeAccountProfiles+Promote.swift` – „Zum Hauptkonto machen": Login nach main verschieben, Daten mischen, Rollback.
- `ClaudeAccountProfiles+SharedConfig.swift` – Symlink-Heilung der geteilten Einträge, Schutz vor Entfernen registrierter Plugin-Pfade.
- `AccountMovePlanner.swift` / `AccountMoveFacts.swift` – reine Planung: wer darf wohin, Überspringgründe.
- `AccountMoveService.swift` – führt Umzüge aus (erst Datei, dann Stempel), Undo, Scan-Pause.
- `AccountMoveJournal.swift` – Batch-Journal für „Rückgängig".
- `AccountMoveStopResume.swift` – Stop-and-resume-Auswahl, Composer-Entwurfs-Tracker, Prozessende-Warten.
- `AccountSwitchPlanner.swift` – entscheidet sofort/vormerken/blockiert; `ClaudeAccountPreflight` liest Trust und MCP des Zielkontos.
- `AccountSwitchCoordinator.swift` – Vormerkungen, Timer, Anhalten-und-Fortsetzen.
- `ClaudeSharedMemoryPath.swift` – berechnet `autoMemoryDirectory` (Claude-Pfadregel nachgebaut).
- `ClaudeMemoryMigration.swift` – einmalige Memory-Zusammenführung nach main mit Backup.
- `ClaudeMCPSync.swift` – gleicht User-MCP-Server über Konten per `claude mcp add-json` an.
- `ClaudeAccountUsageFetcher.swift` / `ClaudeAccountLimitPinger.swift` – Nutzungsanzeige, Token-Auffrischung per CLI-Ping.

GPT-Backend:
- `ClaudeCodeProxyManager.swift` – Lifecycle von main-Proxy, Profil-Instanzen, Router; Login, Grant-Tausch, Auth-Status.
- `ClaudeCodeProxyBinaryInstaller.swift` – Download, SHA-256-Prüfung, Auto-Update des Fremdbinarys.
- `ClaudeCodeProxyOrphanGuard.swift` – beendet veraltete Waisen-Proxys beim App-Start.
- `ClaudeCodeProxyModelRegistry.swift` – Modelle des laufenden Proxys (Schnittmenge mit Codex-Katalog).
- `ClaudeGPTMixRouter.swift` – HTTP-Router, Modell- und Profil-Routing, Schema-Bereinigung, Streaming.
- `GPTAccountProfiles.swift` – ChatGPT-Konten unter `~/.gpt-profiles/<name>/`, Hauptkonto-Tausch, `GPTPromotedProfiles`-Alias.
- `ClaudeGPTModelAlias.swift` / `ClaudeGPTModelCatalog.swift` / `ClaudeGPTLaunchGuard.swift` – Modellwahl (`auto` = Frontier), Picker-Fragment, Fallback-Entscheidung.
- `ClaudeGPTAgentDefinition.swift` – verwaltete `agents/gpt.md` in allen Claude-Profilen.
- `CodexUsageReader.swift` – ChatGPT-Nutzung aus CLI-Logs und `wham/usage`.
- `WhisperM8/Services/Dictation/ChatGPTSubscriptionTranscription.swift` – Diktat-Upload an den Profil-Proxy, Prewarm.
- Einstellungen: `WhisperM8/Views/Settings/Pages/` – `AgentChatsClaudeAccountsTab.swift`, `ClaudeMCPSyncSection.swift`, `GPTBackendSettingsPage.swift`, `GPTAccountsSection.swift`, `GPTBackendSetupRunner.swift`; Nutzung in `WhisperM8/Views/AgentUsagePopovers.swift`.

## Zustände und Persistenz

| Ort | Inhalt | Schreiber |
|---|---|---|
| `~/.claude-profiles/<name>/` | Config-Root je Claude-Konto (Login, `projects/`, Symlinks auf geteilte Einträge, `.keychain-service`) | Claude Code selbst; WhisperM8 legt an, verschiebt, löscht (Papierkorb) |
| `~/.claude-profiles/.active` | aktives Profil für neue Chats | `ClaudeAccountProfiles.setActiveProfile` (auch von `ccs.zsh` gelesen) |
| Keychain `Claude Code-credentials[-<sha256[:8] des Pfads>]` | OAuth-Grant je Konto | Claude Code; WhisperM8 liest, verschiebt bei Rename/Promote (per `security`-CLI) |
| `~/.claude.json` je Profil | `oauthAccount`, Trust, `mcpServers` | Claude Code; WhisperM8 liest, `mcp add-json` und Promote schreiben |
| `AgentSessions.json` (Workspace) | Stempel `claudeProfileName`, `gptProfileName`, `claudeBackendModel` | `AgentSessionStore` (Single Writer) |
| Account-Move-Journal (Application Support) | letzter Umzugs-Batch | `AccountMoveJournal` |
| `~/.gpt-profiles/<name>/` | `codex/auth.json` (Grant), Kontoinfo; Profil-Instanz läuft mit `HOME` = dieser Ordner | Proxy-Instanz; WhisperM8 legt an/löscht |
| `~/.config/claude-code-proxy/codex/auth.json` | Grant des GPT-Hauptkontos | Proxy; WhisperM8 tauscht ihn bei „Hauptkonto" |
| `Application Support/WhisperM8/bin/claude-code-proxy` + `.version` | verwaltetes Proxy-Binary | `ClaudeCodeProxyBinaryInstaller` |
| `Application Support/WhisperM8/whisperm8-limit-ping/` | Arbeitsordner der Limit-Pings | `ClaudeAccountLimitPinger` |
| `Application Support/WhisperM8/memory-migration/<zeit>/` | Backups der Memory-Zusammenführung | `ClaudeMemoryMigration` |
| `~/.claude/projects/<kodiert>/memory/` | gemeinsames Auto-Memory, Ziel für alle Konten | Claude Code (über `autoMemoryDirectory` in `claude-hooks/<id>.json`) |
| UserDefaults | `claudeGPTBackendEnabled`, `claudeGPTBackendPort`, `claudeGPTRouterPort`, Modellfelder, `gptAccountProfilesEnabled`, `chatGPTTranscriptionEnabled`, `claudeSharedMemoryEnabled`, `accountSwitchAfterTurnEnabled`, `mcpAutoSyncEnabled`, `mcpSyncExcludedServers`, `claudeCodeProxyAutoUpdateEnabled`, Merker `claudeSharedMemoryMigrationDone` | `AppPreferences`, Settings-Seiten |
| flüchtig | Vormerkungen (`AccountSwitchCoordinator.pending`), laufende Proxy-Handles, `GPTPromotedProfiles`, Token-Refresh-Drossel, `ClaudeCodeProxyModelRegistry` | Singletons im Prozess |

## Externe Abhängigkeiten

- **CLIs:** `claude` (`mcp add-json`, `-p` für Pings, `--bg`), `security` (Keychain lesen/schreiben/löschen), `lsof`/`ps` (Waisen-Erkennung), `tar`/`xattr` (Installer), `codex` (Login-Store, Modellkatalog `~/.codex/models_cache.json`), Terminal.app für den Claude-Login.
- **Netz:** `api.anthropic.com` (Nutzung, Router-Durchreichen), `chatgpt.com/backend-api` (Nutzung `wham/usage`, Transkription `transcribe`, Codex-Upstream über den Proxy), GitHub `raine/claude-code-proxy` (Releases, Prüfsummen-Sidecar), Anthropic-OAuth-Token aus der Keychain für die Nutzungsabfrage.
- **Prozesse:** nachgeladenes Fremdbinary `claude-code-proxy` (Loopback, Ports ab `claudeGPTBackendPort`, Profil-Instanzen ab Port+10), eigener Router-Listener.
- **TCC/Rechte:** keine eigene Berechtigung. Keychain-Zugriff auf Claudes Items kann Rückfragen auslösen. Kein Netz-/Mikro-Recht beteiligt (Audio kommt vom Diktat-Teil).
- **Inoffiziell/rechtlich:** ChatGPT-Abo-Upstream und Mehrfach-Claude-Konten (Nutzungsbedingungen, Entscheidung E3/E2 der Launch-Definition).

## Invarianten, die jeder Umbau erhalten muss

1. Der Profil-Stempel einer Session ist stabil; Resume läuft im Config-Dir, in dem das Transcript tatsächlich liegt. `main` bekommt nie `CLAUDE_CONFIG_DIR`; geerbtes `CLAUDE_CONFIG_DIR`/`ANTHROPIC_CUSTOM_HEADERS` wird aus der Basis-Umgebung entfernt.
2. Keychain-Service-Name hängt am Config-Pfad (sha256-Suffix): Rename/Promote müssen Login und Ordner gemeinsam und mit Rücknahme bewegen. Logins werden verschoben, nie kopiert (zwei Stores derselben Refresh-Familie entwerten sich).
3. Umzug: erst Transcript samt Subagent-Ordner, dann Stempel; Teilerfolge bleiben im Journal; ein Rückweg wird nicht selbst zum neuen Batch. Laufende Chats werden nie unter dem Prozess verschoben.
4. Kontowechsel nach dem Turn: Unbekannter Status zählt als beschäftigt; fehlender Trust im Zielkonto blockiert das Vormerken; Prozessende wird nachgewiesen, bevor Dateien wandern.
5. Memory-Migration: kopieren statt verschieben, Backup zuerst, nie überschreiben (Konflikt wird `<name>.<profil>.md`), idempotent; `main` bekommt kein `autoMemoryDirectory`-Fragment.
6. MCP-Angleich: nur ergänzen, nie löschen; abweichende Definitionen unter einem Namen werden nie verteilt; Definitionen nie ins Log.
7. Health nur bei `GET /healthz` mit 200, JSON, `{"ok":true}`, ohne Redirect. Alle Listener nur auf `127.0.0.1`. Nur selbst gestartete Handles werden regulär beendet.
8. Router: `gpt-*` geht an den Proxy, alles andere an Anthropic; Anthropic-Credentials werden vor dem Proxy entfernt; der Profil-Header ist reines Router-Signal und wird vor jedem Upstream gestrippt; Header „main" ist ausdrücklich und kontostabil.
9. Binary-Download nur mit SHA-256-Prüfung; Stempel und Binary dürfen nie divergieren; Auto-Update wirkt erst beim nächsten Proxy-Start.
10. Zusatz-GPT-Profile laufen mit eigenem `HOME` und eigener Auth-Datei; ein Profil ohne eigene `codex/auth.json` wird nie gestartet und fällt nicht still auf main.
11. Transkription geht direkt an den Instanzport, nie über den Router; kein Auto-Fallback auf Groq/OpenAI; „Connection refused" löst genau einen Start und einen Retry aus.
12. Die verwaltete `gpt.md` trägt den Marker `managed-by: whisperm8-gpt-backend`; fremde Dateien bleiben unangetastet.
13. Kill-Switches bleiben als Notbremse: `claudeSharedMemoryEnabled`, `accountSwitchAfterTurnEnabled`, `mcpAutoSyncEnabled`, `gptAccountProfilesEnabled`, `chatGPTTranscriptionEnabled`, `claudeCodeProxyAutoUpdateEnabled`.

## Top-Risiken (Quelle: `findings.jsonl`, Rohbericht `02-findings/A4-konten-gpt.md`)

| Risiko | LR-ID |
|---|---|
| OAuth-/Refresh-Token stehen bei Rename und Promote als `-w`-Argument im Prozess-argv (Doppelmeldungen -010, -011) | LR-KO-001 |
| MCP-Angleich legt Header-Tokens und Env-Secrets in argv offen | LR-KO-002 |
| Limit-Ping-Cleanup löscht per Namenssuffix fremde Projektordner samt Transcripts | LR-KO-003 |
| Router ohne Client-Authentisierung: jeder lokale Prozess verbraucht GPT-Konten | LR-GPT-001 |
| Fremder Listener mit nachgeahmtem `/healthz` übernimmt Prompts und Diktat-Audio | LR-GPT-002 |
| Port nahe 65535 plus Profil-Offset löst Overflow-Trap, App stürzt ab | LR-GPT-003 |
| Vorgemerkter Kontowechsel verwirft zwischenzeitlich getippten Entwurf (Race) | LR-KO-004 |
| Profil-Remove ohne Prozessschutz, Rename bricht Plugin-Registry, Keychain-Lesefehler gilt als „kein Login" | LR-KO-005, LR-KO-006, LR-KO-007 |
| Umzug nach main meldet Kollision als Erfolg; Teil-Undo löscht offene Journal-Einträge | LR-KO-008, LR-KO-009 |
| Start/Stop-Race lässt Proxy über App-Ende hinaus laufen (W7-Deinstallation) | LR-GPT-004, LR-BR-005 |
| Hauptkonto-Tausch ohne nachgewiesenes Prozessende; Waisen-Schutz killt extern gestartete Proxys | LR-GPT-005, LR-GPT-006 |
| Usage-Popover fragt GPT-Konten trotz ausgeschaltetem Backend | LR-GPT-007 |
| Berührungspunkte mit Agent-Chats: Summary-Läufe verlieren Konto/Backend, `resumeScans` setzt Stempel zurück, Background-Task-Cache | LR-AK-009, LR-AK-011, LR-AK-025 |
| Subprozesse erben App-Secrets; Labs/Experten nicht vom Setup getrennt | LR-SH-010, LR-ONB-012 |

Nicht als Befund geführt, aber beachtenswert: Der Prüfsummen-Sidecar neuerer Proxy-Versionen stammt aus demselben GitHub-Release wie das Archiv (Vertrauen nur über Transportsicherheit); nur die gepinnte Version `0.1.42` hat fest eingebaute Hashes.
