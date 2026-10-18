---
status: roh
updated: 2026-10-17
description: Workflow B, B2 Session-Manager — Vergleich mit anderen Projekten und Rahmenbedingungen (aus der strukturierten Agent-Rückgabe erzeugt).
---

# B2 Session-Manager

## Kurzfazit

B2 abgeschlossen, Recherche-Stand 17.10.2026, Status roh. Alle sechs Juli-Berichte sowie Launch-Definition, Feature-Inventar und ADR 0001 wurden gelesen; Fremdcode wurde ausschließlich gelesen, nichts gebaut oder ausgeführt. Kein Bericht wurde als Datei geschrieben; report_path bleibt deshalb leer. Die folgenden Ergebnisse sind zur direkten Übernahme durch den Hauptagenten bestimmt.

Kurzfazit: Priorität haben geführte CLI-Installation und Anmeldung, differenzierte Fehlerzustände und getestete Wiederaufnahme — nicht ein Stack-Wechsel oder zusätzliche Agenten. Conductor und Claude Desktop setzen beim Einstieg den Maßstab: benötigte Laufzeit bereitstellen, Anmeldung führen, ersten Erfolg ermöglichen. Superset ist inzwischen ein besonders relevanter Vergleich: echtes Terminal-Hosting, Lifecycle-Hooks, mehrere Konten und langlebiger PTY-Daemon.

Korrekturen zur Juli-Analyse: (1) Echtes eingebettetes TUI-Hosting und Hook-Status sind keine Alleinstellungsmerkmale; Superset und cmux widerlegen die damaligen Absolutaussagen. (2) Superset bietet inzwischen ausdrücklich mehrere Claude- und Codex-Konten. (3) opcode hat neue Commits vom September, aber weiterhin nur das Release v0.2.0 vom August 2025; Commit-Aktivität ist nicht gleich ausgelieferte Kompatibilität. (4) Crystal bleibt eingestellt, Nimbalyst ist jedoch öffentlich unter MIT verfügbar — die Juli-Einordnung als Closed Source ist falsch. (5) WhisperM8 verwendet inzwischen SwiftTerm 1.15 mit zwei Selection-Patches; Terminal-Snapshots und die alte Timeline sind entfallen. Empfehlungen zum Ausbau dieser gelöschten Komponenten sind obsolet. (6) Die pauschale Juli-Aussage, Resume erzeuge immer eine neue ID, darf nicht als Vertrag übernommen werden: reguläres Resume und explizites Fork müssen getrennt getestet werden. (7) Die aktuelle offizielle Dokumentation beschreibt automatisches Resume→Attach seit 2.1.285, aber ausdrücklich nicht mit mehreren Konfigurationsflags, darunter --settings. WhisperM8s eigener Attach-Fallback bleibt daher relevant.

Was WhisperM8 schon besser macht: Session-bezogene Hook-Dateien statt globalem Hook-Umbau; automatische Discovery beider CLI-Provider; explizite ESC-Heilung mit 5-Sekunden-Verifikation und zusätzlichem 180-Sekunden-Netz; profilgebundene Kontoumzüge einschließlich Trust-/Entwurfsprüfung; messbare Performance-Budgets. Das sind konkrete Architekturvorteile, keine nachgewiesene generelle Geschwindigkeitsüberlegenheit. Superset hat seinerseits inzwischen begrenzte Transcript-Tails, Fehlerstatus und einen UI-unabhängigen Prozess-Owner.

Offene Fragen: Installer-Flows wurden nicht auf einem frischen Mac ausgeführt; Signatur-/Notarisierungs-Pipelines wurden gelesen, veröffentlichte Binärdateien nicht kryptografisch geprüft. Anthropics Vertragsbedingungen für mehrere Konten werden hier nicht rechtlich bewertet. Bei Conductor wurden ausschließlich öffentliche UX-/Hilfeseiten untersucht; interne Status-, Discovery- und Persistenzmechanismen bleiben unbekannt. Die neu entdeckte September-Erweiterung Vitalini/claude-session-management hat keine verifizierte Lizenz. Ziel für die spätere Ablage durch den Hauptagenten: /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/docs/audit/2026-10-launch-readiness/03-vergleich/B2-session-manager.md.

## Untersuchte Projekte und Quellen

