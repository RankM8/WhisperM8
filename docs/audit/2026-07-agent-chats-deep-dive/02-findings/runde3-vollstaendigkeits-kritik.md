---
status: abgeschlossen
updated: 2026-07-18
description: Vollständigkeitskritik des Gesamtaudits nach Runde 3 mit Quellbaum-Abdeckung, Finding-zu-Roadmap-Lücken, offenen Verifikationen, Dokumentwidersprüchen und Startvoraussetzungen.
---

# Runde 3: Vollständigkeitskritik — was fehlt noch?

## 0. Prüfrahmen und Urteil

Gelesen wurden der vollständige Stand mit 80 Dokumenten unter
`docs/audit/2026-07-agent-chats-deep-dive/`, einschließlich aller sechs
`04-verifikation/runde3-*.md`, sowie der aktuelle Swift-Quellbaum unter
`WhisperM8/`. Für die mechanische Abdeckungsprüfung wurden alle 281 Swift-Dateien
gegen wörtliche Pfad- oder Dateinamen-Nennungen in `02-findings/*.md` und danach
gegen den gesamten Audit-Korpus verglichen. „Nicht abgedeckt“ bedeutet daher
präzise: **keine wörtliche Datei-Zuordnung in einem Finder-Dokument**; es ist
nicht die stärkere, unbeweisbare Aussage, dass kein Agent jemals angrenzenden
Code gesehen habe.

**Gesamturteil: Das Gesamtaudit ist noch nicht umsetzungsreif als einheitlicher
Plan.** Einzelne, klar abgegrenzte Fixes können vorbereitet werden. Vor dem Start
der Identitäts-/Recovery-Welle oder einer breiten GPT-Backend-Freigabe fehlen
aber eine neue Synthese, eindeutige Finding-IDs, Roadmap-Zuordnung der bestätigten
Runde-3-Befunde und mehrere bereits selbst als P0 klassifizierte
Vertragsentscheidungen.

Die stärksten Vollständigkeitslücken sind:

1. Die Roadmap ist vollständig nur für C01–C16 und N01–N16. Runde 3 bestätigt 20
   primäre GPT-Findings (plus den separaten Usage-Live-Defekt), ohne dass eine
   explizite Runde-3-Maßnahme, Abhängigkeit oder Ship-Sperre in der Roadmap
   existiert.
2. Fünf Terminal-Snapshot-Findings besitzen keinen eigenen
   `04-verifikation/runde3-terminal-*.md`-Verdictbericht; drei davon
   (Privacy/Retention, Lösch-Durability, kaputter-Sidecar-Fallback) sind in der
   Roadmap nicht als aktuelle Sidecar-Maßnahmen enthalten.
3. 138 von 281 Swift-Dateien haben keine Finder-Zuordnung; 97 davon werden im
   gesamten Audit nicht einmal wörtlich genannt. Darunter liegen nicht nur
   Darstellungskomponenten, sondern OAuth-/Usage-Abfragen, CLI-Parsing,
   Agent-Launch, Grid/Drag-Drop, Transcript-Rendering und Diktat-Providerpfade.
4. README, Roadmap und Umsetzungsdokumente melden gleichzeitig „abgeschlossen“,
   „Umsetzungsvorbereitung abgeschlossen“ und „noch nicht umsetzungsreif“.
   Dadurch ist nicht erkennbar, welches Dokument die Freigabeautorität besitzt.

## 1. MUSS vor Umsetzungsbeginn geschlossen werden

### M0.1 — Eine autoritative Traceability-Matrix fehlt weiterhin

Die Roadmap erklärt als Grundlage „alle Findings aus `02-findings/`, nennt aber
nur C01–C16 und N01–N16 als verifizierte Population
(`05-roadmap/refactor-roadmap.md:10-14`). Der Konsistenzcheck bestätigt nur für
genau diese 32 IDs eine lückenlose Zuordnung
(`05-roadmap/konsistenz-check-fable.md:146-152`). Die neuen Berichte verwenden
hingegen in vier Dokumenten jeweils erneut `G01`, `G02` usw.; ohne
Dokumentpräfix ist `G03` nicht eindeutig.

**Vorbedingung:** Eine maschinenlesbare Matrix mit mindestens
`stable_id`, Quelle, aktuellem Schweregrad, Verdict, Duplikat-/Supersedes-Bezug,
Roadmap-Maßnahme, Welle, Owner, Test-/QA-Gate und Ship-Blocker. Empfohlene
stabile Präfixe sind etwa `R3-DEF-*`, `R3-MIX-*`, `R3-PROXY-*`, `R3-SEC-*`,
`R3-SNAP-*` und `R3-LIVE-*`. Widerlegte Findings müssen in ihrer Quelle sichtbar
als widerlegt oder superseded markiert werden; ein späterer Leser darf nicht aus
einem weiterhin `status: aktiv` gesetzten Finder-Dokument implementieren.

### M0.2 — Die bestätigten Runde-3-GPT-Findings fehlen als Roadmap-Paket

Die sechs Runde-3-Verifikationsberichte ergeben folgende primäre Population:

| Eindeutiger Alias | Verifikationsstand | Roadmap-Stand |
|---|---|---|
| `R3-DEF-G01..G04` | 4 bestätigt; Finder-G05 widerlegt (`04-verifikation/runde3-definition-settings.md:373-383`) | Keine explizite Maßnahme |
| `R3-MIX-G01..G07` | 7 bestätigt; G01 mit E2E-Teilvorbehalt (`04-verifikation/runde3-mixrouter.md:461-474`) | Keine explizite Maßnahme |
| `R3-PROXY-G01..G05` | 5 bestätigt (`04-verifikation/runde3-proxy.md:403-415`) | Keine explizite Maßnahme |
| `R3-SEC-G01..G04` | 4 bestätigt, G03 auf niedrig abgestuft (`04-verifikation/runde3-security.md:27-39`) | Keine explizite Maßnahme; nur Teilüberlappung mit P1.1 |
| `R3-LIVE-G01` | End-to-End-Defekt bestätigt, ursprüngliche Ursachenbehauptung korrigiert (`04-verifikation/runde3-recherche-proxy.md:138-163,218-234`) | Nur Entwurfs-Spec, keine Roadmap-Maßnahme |

