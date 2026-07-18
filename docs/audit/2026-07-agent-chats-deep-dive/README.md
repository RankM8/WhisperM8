---
status: abgeschlossen
updated: 2026-07-18 18:18
description: Einstieg und vollständiger Dokumentindex zum zweirundigen Agent-Chats-Deep-Dive-Audit von WhisperM8.
description_long: Fasst die bestätigten Stabilitäts-, Datenintegritäts-, Security-, Supervisor- und Transcript-Befunde sowie die Technologieentscheidungen zusammen und verlinkt alle Audit-Artefakte.
---

# Ultra Deep Dive: Agent Chats & Stabilität (2026-07-18)

> Status: **Audit abgeschlossen (2 Runden + Tech-Scan), Umsetzungsvorbereitung
> abgeschlossen (Workflow 3)**. Die erste Verifikationsrunde bestätigte
> C01–C16, die zweite N01–N16; keine der 32 adversarial geprüften Behauptungen
> wurde widerlegt. Die Plan-Verifikation aus Runde 2 ist in die
> [konsolidierte Roadmap](05-roadmap/refactor-roadmap.md) eingearbeitet.
> Workflow 3 (Feldvergleich von sieben Referenz-Repositories + Schluss-
> Verifikation) ist synthetisiert; Einstieg in die Umsetzungsphase:
> [06-umsetzung/README.md](06-umsetzung/README.md).

Multi-Agent-Audit des WhisperM8-Projekts (Fable-Finder + Codex-Refuter; Ablauf
siehe [WORKPLAN.md](WORKPLAN.md)) mit Fokus auf Stabilität,
Claude-/Codex-Integration, Diktat, Prozess- und Datenintegrität, Security,
Performance, Wartbarkeit und aktuelle Technologieoptionen.

## Kernergebnisse

- **Der gemeldete Diktat-Crash ist erklärt:** Zwischen Formatprüfung und
  `engine.start()` bleibt ein TOCTOU-Fenster für eine AVFoundation-
  NSException; der Configuration-Change-Handler arbeitet nach `await` zudem auf
  potenziell veralteter Engine-/Converter-Generation weiter (C01–C03).
- **Runde 2 ergänzt konkrete Datenverlustpfade:** App-Quit kann eine laufende
  Aufnahme verlieren (N02), doppelte oder inkompatible Output-Modi können
  crashen beziehungsweise alle Custom-Modi überschreiben (N03/N04), und
  Future-Schema- sowie fehlgeschlagene Keychain-Migrationen gefährden Session-
  oder Credential-Daten (N05/N06).
- **Der Codex-Supervisor-Vertrag ist nicht zuverlässig:** Der Detach erfolgt zu
  spät (N07), unvollständige Turns können als Erfolg enden (N08), und ein
  frühes Stop-Signal kann vor Prozessregistrierung verloren gehen (N14).
- **Prozessidentität und Secrets brauchen harte Grenzen:** Eine veraltete
  Terminal-PID kann im Race einen fremden Prozess treffen (N01), Agent-Kinder
  erben heute fremde Parent-Secrets (N09), und ein Claude-OAuth-Secret landet
  beim Profil-Rename in argv (N10).
- **Diktat-Auslieferung ist nicht sicher an das ursprüngliche Ziel gebunden:**
  Ein Fokuswechsel während Transkription oder Nachbearbeitung kann vertraulichen
  Text in einen anderen Chat senden (N11).
- **Job- und Transcript-Zustände haben belegte Lost-Update-/Drift-Lücken:**
  Orphan-Korrektur und UI-Composer können neuere Jobzustände überschreiben
  (N12/N13); parallele Tool-Resultate verlieren ihre Korrelation (N15), und
  unbekannte aktuelle Codex-Events verschwinden lautlos (N16).
- **Die Erstrunden-Befunde bleiben gültig:** Headless-Junk, falsches
  Claude-cwd-Encoding, unvollständige Profilpropagation und kaperbare
  Session-Bindung (C04–C09), fehlerhaftes PTY-Drain/Snapshotting (C10) sowie
  bestätigte Store-, Merge-, Git-, Window- und Transcript-Hotspots (C11–C16)
  sind weiterhin Teil der Roadmap.