| Name | URL | Lizenz | Geprüft über | Relevanz |
|---|---|---|---|---|
| Superset | https://github.com/superset-sh/superset | Elastic License 2.0; source-available, nicht pauschal als uneingeschränkt Open Source behandeln | code | Wichtigster direkter Vergleich: echte CLI-Terminals, Hooks, native Transcript-Adapter, mehrere Konten, PTY-Daemon. Gelesener Stand bbee1df0cea918579211fccc09c068d2b1f012d9, Commit 17.10.2026; letztes API-gelistetes stabiles Release desktop-v1.38.0 vom 14.10.2026. LICENSE.md direkt gelesen. |
| opcode, ehemals Claudia | https://github.com/winfunc/opcode | AGPL-3.0 | code | Discovery über ~/.claude/projects, Rust-Prozessverwaltung und selbst gerenderter strukturierter CLI-Output. Stand d1ca30a3c0c39fff01fde2f86c2d5af6a1db658b vom 18.09.2026; letztes Release v0.2.0 vom 31.08.2025. Konkretes Negativbeispiel für veraltete Installationshilfe. |
| claude-squad | https://github.com/smtg-ai/claude-squad | AGPL-3.0 | code | Echte CLIs über tmux, Worktrees und eigener JSON-Zustand; Status aus Pane-Capture und Textmustern. Stand ce1ffb4392b01f38e2c4599c7c84d2a93973b138 vom 20.08.2026, Release v1.0.20 am selben Tag. Kein Desktop-Onboarding-Vorbild. |
| Crystal | https://github.com/stravu/crystal | MIT | code | Historische Referenz für Worktrees, eigene Sitzungsdaten und stream-json-Agenten neben PTY-Terminals. Stand 1e18e0bc981225f75b5226f82a300fa741970c6f vom 26.02.2026. README bestätigt ausdrücklich Einstellung im Februar 2026 zugunsten von Nimbalyst. |
| Vibe Kanban | https://github.com/BloopAI/vibe-kanban | Apache-2.0 | code | Task-/Worktree-Orchestrierung, strukturierte Executor-Protokolle, Agent-Verfügbarkeit und eigene Desktop-/Web-Flächen. Stand d5cbb5380fa0b32e98ef9b8d987f63decce4be3a vom 19.09.2026; README bestätigt weiterhin Sunsetting. Architekturvorbild, kein empfehlenswerter neuer Abhängigkeitsanker. |
| Conductor | https://www.conductor.build/docs/installation | — | doku | Nur UX/Doku untersucht. Installation prüft Voraussetzungen; FAQ bestätigt eigene gebündelte Claude-/Codex-Binaries und Nutzung vorhandener Anmeldung. Sehr relevantes Vorbild für E5 und Worktree-Einstieg. Lizenz, Signatur und interne Implementierung nicht verifiziert. |
| Claude Desktop und Claude Code | https://code.claude.com/docs/en/desktop-quickstart | — | doku | Offizielle Referenz für laiengerechten Erststart, Browser-Anmeldung, Code-Tab ohne separate CLI-Installation, Worktrees und Benachrichtigungen. CLI-Setup-, Sessions- und Hooks-Dokumentation am 17.10.2026 gelesen; kein interner Desktop-Code untersucht. |
| cmux | https://github.com/manaflow-ai/cmux | macOS-App grundsätzlich GPL-3.0-or-later; bestimmte Serververzeichnisse separat BUSL-1.1 | code | Direkter nativer Vergleich: Swift/AppKit, libghostty, echte CLIs, Hooks, sichtbare Aufmerksamkeitszustände und Resume-Bindungen. Stand 3e7ed5a562ae01cb1cd6ff1faa1a41bbf9f6251b vom 17.10.2026. Seit Januar existent, also neu im Vergleich, nicht seit Juli neu entstanden. |
| Claude Session Management | https://github.com/Vitalini/claude-session-management | Keine Lizenz verifiziert; GitHub-Metadaten liefern null | code | Tatsächlich seit Juli neu: Repository erstellt am 16.09.2026, letzter Commit 74a97a240f831412e6629c3dcae91adfded910af vom 02.10.2026. cmux-Erweiterung mit Transcript-Index, SQLite-Suche, Parken/Resume und optionalem Telegram-Watchdog. Installations-/Bedienkomplexität ist kein Laien-Vorbild. |
| Nimbalyst | https://github.com/nimbalyst/nimbalyst | MIT für dieses Repository; separater Collaboration-Server nicht eingeschlossen | doku | README und Lizenz direkt über GitHub gelesen; letzter Push laut API 16.10.2026. Korrigiert die Juli-Aussage Closed Source. Dokumentiert Session-Kanban, Worktrees, integriertes Terminal, mobilen Begleiter und stabile/Alpha-Updatekanäle; aktuelle interne Agent-Implementierung hier nicht erneut geprüft. |

## Antworten auf die Fragestellungen

### 1. Laien-Einstieg: CLI-Erkennung, Installation, Rückfrage, Login und fehlende Voraussetzungen?

**Konfidenz:** hoch

Conductor dokumentiert beim Start Werkzeug-/Credential-Prüfungen und geführte Einrichtung; die FAQ bestätigt gebündelte Claude-/Codex-Versionen unter Application Support. Browser-/Login-Details sind nicht vollständig öffentlich beschrieben. Claude Desktop hat den klarsten dokumentierten Weg: App installieren, anmelden, Code-Tab, Ordner wählen; separate CLI und Node.js sind dafür nicht nötig. Für WhisperM8 ist das ein UX-Maßstab, keine Aufforderung, die echte CLI durch Desktop oder SDK zu ersetzen.

Superset dokumentiert Live-Erkennung von Claude/Codex und eine automatisch aktualisierte Voraussetzungenliste. Im gelesenen aktuellen Onboarding-Code ist konkret eine alle vier Sekunden aktualisierte GitHub-CLI-Zeile mit Installations-/Anmeldedialog implementiert. Daraus folgt ausdrücklich noch kein verifizierter vollständiger Auto-Installer für Claude/Codex. Zusätzliche Agent-Konten melden sich in einem eingebetteten Terminaldialog an; Browserlinks öffnen den Systembrowser und erfolgreicher Login wird automatisch erkannt.

opcode sucht gespeicherte Pfade, PATH und typische Installationsorte und zeigt einen Auswahl-/Fehlendialog. Dieser empfiehlt tatsächlich den falschen Befehl npm install -g @claude. Die Release-Codeprüfung nimmt bei vorhandenem Binary-Pfad teilweise Installation an, ohne den Versionsaufruf durchzuführen. Das ist kein Vorbild für belastbare Einsatzbereitschaft.

claude-squad setzt tmux, gh und ein vorhandenes Agent-Programm voraus; Claude wird über Shell/PATH gesucht. Ein geführter OAuth-/CLI-Installationsablauf wurde nicht gefunden. Crystal setzt laut Welcome/Hilfe installierte CLIs mit Credentials voraus, startet inzwischen aber trotz fehlender CLIs; seine Manager liefern Installations-/PATH-Hinweise. Vibe Kanban verlangt vorherige Anmeldung und startet Agenten teilweise über gepinnte npx -y-Pakete. Verfügbarkeit wird bei Claude aus Existenz/mtime von ~/.claude.json, bei Codex unter anderem aus auth.json abgeleitet: kein Nachweis eines aktuell gültigen Logins.

WhisperM8 hat Codex-Statusprüfung über login status, aber bei fehlender CLI führt der Login-Knopf nur auf eine Hilfeseite; der vorhandene Login öffnet ein externes Terminal. Ein Claude-Installationsschritt fehlt im Onboarding. E5 deshalb mit einem expliziten, optionalen Installieren→Anmelden→Prüfen-Flow umsetzen. Aktuell offiziell dokumentiert sind sowohl Claudes nativer Installer als auch Codex' Standalone-Installer. Fremde Installationsbefehle nicht aus alten Manager-UIs übernehmen; keine heimliche npx-Nachinstallation und keine Installation beider CLIs für das Profil dictationRaw.

