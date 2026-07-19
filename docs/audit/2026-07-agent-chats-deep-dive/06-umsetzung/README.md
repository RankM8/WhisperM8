---
status: aktiv
updated: 2026-07-19
description: Autoritative Workflow-3-Synthese mit verifizierten Feldmustern, Runde-4-Abschlusskritik, gesperrtem Identitätsumbau und offenen Freigabemängeln.
---

# Workflow 3 — Synthese und Umsetzungs-Gate

## Status

**Workflow 3 ist dokumentiert, aber weiterhin nicht umsetzungsreif.** Die
Runde-4-Abschlusskritik bewertet alle fünf P0-Blocker erneut: Keiner ist
entschärft; P0 1 „Weg A gegen Weg B“ und P0 3 „Laufzeitwechsel durch
`/branch`/`/rewind`“ sind unverändert, P0 2 „Launch-ID-Transport“, P0 4
„Inventar als Oracle“ und P0 5 „Test-Spec für W0/W1 und C07“ sind verschärft
([runde4-abschlusskritik.md:13-23](../02-findings/runde4-abschlusskritik.md)).
Die verifizierte Matrix korrigiert außerdem den Altbestand: C04 ist als offener
Hoch-Defekt widerlegt, N01 nicht bestätigt, C10/N07 nur teilbestätigt; die beiden
Alt-Teilfixe sind ausdrücklich nicht geschlossen
([runde4-findings-matrix.md:17-73](../04-verifikation/runde4-findings-matrix.md)).
Damit gibt es weder ein Go für die Identitäts-/Recovery-Implementierung noch ein
pauschales Go für Welle 0/1. Maßgeblich bleibt der Restweg G0–G6; kleine,
nichtdestruktive Vorarbeiten sind weiterhin nur im bereits eng freigegebenen
Umfang zulässig
([runde4-abschlusskritik.md:25-78](../02-findings/runde4-abschlusskritik.md);
[verifikation-schluss.md:348-360](verifikation-schluss.md)).

## 1. Kurzfazit Feldvergleich

Übernommen werden nur Muster, die die adversariale
[Schluss-Verifikation der sieben Repo-Analysen](../03-vergleich/code-analysen/verifikation-fable.md)
als tragfähig belegt hat:

| Bestätigtes Muster | Konsequenz für WhisperM8 |
|---|---|
| **Getrennte Identitäten plus Account-Scope:** lokale Chat-/Wrapper-ID, Claude-Branch-ID und Prozess-/PTY-Inkarnation sind verschiedene Schlüssel; Provider-IDs werden mit Config-Root/Account gescopet. Die Konvergenz aller sieben Quellen ist ausdrücklich verifiziert ([verifikation-fable.md:125-140](../03-vergleich/code-analysen/verifikation-fable.md)). | Das Identitätsmodell ist kein lokaler Binder-Fix, sondern der Kern-Umbau. Der aktuelle Code hält lokale Sessiondaten gemeinsam in `AgentChatSession` und die PTY-Registry besitzt Controller pro lokaler UUID (`WhisperM8/Models/AgentChat.swift:225-307`; `WhisperM8/Views/AgentTerminalView.swift:323-364`). |
| **Fork/Resume als geplanter, danach bestätigter Übergang:** Fork braucht einen Parent-ID-Guard und einen atomaren Commit erst nach belastbarer Child-Evidenz; die konkrete Fork-Hook-Folge ist vor Umsetzung live zu reproduzieren ([verifikation-fable.md:53-65,136-140](../03-vergleich/code-analysen/verifikation-fable.md); [verifikation-schluss.md:124-127](verifikation-schluss.md)). | Spawn-Intent und beobachtete Provider-Identität dürfen nicht gleichgesetzt werden. Der heutige Binder übernimmt jede abweichende nichtleere Hook-ID ohne Fork-Parent-, Claim-, Config-Root- oder Transcriptpfad-Guard (`WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:345-363`). |
| **Autoritative Fehlerklassifikation und konservative Reconciliation:** JSONL-Miss ist ein Soft-Signal, Mehrdeutigkeit darf nicht binden, und destruktives Aufräumen braucht Schonfrist beziehungsweise Recovery-Zustand ([verifikation-fable.md:69-79,136-140](../03-vergleich/code-analysen/verifikation-fable.md)). | Kein stiller Fresh-Start und kein Prune aufgrund eines einzelnen negativen Scans. Der heutige Lazy-Fallback wählt den jüngsten Kandidaten nach Zeituntergrenze (`WhisperM8/Services/AgentChats/AgentSessionStore.swift:623-633`). |
| **Watcher-/Hook-Dubletten transaktional zusammenführen und Transcriptstrukturen über Provider-IDs korrelieren:** Zwei-Spalten-Identität, Subagent-Filter und `uuid`/`parentUuid`-DAG sind als Referenzmuster belegt ([verifikation-fable.md:81-115](../03-vergleich/code-analysen/verifikation-fable.md)). | Merge und Transcript-Härtung folgen erst nach stabilen Identitäts- und Revisionsinvarianten; aktuelle Mehrfachkandidaten werden im ±5-Sekunden-Fenster nur nach zeitlicher Nähe gewählt (`WhisperM8/Services/AgentChats/AgentSessionStore.swift:825-850`). |
| **Adoption statt Doppel-Spawn:** Eine persistente Terminalidentität und „Initialkommando nach Adoption nie erneut senden“ sind extern E2E-belegt ([verifikation-fable.md:39-51](../03-vergleich/code-analysen/verifikation-fable.md)). | Das Prinzip ist verwendbar; ein externer PTY-Broker ist dagegen ein eigenes Architekturprojekt und keine freigegebene P1-Übernahme ([verifikation-fable.md:142-146](../03-vergleich/code-analysen/verifikation-fable.md)). |

Nicht als bestätigt übernommen werden `--session-id`-Vorvergabe, die konkrete
Fork-Hook-Ereignisfolge ohne Live-Repro, ein externer PTY-Broker als kurzfristige
Maßnahme oder SDK-/Eigen-UI-Mechanik. Die SDK-nahen Quellen dienen ausschließlich
als Invarianten-Norm; WhisperM8 bleibt Host der echten Claude-/Codex-CLI im PTY
([verifikation-fable.md:125-146](../03-vergleich/code-analysen/verifikation-fable.md);
[verifikation-schluss.md:331-346](verifikation-schluss.md)).

## 2. Identitätsmodell als Kern-Umbau

Die fachlich bestätigte Zieltrennung lautet:

1. **Lokaler Chat:** langlebige UI-/Workspace-Identität.
2. **Launch-Generation:** pro Spawn neue Inkarnation mit Launchmodus, Profil,
   Config-Root, cwd, Startzeit und eigener Hook-Generation.
3. **Provider-Branch:** gescopeter Schlüssel aus Provider, Config-Root und
   externer Session-ID; dazu autoritativer Transcriptpfad und Lineage-Evidenz.

Die bestehende `identitaetsmodell-spec.md` ist dafür **nicht freigegeben**. Vor
Implementierung müssen folgende Verträge gemeinsam revidiert werden:

- capability-gegatete Wahl zwischen hostvergebener und providervergebener
  Child-ID statt des Widerspruchs zwischen Weg A und Weg B
  ([verifikation-schluss.md:88-110](verifikation-schluss.md));
- launchspezifischer Hook-Envelope/Eventpfad mit Generation-Guard, erwarteter
  Config-Root-Ableitung und atomarer Claim-API; der Hook transportiert heute
  keine WhisperM8-Launch-ID (`WhisperM8/Services/AgentChats/ClaudeHookEventStore.swift:36-46,121-136`;
  `WhisperM8/Services/AgentChats/ClaudeHookBridge.swift:27-41,218-229`);