Das sind **20 bestätigte primäre GPT-Findings plus ein separat live
reproduzierter Usage-Vertrag**. Mehrere Forschungs-Verdicts duplizieren diese
Befunde und dürfen nicht doppelt gezählt werden. Trotzdem fehlt selbst eine
konsolidierte Clusterzuordnung. Mindestens folgende Pakete müssen vor Start in
die Roadmap:

1. **GPT-Lifecycle und Konfigurationsgeneration:** Start und Stop teilen heute
   nicht dasselbe Lock; `ensureRunning` serialisiert nur Starts
   (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:218-283`),
   während `stopIfSelfStarted` separat Handle und Router verändert
   (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:286-300`). Dazu
   gehören Crash-Recovery, Kill-Switch-Barriere, immutable Port-/Endpoint-
   Snapshot, Background-Spawn-Guard und Definition-Sync-Generation. Der
   Background-Runner übergibt dem Prozess aktuell nur executable, arguments,
   cwd und timeout, aber keinen Router-/Profil-Environment-Snapshot
   (`WhisperM8/Services/AgentChats/BackgroundAgentSpawner.swift:78-112`).
2. **Lokale Vertrauensgrenze:** Health-Identität besteht weiterhin nur aus
   Status 200, JSON-Content-Type und `{ "ok": true }`
   (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:469-537`). Der
   MixRouter akzeptiert Verbindungen ohne Client-Credential und legt sie direkt
   als aktive `ClientConnection` ab
   (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:403-423`). Prozess-
   Ownership, lokale Client-Authentisierung und getrennte Router-/Proxy-
   Shutdown-Policy brauchen deshalb ein eigenes Security-Gate.
3. **Protokoll- und Ressourcenvertrag:** Der Router puffert den kompletten Body,
   routet per Modellpräfix und setzt einen 600-Sekunden-Request
   (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:502-575`); lokale
   Pre-Head-Fehler werden generisch als Plaintext-502 gesendet
   (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:603-633`). Nach Start
   der Upstream-Task wird der Client-Read nicht erneut armiert
   (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:481-499`), und jede
   Anfrage erzeugt eine eigene ephemere URLSession mit 600-Sekunden-Timeouts
   (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:689-729`). Version/
   Capability, Thinking-Providergrenze, Tool-Result-Bilder, Tokenzählung,
   Cancellation, Fehlerformat und globale Budgets gehören in ein gemeinsames,
   aber in getrennte Changes geschnittenes Contract-Paket.
4. **Skill-/Definition-Ownership:** Der Skill-Exporter bestimmt den globalen
   Zielpfad nur aus dem Skillnamen und klassifiziert jede vorhandene Datei als
   installiert (`WhisperM8/Services/Shared/CLISkillExporter.swift:102-143`);
   Installation überschreibt `SKILL.md` und bekannte Referenzen ohne
   Ownership-/Backup-Vertrag (`WhisperM8/Services/Shared/CLISkillExporter.swift:145-175`).
   Der Definition-Installer schreibt mehrere Roots ohne Batch-Generation,
   schluckt Remove-Fehler und bildet Write-Fehler als No-op ab
   (`WhisperM8/Services/AgentChats/ClaudeGPTAgentDefinition.swift:50-94`).