Quellen: https://www.conductor.build/docs/installation, https://www.conductor.build/docs/faq, https://code.claude.com/docs/en/desktop-quickstart, https://code.claude.com/docs/en/setup, https://learn.chatgpt.com/docs/codex/cli, https://github.com/superset-sh/superset/blob/bbee1df0cea918579211fccc09c068d2b1f012d9/apps/docs/content/docs/install.mdx, https://github.com/superset-sh/superset/blob/bbee1df0cea918579211fccc09c068d2b1f012d9/apps/desktop/src/renderer/routes/_authenticated/onboarding/page.tsx, https://github.com/superset-sh/superset/blob/bbee1df0cea918579211fccc09c068d2b1f012d9/apps/docs/content/docs/usage.mdx, https://github.com/winfunc/opcode/blob/d1ca30a3c0c39fff01fde2f86c2d5af6a1db658b/src/components/ClaudeBinaryDialog.tsx, https://github.com/winfunc/opcode/blob/d1ca30a3c0c39fff01fde2f86c2d5af6a1db658b/src-tauri/src/commands/claude.rs, https://github.com/smtg-ai/claude-squad/blob/ce1ffb4392b01f38e2c4599c7c84d2a93973b138/README.md, https://github.com/stravu/crystal/blob/1e18e0bc981225f75b5226f82a300fa741970c6f/main/src/utils/claudeCodeTest.ts, https://github.com/BloopAI/vibe-kanban/blob/d5cbb5380fa0b32e98ef9b8d987f63decce4be3a/crates/executors/src/executors/claude.rs, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Views/OnboardingView.swift, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/Dictation/CodexSupport.swift

### 2. Session-Discovery und Persistenz: native JSONL-Dateien und Format-Drift?

**Konfidenz:** hoch

opcode liest ausdrücklich ~/.claude/projects. Der History-Reader verarbeitet JSONL zeilenweise zu serde_json::Value und überspringt ungültige Zeilen. Das toleriert zusätzliche Felder, garantiert aber weder semantische Vollständigkeit noch sichtbare Drift-Diagnose.

Superset hat inzwischen eigene Claude-/Codex-Session-Adapter. Der Claude-Adapter verwendet Profil-Environment und reale Pfade, kennt den 200-Zeichen-Pfadencoder mit Hash und sucht IDs bei Bedarf über Projektordner. Bemerkenswert: hasSession unterscheidet true, false und null; ein nicht lesbarer oder abgeschnittener Scan beweist nicht, dass eine Session gelöscht wurde. Transcript-Tails wachsen begrenzt von 4 bis maximal 128 MiB und verwenden denselben offenen Dateideskriptor gegen Austauschrennen. Das ist eine gezielte Auflösung bekannter Sessions, kein Beleg für eine WhisperM8-identische automatische Discovery aller fremden Sessions. Zusätzliche Events/Blöcke werden im gelesenen textorientierten Adapter nicht vollständig projiziert.

claude-squad persistiert eigene Instanzen einschließlich Worktree-, Branch- und Statusdaten als JSON und verwaltet die zugehörigen tmux-Sessions; kein ~/.claude-Importer wurde im untersuchten Pfad gefunden. Crystal verwaltet selbst erzeugte Sessions und strukturierte Agent-Ausgabe in eigener Persistenz. Vibe Kanban startet eigene Executor-Sessions; der aktuelle Codex-Pfad nutzt app-server, nicht nur den im Juli zusammenfassend genannten stream-json-Ansatz. Conductor-Interna bleiben unbekannt.

Die September-Neuentwicklung Vitalini indexiert native Claude-Transcripts zeilenweise, hält mtime+size in SQLite und überspringt Parsefehler. Ihr Fallback auf die jüngste Datei ist für WhisperM8s Identitätsbindung ausdrücklich kein Vorbild. cmux hat eine konkrete Schutzlogik gegen Resume auf eine Session, die vor dem ersten Prompt nie ein Transcript geschrieben hat.

WhisperM8s bestehende Chunk-/Tail-Reader, externe Discovery und getrennte Workspace-/UI-Persistenz behalten. Juli-Empfehlung übernehmen: projected/ignoredKnown/unknown/malformed/pendingFragment unterscheiden und versionsübergreifende Fixtures pflegen. Nicht die entfernte FIFO-Timeline reparieren. Anthropic erklärt das JSONL-Format weiterhin ausdrücklich für intern und veränderlich. Hook-transcript_path als Anker verwenden; unbekannter Storezustand darf weder Archivierung noch Löschung oder stilles Neubinden auslösen.

Quellen: https://code.claude.com/docs/en/sessions#where-transcripts-are-stored, https://github.com/winfunc/opcode/blob/d1ca30a3c0c39fff01fde2f86c2d5af6a1db658b/src-tauri/src/commands/claude.rs, https://github.com/superset-sh/superset/blob/bbee1df0cea918579211fccc09c068d2b1f012d9/packages/host-service/src/terminal-agents/harness-sessions/claude.ts, https://github.com/superset-sh/superset/blob/bbee1df0cea918579211fccc09c068d2b1f012d9/packages/host-service/src/terminal-agents/harness-sessions/tail.ts, https://github.com/smtg-ai/claude-squad/blob/ce1ffb4392b01f38e2c4599c7c84d2a93973b138/session/storage.go, https://github.com/BloopAI/vibe-kanban/blob/d5cbb5380fa0b32e98ef9b8d987f63decce4be3a/crates/executors/src/executors/codex.rs, https://github.com/Vitalini/claude-session-management/blob/74a97a240f831412e6629c3dcae91adfded910af/scripts/index-sessions.mjs, https://github.com/manaflow-ai/cmux/blob/3e7ed5a562ae01cb1cd6ff1faa1a41bbf9f6251b/Sources/RestorableAgentSessionIndex%2BClaudeTranscriptlessResume.swift, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/docs/audit/2026-07-agent-chats-deep-dive/03-vergleich/jsonl-schema-drift.md, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/AgentChats/CodexTranscriptReader.swift

### 3. Status-Erkennung: Hooks, Parsing, SDK und Robustheit gegen ESC oder fehlende Stop-Ereignisse?

**Konfidenz:** hoch

Superset registriert für Claude aktuell SessionStart/End, UserPromptSubmit, Stop, StopFailure, SubagentStart/Stop, PostToolUse/Failure und PermissionRequest. Die UI unterscheidet working, permission, failed und ungelesenes review. Die Dokumentation räumt hängenden Running-Status nach erzwungenem Stop ausdrücklich ein und bietet Clear Status. Hooks allein sind also keine Vollständigkeitsgarantie. Superset schreibt seine Claude-Hooks in globale Settings; WhisperM8s sessionbezogene --settings-Datei ist hier weniger invasiv.

cmux registriert ebenfalls Lifecycle-Hooks einschließlich StopFailure und zeigt API-Fehler getrennt nach Nutzungslimit, Rate-Limit, Authentifizierung, Verbindungsabbruch, Überlastung und weiteren Ursachen. Das ist die unmittelbar übertragbare Verbesserung: Fehlgeschlagen ist nicht fertig und nicht nur still.

