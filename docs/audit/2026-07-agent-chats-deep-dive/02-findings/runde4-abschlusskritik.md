---
status: abgeschlossen
updated: 2026-07-19
description: Abschlusskritik der fünf P0-Blocker der Schlussverifikation nach Runde 4 und priorisierter Restweg zur Umsetzungsfreigabe von Welle 0/1.
---

# Runde 4: Abschlusskritik und Freigabeweg

## Prüfmaßstab

Diese Kritik beantwortet ausschließlich zwei Fragen: den Status jedes der fünf P0-Blocker aus dem Gesamturteil der Schlussverifikation nach Runde 4 und den jetzt noch abzuarbeitenden Weg zur Freigabe von Welle 0/1. „Entschärft“ bedeutet, dass neue Evidenz einen Blocker fachlich verkleinert oder einen belastbaren Lösungsbaustein liefert; „verschärft“ bedeutet, dass Runde 4 bzw. die 19 neuen Commits zusätzliche, unmittelbar freigaberelevante Widersprüche oder Sicherheitsrisiken belegen; reine neue Dokumentation ohne geschlossenen Vertrag gilt als „unverändert“.

## Antwort 1: Status der fünf P0-Blocker

**Kurzurteil: Keiner der fünf Blocker ist entschärft. Zwei sind unverändert, drei sind verschärft.** Runde 4 liefert punktuell präzisere Gegenbelege, aber weder einen konsistenten Identitätsvertrag noch die fehlenden Oracles.