5. **Usage/Kompaktierung:** Der aktuelle Builder setzt das 272k-Fenster nur für
   GPT-gestempelte Sessions
   (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:267-307`). Das löst
   nicht allein den verifizierten Subagent-Vertrag, dessen Root Cause laut
   Diagnose im nullwertigen `message_start` plus nicht gemergtem finalen
   `message_delta` liegt
   (`06-umsetzung/gpt-usage-kompaktierung-fix-spec.md:145-194`). Die Roadmap muss
   festlegen, ob ein gepinnter/gepatchter Proxy, eine Mindestversion oder ein
   enger Router-Rewrite das Ship-Gate erfüllt; die frühere große
   Fill-if-missing-Skizze ist laut demselben Dokument nicht mehr das Ziel.

**Startentscheidung:** Diese Cluster müssen nicht in einem Big Bang umgesetzt
werden. Sie müssen aber **vor dem ersten Produktchange** als getrennte Tickets mit
Abhängigkeiten und einem GPT-Ship-Gate in die autoritative Roadmap aufgenommen
werden. Insbesondere darf „Backend aktivieren“ nicht als releasefähig gelten,
solange Background-Spawn, lokale Authentisierung und Kill-Switch-Lifecycle offen
sind.

### M0.3 — Terminal-Snapshot-Verifikation und Roadmap-Scope fehlen

`02-findings/runde3-terminal-snapshots.md` enthält fünf Findings. Unter den sechs
`04-verifikation/runde3-*.md` existiert kein eigener Terminal-Snapshot-Refuter.
Runde-1-/Runde-2-Berichte bestätigen zwar den Main-Thread-/Drain-Kern von G01 und
den zu frühen Capture-Marker aus G05, aber es fehlt eine geschlossene
G01–G05-Urteilsmatrix mit eigenem finalen Schweregrad.

Drei Sidecar-Verträge sind nicht durch T1 abgedeckt:

- **Privacy/Retention:** Das aktuelle Format ist UTF-8-Plaintext, pro Datei auf
  2.000 Zeilen begrenzt, ohne TTL-/Gesamtbudget-API
  (`WhisperM8/Services/AgentChats/TerminalSnapshotStore.swift:14-29,48-60,65-119`).
  T1 plant Limits für ein neues output-only Recording, lässt aber den heutigen
  Plaintext-Endsnapshot ausdrücklich als Fallback bestehen
  (`05-roadmap/refactor-roadmap.md:356-366`).
- **Lösch-Durability:** `delete` verwirft jeden Fehler und liefert keinen
  Erfolgswert (`WhisperM8/Services/AgentChats/TerminalSnapshotStore.swift:109-119`).
  Dafür gibt es keine Tombstone-/Retry-/Startup-Reconciliation-Maßnahme.
- **Validitäts-Fallback:** `hasSnapshot` prüft nur Existenz, während `load` bei
  kaputtem oder neuerem Header `nil` liefert
  (`WhisperM8/Services/AgentChats/TerminalSnapshotStore.swift:70-73,94-106`).
  Die View deferiert den JSONL-Load bereits aufgrund der Existenz und triggert
  nach einem asynchronen `nil` keinen erneuten Load
  (`WhisperM8/Views/AgentSessionDetailView.swift:201-225,255-260`).

G01 gehört sachlich zum vorhandenen P0.7/R2.1-Termination-Contract; G05 ist dort
nur teilweise erfasst. G02–G04 brauchen eigene Roadmap-Unterpunkte. Vor Beginn
des Terminal-Teardowns muss außerdem die Reihenfolge feststehen: Der App-Hook
capturt heute synchron und antwortet sofort `.terminateNow`
(`WhisperM8/WhisperM8App.swift:343-351`), während R2.1 bereits in Welle 1 und
P0.7 erst in Welle 2 denselben Terminationsvertrag umbauen.

### M0.4 — Die Identitäts-/Recovery-Welle ist laut eigener Schlussverifikation gesperrt

`06-umsetzung/README.md` nennt die Umsetzungsvorbereitung abgeschlossen, doch die
spätere Schlussverifikation urteilt ausdrücklich „noch nicht umsetzungsreif“ und
nennt fünf P0-Lücken (`06-umsetzung/verifikation-schluss.md:27-45`). Deren
verbindliche Nacharbeit ist weiterhin offen
(`06-umsetzung/verifikation-schluss.md:348-360`):

1. Weg A/Weg B als capability-gegatete gemeinsame State-Machine entscheiden.
2. Per-Launch Hook-Envelope/Generation, Config-Root-Ableitung und Claim-API
   operationalisieren.
3. `/branch`, `/rewind`, `/clear`, `/resume`, `/compact` vollständig modellieren
   und `SessionStart.source` erhalten.
4. JSONL-Fallback-Evidenz ohne erfundene Parent-Lineage definieren.
5. Feature-Inventar und Test-Specs korrigieren, insbesondere C07.

Der aktuelle Code belegt den Kern: Fork und Resume werden im Builder getrennt
vorbereitet, aber die ID wird als zwei Argumente `--resume`, `<id>` angehängt
(`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:366-415`); der Binder
übernimmt danach jede nichtleere Hook-ID ohne Fork-Parent-, Claim-, Config-Root-
oder Transcriptpfad-Prüfung
(`WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:345-363`).
Die Roadmap formuliert dagegen noch „erste passende Hook-ID bindet atomar“ und
stellt späteres `--session-id`/Fork-Ziel in Aussicht
(`05-roadmap/refactor-roadmap.md:203-220`), während die Identitätsspec
`--session-id` absolut ausschließt (`06-umsetzung/identitaetsmodell-spec.md:82-88`).

**Startentscheidung:** Die eigentliche Binding-Architektur nicht beginnen, bis
alle neun Punkte aus der Schlussverifikation erledigt und Roadmap, Identitätsspec,
Verlorene-Chats-Spec sowie Tests auf denselben Vertrag gebracht sind. Nur die in
`verifikation-schluss.md:360` ausdrücklich freigegebenen kleinen,
nichtdestruktiven Vorarbeiten dürfen separat starten.

### M0.5 — README und Roadmap dürfen noch keine Abschluss-/Freigabeautorität behaupten

Die README meldet „Audit abgeschlossen (2 Runden + Tech-Scan)“ und 32 von 32
bestätigte Behauptungen (`README.md:8-17`), indexiert aber weder Runde 3 noch die
Runde-3-Verifikationen oder die Schlussverifikation. Die Roadmap-Frontmatter
spricht ebenfalls nur von zwei Verifikationsrunden
(`05-roadmap/refactor-roadmap.md:1-5`). Gleichzeitig existieren 20 bestätigte
primäre GPT-Findings, ein bestätigter Live-Defekt und fünf noch nicht geschlossen
verifizierte Terminal-Findings.

**Vorbedingung:** README und Roadmap erst nach der Traceability-Matrix
aktualisieren. Eine einzige Datei muss als Freigabe-SSoT benannt werden; historische
Wellenangaben in `plan-review.md` und `verdicts-runde2.md` müssen als historisch
markiert werden. Bis dahin lautet der belastbare Status: **Audit-Findings
vorhanden, Gesamtsynthese und Umsetzungsfreigabe offen.**

## 2. Bestätigte Findings ohne beziehungsweise nur mit partieller Roadmap-Zuordnung

### 2.1 Vor Runde 3

Für die formal verifizierten C01–C16 und N01–N16 fehlt keine Zuordnung; das ist
im Konsistenzcheck nachvollziehbar belegt
(`05-roadmap/konsistenz-check-fable.md:146-161`). Offen bleiben jedoch bereits
vor Runde 3 Finder-Befunde, die nie in die verifizierte Population aufgenommen
wurden:

- Postprocessing F1 (keine Deadline/Kill-Pfad) und F3 (Task-Modus verspricht
  Ausführung, läuft read-only) sind laut Konsistenzcheck weder verifiziert noch
  verplant (`05-roadmap/konsistenz-check-fable.md:43-67`).
- Die drei hohen Lifecycle-Leaks aus `memory-lifecycle-codex.md` und die OSC-8-
  Härtung wurden als fehlende Quick Wins benannt, aber nicht in eine
  Finding→Verdict→Maßnahme-Kette überführt
  (`05-roadmap/konsistenz-check-fable.md:57-64`).
- NF1–NF8 aus der Runde-2-Vollständigkeitskritik besitzen keine eigene
  adversariale Verdictmatrix. Besonders NF1 (Privacy-Schalter versus
  Reportkopien), NF2 (Release/Notarisierung) und NF3 (geratene Codex-Resume-
  Optionen) dürfen deshalb weder als bestätigt noch als widerlegt aus der
  Synthese verschwinden (`02-findings/runde2-vollstaendigkeits-kritik.md:162-290`).

### 2.2 Runde 3

Explizit unzugeordnet sind alle in M0.2 aufgeführten GPT-Cluster. Teilüberlappung
ist keine Traceability:

- P1.1 kann das geerbte `CCP_TRAFFIC_LOG` prinzipiell mit einem Minimal-
  Environment entschärfen, nennt aber Proxy-Diagnostikvariablen und den
  langlebigen GPT-Proxy nicht ausdrücklich. Der gemeinsame Environment-Helfer
  kopiert weiterhin das Parent-Environment und entfernt nur Claude-spezifische
  Keys plus `NO_COLOR`
  (`WhisperM8/Services/Shared/LoginShellEnvironment.swift:91-137`).
- P0.7 behandelt Terminal-Drain/Snapshot-Reihenfolge, nicht Sidecar-Privacy,
  Löschdurability oder kaputte Header.
- P0.5/P0.6/P1.3/P1.4 bilden die alte Session-Bindung ab, nicht die in Workflow 3
  spezifizierte Laufzeit-Branch-State-Machine, Writer-Lease und Hook-Generation.
- Der Usage-Fix besitzt eine eigene Entwurfs-Spec, aber keine Roadmap-ID und kein
  definiertes Mindestversions-/Upstream-PR-Gate.

## 3. Behauptungen ohne ausreichende Verifikation

### V1 — Terminal G01–G05 haben keinen dedizierten Runde-3-Verdictbericht

Vor Implementierung von G02–G04 ist ein kurzer adversarialer Refuter ausreichend;
G01/G05 können auf die vorhandenen C10-/Teardown-Belege referenzieren. Das
Ergebnis muss trotzdem als eine fünfzeilige Matrix vorliegen, damit Schweregrad,
Duplikate und Maßnahmen eindeutig sind.

### V2 — MixRouter-G01 ist nur code-seitig, nicht end-to-end vollständig bestätigt

Der Refuter bestätigt die asymmetrische Thinking-Verarbeitung, hält aber
explizit offen, wie die aktuell installierte Claude-CLI providerfremde Signaturen
im realen Request behandelt (`04-verifikation/runde3-mixrouter.md:28-38,79-110`).
Vor einem verlustbehafteten History-Rewrite braucht es die dort geforderte echte
`Fable → GPT → Fable`-Fixture; andernfalls könnte ein Fix Kontext unnötig
entfernen.

### V3 — Die Fork-Hook-Ereignisfolge ist nicht live bewiesen

Der Code beweist nur die Fehlerkette **falls** der frühe Fork-`SessionStart` die
Parent-ID liefert. Die Schlussverifikation hält ausdrücklich fest, dass weder
Code noch `claude --help` diese konkrete Ereignisfolge beweisen
(`06-umsetzung/verifikation-schluss.md:19,124-127`). Die Reproduktion gegen die
unterstützte CLI-Version ist eine Vorbedingung der Identitätsspec, kein optionaler
späterer QA-Punkt.

### V4 — Externe Proxy-Verträge sind nicht dauerhaft reproduzierbar archiviert

Mehrere Runde-3-Refuter zitieren lokale Scratch-Klone. Der produktive Manager
startet irgendein über PATH gefundenes `claude-code-proxy` und prüft weder
Version noch Capabilities (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:225-283,469-537`).
Vor Umsetzung extern verursachter Findings braucht es deshalb ein eingechecktes
Manifest aus Repository, Commit/Tag, Binary-Hash, unterstütztem Semver-Bereich
und hermetischen Golden-Fixtures. Sonst kann derselbe WhisperM8-Commit je nach
PATH-Binary einen anderen Vertrag haben.