claude-squad vergleicht Hashes von tmux capture-pane und erkennt Eingabebedarf anhand konkreter englischer Prompttexte. Das ist UI- und sprachabhängig; unveränderter Bildschirm beweist keinen Turn-Abschluss. opcode und Crystal können für selbst gestartete strukturierte Runs Prozess- und Ausgabeereignisse verarbeiten; daraus folgt keine gleichwertige Live-Beobachtung beliebiger externer TUIs. Vibe Kanban nutzt eigene Protokoll-/Approval-Adapter, beim aktuellen Codex app-server. Conductor zeigt laut Doku geführte Agent-Arbeit, sein interner Statuskanal wurde nicht verifiziert.

WhisperM8 ist bei der konkret gelesenen ESC-Behandlung bereits weiter als eine bloße Stop-Hook-Lösung: ESC/Interrupt erzeugt einen Verdacht; nach fünf Sekunden wird nur bei unveränderten Hook- und Transcript-Zeitstempeln abgebrochen markiert. Zusätzlich heilt nur working nach über 180 Sekunden Hook-Stille und Transcript-idle; awaitingInput wird absichtlich nicht zeitbasiert gelöscht. Restrisiko langer stiller Verarbeitung bleibt. Im aktuellen HookSettingsBuilder fehlt aber StopFailure weiterhin. Ergänzung, Fehler-UI und echte CLI-Kompatibilitätstests priorisieren; keine pauschale Behauptung absolut korrekten Status und keine Rückkehr zu Spinner-/Screen-Regex.

Quellen: https://github.com/superset-sh/superset/blob/bbee1df0cea918579211fccc09c068d2b1f012d9/packages/agent-setup/src/agent-wrappers-claude-codex-opencode.ts, https://github.com/superset-sh/superset/blob/bbee1df0cea918579211fccc09c068d2b1f012d9/packages/shared/src/agent-status.ts, https://github.com/superset-sh/superset/blob/bbee1df0cea918579211fccc09c068d2b1f012d9/apps/docs/content/docs/agent-status.mdx, https://github.com/manaflow-ai/cmux/blob/3e7ed5a562ae01cb1cd6ff1faa1a41bbf9f6251b/CLI/CMUXCLI%2BClaudeHookSettings.swift, https://github.com/manaflow-ai/cmux/blob/3e7ed5a562ae01cb1cd6ff1faa1a41bbf9f6251b/CLI/CMUXCLI%2BClaudeHookStopFailure.swift, https://github.com/smtg-ai/claude-squad/blob/ce1ffb4392b01f38e2c4599c7c84d2a93973b138/session/tmux/tmux.go, https://code.claude.com/docs/en/hooks, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/AgentChats/ClaudeHookSettingsBuilder.swift, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift

### 4. Terminal-Hosting und Performance mit vielen parallelen Sessions?

**Konfidenz:** hoch

Superset hostet echte CLIs mit xterm.js und node-pty; der aktuelle Desktop-Paketstand nennt xterm 6.1.0-beta.315 und node-pty 1.2.0-beta.14. PTYs gehören einem gesonderten Daemon. cmux ist ein nativer Swift/AppKit-Host auf libghostty. Damit sind die Juli-Alleinstellungsbehauptungen über WhisperM8s echte TUI-Einbettung nicht haltbar. Die Existenz einer libghostty-basierten App beweist allerdings keine stabile, für WhisperM8 ohne Weiteres nutzbare Embedding-API und rechtfertigt keinen Stack-Wechsel.

claude-squad überlässt Darstellung und Prozessbesitz tmux und dem Benutzerterminal. opcode rendert strukturierte CLI-Ausgabe selbst statt ein voll interaktives Agent-TUI einzubetten. Crystal hat PTY-Terminals, sein gelesener Claude-Agentpfad startet aber stream-json; ein PTY als Transport bedeutet nicht automatisch Original-TUI-Hosting. Vibe Kanban verwendet xterm.js/portable-pty für seine Terminalflächen, während Agenten eigene strukturierte Executor-Pfade haben. Für Conductor wurde bewusst keine Renderer-/SDK-Implementierung behauptet.

Aktuelle Problemberichte sind konkret: Superset #6339 beschreibt fehlende Reaktionsfähigkeit ab vier Projekten mit mehreren Tabs auf M4 Pro/24 GB. #8108 nennt bei 209 Workspaces, sieben Hosts und etwa 20 TUIs 59–64 % eines Renderer-Kerns sowie periodische Eingabestalls; der Reporter ordnet das Query-/Persistenz-Churn in der Sidebar zu. Das sind Nutzerberichte, keine hier reproduzierten Messwerte. Der Juli-Sammeltracker #5602 enthält historische Speicher-, CPU- und Scrollback-Schreibprobleme; geschlossene Einzelissues darin wurden teilweise lediglich als veraltet zusammengeführt, nicht nachgewiesen behoben.

WhisperM8 bleibt gemäß ADR nativ auf SwiftTerm 1.15. Übertragbar sind Lastfälle und Ursachenklassen: viele Tabs plus Statusänderungen, große Transcripts, archivierte Layoutdaten, wiederholtes Öffnen/Schließen und reale Dateideskriptor-Churn-Tests. Kein pauschales Hochsetzen von Scrollback, kein Metal-Default und kein libghostty-Rewrite vor A/B-Messung.

Quellen: https://github.com/superset-sh/superset/blob/bbee1df0cea918579211fccc09c068d2b1f012d9/apps/desktop/package.json, https://github.com/superset-sh/superset/blob/bbee1df0cea918579211fccc09c068d2b1f012d9/packages/pty-daemon/README.md, https://github.com/superset-sh/superset/issues/6339, https://github.com/superset-sh/superset/issues/8108, https://github.com/superset-sh/superset/issues/5602, https://github.com/manaflow-ai/cmux/blob/3e7ed5a562ae01cb1cd6ff1faa1a41bbf9f6251b/README.md, https://github.com/stravu/crystal/blob/1e18e0bc981225f75b5226f82a300fa741970c6f/main/src/services/panels/claude/claudeCodeManager.ts, https://github.com/BloopAI/vibe-kanban/blob/d5cbb5380fa0b32e98ef9b8d987f63decce4be3a/crates/local-deployment/Cargo.toml, https://github.com/BloopAI/vibe-kanban/blob/d5cbb5380fa0b32e98ef9b8d987f63decce4be3a/packages/local-web/package.json, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/Package.swift, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/docs/adr/0001-kein-stack-wechsel.md

### 5. Worktrees, Isolation, Background-Agents und Benachrichtigungen?

**Konfidenz:** hoch