| Nr. | P0 aus dem Gesamturteil | Status nach Runde 4 | Begründung |
|---:|---|---|---|
| 1 | Weg A gegen Weg B | **unverändert** | Der Spezifikationswiderspruch aus `docs/audit/2026-07-agent-chats-deep-dive/06-umsetzung/verifikation-schluss.md:31,88-97` ist nicht aufgelöst. HEAD implementiert weiterhin ausdrücklich Weg B: Fresh-Sessions beginnen ohne externe ID (`WhisperM8/Views/AgentChatsView+SessionLifecycle.swift:45-50`), und der Builder startet Fresh ohne `--session-id` (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:404-425`). Runde 4 bestätigt keinen capability-gegaterten Vertrag für `hostAssignedUnsupported`/`hostAssignedVerified`. |
| 2 | `launchID` wird verlangt, aber nicht zum Hook transportiert | **verschärft** | Der Grunddefekt bleibt: Das Eventmodell enthält Session-ID, Transcriptpfad, cwd und Reason, aber keine Launch-Identität (`WhisperM8/Services/AgentChats/ClaudeHookEventStore.swift:36-46`); der Parser übernimmt ebenfalls keine `source` oder `launchID` (`WhisperM8/Services/AgentChats/ClaudeHookEventStore.swift:121-136`), und ein Bridge-Eintrag ist nur an lokale Chat-ID, Eventdatei und Attach-Zeit gebunden (`WhisperM8/Services/AgentChats/ClaudeHookBridge.swift:27-41`). Verschärfend kam mit `whisperm8 chats new` ein weiterer Vertrag hinzu: Er gibt die lokale ID ausdrücklich für sofortiges `wait --ref` zurück (`WhisperM8/Services/AgentChats/AgentChatLaunchService.swift:38-42,79-96`), während `wait` den Workspace nur einmal lädt und ein unveränderliches Entry-Array hält (`WhisperM8/CLI/ChatsWaitEngine.swift:41-67,321-342`). Ohne spätes externes Binding liefert der Probe weder Revision noch Transcriptpfad (`WhisperM8/CLI/ChatsStatusProbe.swift:74-85`). Runde 4 bestätigt diesen neuen Ausfall als **R4-WAIT-01, hoch** (`docs/audit/2026-07-agent-chats-deep-dive/04-verifikation/runde4-chats-cli.md:50-56,94-105`). Damit ist nicht nur die Spezifikation unimplementierbar, sondern ein neuer öffentlicher CLI-Pfad bereits von derselben Bindungslücke betroffen. |
| 3 | Laufzeitwechsel durch `/branch`/`/rewind` fehlt | **unverändert** | Die fehlende Transition aus `docs/audit/2026-07-agent-chats-deep-dive/06-umsetzung/verifikation-schluss.md:33,112-116` wurde weder spezifiziert noch durch Runde 4 ersetzt. HEAD reduziert `SessionStart` weiterhin nur statusbezogen und lässt laufende Zustände unverändert (`WhisperM8/Services/AgentChats/AgentSessionStateMachine.swift:183-193`); `SessionStart.source` wird weiterhin nicht modelliert oder geparst (`WhisperM8/Services/AgentChats/ClaudeHookEventStore.swift:36-46,121-136`). Für Zweigwechsel ohne PTY-Relaunch existiert damit noch kein freigabefähiger Identitätsübergang. |
| 4 | Agent-Chats-Inventar ist kein verlässliches Oracle | **verschärft** | Die drei bereits belegten Falschaussagen bleiben: AC-41 behauptet externe ID-Eindeutigkeit (`docs/audit/2026-07-agent-chats-deep-dive/06-umsetzung/feature-inventar-agentchats.md:350-356`), obwohl der Binder jede abweichende nichtleere Hook-ID in dieselbe Row schreibt, ohne kollidierende Rows zu prüfen (`WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:371-389`); AC-52 behauptet eindeutige Adoption (`docs/audit/2026-07-agent-chats-deep-dive/06-umsetzung/feature-inventar-agentchats.md:442-448`), obwohl der Merge bei mehreren Kandidaten den zeitlich nächsten wählt (`WhisperM8/Services/AgentChats/AgentSessionStore.swift:835-861`); AC-30 beschreibt den kaputten Sidecar nur als unerwünschtes Soll, während der Load schon bei bloßer Dateiexistenz deferiert (`WhisperM8/Views/AgentSessionDetailView.swift:234-240,270-275`). Runde 4 verschärft den Oracle-Befund mit **R4-AS-11, hoch**: Persistenz wird dekodiert und migriert, ohne IDs zu deduplizieren (`WhisperM8/Services/AgentChats/AgentWorkspaceRepository.swift:50-64`; `WhisperM8/Services/AgentChats/AgentSessionStore.swift:1182-1196`), danach setzt der Summary-Planer eindeutige IDs über `Dictionary(uniqueKeysWithValues:)` hart voraus (`WhisperM8/Services/AgentChats/SummaryStartupPlanner.swift:9-20`; `docs/audit/2026-07-agent-chats-deep-dive/04-verifikation/runde4-abdeckung-services.md:23-25,39-49`). Das Inventar ist somit nicht nur an drei Stellen falsch, sondern lässt eine weitere trap-fähige Eindeutigkeitsvorbedingung aus. |
| 5 | Test-Spec deckt Welle 0/1 und C07 nicht ab | **verschärft** | C07 und die bereits benannten Welle-1-Verträge fehlen weiterhin (`docs/audit/2026-07-agent-chats-deep-dive/06-umsetzung/verifikation-schluss.md:269-303`; `docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:49-61,514-518`). Zusätzlich haben die neuen Commits weitere hohe, testpflichtige Verträge geschaffen, insbesondere sechs bestätigte hohe Befunde in der Chats-CLI (**R4-AUTH-01/02, R4-IDEM-01, R4-WAIT-01/02, R4-PROF-01**; `docs/audit/2026-07-agent-chats-deep-dive/04-verifikation/runde4-chats-cli.md:94-109`). Die bestehende Spec endet inhaltlich bei A01–A06 und B01–B17 (`docs/audit/2026-07-agent-chats-deep-dive/06-umsetzung/test-specs-welle0-1.md:36-262`) und enthält weder diese Control-/Wait-Verträge noch R4-AS-11. Der Abstand zwischen Dokumenttitel und realem W0/W1-Oracle ist deshalb größer geworden. |

## Antwort 2: Konkreter Restweg bis zur Freigabe von Welle 0/1

Die Freigabe braucht **keine weitere Großanalyse**. Sie braucht eine endliche Vertrags-, Traceability- und Test-Spec-Nacharbeit. Die folgende Reihenfolge ist abarbeitbar; ein späterer Punkt darf den früheren nicht durch vorgezogene Produktimplementierung umgehen.

### G0 — Identitätsstrategie vereinheitlichen

- **Arbeit:** `identitaetsmodell-spec.md` und `verlorene-chats-spec.md` auf eine gemeinsame, capability-gegaterte State-Machine umstellen: `hostAssignedUnsupported` und `hostAssignedVerified`; für Fresh, Resume und Fork je Zustand Persistenz, Launch-Intent, erwartete Provider-ID und Fehlerzustand festlegen. Die absoluten Aussagen „nie `--session-id`“ und „immer vorab reservieren“ entfernen.
- **Erledigt, wenn:** Beide Specs dieselbe Tabelle und dieselben Begriffe verwenden und Roadmap/Test-Spec auf diese Zustände verweisen.
- **Erledigt:** P0 1; `docs/audit/2026-07-agent-chats-deep-dive/06-umsetzung/verifikation-schluss.md:88-97,348-350`.

### G1 — Per-Launch-Korrelation und Claim-Vertrag festschreiben

- **Arbeit:** Den bereits geforderten Vertrag konkret in die Identitätsspec übernehmen: Event-/Settingspfad pro `(chatID, launchID)`, Bridge-Envelope mit `expectedConfigRoot` und `launchedAt`, Generation-Guard, Schließen alter FDs/Pfade, Diagnose später Alt-Events sowie eine atomare Claim-API mit Kollisions- und Mehrdeutigkeitsausgang. Der Chats-CLI-Vertrag muss zusätzlich festlegen, wie `new → wait` spätes Binding nachlädt, statt einen einmaligen Workspace-Snapshot dauerhaft zu verwenden.
- **Erledigt, wenn:** Jede Bindungsquelle — Hook, Indexer und Control-CLI — dieselbe aktuelle Launchgeneration und denselben gescopten Provider-Key prüfen kann; unklare Claims mutieren keine Row.
- **Erledigt:** P0 2 sowie R4-WAIT-01; `docs/audit/2026-07-agent-chats-deep-dive/06-umsetzung/verifikation-schluss.md:99-110,147-159,348-351`; `docs/audit/2026-07-agent-chats-deep-dive/04-verifikation/runde4-chats-cli.md:50-56`.

### G2 — Vollständige Laufzeit-Übergangsmatrix ergänzen

- **Arbeit:** Für `/branch`, `/rewind`, `/clear`, `/resume` und `/compact` jeweils altes/neues gescoptes Session-Key, `source`, Transcriptpfad, cwd, Lineage, Row-/Tab-Verhalten, Unread und Auto-Naming festlegen. `activeBranchChange` muss ausdrücklich von In-Place-Compact und Prozessende getrennt sein.
- **Erledigt, wenn:** Für jedes Event eine deterministische Transition und ein negativer Mehrdeutigkeitsfall beschrieben ist; `SessionStart.source` gehört zum Parser- und Testvertrag.
- **Erledigt:** P0 3; `docs/audit/2026-07-agent-chats-deep-dive/06-umsetzung/verifikation-schluss.md:112-122,348-353`.

### G3 — Inventar vom Wunschbild zum belastbaren Oracle korrigieren

- **Arbeit:** AC-41, AC-52 und AC-30 jeweils in **Ist-Verhalten**, **heutige Lücke** und **Soll-Gate** teilen. R4-AS-11 als eigene Persistenz-/Startup-Invariante aufnehmen: doppelte lokale IDs müssen beim Load kontrolliert behandelt werden und dürfen keinen trap-fähigen Planer erreichen. Snapshot-Privacy/Retention ebenfalls als offene Gates, nicht als erhaltene Eigenschaft, führen.
- **Erledigt, wenn:** Kein Charakterisierungstest eine heute rote Soll-Eigenschaft als bestehende Invariante ausgibt und jede der vier Lücken auf einen konkreten Testfall zeigt.
- **Erledigt:** P0 4; `docs/audit/2026-07-agent-chats-deep-dive/06-umsetzung/verifikation-schluss.md:206-222,348-355`; R4-AS-11 in `docs/audit/2026-07-agent-chats-deep-dive/04-verifikation/runde4-abdeckung-services.md:23-25,39-49`.

### G4 — Test-Spec tatsächlich auf W0/W1 schneiden

- **Arbeit:**
  1. Entweder das Dokument ehrlich als Teilmenge W0–W3 benennen oder die fehlenden W1-Gates als B18–B22 ergänzen: Child-Environment/Profile/Secret-Canary, Headless-Nichtpersistenz/Scratch-cwd/Profile, Git-Stale-Result, WindowStore-Diff-Sideeffects und Transcript-Cache Hit/Miss/Move/Profile.
  2. Die vollständige C07-Matrix ergänzen: zwei parallele Launches mit vertauschter Hook-/Scan-Reihenfolge, bereits belegte externe ID, zwei Kandidaten im Zeitfenster, Fork-Parent vor Child, spätes Alt-Launch-Event und gleiche nackte UUID in zwei Config-Roots.
  3. H3 nicht als God-Spy planen, sondern in One-shot-Runner und kontrollierbaren langlebigen Child-Prozess teilen; H6/H10 ebenso auf minimale Nähte reduzieren.
  4. Für die neu in W0/W1 einzuordnenden Runde-4-Hochbefunde vor dem jeweiligen Fix rote Oracles benennen, mindestens R4-AS-11 und die sechs hohen Chats-CLI-Findings.
- **Erledigt, wenn:** Jede W0/W1-Roadmapmaßnahme mindestens einen ausführbaren Testvertrag, benötigte minimale Naht, deterministischen Scheduler/Clock und Negativfall besitzt; W2/W3-Tests sind sichtbar separat.
- **Erledigt:** P0 5; `docs/audit/2026-07-agent-chats-deep-dive/06-umsetzung/verifikation-schluss.md:269-303,356-357`; `docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:49-61,507-518`; `docs/audit/2026-07-agent-chats-deep-dive/04-verifikation/runde4-chats-cli.md:94-109`.

### G5 — Runde-4-Verdicts lückenlos in Matrix und Roadmap routen

- **Arbeit:** Die aktuelle Roadmap-Matrix endet bei Runde 3 und behauptet für ihre 53 bestätigten Findings vollständige Wellenzuordnung (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/findings-matrix.md:105-122`). Eine neue Runde-4-Sektion muss jede **bestätigte kritische/hohe** Zeile aus den vorhandenen Urteilstabellen genau einer Kategorie zuordnen: W0-Oracle, W1-Aktivschaden-Fix oder ausdrücklich begründetes späteres Gate. Mittel/niedrig darf gesammelt nachgelagert werden; ungeprüfte Einträge dürfen nicht als bestätigt erscheinen.
- **Priorität innerhalb der Zuordnung:** zuerst Security/Datenhoheit und falsche Mutationen (Chats-CLI Auth/Idempotenz, Statusline-/Skill-Lost-Update, GPT-Update-Vertrauenswurzel), danach Identität/Persistenz/Wait, danach Verfügbarkeit. Die Urteile sind bereits vorhanden; erforderlich ist Traceability, keine Wiederholung der Analyse (`docs/audit/2026-07-agent-chats-deep-dive/04-verifikation/runde4-chats-cli.md:94-109`; `docs/audit/2026-07-agent-chats-deep-dive/04-verifikation/runde4-abdeckung-services.md:35-50`; `docs/audit/2026-07-agent-chats-deep-dive/04-verifikation/runde4-delta-auditiert.md:59-75`; `docs/audit/2026-07-agent-chats-deep-dive/04-verifikation/runde4-gpt-setup.md:53-63`; `docs/audit/2026-07-agent-chats-deep-dive/04-verifikation/runde4-plugin-manager.md:58-71`; `docs/audit/2026-07-agent-chats-deep-dive/04-verifikation/runde4-statusline-skills.md:45-60`; `docs/audit/2026-07-agent-chats-deep-dive/04-verifikation/runde4-context-profile.md:77-85`; `docs/audit/2026-07-agent-chats-deep-dive/04-verifikation/runde4-abdeckung-views-cli.md:29-45`).
- **Erledigt, wenn:** Jede bestätigte kritische/hohe Runde-4-ID genau einen Roadmap-Link und einen Test-Gate-Link hat; kein Finding ist doppelt oder nur über Freitext repräsentiert.
- **Erledigt:** die durch Runde 4 entstandene Freigabelücke hinter P0 4/5.

