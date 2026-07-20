---
status: aktiv
updated: 2026-07-20
description: Laufendes Umsetzungslog der freigegebenen Sofort-Fixes und Quick Wins mit Commits, Teststand und offener QA; das Freigabe-Gate für Identitäts-/Kernwellen bleibt unberührt.
---

# Umsetzungslog: Sofort-Fixes und Quick Wins

Dieses Log dokumentiert, welche Audit-Findings bereits **umgesetzt** sind —
ausschließlich Maßnahmen, die die Abschlusskritik bzw. Roadmap explizit als
gate-unabhängige Vorab-Changes zulässt (Quick Wins W1 · P1.6/P1.7/P1.9,
P0.4a sowie kleine, separat getestete Runde-4-Fixes). **Das Freigabe-Gate
bleibt unverändert geschlossen:** keiner der fünf P0-Blocker ist durch diese
Changes berührt; die Identitäts-/Recovery-Pakete (P0.3/P0.4, P0.5/P0.6/
P1.3/P1.4) bleiben gesperrt ([runde4-abschlusskritik.md](../02-findings/runde4-abschlusskritik.md)).

Statusangaben hier sind **Selbstauskunft der Umsetzung** — die verifizierte
Findings-Matrix ([runde4-findings-matrix.md](../04-verifikation/runde4-findings-matrix.md))
wird erst durch einen erneuten Verifikationslauf (G5/G6) fortgeschrieben,
nicht durch dieses Log.

## Umgesetzte Maßnahmen (Stand 2026-07-20)

| Finding | Maßnahme | Commit | Tests |
|---|---|---|---|
| **C14** (hoch) | `AgentWindowStore.mutate` diff-gated (Kopie → Equatable-Vergleich → Write; Muster wie `prune`), billiger Vorab-Guard in `updateWindow` für Hot-Caller. No-op-Mutationen publizieren nicht mehr, erhöhen keine Revision, schedulen keinen Save. | `a36fcee` | 3 neue (No-op-Wiederholungen, Revision genau +1, Grid-Pfad ohne Caller-Guard) |
| **C13** (hoch) | Git-Status off-main (`GitProjectStatus.load`, detached), View auf `.task(id:)` mit Sofort-Leeren + Stale-Guard (Cancel + Pfadvergleich nach `await`); Runner-Seam für Tests. Nebenbefund derselben Klasse wie R4-AS-03 mitbehoben: stdout-Drain VOR `waitUntilExit`, stderr → `nullDevice`, 10-s-Deadline. | `87d3027` | 6 neue (Parsing, Degradation, Binär-numstat, Detached-HEAD, async≡sync) |
| **C16** (mittel) | Neuer `CodexTranscriptLocator`: ein Walk harvestet alle Session-UUIDs in eine Map; Hits per `fileExists` validiert (Move/Delete → Re-Scan); Misses 2 s negativ gecacht; Suffix-Scan-Fallback für Nicht-UUID-IDs (Verhaltenserhalt). `CodexTranscriptReader.transcriptURL` delegiert nur noch. | `97a124d` | 6 neue (Hit, Harvest, Negativ-TTL, Move, Fallback, Filename-Parsing) |
| **C05 → P0.4a** (hoch, **nur Prävention**) | Auto-Namer + Summarizer starten Claude-Printläufe mit `--no-session-persistence` und `codex exec` mit `--ephemeral` (Codex-Äquivalent existiert, verifiziert an installierter CLI); explizites Scratch-cwd statt geerbtem App-cwd (`/`); Kompatibilitäts-Gate: lehnt eine ältere CLI das Flag ab, einmal sichtbar geloggter Retry ohne Flag. **Kein Bestands-Cleanup — P0.4b bleibt gesperrt.** | `8a86863` | 5 neue (argv-Verträge beide Provider, Retry-Gate 3 Fälle, `/bin/pwd`-cwd-Beweis) |
| **R4-AS-11** (hoch) | `migratedWorkspace()` dedupliziert doppelte lokale Session-IDs beim Load/Normalize deterministisch (erste Row gewinnt — die per `first(where:)` ohnehin sichtbare; Log-Notice `agent_store_duplicate_session_ids`). Planer zusätzlich trap-frei (`uniquingKeysWith`) als zweite Verteidigungslinie. | `7953cf5` | 2 neue (Planer-Duplikat ohne Trap, Load-Dedup erste Row) |
| **R4-RESUME-01** (hoch) | `focusLaunchInFlight` wird auf beiden Fehlerpfaden zurückgesetzt: Archiv-/Delete-Guard im Warmup-Task und `catch` in `prepareCommand` (Resume-Transcript fehlt, Builder-Fehler). | `3db6d4d` | — (SwiftUI-`@State`, siehe offene QA) |

Teststand am aktuellen HEAD (`269f8bc`): **1648 Tests, 0 Failures**
(`swift test`, vollständige Suite am 2026-07-20).

## Parallel gelandete Fixes anderer Sessions

Die folgenden Urteile sind ebenfalls **Selbstauskunft der Umsetzung gegen
HEAD**; die verifizierte Matrix bleibt bis zum nächsten G5/G6-Lauf
unverändert.