Superset, claude-squad, Crystal und Vibe Kanban organisieren parallele Aufgaben über Worktrees/Branches. Supersets README erklärt inzwischen ausdrücklich die wichtige Grenze: getrennte Arbeitsdateien sind keine Prozess-Sandbox und verhindern keine späteren Merge-Konflikte. Conductor setzt Workspaces ins Zentrum; Claude Desktop bietet Worktree-Wahl beim Sessionstart, Diff-Review und Betriebssystem-Benachrichtigungen. Diese taskbezogene Erklärung ist für Laien hilfreicher als ein bloßer Agent-/Tab-Katalog.

Supersets Terminal-Daemon hält Agent-Prozesse über Fenster-Schließen, App-Quit und Updates am Leben; vollständiges Beenden ist eine separate Aktion. Der gelesene Daemon-Vertrag enthält sogar FD-Handoff bei Daemon-Upgrades. Das ist stärker als WhisperM8s Wiederaufnahme nach einem Absturz, die den Gesprächsverlauf erneut startet, aber einen unterbrochenen Prozess nicht erhält. claude-squad erhält über tmux den Prozess-Owner außerhalb seiner TUI. Die Begriffe Hintergrund, unbeaufsichtigt und UI-unabhängiger Prozess müssen daher getrennt werden.

Superset und cmux liefern sichtbare Aufmerksamkeitsindikatoren und Notifications; Superset unterscheidet Eingabebedarf und Abschluss, cmux hebt Pane und Sidebar hervor. Vitalinis neue Erweiterung bietet Parken/Resume und optional Telegram, verlangt aber eine manuelle Wiederaufnahme statt nach dem Quotenreset automatisch eine ganze Flotte zu starten. Ein zusätzlicher externer Benachrichtigungskanal ist für WhisperM8 kein Launch-Muss und erzeugt neuen Datenabfluss.

WhisperM8 soll zuerst bestehende native --bg-/attach-Wege verständlich machen und drei Aktionen eindeutig erklären: Tab schließen, Chat stoppen, App beenden. Wiederaufnahme muss zwischen unbeabsichtigtem Prozessende und bewusstem Stop unterscheiden. Den Juli-Supervisor-Bericht weiter als Vertrag für bestätigtes Detach-Handoff, unabhängige Waiter und bestätigten Abschluss verwenden; seine damaligen Einzelbugs wurden in B2 nicht erneut als heute offen bewiesen. Einen allgemeinen PTY-Daemon nur nach dem Launch als eigenes größeres Architekturvorhaben prüfen. Optionaler Worktree-Erststart für parallele Schreibaufgaben ist sinnvoll, aber kein Anlass für einen IDE-/Git-Workflow-Neubau.

Quellen: https://github.com/superset-sh/superset/blob/bbee1df0cea918579211fccc09c068d2b1f012d9/README.md, https://github.com/superset-sh/superset/blob/bbee1df0cea918579211fccc09c068d2b1f012d9/apps/docs/content/docs/keep-agents-running.mdx, https://github.com/superset-sh/superset/blob/bbee1df0cea918579211fccc09c068d2b1f012d9/packages/pty-daemon/README.md, https://github.com/smtg-ai/claude-squad/blob/ce1ffb4392b01f38e2c4599c7c84d2a93973b138/README.md, https://code.claude.com/docs/en/desktop, https://www.conductor.build/docs/installation, https://github.com/manaflow-ai/cmux/blob/3e7ed5a562ae01cb1cd6ff1faa1a41bbf9f6251b/README.md, https://github.com/Vitalini/claude-session-management/blob/74a97a240f831412e6629c3dcae91adfded910af/README.md, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/AgentChats/AgentCrashRecovery.swift, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/docs/audit/2026-07-agent-chats-deep-dive/03-vergleich/supervisor-detach-vertraege.md

### 6. Mehrere Konten und Konto-Wechsel: bietet das jemand an, und wie?

**Konfidenz:** hoch

Ja: Superset bietet inzwischen einen ausdrücklichen Mehrkonten-Flow für Claude Code und Codex. Add account erzeugt ein Profil und öffnet dessen Login im Terminaldialog; Make default wirkt auf neue Starts, laufende Agenten behalten ihr Konto bis zum Neustart. Die technische Basis sind CLAUDE_CONFIG_DIR beziehungsweise CODEX_HOME. Die Doku beschreibt gemeinsames Setup und für Claude gemeinsame Conversation-History; Identitäten/Credentials bleiben pro Konto getrennt. Profilgebundene Login-Befehle und Tests zum Shell-Quoting sind im Code vorhanden. Die Juli-Erzählung, integriertes Multi-Account sei praktisch nur bei WhisperM8 zu finden, muss korrigiert werden.

Vibe Kanban dokumentiert CODEX_HOME für getrennte Konfigurationen; das ist noch kein vergleichbarer UI-Kontowechsler. Bei claude-squad, Crystal, opcode, Conductor und Claude Desktop wurde in dieser Stichprobe kein gleichwertiger, belegter Mehrkonten-Produktflow nachgewiesen. Das ist keine Behauptung, die Funktion existiere nirgends. cmux berücksichtigt CLAUDE_CONFIG_DIR bei Resume; das allein beweist ebenfalls keine Kontenverwaltung.

WhisperM8 geht im geprüften eigenen Modell weiter als Supersets dokumentierter Default-Wechsel: bestehende Chats können gezielt umziehen, beschäftigte Chats werden vorgemerkt, Trust und Composer-Entwurf werden berücksichtigt, Hauptkonto-Promotion und profilübergreifendes Memory/MCP sind eigene Funktionen. Diese Vorteile beibehalten und als Erweitert erklären. Keine automatische Quoten-Umgehung oder stillen Konto-Fallback einführen. Konto, Projektfreigabe und tatsächlich verwendeter CLI-Login müssen vor einem Neustart erkennbar sein. Die Zulässigkeit nach Anbieterbedingungen ist eine getrennte offene E3-Prüfung; die bloße Existenz ähnlicher Konkurrenzfeatures ist kein rechtlicher Beleg.

Quellen: https://github.com/superset-sh/superset/blob/bbee1df0cea918579211fccc09c068d2b1f012d9/apps/docs/content/docs/usage.mdx, https://github.com/superset-sh/superset/blob/bbee1df0cea918579211fccc09c068d2b1f012d9/apps/desktop/src/renderer/routes/_authenticated/settings/usage/components/UsageView/utils/switchSignInCommand/switchSignInCommand.ts, https://github.com/superset-sh/superset/blob/bbee1df0cea918579211fccc09c068d2b1f012d9/packages/host-service/src/trpc/router/usage/default-account.ts, https://github.com/BloopAI/vibe-kanban/blob/d5cbb5380fa0b32e98ef9b8d987f63decce4be3a/docs/agents/openai-codex.mdx, https://github.com/manaflow-ai/cmux/blob/3e7ed5a562ae01cb1cd6ff1faa1a41bbf9f6251b/CHANGELOG.md, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/AgentChats/AccountSwitchPlanner.swift, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/AgentChats/AccountSwitchCoordinator.swift, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/docs/audit/2026-10-launch-readiness/00-scope/launch-definition.md