### V5 — Alte Finder-Findings außerhalb C/N bleiben ohne Status

Der Satz „Grundlage sind alle Findings“ ist erst wahr, wenn mindestens alle
kritischen/hohen Alt-Findings einen Status `bestätigt`, `widerlegt`, `duplikat`
oder `zurückgestellt mit Grund` besitzen. Der heutige Freitext erlaubt weiterhin
nicht, nicht geprüft von nicht vorhanden zu unterscheiden. F1/F3, NF1–NF8 und
die im Konsistenzcheck genannten Lifecycle-/OSC-Lücken sind die konkrete
Restliste, nicht nur ein Methodikwunsch.

## 4. Widersprüche zwischen Dokumenten

| Priorität | Widerspruch | Erforderliche Auflösung |
|---|---|---|
| P0 | README: „Audit abgeschlossen“/„Umsetzungsvorbereitung abgeschlossen“ (`README.md:8-17`) versus Schlussverifikation: „noch nicht umsetzungsreif“ (`06-umsetzung/verifikation-schluss.md:27-45`). | Schlussverifikation als aktuelles Gate markieren; README-Status zurücknehmen. |
| P0 | Roadmap behauptet Grundlage aller Findings, verarbeitet aber explizit nur C/N (`05-roadmap/refactor-roadmap.md:10-14`); Runde 3 fehlt vollständig. | Neue Matrix und Roadmap-Revision vor jedem Change. |
| P0 | Roadmap bindet „erste passende Hook-ID“ (`05-roadmap/refactor-roadmap.md:203-220`), Identitätsspec verbietet Parent-ID beim Fork (`06-umsetzung/identitaetsmodell-spec.md:59-65`), realer Binder übernimmt jede ID (`WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:345-363`). | Einen operationalen Hook-/Claim-Vertrag festlegen. |
| P0 | Identitätsspec schreibt Weg B ohne `--session-id` fest (`06-umsetzung/identitaetsmodell-spec.md:82-88`), Verlorene-Chats-Spec plant capability-gegatet Weg A; Schlussverifikation erklärt die Kombination als nicht entschieden (`06-umsetzung/verifikation-schluss.md:88-110,153-156`). | Gemeinsame State-Machine und Capability-Probe; keine parallelen Soll-Dokumente. |
| P0 | Live-Repro behauptet, Usage werde „nirgends übersetzt“ (`02-findings/runde3-live-repro-usage-kompaktierung.md:14-22`); der Refuter belegt vorhandenes Proxy-Mapping und korrigiert die Ursache (`04-verifikation/runde3-recherche-proxy.md:138-163`). | Live-Repro mit „Ursache widerlegt, Wirkung bestätigt“ markieren und auf Diagnose-Nachtrag verweisen. |
| P1 | Finder-G05 behauptet einen Widerspruch der Skill-Dokumentation (`02-findings/runde3-gpt-backend-definition-settings.md:216-261`); der Refuter widerlegt G05 vollständig (`04-verifikation/runde3-definition-settings.md:308-383`). | Finder-G05 sichtbar als widerlegt/superseded markieren; keinen Doku-Fix daraus planen. |
| P1 | `TerminalSnapshotStore.load` verspricht Transcript-Fallback bei unbekanntem Header (`WhisperM8/Services/AgentChats/TerminalSnapshotStore.swift:94-106`), die View blockiert den Load aber bereits bei Dateiexistenz (`WhisperM8/Views/AgentSessionDetailView.swift:219-225,255-260`). Das Feature-Inventar führte den Sollzustand zunächst als Erhaltungsinvariante; die Schlussverifikation korrigiert ihn (`06-umsetzung/verifikation-schluss.md:218-232`). | Inventar als Ist-Bug/Soll-Test korrigieren, dann Roadmap-Maßnahme. |
| P1 | Roadmap setzt R2.1-Termination in Welle 1 und P0.7-Terminalautomaten in Welle 2 an, obwohl beide denselben App-Quit-Pfad ändern (`05-roadmap/refactor-roadmap.md:84-95,277-291`). | Gemeinsamen Termination-Contract vor beiden Wellen spezifizieren; Doppelumbau vermeiden. |
| P1 | Plan-Review führt das verworfene P0.8 weiter, während Roadmap es gestrichen hat (`05-roadmap/konsistenz-check-fable.md:25-41`). | Historisch-Vermerk und Roadmap als SSoT. |