### G6 — Referenzen stabilisieren und das Go-Gate einmal formal abnehmen

- **Arbeit:** Nach Abschluss der parallel laufenden Änderungen alle `Datei:Zeile`-Verweise in den fünf Freigabedokumenten gegen den finalen Branch nachziehen. Danach eine kompakte Gate-Tabelle führen: G0–G5 grün, fünf P0 geschlossen, alle Runde-4-kritisch/hoch geroutet, W0/W1-Testverträge vollständig, P0.3/P0.4 weiterhin gesperrt bis G0–G3 abgeschlossen.
- **Erledigt, wenn:** Die Dokumente widerspruchsfrei auf denselben Stand zeigen und die Freigabeentscheidung ohne Interpretation aus der Gate-Tabelle folgt.
- **Erledigt:** Abschlussbedingung aus `docs/audit/2026-07-agent-chats-deep-dive/06-umsetzung/verifikation-schluss.md:348-360`.

## Freigabeentscheidung

**Aktuell: kein Go für die Identitäts-/Recovery-Implementierung und kein pauschales Go für Welle 0/1.** Nach G0–G6 kann W0.1 als Oracle-Welle freigegeben werden; danach W1 entlang der gerouteten Aktivschaden-Pakete. P0.1 „Headless-Junk stoppen“ und der nichtdestruktive Teil von P0.2 dürfen weiterhin nur als kleine, separat getestete Vorab-Changes vorbereitet werden. Die eigentliche Bindungsarchitektur P0.3/P0.4 bleibt bis zum Abschluss der Identitäts-, Inventar- und Oracle-Gates gesperrt (`docs/audit/2026-07-agent-chats-deep-dive/06-umsetzung/verifikation-schluss.md:348-360`).