| Finding | Umsetzungsurteil gegen HEAD | Commit | Tests |
|---|---|---|---|
| **R4-STATUS-01** (hoch) | **Geschlossen.** Der Produktionsdefault ist jetzt `Bundle.module`; `bundledScript()` löst die dort deklarierte SwiftPM-Ressource auf (`WhisperM8/Services/Shared/StatuslineInstaller.swift:25-30,77-82`; `Package.swift:37-45`). Der App-Bundle-Schritt kopiert die generierten `.bundle`-Verzeichnisse nach `Contents/Resources`, also genau die von `Bundle.module` adressierte Ressource (`Makefile:236-248`). Ein Root-Copy der Shell-Datei ist damit nicht mehr erforderlich. | `63c2adc` | 1 neuer Regressionstest ohne Bundle-Injektion (`Tests/WhisperM8Tests/StatuslineInstallerTests.swift:43-48`) |
| **R4-UI-01** (niedrig) | **Geschlossen.** Die Default-Ziele werden über `standardizedFileURL.path` reihenfolgeerhaltend dedupliziert und mit dem injizierten Home aufgebaut (`WhisperM8/Services/Shared/StatuslineInstaller.swift:35-43`). Dieselbe deduplizierte Liste speist Anzeigezähler und Mutation (`WhisperM8/Services/Shared/StatuslineInstaller.swift:110-128,139-161`); `~/.claude` wird daher weder doppelt gezählt noch doppelt beschrieben. Der zusätzliche UI-Refresh im Fehlerpfad hält Zählung und Button nach Teilfehlern aktuell. | `9592d17` | 1 neuer Regressionstest für eindeutige Pfade und injiziertes Home (`Tests/WhisperM8Tests/StatuslineInstallerTests.swift:51-59`) |

Außerdem landeten seit dem vorherigen Log-Stand die CLI-Erweiterungen
`chats close` (`be7ac37`), Tab-/Workspace-Management (`8754a52`) und
Archiv-Suche/Reaktivierung (`415987f`) sowie der ausgelieferte
`gpt-coworker`-Skill (`269f8bc`). Diese vier Commits sind hier als
HEAD-Abgleich erfasst, schließen aber kein Finding der verifizierten
Runde-4-Matrix und verändern das geschlossene Freigabe-Gate nicht.

## Bewusste Abgrenzungen

- **C05 ist damit nicht geschlossen:** P0.4a verhindert nur NEUEN Junk;
  die signaturbasierte Bestandsmigration (P0.4b, W3) bleibt hinter dem Gate.
- **C13-Restschuld:** Die Roadmap-Formulierung „Timeout/Drain definieren"
  ist mit 10-s-Deadline + Drain-Reihenfolge umgesetzt; Läufe > 10 s
  degradieren jetzt sichtbar (Status „—") statt unbegrenzt zu blockieren —
  neue, bewusste Grenze.
- **C16-Trade-off:** Erst-Auflösung brandneuer Codex-Sessions kann durch den
  Negativ-Cache bis ~2 s später erfolgen als der alte Walk-pro-Aufruf;
  dafür entfallen Voll-Walks pro Watcher-Tick vollständig (`negativeTTL`
  justierbar).
- **R4-AS-11:** Der Dedup ist eine Normalisierung mit Datenmutation —
  gedeckt durch die bestehende Backup-vor-Migration-Mechanik des
  Repositories (`AgentWorkspaceRepository.loadBody`). Das tiefer liegende
  N05-Future-Schema-Problem bleibt offen (W1 · R2.3).
- **Kein W0-Oracle-Anspruch:** Die neuen Tests sind gezielte Rot→Grün-
  bzw. Verhaltens-Tests der jeweiligen Fixes, kein Ersatz für die in G4
  geforderte vollständige W0/W1-Test-Spec (insb. C07-Matrix).

## Offene manuelle QA (nach `make dev` durch den User)

1. **P0.4a-Abnahme:** Auto-Naming + Summary je einmal für Claude- und
   Codex-Chat auslösen; danach darf unter `~/.claude/projects/` keine neue
   Session und unter `~/.codex/sessions/` kein neues Rollout liegen.
2. **C13:** Projektwechsel im Inspector mit großem/kaltem Repo — kein
   UI-Freeze, kein Stale-Status des vorherigen Projekts.
3. **C14:** Multi-Window-Verhalten unverändert (Tabs, Selektion, Grid);
   keine ausbleibenden UI-Updates durch das Diff-Gate.
4. **R4-RESUME-01:** `whisperm8 chats resume` auf eine Session mit
   gelöschtem Transcript → Fehlermeldung erscheint, und ein ZWEITER
   Resume-Versuch feuert wieder (vorher verriegelt).
5. **Messnachweis (Ship-Gate 4):** Vorher/Nachher über die
   `perf.sidebar`/`perf.store`-Signposts für C14/C12-Pfade nachholen.

## Nächste freigegebene Kandidaten

R4-VC-11 (Path-Traversal-Delete), R4-AS-03/R4-VC-03
(Pipe-Drain-Deadlocks; Muster liegt seit C13 vor) — alle klein,
gate-unabhängig, mit rotem Oracle vor dem Fix. Parallel dazu der größte
Hebel: die G0–G6-Spec-Nacharbeit der Abschlusskritik.