## 5. Codebereiche ohne Finder-Abdeckung

### 5.1 Quantitatives Ergebnis

| Bereich | Swift-Dateien ohne Finder-Nennung | Davon ohne jede Nennung im gesamten Audit |
|---|---:|---:|
| `WhisperM8/CLI` | 4 | 2 |
| `WhisperM8/Models` | 10 | 8 |
| `WhisperM8/Services/AgentChats` | 19 | 13 |
| `WhisperM8/Services/Dictation` | 14 | 7 |
| `WhisperM8/Services/Shared` | 9 | 4 |
| `WhisperM8/Support` | 4 | 3 |
| `WhisperM8/Views` | 77 | 59 |
| `WhisperM8/Windows` | 1 | 1 |
| **Gesamt** | **138 / 281** | **97 / 281** |

Die Zahl ist keine Defektzahl. Sie beweist aber, dass das Audit keine
quellbaumweite Finder-Coverage besitzt. Besonders vor W0/W1 nachzuauditieren sind:

1. **Usage-/Credential-Pfade:** `CodexUsageFetcher` liest ein Access-Token aus
   `~/.codex/auth.json` und sendet es an einen Usage-Endpoint
   (`WhisperM8/Services/AgentChats/CodexUsageReader.swift:143-184`).
   `ClaudeAccountUsageFetcher` liest das Profil-Secret über `security`, ruft den
   OAuth-Usage-Endpoint auf und schreibt die Antwort in einen vorhersagbaren
   `/tmp/claude-usage-cache-<profil>.json`-Pfad
   (`WhisperM8/Services/AgentChats/ClaudeAccountUsageFetcher.swift:25-84`). Diese
   beiden Dateien fehlen in allen Finder-Dokumenten; ihre Auth-, Privacy-,
   Dateimodus-, Multi-User- und Endpoint-Versionsverträge benötigen einen eigenen
   Security-/Lifecycle-Pass.
2. **CLI-Eingangs- und Medienpfade:** Der Agent-CLI-Parser definiert Run/Send/List/
   Logs-Optionen (`WhisperM8/CLI/AgentCLIArguments.swift:18-43,52-82,169-226`),
   während der Medienpfad AVFoundation- und ffmpeg-Extraktion anbietet
   (`WhisperM8/CLI/CLIAudioExtractor.swift:31-62,181-220`). Parsergrenzen,
   Pfad-/Argumentbehandlung, Timeouts und große Medien sind nicht als Finder-
   Scope dokumentiert.
3. **Agent-Launch und Usage-UI:** `AgentChatLaunchService` erstellt und öffnet
   Codex-Chats direkt mit globalen Defaults
   (`WhisperM8/Services/AgentChats/AgentChatLaunchService.swift:8-36`); Usage-
   Reader, Account-Fetcher und `AgentUsagePopovers` besitzen keine Finder-
   Zuordnung. Diese Pfade sind von Identity-, Profile- und Environment-Refactors
   betroffen.
