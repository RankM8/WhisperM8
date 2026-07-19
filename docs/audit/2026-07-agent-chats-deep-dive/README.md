---
status: aktiv
updated: 2026-07-19
description: Einstieg und Dokumentindex zum Agent-Chats-Deep-Dive mit vier Findings-Runden, verifizierter Findings-Matrix, Roadmap-Nachträgen und offenem Umsetzungs-Gate.
---

# Ultra Deep Dive: Agent Chats & Stabilität (2026-07)

> **Status:** Die verifizierte Runde-4-Matrix korrigiert den Altbestand: C04 ist
> als offener Hoch-Defekt widerlegt, N01 nicht bestätigt, C10/N07 nur
> teilbestätigt und die beiden dokumentierten Alt-Teilfixe bleiben offen
> ([runde4-findings-matrix.md:17-73](04-verifikation/runde4-findings-matrix.md)).
> Runde 4 auditiert zusätzlich Chats-CLI, Context-Profile, Plugin-Manager,
> Statusline/Skills und GPT-Setup. Das Gesamtaudit ist weiterhin **nicht
> umsetzungsfreigegeben**: Keiner der fünf P0-Blocker ist entschärft; P0 1 und 3
> sind unverändert, P0 2, 4 und 5 verschärft
> ([runde4-abschlusskritik.md:13-23](02-findings/runde4-abschlusskritik.md)).
> Aktuelle Synthese: [06-umsetzung/README.md](06-umsetzung/README.md); Planung:
> [Roadmap mit Runde-4-Nachtrag](05-roadmap/refactor-roadmap.md#nachtrag-runde-4).

Multi-Agent-Audit des WhisperM8-Projekts (Fable-Finder, Codex-Refuter und
Workflow-3-Feldvergleich; Ablauf siehe [WORKPLAN.md](WORKPLAN.md)) mit Fokus auf
Stabilität, Claude-/Codex-Integration, Diktat, Prozess- und Datenintegrität,
Security, Performance, Wartbarkeit und Technologieoptionen.

## Kernergebnisse

### Basis aus Runde 1 und 2, korrigiert durch Runde 4

- **Diktat-Lifecycle:** C01–C03 belegen Crash-/Race-Risiken zwischen
  Audioformatprüfung, `engine.start()` und Reconfiguration; N02 ergänzt den
  Verlustpfad bei App-Quit.
- **Daten- und Credential-Schutz:** N03–N06 betreffen doppelte beziehungsweise
  inkompatible Output-Modi, Future-Schema-Downgrade und nichttransaktionale
  Keychain-Migration.
- **Supervisor und Prozessidentität:** N08 und N14 bestätigen Defekte bei
  semantischer Turn-Finalität und verlorenem frühen Stop-Intent. N07 ist nur
  teilbestätigt; N01 wurde an den angegebenen Stellen nicht bestätigt
  ([runde4-findings-matrix.md:30-49](04-verifikation/runde4-findings-matrix.md)).
- **Secrets und Zielbindung:** N09/N10 belegen zu breite Child-Environments und
  Secret in argv; N11 bindet Auto-Paste nicht sicher an den Aufnahme-Intent.
- **Store und Transcript:** N12/N13 belegen Lost Updates; N15/N16 fehlende
  Provider-Korrelation und lautlos verschwindende unbekannte Events. C04 ist als
  offener Hoch-Defekt widerlegt, C10 nur teilbestätigt; die übrigen bestätigten
  C-Befunde bleiben Bestandteil der Roadmap
  ([runde4-findings-matrix.md:17-29](04-verifikation/runde4-findings-matrix.md)).

### Runde 3 / Workflow 3

- **Identität ist der Kern-Umbau:** Die Feldanalyse bestätigt getrennte lokale
  Chat-, Provider-Branch- und Prozess-/PTY-Identitäten plus Config-Root-Scope
  sowie geplante→bestätigte Übergänge
  ([verifikation-fable.md:125-140](03-vergleich/code-analysen/verifikation-fable.md)).
  WhisperM8 bindet heute jede abweichende nichtleere Hook-ID ohne Fork-Parent-,
  Claim-, Config-Root- oder Transcriptpfad-Guard
  (`WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:345-363`).
- **Der Identitätsentwurf ist noch gesperrt:** Weg A/Weg B widersprechen sich,
  eine Launch-ID wird gefordert, aber nicht zum Hook transportiert, und
  `/branch`/`/rewind` fehlen in der Laufzeitmatrix. `SessionStart.source` wird
  heute verworfen (`WhisperM8/Services/AgentChats/ClaudeHookEventStore.swift:121-136`;
  [verifikation-schluss.md:86-130](06-umsetzung/verifikation-schluss.md)).
- **GPT-Backend:** Bestätigt sind 4 Definition-/Settings-, 7 MixRouter-, 5
  Proxy-Lifecycle- und 4 Security-Findings. Finder-G05 der
  Definition-/Settings-Runde ist widerlegt; MixRouter-G01 behält einen
  E2E-Teilvorbehalt. Der Roadmap-Nachtrag vergibt stabile IDs und Wellen
  ([runde3-vollstaendigkeits-kritik.md:66-138](02-findings/runde3-vollstaendigkeits-kritik.md)).
- **GPT-Ship-Blocker:** Background-Spawn kann Guard/Router-Environment umgehen,
  Kill-Switch und Start/Stop teilen keinen atomaren Lifecycle, Health ist
  imitierbar, und lokale Listener besitzen keine Client-Authentisierung
  (`WhisperM8/Services/AgentChats/BackgroundAgentSpawner.swift:78-137,223-258`;
  `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:218-300,469-537`;
  `WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:403-423`).
- **Usage/Kompaktierung:** Die Wirkung ist live bestätigt, die frühere Ursache
  „keine Übersetzung“ jedoch korrigiert. Der Diagnose-Nachtrag belegt einen
  pfadabhängigen Subagent-Vertrag; der GPT-spezifische Fensterwert ist als
  Teilfix dokumentiert, Proxy-/CLI-E2E- und Upstream-Gate bleiben offen. Die
  große Router-Fill-if-missing-Skizze ist nicht mehr das Ziel
  ([gpt-usage-kompaktierung-fix-spec.md:145-235](06-umsetzung/gpt-usage-kompaktierung-fix-spec.md)).
- **Terminal-Snapshots bleiben offen:** Für G01–G05 fehlt im aktuellen
  Dokumentbestand eine dedizierte Runde-3-Verdictmatrix. Privacy/Retention,
  Löschdurability und kaputter-Sidecar-Fallback sind deshalb keine abgeschlossene
  bestätigte Population; die Existenzprüfung kann den JSONL-Fallback trotz
  ungültigem Snapshot blockieren
  (`WhisperM8/Services/AgentChats/TerminalSnapshotStore.swift:70-73,94-119`;
  `WhisperM8/Views/AgentSessionDetailView.swift:201-225,255-260`).
- **Regressionsschutz vor Refactor:** Die Feature-Inventare sind Referenzen, aber
  noch zu korrigieren. Kategorie-1-Verträge werden vor dem Umbau getestet;
  Kategorie-2-Bugs erhalten Rot→Grün-Tests mit dem jeweiligen Fix. Die aktuelle
  Test-Spec lässt insbesondere C07 und mehrere Welle-1-Verträge aus
  ([verifikation-schluss.md:256-329](06-umsetzung/verifikation-schluss.md)).
- **Audit-Abdeckung ist nicht quellbaumweit:** Die mechanische Kritik findet 138
  von 281 Swift-Dateien ohne Finder-Zuordnung und priorisiert Usage/Credentials,
  CLI, Agent-Launch, Grid/Drag-Drop, Transcript-Rendering und Diktat-Provider für
  einen risikobasierten Nachlauf. Diese Zahl ist ausdrücklich keine Defektzahl
  ([runde3-vollstaendigkeits-kritik.md:323-380](02-findings/runde3-vollstaendigkeits-kritik.md)).

### Runde 4

- **Chats-CLI:** Sechs hohe Befunde betreffen fehlende Actor-Autorisierung,
  nicht authentisierten Serverkontakt, nicht retry-stabile Idempotenz, zwei
  blinde `wait`-Verträge und abweichende Profilstempel. Der Server prüft heute
  nur Same-EUID (`WhisperM8/Services/AgentChats/AgentControlServer.swift:228-239`),
  während `wait` ein unveränderliches Entry-Array hält
  (`WhisperM8/CLI/ChatsWaitEngine.swift:41-67,321-342`).
- **Context-Profile:** Restriktions-Settings fallen bei Schreibfehlern offen aus,
  Respawn verwendet ein altes Overlay und der Profilfilter kann bereinigte
  `CLAUDE_CODE_*`-Identität wieder einführen
  (`WhisperM8/Services/AgentChats/ClaudeHookBridge.swift:86-118`;
  `WhisperM8/Services/AgentChats/BackgroundAgentLifecycle.swift:99-106,150-172`;
  `WhisperM8/Services/AgentChats/ClaudeContextSettingsBuilder.swift:13-24,56-67`).
- **Plugin-Manager:** Secrets können über freie `--config key=value`-Argumente
  in argv gelangen, und Headless-Failsafe plus Serializer garantieren keine
  Prozessbaum-Finalität (`WhisperM8/Services/AgentChats/ClaudePluginCLI.swift:91-101`;
  `WhisperM8/Services/AgentChats/AgentHeadlessCLI.swift:78-111,174-190`).
- **Statusline und Skills:** App-Bundle und Lookup-Ort driften auseinander,
  externe Anzeigetexte werden mit `echo -e` erneut interpretiert, Settings-
  Updates können Fremdwrites verlieren und Skill-Updates besitzen keinen
  Ownership-Guard (`WhisperM8/Services/Shared/StatuslineInstaller.swift:24-27,70-76,190-216`;
  `Makefile:217-245`; `WhisperM8/Resources/whisperm8-statusline.sh:36-56,232-249,369-429`;
  `WhisperM8/Services/Shared/CLISkillExporter.swift:127-177`).
- **GPT-Setup:** Nicht gepinnte Updates beziehen Payload und Hash aus derselben
  Quelle; Setup/Refresh besitzen keine belastbare Generation
  (`WhisperM8/Services/AgentChats/ClaudeCodeProxyBinaryInstaller.swift:123-150`;
  `WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:404-492`).
- **Breiter Delta-/Abdeckungsnachlauf:** Weitere bestätigte Hochbefunde betreffen
  Paste-/Submit-Korrektheit, Future-Schema, Resume-/Startup-Lifecycle, doppelte
  Session-IDs sowie blockierende Git-/ffmpeg-Pipes
  (`WhisperM8/Views/AgentTerminalView.swift:649-667`;
  `WhisperM8/Models/AgentChat.swift:602-627`;
  `WhisperM8/Services/AgentChats/SummaryStartupPlanner.swift:9-20`;
  `WhisperM8/Services/AgentChats/AgentWorktreeManager.swift:73-87`;
  `WhisperM8/CLI/CLIAudioExtractor.swift:197-211`).
- **Freigabefolge bleibt gesperrt:** Keiner der fünf P0-Blocker ist entschärft;
  G0–G6 der Abschlusskritik und der Runde-4-Roadmap-Nachtrag bilden den
  Restweg ([runde4-abschlusskritik.md:25-78](02-findings/runde4-abschlusskritik.md)).

## Freigabeautorität

Die aktuelle Reihenfolge der Autorität lautet:

1. [runde4-abschlusskritik.md](02-findings/runde4-abschlusskritik.md) für
   P0-Status und den aktuellen Freigabeweg;
2. [runde4-findings-matrix.md](04-verifikation/runde4-findings-matrix.md) für
   den verifizierten Status der bisherigen kritisch/hoch-Population;
3. [verifikation-schluss.md](06-umsetzung/verifikation-schluss.md) für
   Identitäts-/Recovery-Specs und Inventar-/Testfreigabe;
4. [runde3-vollstaendigkeits-kritik.md](02-findings/runde3-vollstaendigkeits-kritik.md)
   für die historische Gesamtvollständigkeit;
5. [refactor-roadmap.md](05-roadmap/refactor-roadmap.md) für Wellen und die
   Runde-3-/Runde-4-Zuordnung;
6. [06-umsetzung/README.md](06-umsetzung/README.md) als Synthese.

`plan-review.md`, `verdicts-runde2.md` und frühere Statusformulierungen bleiben
historische Eingaben; sie erteilen allein keine aktuelle Umsetzungsfreigabe.

## Dokumente

### Plan, Subsysteme und Findings Runde 1/2

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
| 01 Subsysteme | [ui-shell.md](01-subsysteme/ui-shell.md) | Shell, Tabs, Grid und Fenster |
| 02 Findings | [architektur-wartbarkeit-fable.md](02-findings/architektur-wartbarkeit-fable.md) | Architektur und Wartbarkeit |
| 02 Findings | [claude-integration-codex.md](02-findings/claude-integration-codex.md) | Gegenprüfung Claude-Integration |
| 02 Findings | [claude-integration-fable.md](02-findings/claude-integration-fable.md) | CLI-Korrektheit, Bindung und Profile |
| 02 Findings | [crash-diktat-codex.md](02-findings/crash-diktat-codex.md) | Gegenprüfung Diktat-Crashpfade |
| 02 Findings | [crash-diktat-fable.md](02-findings/crash-diktat-fable.md) | Diktat-Crashjagd |
| 02 Findings | [memory-lifecycle-codex.md](02-findings/memory-lifecycle-codex.md) | Speicher und Lifecycle |
| 02 Findings | [performance-codex.md](02-findings/performance-codex.md) | Ergänzende Performanceanalyse |
| 02 Findings | [performance-fable.md](02-findings/performance-fable.md) | Merge-, Git-, Body- und Transcript-Hotspots |
| 02 Findings | [races-agentchats-codex.md](02-findings/races-agentchats-codex.md) | Race- und Generation-Befunde |
| 02 Findings | [races-agentchats-fable.md](02-findings/races-agentchats-fable.md) | PTY-, Store-, Hook- und Scan-Races |
| 02 Findings | [robustheit-codex.md](02-findings/robustheit-codex.md) | Robustheit, Parserdrift und Recovery |
| 02 Runde 2 | [runde2-cli-supervisor-codex.md](02-findings/runde2-cli-supervisor-codex.md) | CLI-Supervisor, Detach, Exit und Stop |
| 02 Runde 2 | [runde2-grid-tabs-codex.md](02-findings/runde2-grid-tabs-codex.md) | Grid-, Tab- und Geometrieverhalten |
| 02 Runde 2 | [runde2-onboarding-permissions-codex.md](02-findings/runde2-onboarding-permissions-codex.md) | Onboarding, Berechtigungen und App-Quit |
| 02 Runde 2 | [runde2-postprocessing-codex.md](02-findings/runde2-postprocessing-codex.md) | Nachbearbeitung und Output-Modi |
| 02 Runde 2 | [runde2-security-codex.md](02-findings/runde2-security-codex.md) | Environment-, argv-, Datei- und Link-Security |
| 02 Runde 2 | [runde2-settings-migration-codex.md](02-findings/runde2-settings-migration-codex.md) | Settings, Schema und Keychain |
| 02 Runde 2 | [runde2-tests-qualitaet-codex.md](02-findings/runde2-tests-qualitaet-codex.md) | Testabdeckung und Oracles |
| 02 Runde 2 | [runde2-transcript-rendering-codex.md](02-findings/runde2-transcript-rendering-codex.md) | Transcript-Parsing und Rendering |
| 02 Runde 2 | [runde2-vollstaendigkeits-kritik.md](02-findings/runde2-vollstaendigkeits-kritik.md) | Auditabdeckung und Blindstellen |

### Vergleich, Tech-Scan und Workflow-3-Feldanalyse

| Bereich | Dokument | Inhalt |
|---|---|---|
| 03 Vergleich | [claude-cli-oekosystem.md](03-vergleich/claude-cli-oekosystem.md) | CLI-Verträge, Status und Multi-Account |
| 03 Vergleich | [claude-session-manager.md](03-vergleich/claude-session-manager.md) | Native und externe Session-Manager |
| 03 Vergleich | [diktat-apps.md](03-vergleich/diktat-apps.md) | Diktat-Apps und Audio-Lifecycle |
| 03 Vergleich | [swiftui-architektur.md](03-vergleich/swiftui-architektur.md) | Stores, Module, Persistenz und Tests |
| 03 Vergleich | [terminal-pty.md](03-vergleich/terminal-pty.md) | Terminalkerne und Teardown |
| 03 Tech-Scan | [tech-claude-cli-2026.md](03-vergleich/tech-claude-cli-2026.md) | Aktuelle Claude-CLI-Hostschnittstellen |
| 03 Tech-Scan | [tech-swift-stack-2026.md](03-vergleich/tech-swift-stack-2026.md) | Swift 6, Subprocess, Testing und SwiftPM |
| 03 Tech-Scan | [tech-terminal-persistenz.md](03-vergleich/tech-terminal-persistenz.md) | Recording, Broker und OSC |
| Workflow 3 | [workflow3-kandidaten.md](03-vergleich/workflow3-kandidaten.md) | Kandidaten und Edge-Case-Landkarte |
| Workflow 3 | [code-analysen/agent-deck.md](03-vergleich/code-analysen/agent-deck.md) | Fork-Datenmodell und Identitätsscope |
| Workflow 3 | [code-analysen/superset.md](03-vergleich/code-analysen/superset.md) | Terminal-Adoption und Reaper |
| Workflow 3 | [code-analysen/cmux.md](03-vergleich/code-analysen/cmux.md) | Fork-Guard und Runtime-Generation |
| Workflow 3 | [code-analysen/nimbalyst.md](03-vergleich/code-analysen/nimbalyst.md) | Resume-Fehlerklassen und Reconciliation |
| Workflow 3 | [code-analysen/claudecodeui.md](03-vergleich/code-analysen/claudecodeui.md) | Zwei-Spalten-Identität und Watcher-Merge |
| Workflow 3 | [code-analysen/claude-code-log.md](03-vergleich/code-analysen/claude-code-log.md) | Transcript-DAG und Korrelation |
| Workflow 3 | [code-analysen/claude-agent-sdk-python.md](03-vergleich/code-analysen/claude-agent-sdk-python.md) | Übergangsnorm und Flag-Härtung |
| Workflow 3 | [code-analysen/verifikation-fable.md](03-vergleich/code-analysen/verifikation-fable.md) | Schluss-Verifikation der sieben Repo-Analysen |
| Workflow 3 neu | [code-analysen/claude-code-router.md](03-vergleich/code-analysen/claude-code-router.md) | Router-/Gateway-Analyse |
| Workflow 3 neu | [supervisor-detach-vertraege.md](03-vergleich/supervisor-detach-vertraege.md) | Ready/Detach, Waiter und Stop-Latch |
| Workflow 3 neu | [jsonl-schema-drift.md](03-vergleich/jsonl-schema-drift.md) | Provider-IDs, Parse-Outcome und Drift |
| Workflow 3 neu | [tech-observability-secrets.md](03-vergleich/tech-observability-secrets.md) | Crash-Observability und Secrets |
| Workflow 3 neu | [proxy-muster-litellm.md](03-vergleich/proxy-muster-litellm.md) | Proxy-/SSE-Mustervergleich |

### Runde 3: Findings und Verifikation

| Bereich | Dokument | Inhalt / Urteil |
|---|---|---|
| 02 Runde 3 | [runde3-gpt-backend-definition-settings.md](02-findings/runde3-gpt-backend-definition-settings.md) | Skill, Definition und Settings |
| 02 Runde 3 | [runde3-gpt-backend-mixrouter.md](02-findings/runde3-gpt-backend-mixrouter.md) | MixRouter-Protokoll und Ressourcen |
| 02 Runde 3 | [runde3-gpt-backend-proxy.md](02-findings/runde3-gpt-backend-proxy.md) | Proxy-Lifecycle |
| 02 Runde 3 | [runde3-gpt-backend-security.md](02-findings/runde3-gpt-backend-security.md) | Lokale Vertrauensgrenze |
| 02 Runde 3 | [runde3-live-repro-usage-kompaktierung.md](02-findings/runde3-live-repro-usage-kompaktierung.md) | Live-Wirkung; ursprüngliche Ursache korrigiert |
| 02 Runde 3 | [runde3-terminal-snapshots.md](02-findings/runde3-terminal-snapshots.md) | Fünf Findings; finale Runde-3-Matrix fehlt |
| 02 Runde 3 | [runde3-vollstaendigkeits-kritik.md](02-findings/runde3-vollstaendigkeits-kritik.md) | Gesamtkritik und Freigabe-Gate |
| 04 Runde 3 | [runde3-definition-settings.md](04-verifikation/runde3-definition-settings.md) | 4 bestätigt, 1 widerlegt |
| 04 Runde 3 | [runde3-mixrouter.md](04-verifikation/runde3-mixrouter.md) | 7 bestätigt; G01 mit E2E-Teilvorbehalt |
| 04 Runde 3 | [runde3-proxy.md](04-verifikation/runde3-proxy.md) | 5 bestätigt |
| 04 Runde 3 | [runde3-security.md](04-verifikation/runde3-security.md) | 4 bestätigt; G03 abgestuft |
| 04 Runde 3 | [runde3-recherche-muster.md](04-verifikation/runde3-recherche-muster.md) | Supervisor/JSONL/Observability/Secrets |
| 04 Runde 3 | [runde3-recherche-proxy.md](04-verifikation/runde3-recherche-proxy.md) | Reale Proxy-Lücken und Widerlegungen |

### Runde 4: Findings, Refuter-Urteile und Abschlusskritik

| Bereich | Dokument | Inhalt / Urteil |
|---|---|---|
| 02 Runde 4 | [runde4-abdeckung-services.md](02-findings/runde4-abdeckung-services.md) | Risikobasierter Nachlauf Services |
| 02 Runde 4 | [runde4-abdeckung-views-cli.md](02-findings/runde4-abdeckung-views-cli.md) | Risikobasierter Nachlauf Views und CLI |
| 02 Runde 4 | [runde4-chats-cli.md](02-findings/runde4-chats-cli.md) | Chats-CLI, Control-Socket und Wait |
| 02 Runde 4 | [runde4-context-profile.md](02-findings/runde4-context-profile.md) | Context-Profile und Account-Scope |
| 02 Runde 4 | [runde4-delta-auditierte-dateien.md](02-findings/runde4-delta-auditierte-dateien.md) | Delta der neu auditierten Dateien |
| 02 Runde 4 | [runde4-gpt-setup.md](02-findings/runde4-gpt-setup.md) | GPT-Installation, Setup und Login |
| 02 Runde 4 | [runde4-plugin-manager.md](02-findings/runde4-plugin-manager.md) | Plugin-Manager und Headless-CLI |
| 02 Runde 4 | [runde4-statusline-skills.md](02-findings/runde4-statusline-skills.md) | Statusline, Installer und Skills |
| 02 Runde 4 | [runde4-abschlusskritik.md](02-findings/runde4-abschlusskritik.md) | Fünf P0-Blocker: zwei unverändert, drei verschärft |
| 04 Runde 4 | [runde4-abdeckung-services.md](04-verifikation/runde4-abdeckung-services.md) | 3 hohe und 2 mittlere Stichproben bestätigt |
| 04 Runde 4 | [runde4-abdeckung-views-cli.md](04-verifikation/runde4-abdeckung-views-cli.md) | 1 hoher und 2 mittlere Befunde bestätigt |
| 04 Runde 4 | [runde4-chats-cli.md](04-verifikation/runde4-chats-cli.md) | 6 hohe und 2 mittlere Befunde bestätigt |
| 04 Runde 4 | [runde4-context-profile.md](04-verifikation/runde4-context-profile.md) | 3 hohe und 2 mittlere Befunde bestätigt |
| 04 Runde 4 | [runde4-delta-auditiert.md](04-verifikation/runde4-delta-auditiert.md) | 10 bestätigt; eigene Schwere: 7 hoch, 3 mittel |
| 04 Runde 4 | [runde4-gpt-setup.md](04-verifikation/runde4-gpt-setup.md) | 2 hohe und 2 mittlere Befunde bestätigt |
| 04 Runde 4 | [runde4-plugin-manager.md](04-verifikation/runde4-plugin-manager.md) | 2 hohe und 2 mittlere Befunde bestätigt |
| 04 Runde 4 | [runde4-statusline-skills.md](04-verifikation/runde4-statusline-skills.md) | 4 hohe, 2 mittlere und 1 niedriger Befund bestätigt |
| 04 Runde 4 | [runde4-findings-matrix.md](04-verifikation/runde4-findings-matrix.md) | Verifizierte kritisch/hoch-Matrix und Alt-Teilfixe |

### Roadmap und Umsetzungsvorbereitung

| Bereich | Dokument | Inhalt / aktueller Stand |
|---|---|---|
| 04 Verifikation | [verdicts.md](04-verifikation/verdicts.md) | Runde 1: C01–C16 |
| 04 Verifikation | [verdicts-runde2.md](04-verifikation/verdicts-runde2.md) | Runde 2: N01–N16 und historischer Plan-Verdict |
| 04 Verifikation | [nachpruefung-fable.md](04-verifikation/nachpruefung-fable.md) | Nachprüfung früherer Verdicts |
| 05 Roadmap | [plan-review.md](05-roadmap/plan-review.md) | Historischer Review von Prioritäten und Risiken |
| 05 Roadmap | [konsistenz-check-fable.md](05-roadmap/konsistenz-check-fable.md) | C/N-Konsistenz und alte Restlücken |
| 05 Roadmap | [findings-matrix.md](05-roadmap/findings-matrix.md) | Historische deduplizierte C/N-/Runde-3-Matrix; durch Runde-4-Verifikation korrigiert |
| 05 Roadmap | [refactor-roadmap.md](05-roadmap/refactor-roadmap.md) | Bestehende Wellen plus Runde-3-/Runde-4-Nachtrag; kein Produkt-Go |
| 06 Umsetzung | [README.md](06-umsetzung/README.md) | Aktuelle Workflow-3-Synthese und Gate |
| 06 Umsetzung | [identitaetsmodell-spec.md](06-umsetzung/identitaetsmodell-spec.md) | Entwurf; Revision erforderlich |
| 06 Umsetzung | [verlorene-chats-spec.md](06-umsetzung/verlorene-chats-spec.md) | Recovery-Spec; Binding-Teile gesperrt |
| 06 Umsetzung neu | [feature-inventar-agentchats.md](06-umsetzung/feature-inventar-agentchats.md) | Breit, aber als Oracle noch zu korrigieren |
| 06 Umsetzung neu | [feature-inventar-diktat.md](06-umsetzung/feature-inventar-diktat.md) | Nahezu freigabefähig; Ergänzungen offen |
| 06 Umsetzung neu | [test-specs-welle0-1.md](06-umsetzung/test-specs-welle0-1.md) | Neu zu schneiden und zu vervollständigen |
| 06 Umsetzung | [gpt-usage-kompaktierung-fix-spec.md](06-umsetzung/gpt-usage-kompaktierung-fix-spec.md) | Diagnose, Teilfix und offene E2E-/Upstream-Gates |
| 06 Umsetzung neu | [verifikation-schluss.md](06-umsetzung/verifikation-schluss.md) | Aktuelles Urteil: nicht umsetzungsreif |