- **Technologiepfad:** Swift 6.3 mit Complete Concurrency Checking im
  Swift-5-Modus jetzt adoptieren und Targets schrittweise migrieren;
  `claude agents --json` profilbezogen als Background-SSoT adoptieren;
  output-only Terminal-Recording jetzt, PTY-Broker und OSC-Protokolle erst
  später hinter klaren Security-/Lifecycle-Gates.
- **Nicht als Sofortlösung:** `swift-subprocess` erst nach stabilem 1.0 für
  einfache headless Commands pilotieren; es ersetzt weder SwiftTerm/PTY noch
  Supervisor- oder Environment-Policy. Ghostty, AUHAL und lokale
  Transkriptionsbackends bleiben getrennte, optionale Spikes.

## Dokumente

| Bereich | Dokument | Inhalt |
|---|---|---|
| Plan | [WORKPLAN.md](WORKPLAN.md) | Phasen, Agent-Aufstellung und Auditregeln |
| 01 Subsysteme | [background-jobs.md](01-subsysteme/background-jobs.md) | Background-Agenten, Jobs und Supervisor |
| 01 Subsysteme | [diktat.md](01-subsysteme/diktat.md) | Aufnahme-, Transkriptions- und Paste-Pipeline |
| 01 Subsysteme | [hooks-accounts.md](01-subsysteme/hooks-accounts.md) | Claude-Hooks, Profile und Account-Wechsel |
| 01 Subsysteme | [indexierung.md](01-subsysteme/indexierung.md) | Claude-/Codex-Indexer und Cachepfade |
| 01 Subsysteme | [persistenz.md](01-subsysteme/persistenz.md) | Workspace-, UI- und Report-Persistenz |
| 01 Subsysteme | [runtime-status.md](01-subsysteme/runtime-status.md) | Statusquellen und Zustandsautomat |
| 01 Subsysteme | [shared-infra.md](01-subsysteme/shared-infra.md) | Gemeinsame Infrastruktur und Updatepfade |
| 01 Subsysteme | [terminal.md](01-subsysteme/terminal.md) | PTY, SwiftTerm, Controller und Snapshots |
| 01 Subsysteme | [ui-shell.md](01-subsysteme/ui-shell.md) | Agent-Chats-Shell, Tabs, Grid und Fenster |
| 02 Findings | [architektur-wartbarkeit-fable.md](02-findings/architektur-wartbarkeit-fable.md) | Architektur- und Wartbarkeitsbefunde |
| 02 Findings | [claude-integration-codex.md](02-findings/claude-integration-codex.md) | Codex-Gegenprüfung der Claude-Integration |
| 02 Findings | [claude-integration-fable.md](02-findings/claude-integration-fable.md) | Claude-CLI-Korrektheit, Bindung und Profile |
| 02 Findings | [crash-diktat-codex.md](02-findings/crash-diktat-codex.md) | Codex-Gegenprüfung der Diktat-Crashpfade |
| 02 Findings | [crash-diktat-fable.md](02-findings/crash-diktat-fable.md) | Diktat-Crashjagd und Ursachenranking |
| 02 Findings | [memory-lifecycle-codex.md](02-findings/memory-lifecycle-codex.md) | Speicher-, Retain- und Lifecycle-Befunde |
| 02 Findings | [performance-codex.md](02-findings/performance-codex.md) | Ergänzende Performanceanalyse |
| 02 Findings | [performance-fable.md](02-findings/performance-fable.md) | Merge-, Git-, Body- und Transcript-Hotspots |
| 02 Findings | [races-agentchats-codex.md](02-findings/races-agentchats-codex.md) | Ergänzende Race- und Generation-Befunde |
| 02 Findings | [races-agentchats-fable.md](02-findings/races-agentchats-fable.md) | PTY-, Store-, Hook- und Scan-Races |
| 02 Findings | [robustheit-codex.md](02-findings/robustheit-codex.md) | Robustheit, Parserdrift und Recovery |
| 02 Findings Runde 2 | [runde2-cli-supervisor-codex.md](02-findings/runde2-cli-supervisor-codex.md) | CLI-Supervisor, Detach, Exit und Stop |
| 02 Findings Runde 2 | [runde2-grid-tabs-codex.md](02-findings/runde2-grid-tabs-codex.md) | Grid-, Tab- und Geometrieverhalten |
| 02 Findings Runde 2 | [runde2-onboarding-permissions-codex.md](02-findings/runde2-onboarding-permissions-codex.md) | Onboarding, Berechtigungen und App-Quit |
| 02 Findings Runde 2 | [runde2-postprocessing-codex.md](02-findings/runde2-postprocessing-codex.md) | Diktat-Nachbearbeitung und Output-Modi |
| 02 Findings Runde 2 | [runde2-security-codex.md](02-findings/runde2-security-codex.md) | Environment-, argv-, Datei- und Link-Security |
| 02 Findings Runde 2 | [runde2-settings-migration-codex.md](02-findings/runde2-settings-migration-codex.md) | Settings-, Schema- und Keychain-Migration |
| 02 Findings Runde 2 | [runde2-tests-qualitaet-codex.md](02-findings/runde2-tests-qualitaet-codex.md) | Testabdeckung und fehlende Oracles |
| 02 Findings Runde 2 | [runde2-transcript-rendering-codex.md](02-findings/runde2-transcript-rendering-codex.md) | Transcript-Parsing, Korrelation und Rendering |
| 02 Findings Runde 2 | [runde2-vollstaendigkeits-kritik.md](02-findings/runde2-vollstaendigkeits-kritik.md) | Auditabdeckung, Widersprüche und Methodik |
| 03 Vergleich | [claude-cli-oekosystem.md](03-vergleich/claude-cli-oekosystem.md) | CLI-Verträge, Bindung, Status und Multi-Account |
| 03 Vergleich | [claude-session-manager.md](03-vergleich/claude-session-manager.md) | Vergleich nativer und externer Session-Manager |
| 03 Vergleich | [diktat-apps.md](03-vergleich/diktat-apps.md) | Diktat-Apps, Audio-Lifecycle und Paste |
| 03 Vergleich | [swiftui-architektur.md](03-vergleich/swiftui-architektur.md) | Stores, Module, Persistenz und Tests |
| 03 Vergleich | [terminal-pty.md](03-vergleich/terminal-pty.md) | Terminalkerne, Scroll, Auswahl und Teardown |
| 03 Tech-Scan | [tech-claude-cli-2026.md](03-vergleich/tech-claude-cli-2026.md) | Aktuelle Claude-CLI-Hostschnittstellen |
| 03 Tech-Scan | [tech-swift-stack-2026.md](03-vergleich/tech-swift-stack-2026.md) | Swift 6, swift-subprocess, Testing und SwiftPM |
| 03 Tech-Scan | [tech-terminal-persistenz.md](03-vergleich/tech-terminal-persistenz.md) | Terminalkern, Recording, Broker und OSC |
| 03 Vergleich | [workflow3-kandidaten.md](03-vergleich/workflow3-kandidaten.md) | Kandidaten und Bewertung für Workflow 3 |
| 04 Verifikation | [verdicts.md](04-verifikation/verdicts.md) | Runde 1: C01–C16, alle bestätigt |
| 04 Verifikation | [verdicts-runde2.md](04-verifikation/verdicts-runde2.md) | Runde 2: N01–N16 plus Plan-Verifikation |
| 05 Roadmap | [plan-review.md](05-roadmap/plan-review.md) | Review von Prioritäten, Abhängigkeiten und Risiken |
| 05 Roadmap | [refactor-roadmap.md](05-roadmap/refactor-roadmap.md) | Konsolidierte, regressionsgesicherte Umsetzungswellen |
| 03 Vergleich (Workflow 3) | [code-analysen/](03-vergleich/code-analysen/verifikation-fable.md) | Sieben Repo-Codeanalysen (agent-deck, superset, cmux, nimbalyst, claudecodeui, claude-code-log, claude-agent-sdk-python) + Schluss-Verifikation |
| 06 Umsetzung | [06-umsetzung/README.md](06-umsetzung/README.md) | Einstieg Umsetzungsphase: verifizierte Feldvergleichs-Muster, Identitätsmodell als Kern-Umbau, Regressionsschutz-Vorgehen — Status: Umsetzungsvorbereitung abgeschlossen |