4. **Grid/Drag-Drop/Tab-Switcher:** Zahlreiche reine Resolver und sichtbare
   Container fehlen trotz Runde-2-Grid-Bericht in der Finder-Dateimatrix,
   darunter `AgentGridLayout`, `AgentGridSplitContainer`, `GridDropZoneResolver`,
   `GridSplitResolver`, `AgentTabSwitcherOverlay` und die Drag-Drop-Typen. Vor
   Store-/Identitätsumbauten braucht es mindestens eine Journey-Zuordnung zu den
   vorhandenen Grid-Tests und manuellen Multiwindow-Oracles.
5. **Transcript-Rendering:** `MarkdownBlockParser`, `TranscriptMarkdownView`,
   `SessionSummaryCard`, `TimelineActivityRow`, `TimelineReportView` und
   `TranscriptReportDetailView` fehlen in den Finder-Zitaten. P1.11 schützt
   Provider-Parsing, aber nicht automatisch Markdown-Parsing, Link-/Copy-
   Verhalten, große Blöcke und Timeline-Projektion.
6. **Diktat-Provider und UI-Auslieferung:** `TranscriptionProviders`,
   `TranscriptionService`, `CoreAudioVolumeController`, `AudioDuckingManager`,
   `VisualAttachmentDeliveryBuilder`, `RecordingPillView` und
   `RecordingOverlayView` fehlen als Finder-Ziele. Die vorhandenen Recorder-
   Findings ersetzen keine providerweite 429/Timeout-/Cancel-/Privacy- und
   Overlay-Lifecycle-Matrix.

### 5.2 Vollständige mechanische Liste der 138 nicht genannten Finder-Dateien

#### CLI

- `WhisperM8/CLI/AgentCLIArguments.swift`
- `WhisperM8/CLI/CLIAudioChunker.swift`
- `WhisperM8/CLI/CLIAudioExtractor.swift`
- `WhisperM8/CLI/CLIOutputFormatter.swift`

#### Models

- `WhisperM8/Models/AppState.swift`
- `WhisperM8/Models/CodexPostProcessingModel.swift`
- `WhisperM8/Models/CodexReasoningEffort.swift`
- `WhisperM8/Models/CodexServiceTier.swift`
- `WhisperM8/Models/CodexVisualInputMode.swift`
- `WhisperM8/Models/OutputHistoryFilter.swift`
- `WhisperM8/Models/SelectedContext.swift`
- `WhisperM8/Models/TranscriptContextBundle.swift`
- `WhisperM8/Models/TranscriptRunReportSummary.swift`
- `WhisperM8/Models/TranscriptTimeline.swift`

#### Services/AgentChats

- `WhisperM8/Services/AgentChats/AgentChatLaunchService.swift`
- `WhisperM8/Services/AgentChats/AgentDirectoryEventMonitor.swift`
- `WhisperM8/Services/AgentChats/AgentJobRuntimeModel.swift`
- `WhisperM8/Services/AgentChats/AgentProjectIconResolver.swift`
- `WhisperM8/Services/AgentChats/AgentResourceMonitor.swift`
- `WhisperM8/Services/AgentChats/AgentWorktreeManager.swift`
- `WhisperM8/Services/AgentChats/ClaudeAccountUsageFetcher.swift`
- `WhisperM8/Services/AgentChats/ClaudeThemeWriter.swift`
- `WhisperM8/Services/AgentChats/CodexAgentPreflight.swift`
- `WhisperM8/Services/AgentChats/CodexExecEvent.swift`
- `WhisperM8/Services/AgentChats/CodexExecEventParser.swift`
- `WhisperM8/Services/AgentChats/CodexReportSchema.swift`
- `WhisperM8/Services/AgentChats/CodexUsageReader.swift`
- `WhisperM8/Services/AgentChats/ExternalClaudeHooksInspector.swift`
- `WhisperM8/Services/AgentChats/ProcessAncestry.swift`
- `WhisperM8/Services/AgentChats/SubAgentDiscovery.swift`
- `WhisperM8/Services/AgentChats/SummaryStartupPlanner.swift`
- `WhisperM8/Services/AgentChats/TranscriptEvidenceExtractor.swift`
- `WhisperM8/Services/AgentChats/WorkspaceSlotOps.swift`

#### Services/Dictation

- `WhisperM8/Services/Dictation/AudioDuckingManager.swift`
- `WhisperM8/Services/Dictation/AudioLevelMeter.swift`
- `WhisperM8/Services/Dictation/CodexErrorSummary.swift`
- `WhisperM8/Services/Dictation/CodexStatusCache.swift`
- `WhisperM8/Services/Dictation/ContextCaptureMerge.swift`
- `WhisperM8/Services/Dictation/CoreAudioVolumeController.swift`
- `WhisperM8/Services/Dictation/PostProcessing.swift`
- `WhisperM8/Services/Dictation/PostProcessingService.swift`
- `WhisperM8/Services/Dictation/ProjectPathResolver.swift`
- `WhisperM8/Services/Dictation/RecordingTimer.swift`
- `WhisperM8/Services/Dictation/TranscriptionModels.swift`
- `WhisperM8/Services/Dictation/TranscriptionProviders.swift`
- `WhisperM8/Services/Dictation/TranscriptionService.swift`
- `WhisperM8/Services/Dictation/VisualAttachmentDeliveryBuilder.swift`

#### Services/Shared