### 7. Verteilung, Updates und Signatur der Desktop-Apps?

**Konfidenz:** mittel

Superset veröffentlicht macOS-DMGs und automatische Updates; die gelesene electron-builder-Konfiguration aktiviert hardenedRuntime und notarize, der Hauptprozess verwendet electron-updater. Das belegt die konfigurierte Pipeline, nicht die erfolgreiche Signatur jedes herunterladbaren Artefakts. cmux dokumentiert DMG und Homebrew sowie Sparkle-Autoupdates; seine Lizenz trennt App-Code von bestimmten kommerziell lizenzierten Serverteilen.

opcode hat einen expliziten macOS-Workflow mit Codesign, Notarisierung, Stapling und Gatekeeper-Prüfung. Gleichzeitig ist sein letztes veröffentlichtes Release sehr alt. Aus signingIdentity:null in einer lokalen Tauri-Konfiguration allein dürfte man deshalb weder allgemeine Unsicherheit noch fehlende Release-Signatur ableiten. Crystal hat electron-updater, ist aber eingestellt; seine Konfiguration und Release-Dokumentation unterscheiden zwischen deaktivierter lokaler Notarisierung und optionalem signierten Release. Kein guter Updatekanal für neue Nutzer.

Vibe Kanban dokumentiert weiterhin npx-Start, besitzt inzwischen aber auch eine Tauri-Desktop-Konfiguration und Notarisierungsschritte in CI. Das Projekt kündigt dennoch sein Ende an. claude-squad verteilt ein Terminal-Binary über Homebrew/manuellen Installer, keine vergleichbare macOS-Desktop-App. Conductor dokumentiert App-Download und Verschieben nach Applications; Signatur-/Update-Details wurden über die UX-Doku nicht verifiziert. Nimbalyst dokumentiert automatische Updates und getrennte Stable-/Alpha-Kanäle.

Für WhisperM8 bleiben E4 und Brew-only verbindlich: Developer-ID-Signatur und Notarisierung einschließlich releasefähiger Validierung statt Quarantäne-Entfernung. Den Bedienkomfort der Konkurrenz übernehmen, nicht deren zweiten Installationskanal: Update-Knopf erklärt Wirkung und führt ausschließlich den eigenen Brew-Cask-Upgradeweg aus. Nachprüfung muss installierte Version, Daten-/Tab-Erhalt und TCC-Rechte umfassen. Agent-Prozesse nicht unbemerkt für ein Update abbrechen; für Laien vorab benennen, was weiterläuft, beendet oder später wiederaufgenommen wird.

Quellen: https://github.com/superset-sh/superset/blob/bbee1df0cea918579211fccc09c068d2b1f012d9/apps/desktop/electron-builder.ts, https://github.com/superset-sh/superset/blob/bbee1df0cea918579211fccc09c068d2b1f012d9/apps/desktop/src/main/lib/auto-updater.ts, https://github.com/manaflow-ai/cmux/blob/3e7ed5a562ae01cb1cd6ff1faa1a41bbf9f6251b/README.md, https://github.com/manaflow-ai/cmux/blob/3e7ed5a562ae01cb1cd6ff1faa1a41bbf9f6251b/LICENSE, https://github.com/winfunc/opcode/blob/d1ca30a3c0c39fff01fde2f86c2d5af6a1db658b/.github/workflows/build-macos.yml, https://github.com/winfunc/opcode/releases/tag/v0.2.0, https://github.com/stravu/crystal/blob/1e18e0bc981225f75b5226f82a300fa741970c6f/main/src/autoUpdater.ts, https://github.com/BloopAI/vibe-kanban/blob/d5cbb5380fa0b32e98ef9b8d987f63decce4be3a/.github/workflows/pre-release.yml, https://www.conductor.build/docs/installation, https://github.com/nimbalyst/nimbalyst/blob/main/README.md, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/Shared/AppUpdateChecker.swift

## Übertragbar auf WhisperM8

### B2-R01 · Geführten CLI-Erststart als Launch-Gate umsetzen

*Priorität hoch · Aufwand L · Features F-APP-01, F-DIK-09, F-DIK-12, F-AC-02 · Entscheidung E5 b; E1 c; W3/W4*

In /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Views/OnboardingView.swift und einem neuen Shared-Setup-Service einen profilabhängigen Ablauf anbieten: prüfen → fehlende CLI nach erklärter Zustimmung mit offiziellem Installer installieren → erneut auflösen/Version prüfen → CLI-eigenen Browserlogin führen → Anmeldung prüfen → echten ersten Erfolg testen. Vorhandene Installationen wiederverwenden, Installationskanal erfassen, Abbruch/Offline/Proxy/PATH-Fehler mit konkreter Wiederholungsaktion behandeln. Raw-Diktat benötigt keine Agent-CLI.

**Begründung:** Die aktuelle Codex-Schaltfläche installiert nichts und öffnet bei fehlender CLI nur Hilfe. Conductor und Claude Desktop vermeiden genau diese Einstiegslücke. Eine Cask-Pflichtabhängigkeit für beide CLIs würde das Raw-Profil unnötig belasten und ersetzt keinen Login.

Quellen: https://www.conductor.build/docs/faq, https://code.claude.com/docs/en/desktop-quickstart, https://code.claude.com/docs/en/setup, https://learn.chatgpt.com/docs/codex/cli

### B2-R02 · StopFailure und sichtbare Fehlerzustände ergänzen

*Priorität hoch · Aufwand M · Features F-AC-06, F-AUT-05*

In /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/AgentChats/ClaudeHookSettingsBuilder.swift sowie Eventmodell/Reducer/Notifier StopFailure aufnehmen. API-Fehler, Anmeldung abgelaufen, Nutzungslimit und Verbindungsausfall dürfen weder als erfolgreicher Abschluss noch dauerhaft als working erscheinen. Bestehende ESC-Heilung behalten. Matcher pro Event korrekt modellieren; Notification nicht pauschal wieder aktivieren.