- vollständige Laufzeitmatrix für `/branch`, `/rewind`, `/clear`, `/resume` und
  `/compact`; `SessionStart.source` wird heute beim Parsen verworfen
  (`WhisperM8/Services/AgentChats/ClaudeHookEventStore.swift:121-136`);
- JSONL-Recovery nur mit tatsächlich verfügbarer Evidenz; der Indexer liefert
  heute keine autoritative Branch-Parent-ID
  (`WhisperM8/Services/AgentChats/ClaudeSessionIndexer.swift:112-169`);
- persistierte Recovery-Zustände und Writer-Lease pro gescopetem Provider-Key.

Bis diese Punkte in **einem** Vertrag zusammengeführt sind, sind P0.3/P0.4 der
Recovery-Spec und die Binding-Maßnahme der Roadmap gesperrt
([verifikation-schluss.md:147-169,348-360](verifikation-schluss.md)).

## 3. Regressionsschutz

Die beiden Feature-Inventare sind Referenzen, derzeit aber noch keine
uneingeschränkt freigegebenen Oracles:

- Das Diktat-Inventar braucht noch CLI-Link/Skill sowie eine klare Abgrenzung der
  geteilten App-Shell
  ([verifikation-schluss.md:171-192](verifikation-schluss.md)).
- Im Agent-Chats-Inventar müssen AC-41, AC-52 und AC-30 von vermeintlichen
  Ist-Invarianten in heutige Bugs/Soll-Gates umklassifiziert werden. Zusätzlich
  fehlen Worktree-Jobs, Sidebar-Usage, Agent-Chats-Settings, Theme-Sync und die
  sichtbare GPT-Kontextfenster-Funktion
  ([verifikation-schluss.md:194-254](verifikation-schluss.md)).

Verbindliche Reihenfolge:

1. **Inventare korrigieren und als Referenz einfrieren.** Jede betroffene
   sichtbare Funktion erhält Codebeleg, Ist-Verhalten und Erhaltungs-/Soll-Gate.
2. **Kategorie 1 vor Umbau testen:** Spawn, Resume/Fork, Hook-Generation,
   Claim/Eindeutigkeit, Config-Root, Recovery und Laufzeit-Branchwechsel. Korrektes
   Ist-Verhalten wird als Charakterisierungstest festgehalten; bestätigte Defekte
   werden nicht als Invariante eingefroren.
3. **Kategorie 2 zusammen mit dem Fix testen:** angrenzende Terminal-,
   Multi-Window-, Background-, Auto-Naming- und Diktat-Routing-Verträge erhalten
   Rot→Grün-Tests im jeweiligen Change.
4. **Minimale Testnähte statt God-Spy:** One-shot-Prozesslauf und kontrollierbarer
   langlebiger Child-Prozess werden getrennt injiziert. Das bestehende
   `ProcessRunner`-Protokoll kann Environment, Handles oder Signale nicht
   beobachten (`WhisperM8/Services/AgentChats/BackgroundAgentSpawner.swift:217-230`;
   [verifikation-schluss.md:294-303](verifikation-schluss.md)).
5. **C07 ist Pflicht-Oracle:** parallele Launches, belegte ID, mehrere Kandidaten,
   Fork-Parent vor Child, spätes Alt-Event und gleiche UUID in zwei Config-Roots
   müssen deterministisch abgedeckt sein
   ([verifikation-schluss.md:281-303](verifikation-schluss.md)).

Die aktuelle `test-specs-welle0-1.md` muss vor Verwendung neu geschnitten werden:
Sie enthält Welle-2/3-Fälle, lässt aber Child-Environment, Headless-Prävention,
die drei Welle-1-Quick-Wins und C07 aus; A02, A03 und B10 benötigen fachliche
Korrekturen ([verifikation-schluss.md:267-329](verifikation-schluss.md)).

## 4. GPT-Backend-Reviewstand