- `WhisperM8/Services/Shared/AppProfileActivator.swift`
- `WhisperM8/Services/Shared/CodexGlobalConfigReader.swift`
- `WhisperM8/Services/Shared/CodexModelCatalog.swift`
- `WhisperM8/Services/Shared/FileEventSource.swift`
- `WhisperM8/Services/Shared/GridPerformanceTracker.swift`
- `WhisperM8/Services/Shared/PermissionService.swift`
- `WhisperM8/Services/Shared/SemanticVersion.swift`
- `WhisperM8/Services/Shared/StatuslineInstaller.swift`
- `WhisperM8/Services/Shared/SystemSoundCatalog.swift`

#### Support

- `WhisperM8/Support/AppTheme.swift`
- `WhisperM8/Support/AppearanceOverride.swift`
- `WhisperM8/Support/TextNormalizer.swift`
- `WhisperM8/Support/ThemeManager.swift`

#### Views

- `WhisperM8/Views/AgentChatsView+Archive.swift`
- `WhisperM8/Views/AgentChatsView+DragDrop.swift`
- `WhisperM8/Views/AgentChatsView+SubagentChildren.swift`
- `WhisperM8/Views/AgentDragDropTypes.swift`
- `WhisperM8/Views/AgentGridLayout.swift`
- `WhisperM8/Views/AgentGridSplitContainer.swift`
- `WhisperM8/Views/AgentSessionAmbiguousRebindPicker.swift`
- `WhisperM8/Views/AgentTabSwitcherOverlay.swift`
- `WhisperM8/Views/AgentTerminalLinkInterceptor.swift`
- `WhisperM8/Views/AgentTerminalPalette.swift`
- `WhisperM8/Views/AgentUsagePopovers.swift`
- `WhisperM8/Views/AmbiguousRebindRequest.swift`
- `WhisperM8/Views/BackgroundDispatchModal.swift`
- `WhisperM8/Views/FocusableTextField.swift`
- `WhisperM8/Views/GridDropViews.swift`
- `WhisperM8/Views/GridDropZoneResolver.swift`
- `WhisperM8/Views/GridSplitHandle.swift`
- `WhisperM8/Views/GridSplitResolver.swift`
- `WhisperM8/Views/OutputReportComponents.swift`
- `WhisperM8/Views/OverlayPhase.swift`
- `WhisperM8/Views/OverlayScrollers.swift`
- `WhisperM8/Views/ProjectPickerKeyboard.swift`
- `WhisperM8/Views/ProviderIcon.swift`
- `WhisperM8/Views/RecordingOverlayView.swift`
- `WhisperM8/Views/RecordingPillView.swift`
- `WhisperM8/Views/SessionMenuPolicy.swift`
- `WhisperM8/Views/Settings/Kit/ClipboardClient.swift`
- `WhisperM8/Views/Settings/Kit/SettingsButtonRow.swift`
- `WhisperM8/Views/Settings/Kit/SettingsCodeBlock.swift`
- `WhisperM8/Views/Settings/Kit/SettingsCopyCommandRow.swift`
- `WhisperM8/Views/Settings/Kit/SettingsFeedbackState.swift`
- `WhisperM8/Views/Settings/Kit/SettingsHelpText.swift`
- `WhisperM8/Views/Settings/Kit/SettingsKeyRecorderRow.swift`
- `WhisperM8/Views/Settings/Kit/SettingsKitPreview.swift`
- `WhisperM8/Views/Settings/Kit/SettingsListPanel.swift`
- `WhisperM8/Views/Settings/Kit/SettingsPageContainer.swift`
- `WhisperM8/Views/Settings/Kit/SettingsPickerRow.swift`
- `WhisperM8/Views/Settings/Kit/SettingsRow.swift`
- `WhisperM8/Views/Settings/Kit/SettingsSection.swift`
- `WhisperM8/Views/Settings/Kit/SettingsSliderRow.swift`
- `WhisperM8/Views/Settings/Kit/SettingsStatusRow.swift`
- `WhisperM8/Views/Settings/Kit/SettingsStatusTone.swift`
- `WhisperM8/Views/Settings/Kit/SettingsStepperRow.swift`
- `WhisperM8/Views/Settings/Kit/SettingsTabs.swift`
- `WhisperM8/Views/Settings/Kit/SettingsTextArea.swift`
- `WhisperM8/Views/Settings/Kit/SettingsToggleRow.swift`
- `WhisperM8/Views/Settings/Models/AgentCLIArgumentsPreview.swift`
- `WhisperM8/Views/Settings/Models/CodexConnectionModel.swift`
- `WhisperM8/Views/Settings/Models/OutputArchiveViewModel.swift`
- `WhisperM8/Views/Settings/Models/PermissionSettingsModel.swift`
- `WhisperM8/Views/Settings/Models/SettingsRouteTarget.swift`
- `WhisperM8/Views/Settings/Pages/AIOutputAccountTab.swift`
- `WhisperM8/Views/Settings/Pages/AIOutputSettingsPage.swift`
- `WhisperM8/Views/Settings/Pages/AIOutputTemplatesTab.swift`
- `WhisperM8/Views/Settings/Pages/AIOutputTestLabTab.swift`
- `WhisperM8/Views/Settings/Pages/AboutSettingsPage.swift`
- `WhisperM8/Views/Settings/Pages/OutputWorkspacePage.swift`
- `WhisperM8/Views/Settings/Pages/PermissionsSettingsPage.swift`
- `WhisperM8/Views/Settings/Pages/RecordingSettingsPage.swift`
- `WhisperM8/Views/SettingsView.swift`
- `WhisperM8/Views/SidebarResizeHandle.swift`
- `WhisperM8/Views/SidebarWidthResolver.swift`
- `WhisperM8/Views/TabNavShortcut.swift`
- `WhisperM8/Views/TabScrollSwipeRecognizer.swift`
- `WhisperM8/Views/TabSwitcherModel.swift`
- `WhisperM8/Views/TabSwitcherShortcut.swift`
- `WhisperM8/Views/TerminalFeedBatcher.swift`
- `WhisperM8/Views/Transcript/MarkdownBlockParser.swift`
- `WhisperM8/Views/Transcript/SessionSummaryCard.swift`
- `WhisperM8/Views/Transcript/TeammateMessageParser.swift`
- `WhisperM8/Views/Transcript/TerminalSnapshotView.swift`
- `WhisperM8/Views/Transcript/TimelineActivityRow.swift`
- `WhisperM8/Views/Transcript/TimelineReportView.swift`
- `WhisperM8/Views/Transcript/TranscriptHistoryState.swift`
- `WhisperM8/Views/Transcript/TranscriptMarkdownView.swift`
- `WhisperM8/Views/TranscriptReportDetailView.swift`
- `WhisperM8/Views/TranscriptionAccountControls.swift`