**Begründung:** Superset und cmux behandeln API-Fehler inzwischen explizit. WhisperM8s aktueller Builder registriert weiterhin nur acht Events ohne StopFailure. Fehlende Stop-Events sind eine reale Vertragslücke, keine durch Hooks generell gelöste Eigenschaft.

Quellen: https://code.claude.com/docs/en/hooks, https://github.com/superset-sh/superset/blob/bbee1df0cea918579211fccc09c068d2b1f012d9/packages/agent-setup/src/agent-wrappers-claude-codex-opencode.ts, https://github.com/manaflow-ai/cmux/blob/3e7ed5a562ae01cb1cd6ff1faa1a41bbf9f6251b/CLI/CMUXCLI%2BClaudeHookStopFailure.swift

### B2-R03 · Kompatibilitätsmatrix statt Vertrauen in alte CLI-Annahmen

*Priorität hoch · Aufwand M · Features F-AC-02, F-AC-05, F-AC-06, F-AC-09, F-AC-11*

Für /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/AgentChats/AgentCommandBuilder.swift und Status-/Recovery-Tests eine Matrix anlegen: frischer Start ohne ersten Prompt, Resume, Fork, TUI-internes Backgrounding, Resume mit --settings, zwei parallele Starts, ESC vor/nach erstem Output und fehlendes Transcript. Tatsächliche CLI-Version und Fähigkeiten erfassen. Automatisches natives Resume→Attach nicht blind als Ersatz für den bestehenden Fallback verwenden.

**Begründung:** Die aktuelle offizielle Sessions-Doku beschreibt Resume→Attach seit 2.1.285, schließt aber insbesondere --settings aus. cmux schützt explizit vor transcriptlosen Resume-Zielen. Juli-Annahmen zu ID-Rotation und pauschalem Background-Resume sind nicht als ewiger Vertrag geeignet.

Quellen: https://code.claude.com/docs/en/sessions#resume-a-running-background-session, https://github.com/manaflow-ai/cmux/blob/3e7ed5a562ae01cb1cd6ff1faa1a41bbf9f6251b/Sources/RestorableAgentSessionIndex%2BClaudeTranscriptlessResume.swift, https://github.com/superset-sh/superset/blob/bbee1df0cea918579211fccc09c068d2b1f012d9/apps/docs/content/docs/agent-sessions.mdx

### B2-R04 · Schema-Drift sichtbar und nicht destruktiv behandeln

*Priorität hoch · Aufwand M · Features F-AC-05, F-AC-08, F-AC-06*

In /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/AgentChats/ClaudeTranscriptReader.swift und /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/AgentChats/CodexTranscriptReader.swift bekannte ignorierte Events von unbekannten, defekten und noch unvollständigen Zeilen trennen. Zähler ohne Inhalte, begrenzte Diagnosen und Golden-Fixtures mehrerer CLI-Versionen ergänzen. Nicht lesbar/Scan unvollständig als unbekannt behandeln, niemals als Beweis für Löschung oder neue Identität.

**Begründung:** Anthropic erklärt das JSONL-Schema ausdrücklich für intern. Supersets dreistufige Existenzprüfung ist ein gutes übertragbares Muster; stilles Überspringen in Konkurrenzparsern dagegen kein Robustheitsbeweis. Juli-Analyse bleibt methodisch gültig, die gelöschte Timeline nicht.

Quellen: https://code.claude.com/docs/en/sessions#where-transcripts-are-stored, https://github.com/superset-sh/superset/blob/bbee1df0cea918579211fccc09c068d2b1f012d9/packages/host-service/src/terminal-agents/harness-sessions/claude.ts, https://github.com/winfunc/opcode/blob/d1ca30a3c0c39fff01fde2f86c2d5af6a1db658b/src-tauri/src/commands/claude.rs

### B2-R05 · Signierten Brew-Release und geführten Updateweg schließen

*Priorität hoch · Aufwand L · Features F-APP-04, F-APP-07, F-AC-09 · Entscheidung E4 b; W1/W6*

Release-Pipeline und /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/Shared/AppUpdateChecker.swift gemeinsam abnehmen: Developer ID, Hardened Runtime, Notarisierung/Stapling, reale Gatekeeper-Validierung, keine Quarantäne-Umgehung; Updateaktion ausschließlich über den eigenen Brew-Cask. Daten, Rechte und Chat-Lifecycle vor/nach Upgrade prüfen und erwartete Unterbrechung verständlich ankündigen.

**Begründung:** Konkurrenz liefert komfortable Update- und Signatur-Pipelines. Ihr Komfort ist übertragbar, Sparkle oder DMG-Direktvertrieb widersprechen jedoch dem beschlossenen einzigen Installationskanal. Eine konfigurierte Notarisierung allein ist noch kein geprüfter Release.

Quellen: https://github.com/superset-sh/superset/blob/bbee1df0cea918579211fccc09c068d2b1f012d9/apps/desktop/electron-builder.ts, https://github.com/winfunc/opcode/blob/d1ca30a3c0c39fff01fde2f86c2d5af6a1db658b/.github/workflows/build-macos.yml, https://github.com/manaflow-ai/cmux/blob/3e7ed5a562ae01cb1cd6ff1faa1a41bbf9f6251b/README.md

### B2-R06 · Viele Sessions als Pflicht-Lastfall behandeln

*Priorität hoch · Aufwand M · Features F-AC-01, F-AC-03, F-AC-04, F-AC-06, F-APP-08*

Die Messmatrix unter /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/docs/plans/workspace-performance/ um Status-Churn bei 20 offenen Tabs/sechs Panes, viele archivierte Sessions und wiederholten PTY-Churn erweitern. Sidebar-Publisher, Persistenz und Animationen getrennt messen; keine Dateizugriffe oder globale Neuaufbauten pro Statusereignis. Ressourcenansicht und Diagnose dürfen selbst keinen dauernden Lastpfad eröffnen.

**Begründung:** Superset #8108 berichtet periodische Typing-Stalls und 59–64 % eines Renderer-Kerns bei vielen Workspaces; #6339 nennt bereits vier Projekte. Kosten entstehen auch durch Status-/Persistenzmuster, nicht nur den Renderer. Diese Berichte belegen kein SwiftTerm- oder Stack-Problem, liefern aber sehr passende Regressionstests.

Quellen: https://github.com/superset-sh/superset/issues/8108, https://github.com/superset-sh/superset/issues/6339, https://github.com/superset-sh/superset/issues/5602

### B2-R07 · Stop, Schließen, Beenden und Resume verständlich trennen

*Priorität hoch · Aufwand M · Features F-AC-02, F-AC-03, F-AC-09, F-AC-11*