Die Runde-3-Refuter bestätigen **20 primäre G-Findings**: vier zu
Definition/Settings, sieben zum MixRouter, fünf zum Proxy-Lifecycle und vier zur
Security. Finder-G05 aus Definition/Settings ist widerlegt. Hinzu kommt der live
bestätigte Usage-/Kompaktierungsdefekt, dessen ursprüngliche Ursachenbehauptung
korrigiert wurde
([runde3-vollstaendigkeits-kritik.md:66-138](../02-findings/runde3-vollstaendigkeits-kritik.md)).
Die eindeutigen IDs und Wellen stehen im
[Roadmap-Nachtrag](../05-roadmap/refactor-roadmap.md#nachtrag-runde-3--workflow-3).

Bestätigte Cluster:

- **Lifecycle und Konfigurationsgeneration:** Start/Stop sind nicht gemeinsam
  serialisiert, Crash-Recovery fehlt, Background-Spawn kann Guard/Environment
  umgehen, Kill-Switch und Ports sind kein atomarer Snapshot
  (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:218-300,469-557`;
  `WhisperM8/Services/AgentChats/BackgroundAgentSpawner.swift:78-137,223-258`).
- **Lokale Vertrauensgrenze:** Ein imitierbares konstantes Health-JSON legitimiert
  Listener; Proxy und Router besitzen keine lokale Client-Authentisierung
  (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:469-537`;
  `WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:403-423`).
- **Protokoll und Ressourcen:** Thinking-Historie, Tool-Result-Bilder,
  Tokenzählung, lokale Fehler, Client-FIN, Parallel-/Bytebudgets sowie
  Versions-/Capability-Grenze sind bestätigt; MixRouter-G01 behält einen
  expliziten E2E-Teilvorbehalt
  ([runde3-mixrouter.md:461-474](../04-verifikation/runde3-mixrouter.md)).
- **Skill-/Definition-Ownership:** fremde Dateien können überschrieben werden,
  Profilpropagation ist lückenhaft, Multi-Root-Sync ist nicht als Generation
  serialisiert und Dateifehler bleiben unsichtbar
  ([runde3-definition-settings.md:373-384](../04-verifikation/runde3-definition-settings.md)).
- **Usage/Kompaktierung:** Ebene 1 (GPT-spezifisches Kontextfenster) ist laut
  Diagnose-Nachtrag umgesetzt; offen bleiben Proxy-/CLI-E2E-Gate,
  `message_start`-Usage und zwei Tool-Finish-Pfade. Die große Router-
  Fill-if-missing-Skizze ist ausdrücklich nicht mehr das Ziel
  ([gpt-usage-kompaktierung-fix-spec.md:145-235](gpt-usage-kompaktierung-fix-spec.md)).

Reale, von den Recherche-Refutern bestätigte Ergänzungen werden nicht doppelt
gezählt: Provider-ID und explizites Parse-Outcome ergänzen P1.11; Child-
Environment braucht ein Kompatibilitäts-Gate; Supervisor-Ready/Detach und
Stop-Latch bestätigen R2.4; Usage, Ownership, Client-FIN, Tool-Result-Bilder und
lokale Fehler sind bereits in den G-Clustern enthalten
([runde3-recherche-muster.md:465-477](../04-verifikation/runde3-recherche-muster.md);
[runde3-recherche-proxy.md:309-364](../04-verifikation/runde3-recherche-proxy.md)).
Nicht übernommen werden widerlegte oder nur als verfrüht bewertete Forderungen
wie ein zweiter SSE-Transformator, zusätzliche GPT-Retries, MetricKit/KSCrash als
W0-Pflicht oder ein gemeinsamer Scanner-Umbau vor den Parser-Oracles.

## 5. Offene Mängel und Freigabe-Gate

Vor einem „Go“ für Identitäts-, Terminal- oder GPT-Kernwellen fehlen mindestens:

- eine deduplizierte Traceability-Matrix mit stabilen Runde-3-IDs, Verdict,
  Maßnahme, Welle, Owner und Test-/Ship-Gate;
- alle neun Nacharbeiten der Schlussverifikation, insbesondere Weg A/B,
  Hook-Generation, Laufzeit-Branchwechsel, Inventarkorrektur und vollständige
  W0/W1-Test-Specs;
- eine dedizierte Terminal-Snapshot-G01–G05-Urteilsmatrix. Privacy/Retention,
  Löschdurability und kaputter-Sidecar-Fallback sind noch nicht als geschlossene
  aktuelle Maßnahmen verifiziert; die View deferiert derzeit allein wegen
  Dateiexistenz und triggert nach `nil` keinen JSONL-Fallback
  (`WhisperM8/Services/AgentChats/TerminalSnapshotStore.swift:70-73,94-119`;
  `WhisperM8/Views/AgentSessionDetailView.swift:201-225,255-260`);
- ein gemeinsamer App-Termination-Contract vor R2.1 und P0.7;
- externe Proxy-Version/Capabilities und hermetische Golden-Fixtures sowie der
  echte Fork-Hook-Live-Repro;
- Statusentscheidungen für ältere Findings außerhalb C/N, den risikobasierten
  Finder-Nachlauf, Privacy/Release/Codex-Parität sowie A11y/Locale/Langzeit-QA.

Die vollständige Muss-/Parallel-Liste und das Freigabekriterium stehen in
[runde3-vollstaendigkeits-kritik.md:546-611](../02-findings/runde3-vollstaendigkeits-kritik.md).

## 6. Workflow-3-Dokumente

| Phase | Dokument | Rolle / aktueller Stand |
|---|---|---|
| Einstieg | [workflow3-kandidaten.md](../03-vergleich/workflow3-kandidaten.md) | Kandidaten, Edge-Case-Landkarte und Rechercheaufträge |
| Feldvergleich | [code-analysen/agent-deck.md](../03-vergleich/code-analysen/agent-deck.md) | Fork-Datenmodell und Identitätsscope |
| Feldvergleich | [code-analysen/superset.md](../03-vergleich/code-analysen/superset.md) | Terminal-Adoption und Reaper |
| Feldvergleich | [code-analysen/cmux.md](../03-vergleich/code-analysen/cmux.md) | Fork-Guard und Runtime-Generation |
| Feldvergleich | [code-analysen/nimbalyst.md](../03-vergleich/code-analysen/nimbalyst.md) | Resume-Fehlerklassifikation und Reconciliation |
| Feldvergleich | [code-analysen/claudecodeui.md](../03-vergleich/code-analysen/claudecodeui.md) | Zwei-Spalten-Identität und Watcher-Merge |
| Feldvergleich | [code-analysen/claude-code-log.md](../03-vergleich/code-analysen/claude-code-log.md) | Transcript-DAG und Korrelation |
| Feldvergleich | [code-analysen/claude-agent-sdk-python.md](../03-vergleich/code-analysen/claude-agent-sdk-python.md) | Übergangsnorm und Flag-Härtung |
| Feldvergleich | [code-analysen/verifikation-fable.md](../03-vergleich/code-analysen/verifikation-fable.md) | Adversariale Schluss-Verifikation der sieben Analysen |
| GPT-Vergleich | [code-analysen/claude-code-router.md](../03-vergleich/code-analysen/claude-code-router.md) | Router-/Gateway-Muster |
| Forschung | [supervisor-detach-vertraege.md](../03-vergleich/supervisor-detach-vertraege.md) | Ready/Detach, Waiter, Stop-Latch |
| Forschung | [jsonl-schema-drift.md](../03-vergleich/jsonl-schema-drift.md) | Provider-IDs, Parse-Outcome und Schema-Drift |
| Forschung | [tech-observability-secrets.md](../03-vergleich/tech-observability-secrets.md) | Crash-Observability und Secret-Lifecycle |
| Forschung | [proxy-muster-litellm.md](../03-vergleich/proxy-muster-litellm.md) | Proxy-/SSE-Vergleichsmuster |
| Findings R3 | [runde3-gpt-backend-definition-settings.md](../02-findings/runde3-gpt-backend-definition-settings.md) | Definition, Skill und Settings |
| Findings R3 | [runde3-gpt-backend-mixrouter.md](../02-findings/runde3-gpt-backend-mixrouter.md) | Übersetzung und Ressourcen |
| Findings R3 | [runde3-gpt-backend-proxy.md](../02-findings/runde3-gpt-backend-proxy.md) | Proxy-Lifecycle |
| Findings R3 | [runde3-gpt-backend-security.md](../02-findings/runde3-gpt-backend-security.md) | Lokale Vertrauensgrenze |
| Findings R3 | [runde3-live-repro-usage-kompaktierung.md](../02-findings/runde3-live-repro-usage-kompaktierung.md) | Live-Wirkung bestätigt, ursprüngliche Ursache korrigiert |
| Findings R3 | [runde3-terminal-snapshots.md](../02-findings/runde3-terminal-snapshots.md) | Fünf noch nicht geschlossen verifizierte Snapshot-Findings |
| Kritik R3 | [runde3-vollstaendigkeits-kritik.md](../02-findings/runde3-vollstaendigkeits-kritik.md) | Freigabeblocker und Abdeckungslücken |
| Verifikation R3 | [runde3-definition-settings.md](../04-verifikation/runde3-definition-settings.md) | 4 bestätigt, 1 widerlegt |
| Verifikation R3 | [runde3-mixrouter.md](../04-verifikation/runde3-mixrouter.md) | 7 bestätigt, G01 mit E2E-Teilvorbehalt |
| Verifikation R3 | [runde3-proxy.md](../04-verifikation/runde3-proxy.md) | 5 bestätigt |
| Verifikation R3 | [runde3-security.md](../04-verifikation/runde3-security.md) | 4 bestätigt, G03 abgestuft |
| Verifikation R3 | [runde3-recherche-muster.md](../04-verifikation/runde3-recherche-muster.md) | Supervisor/JSONL/Observability/Secrets |
| Verifikation R3 | [runde3-recherche-proxy.md](../04-verifikation/runde3-recherche-proxy.md) | Reale Proxy-Lücken und Widerlegungen |
| Roadmap | [refactor-roadmap.md](../05-roadmap/refactor-roadmap.md) | Bestehende Wellen plus Runde-3-Nachtrag; keine Umsetzungsfreigabe |
| Umsetzung | [identitaetsmodell-spec.md](identitaetsmodell-spec.md) | Entwurf; Revision erforderlich |
| Umsetzung | [verlorene-chats-spec.md](verlorene-chats-spec.md) | P0.1/P0.2 teilweise startbar; Binding-Teile gesperrt |
| Umsetzung | [feature-inventar-agentchats.md](feature-inventar-agentchats.md) | Breit, aber als Oracle noch zu korrigieren |
| Umsetzung | [feature-inventar-diktat.md](feature-inventar-diktat.md) | Nahezu freigabefähig; benannte Ergänzungen offen |
| Umsetzung | [test-specs-welle0-1.md](test-specs-welle0-1.md) | Neu zu schneiden und zu vervollständigen |
| Umsetzung | [gpt-usage-kompaktierung-fix-spec.md](gpt-usage-kompaktierung-fix-spec.md) | Diagnose präzisiert; Teilfix umgesetzt, E2E-/Upstream-Gate offen |
| Umsetzung | [verifikation-schluss.md](verifikation-schluss.md) | Aktuelles Identitäts-/Recovery-Freigabeurteil: nicht umsetzungsreif |
| Synthese | [README.md](README.md) | Dieses Dokument; kein Produkt-Go |