#### Windows

- `WhisperM8/Windows/OverlayFrameResolver.swift`

## 6. Fehlende Voraussetzungen, die parallel laufen können

Diese Arbeiten blockieren nicht jeden isolierten Bugfix, müssen aber **vor
Abnahme/Shipping der betroffenen Welle** abgeschlossen sein:

1. **Risikobasierter Finder-Nachlauf für die 138 Dateien.** Nicht 138 gleich große
   Reviews starten. Zuerst Usage/Credentials, CLI, Agent-Launch, Grid/Drag-Drop,
   Transcript-Rendering und Diktat-Provider; einfache Settings-Kit-Komponenten
   über gemeinsame A11y-/Locale-/Design-Oracles bündeln.
2. **Terminal G01–G05-Refuter** parallel zum Entwurf des gemeinsamen
   Termination-Contracts; keine Produktdatei muss dafür geändert werden.
3. **Privacy-/Release-/Codex-Paritäts-Nachaudit** aus der Runde-2-Kritik. Diese
   Themen blockieren nicht einen lokalen Recorder-Race-Test, wohl aber ein
   öffentliches Release: Datenlebenszyklus und Unified Logging, notarisiertes
   DMG/Update/Rollback sowie interaktiver Codex-Auth-/Config-/Resume-Vertrag sind
   weiterhin keine geschlossenen End-to-End-Matrizen
   (`02-findings/runde2-vollstaendigkeits-kritik.md:53-104`).
4. **Empirische W0-Arbeit:** echte Proxy-Contract-Fixtures, Fork-Hook-Repro,
   Client-Disconnect, Port-Hijack, App-Quit/PTY-Drain, Low-Disk und Sidecar-
   Löschfehler. Statische Erreichbarkeit allein liefert keine Häufigkeit und
   keinen Runtime-Ordnungsbeweis.
5. **Dokumentbereinigung:** widerlegte Ausgangsfindings markieren, Scratch-
   Quellen manifestieren, Zeilenreferenzen nach laufenden GPT-Änderungen
   nachziehen und README-Index vervollständigen. Lokale Links sind aktuell nicht
   gebrochen; das Problem ist fehlende Autorität und fehlende Indexierung, nicht
   Linksyntax.
6. **Accessibility/Lokalisierung/Langzeit-QA:** kann parallel zu Core-Fixes
   vorbereitet werden, muss aber vor UI-/Settings-Wellen als Oracle stehen. Der
   Runde-2-Bericht hat VoiceOver, Tastatur, Reduce Motion, gemischte UI-Sprache,
   8-Stunden-Lauf, Sleep/Wake und Ressourcendruck weiterhin als Blindstellen
   ausgewiesen (`02-findings/runde2-vollstaendigkeits-kritik.md:106-160`).

## 7. Minimales Freigabe-Gate vor „Go“

### Muss vor dem ersten Change der Identitäts-, Terminal- oder GPT-Kernwellen

erledigt sein

- [ ] Autoritative, deduplizierte Finding→Verdict→Roadmap-Matrix erstellen.
- [ ] Runde-3-GPT-Cluster mit eindeutigen IDs, Ownern, Abhängigkeiten und
      Security-/Contract-Ship-Gates in die Roadmap aufnehmen.
- [ ] Terminal G01–G05 verifizieren und G02–G04 als aktuelle Sidecar-Maßnahmen
      verplanen.
- [ ] Gemeinsamen App-Termination-Contract für Recorder, Terminal-Snapshot,
      Workspace-Flush und Proxy-Shutdown festlegen.
- [ ] Alle neun Nacharbeiten aus `06-umsetzung/verifikation-schluss.md:348-360`
      schließen; insbesondere Weg A/B, Hook-Generation, Runtime-Branchwechsel,
      Inventar und W0/W1-Test-Specs.
- [ ] Live-Usage-Root-Cause und Fixziel autoritativ aktualisieren; echte
      Proxy-/CLI-E2E-Fixture als Gate definieren.
- [ ] README/Plan-Review/alte Verdict-Wellen als historisch markieren und eine
      Freigabe-SSoT benennen.

### Darf parallel laufen

- [ ] Finder-Nachlauf für die priorisierten ungenannten Codebereiche.
- [ ] Privacy-, Release-/DMG-, Codex-Paritäts-, A11y- und Locale-Audits.
- [ ] Nicht-invasive W0-Seams, Fixtures und ManualClock-/Process-/PTY-Harnesses.
- [ ] Kleine, nichtdestruktive Vorarbeiten, die die Schlussverifikation explizit
      freigibt; jede mit eigener Datei-Ownership und ohne Vorgriff auf die
      ungeklärte Identitätsarchitektur.

**Freigabekriterium:** Nicht „alle Dokumente vorhanden“, sondern jede
umsetzungsrelevante Behauptung besitzt genau einen aktuellen Status, genau eine
Maßnahme oder begründete Zurückstellung und ein beobachtbares Regressions-/QA-
Gate. Diesen Zustand erreicht der aktuelle Audit-Stand noch nicht.