In /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Views/AgentChatsView+SessionLifecycle.swift und den Quit-/Update-Dialogen benennen, ob nur ein Tab verschwindet, der Agent gestoppt wird oder ein Background-Agent weiterarbeitet. Wiederaufnahme mit sichtbarem Start-/Fehler-/Retry-Zustand anbieten, bewusst gestoppte Chats nie automatisch starten. Prozessfortsetzung und Gesprächs-Resume sprachlich nicht gleichsetzen.

**Begründung:** Supersets Keep-Agents-Running-Tabelle macht Lebensdauer unmittelbar verständlich. WhisperM8s Crash-Recovery erhält nicht den laufenden PTY-Prozess; diese Grenze muss vor einem Update oder Quit erkennbar sein.

Quellen: https://github.com/superset-sh/superset/blob/bbee1df0cea918579211fccc09c068d2b1f012d9/apps/docs/content/docs/keep-agents-running.mdx, https://github.com/superset-sh/superset/blob/bbee1df0cea918579211fccc09c068d2b1f012d9/apps/docs/content/docs/agent-sessions.mdx

### B2-R08 · Kontenfunktionen als Erweitert erhalten, Herkunft sichtbar machen

*Priorität mittel · Aufwand M · Features F-KO-01, F-KO-02, F-KO-03, F-KO-04 · Entscheidung E3 a*

Bei /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/AgentChats/AccountSwitchCoordinator.swift und der Konten-UI deutlich trennen: Standard für neue Chats, Konto des laufenden Chats, vorgemerkter Umzug. Bestehende Trust-/Entwurfsprüfungen und Undo erhalten; keine automatische Rotation bei Limits. Anbieterbedingungen separat vor Launch prüfen.

**Begründung:** Superset unterstützt mehrere Konten, erklärt aber ausdrücklich, dass laufende Agenten bis zum Neustart auf ihrem Konto bleiben. WhisperM8s bestehender Umzugsfluss ist differenzierter; der Vorteil braucht verständliche Zustände statt versteckter Magie.

Quellen: https://github.com/superset-sh/superset/blob/bbee1df0cea918579211fccc09c068d2b1f012d9/apps/docs/content/docs/usage.mdx, https://github.com/superset-sh/superset/blob/bbee1df0cea918579211fccc09c068d2b1f012d9/packages/host-service/src/trpc/router/usage/default-account.ts

### B2-R09 · Optionale Worktree-Isolation erklären statt IDE nachbauen

*Priorität mittel · Aufwand L · Features F-AC-02, F-AC-12*

Für parallele Schreibaufgaben einen optionalen geführten Worktree-Start auf den vorhandenen Agent-/Projektbausteinen prüfen; Änderungen anschließend read-only zusammenfassen und an vorhandene Git-/Editorwerkzeuge übergeben. In /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/docs/features/agent-chats/ die Grenzen erklären: getrennte Dateien, keine Sicherheits-Sandbox, keine garantierte Konfliktfreiheit. Kein Launch-Blocker für einen vollständigen Diff/Merge-Editor.

**Begründung:** Worktrees sind das wiederkehrende nutzerseitige Muster bei Superset, claude-squad, Crystal, Vibe Kanban und Claude Desktop. Der Nutzen lässt sich übernehmen, ohne das beschlossene CLI-Host-Produkt durch eine IDE zu ersetzen.

Quellen: https://github.com/superset-sh/superset/blob/bbee1df0cea918579211fccc09c068d2b1f012d9/README.md, https://github.com/smtg-ai/claude-squad/blob/ce1ffb4392b01f38e2c4599c7c84d2a93973b138/README.md, https://code.claude.com/docs/en/desktop

### B2-R10 · Juli-Vergleich korrigieren und Überlegenheitsclaims entfernen

*Priorität mittel · Aufwand S · Features F-AC-02, F-AC-05, F-AC-06, F-KO-01*

Bei der späteren Übernahme in /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/docs/audit/2026-10-launch-readiness/03-vergleich/B2-session-manager.md die oben genannten Korrekturen explizit ausweisen. Echte TUI-Einbettung, Hooks und mehrere Konten nicht als exklusiv bewerben. Vorteile konkret an nicht invasiven Session-Hooks, providerübergreifender Discovery, Kontoumzug und Diktat-Verknüpfung erklären; Performance nur mit eigenen vergleichbaren Messungen behaupten.

**Begründung:** Superset und cmux widerlegen zentrale Absolutaussagen des Juli-Vergleichs; Nimbalysts MIT-Repository widerspricht der damaligen Closed-Source-Einordnung. Die Aktualisierung schützt die Launch-Kommunikation vor nachprüfbar falschen Claims.

Quellen: https://github.com/superset-sh/superset/blob/bbee1df0cea918579211fccc09c068d2b1f012d9/README.md, https://github.com/superset-sh/superset/blob/bbee1df0cea918579211fccc09c068d2b1f012d9/apps/docs/content/docs/usage.mdx, https://github.com/manaflow-ai/cmux/blob/3e7ed5a562ae01cb1cd6ff1faa1a41bbf9f6251b/README.md, https://github.com/nimbalyst/nimbalyst/blob/main/LICENSE

### B2-R11 · PTY-Daemon nur als späteres eigenständiges Vorhaben prüfen

*Priorität niedrig · Aufwand XL · Features F-AC-02, F-AC-09, F-AC-11*

Nach dem Launch prüfen, ob UI-unabhängiger PTY-Prozessbesitz den tatsächlichen Bedarf rechtfertigt. Bis dahin native --bg-/attach-Wege nutzen und Crash-Resume ehrlich erklären. Ein späterer Entwurf müsste versioniertes Handoff, Reattach, Stop-Bestätigung, sichere Socket-/FD-Lebensdauer und Updateverhalten vollständig definieren; kein spontaner Umbau von /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Views/AgentTerminalView.swift.

**Begründung:** Supersets Daemon mit FD-Handoff zeigt einen echten funktionalen Vorsprung, aber auch erheblichen Lifecycle-Aufwand. Die Juli-Supervisor-Prinzipien bleiben geeignet; sie sind kein Argument, vor dem Launch einen zweiten allgemeinen Supervisor einzuführen.

Quellen: https://github.com/superset-sh/superset/blob/bbee1df0cea918579211fccc09c068d2b1f012d9/packages/pty-daemon/README.md, https://github.com/superset-sh/superset/blob/bbee1df0cea918579211fccc09c068d2b1f012d9/apps/docs/content/docs/keep-agents-running.mdx, https://code.claude.com/docs/en/sessions#resume-a-running-background-session
