---
status: aktiv
updated: 2026-07-20
description: Operative Single Source der Audit-Umsetzung mit Phase-0-Commits, Gate-Paketstatus, formaler G6-Abnahme, Entscheidungsregister und QA-Sammelliste.
---

# Umsetzungsplan Audit 2026-07 (Single Source für die Umsetzung)

## Handoff — so setzt eine neue Session hier auf

1. **Diese Datei ist der Einstieg.** Sie enthält Stand, Plan, offene
   Entscheidungen und QA. Alles andere ist Referenz:
   [Roadmap](../05-roadmap/refactor-roadmap.md) (Wellen + Maßnahmen-Details,
   inkl. Runde-3/4-Nachträge), [verifizierte Matrix](../04-verifikation/runde4-findings-matrix.md)
   (Finding-Status), [Abschlusskritik](../02-findings/runde4-abschlusskritik.md)
   (P0-Blocker + Gates G0–G6), [Schlussverifikation](verifikation-schluss.md)
   (Spec-Mängel im Detail), [Audit-README](../README.md) (Gesamtindex).
2. **Autoritätsreihenfolge bei Widerspruch:** Abschlusskritik → Matrix →
   Schlussverifikation → Roadmap → dieser Plan. Statusangaben hier sind
   Selbstauskunft der Umsetzung; die Matrix wird nur durch einen
   G5/G6-Verifikationslauf fortgeschrieben. Die formale Abnahme steht in der
   [Gate-Tabelle G0–G6](freigabe-gates-g0-g6.md).
3. **Arbeitsregeln:** Sessions laufen IN der WhisperM8-App — nie
   `make dev`/`make kill` (killt die eigene Session); bauen/testen nur mit
   `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`.
   Manuelle QA sammeln (Liste unten), bis der User bewusst neu baut.
   Delegation an GPT-Subagents (`subagent_type: "gpt"`) für Spec, Analyse,
   Review, klar geschnittene Umsetzung; Review-Gate (Diff + Tests) und
   Commits bleiben beim Orchestrator. Kein Produktcode für Phasen 3–4 vor
   formal abgenommenen Gates.
4. **Regressionsschutz:** Feature-Inventare ([Agent-Chats](feature-inventar-agentchats.md),
   [Diktat](feature-inventar-diktat.md)) sind die Referenz — keine
   Feature-Regression; WhisperM8 bleibt CLI-Host (echte Claude-/Codex-CLI
   im PTY, kein SDK-/Eigen-UI-Ersatz).

## Stand (2026-07-20)

**Phase 0 ist umgesetzt:** R4-VC-11 (`e104706`), R4-AS-03 (`d375855`) und
R4-VC-03 (`3086b9e`) sind mit gezielten Tests gelandet. **Phase 1 ist als
Paketarbeit abgeschlossen beziehungsweise dokumentiert blockiert:** A (`786d012`),
C (`4a78f3d`), D (`b902d41`) und E (`cbf28cd`, `75cd5a9`) liegen vor; B
(`9f7b13a`) blieb am isolierten Auth-Gate fail-closed blockiert; F ist die
[formale Gate-Abnahme](freigabe-gates-g0-g6.md).

Die unabhängige F-Abnahme bestätigt **G0–G6 technisch**: Alle fünf
Dokumentations-/Spezifikations-P0s sind geschlossen und sämtliche gerouteten
Runde-4-Hochbefunde besitzen reale Testverträge. Das ist noch kein Produkt-Go:
R4-WAIT-01 und weitere rote Oracles bleiben als Produktfix offen; P0.3/P0.4
und W0.1 bleiben bis zur formalen User-Abnahme gesperrt.

**Zuletzt vollständig gemessene Suite: 1648 Tests, 0 Failures** — auf
`269f8bc`. Die danach gelandeten Phase-0-Fixes besitzen gezielte Tests, eine
erneute vollständige Suite wurde in Paket F nicht ausgeführt.

### Erledigt (Selbstauskunft, je einzeln committet)

| Finding | Kurz | Commit | Tests |
|---|---|---|---|
| **C14** (hoch) | WindowStore-No-op-Mutationen diff-gated (`mutate` vergleicht Kopie, `updateWindow`-Vorab-Guard) — keine leeren Re-Render-Wellen/Saves | `a36fcee` | 3 neue |
| **C13** (hoch) | Git-Status off-main, cancellable, stale-safe (`.task(id:)`, Sofort-Leeren); `git()`-Helfer: Drain vor Wait, stderr→null, 10-s-Deadline | `87d3027` | 6 neue |
| **C16** (mittel) | `CodexTranscriptLocator`: ein Walk harvestet alle Session-UUIDs, Hit-Validierung per `fileExists`, Negativ-TTL 2 s, Suffix-Fallback | `97a124d` | 6 neue |
| **C05→P0.4a** (hoch, nur Prävention) | Auto-Namer/Summarizer: `--no-session-persistence` (Claude) / `--ephemeral` (Codex) + Scratch-cwd + Retry-Gate für ältere CLIs. Bestands-Cleanup (P0.4b) bleibt gesperrt | `8a86863` | 5 neue |
| **R4-AS-11** (hoch) | Doppelte Session-IDs: Load-Dedup in `migratedWorkspace` (erste Row gewinnt, Log-Notice) + trap-freier Summary-Planner | `7953cf5` | 2 neue |
| **R4-RESUME-01** (hoch) | `focusLaunchInFlight`-Reset auf beiden Fehlerpfaden (Warmup-Guard, `prepareCommand`-catch) — kein verriegelter Tab nach Launch-Fehler | `3db6d4d` | — (View-State → QA) |
| **R4-STATUS-01** (hoch) | Statusline-Skript via `Bundle.module` (SwiftPM-Ressource) statt `Bundle.main` — Installation findet die Ressource | `63c2adc` (Parallel-Session) | 1 neuer |
| **R4-UI-01** (niedrig) | Config-Roots reihenfolgeerhaltend dedupliziert (`standardizedFileURL`) — `~/.claude` nicht mehr doppelt | `9592d17` (Parallel-Session) | 1 neuer |
| **R4-VC-11** (mittel) | Job-IDs validiert; Job-Pfade bleiben unter dem Job-Root, einschließlich Symlink-Grenze | `e104706` | gezielte CLI-/Store-Tests |
| **R4-AS-03** (hoch) | Worktree-Git-Runner drainiert deadlock-frei und besitzt eine Deadline mit Termination/Eskalation | `d375855` | 2 neue |
| **R4-VC-03** (hoch) | ffmpeg-Fallback drainiert deadlock-frei und besitzt Deadline/Termination | `3086b9e` | 3 neue |
| R3-MIX-G07 / R3-LIVE-G01 | Alt-Teilfixe (Managed Installer-Pin; 272k-Fenster) — Restverträge offen | `0bdff8f`+ / `17f76dc` | — |

### Bewusste Abgrenzungen

- **C05:** nur Prävention; ~495 Alt-Junk-Sessions bleiben bis P0.4b (W3).
- **C13:** Git-Läufe >10 s werden jetzt abgebrochen (sichtbare Degradation
  statt Endlos-Hänger) — neue, bewusste Grenze.
- **C16:** Erst-Auflösung brandneuer Codex-Sessions bis ~2 s später
  (Negativ-Cache, `negativeTTL` justierbar); dafür keine Voll-Walks mehr.
- **R4-AS-11:** Dedup ist Datenmutation — gedeckt durch die bestehende
  Backup-vor-Migration-Mechanik; N05-Future-Schema bleibt offen (W1).
- Die neuen Tests sind Fix-Verträge, **kein** Ersatz für die G4-Test-Spec.

## Entscheidungsregister (entschieden am 2026-07-20)

Alle fünf Festlegungen wurden einzeln mit dem User durchgegangen und
entschieden (jeweils die Empfehlung). Sie sind damit verbindliche
Vorgaben für die Gate-Arbeit in Phase 1.

| # | Frage (Klartext) | Entscheidung | Status |
|---|---|---|---|
| E1 | Wer vergibt die Chat-ID: Claude selbst (heute) oder WhisperM8 vorab? | Beim heutigen Weg bleiben (Claude vergibt, App fängt streng geprüft ein = Weg B als Baseline); Vorab-Vergabe (Weg A) nur capability-gegatet nach bestandener Live-Probe der installierten CLI. | **entschieden** |
| E2 | Darf die App in Claudes eigene Daten (`~/.claude`) schreiben? | Nein — nur lesen; Reparaturen nur in WhisperM8-eigenen Daten vermerken. Bestehende Schreib-Ausnahmen (Account-Umzug, Theme-Sync) werden in der Spec-Arbeit als eng gesicherte Ausnahmen festgeschrieben oder zurückgebaut. | **entschieden** |
| E3 | Testnetz vor dem Kern-Umbau: vollständig oder abgespeckt? | Vollständig — fehlende Verträge B18–B22 plus C07-Fallmatrix werden ergänzt, keine Umbenennung in „Teilmenge". | **entschieden** |
| E4 | Terminal-Snapshots: Aufräumregel (Ablauf/Größenlimit) festschreiben? | Ja — verbindliches Soll-Gate: Ablauf/Größenlimit, garantiertes Mitlöschen bei Session-Löschung, keine Eingabe-Aufzeichnung (Umsetzung später, W2/T1). | **entschieden** |
| E5 | Unklare Chat↔Verlauf-Zuordnung: weiter raten oder markieren? | Nicht raten — unklare Fälle fail-closed als „prüfen" markieren und sichtbar machen; User wählt den richtigen Verlauf. | **entschieden** |

## Phasenplan

### Phase 0 — Restliche Sofort-Fixes (abgeschlossen)

| Maßnahme | Problem in Klartext | Status / Evidenz |
|---|---|---|
| R4-VC-11 | Manipulierte Job-ID kann rekursives Löschen AUSSERHALB des Job-Ordners auslösen | **erledigt** — `e104706`, gezielte Argument-/Store-/Symlink-Tests |
| R4-AS-03 | `git status` im Worktree-Manager kann dauerhaft hängen (Pipe-Deadlock; Muster seit C13 vorhanden) | **erledigt** — `d375855`, Drain-/Deadline-Tests |
| R4-VC-03 | ffmpeg-Fallback der Transkriptions-CLI kann dauerhaft hängen (gleiches Muster) | **erledigt** — `3086b9e`, Drain-/Deadline-Tests |

### Phase 1 — Gate-Arbeit G0–G6 (technisch abgenommen; User-Go ausstehend)

Die Pakete sind abgegeben beziehungsweise bei B dokumentiert fail-closed
blockiert. Alle G0–G6-Kriterien sind technisch erfüllt; die verbindliche
Abnahme und Produktsperre stehen in der [Gate-Tabelle G0–G6](freigabe-gates-g0-g6.md).

| Paket | Inhalt | Paketstatus / Evidenz | Gate-Urteil F |
|---|---|---|---|
| A (G0–G2) | Einheitlicher Identitätsvertrag: ID-Vergabe, Launch-Korrelation/Claim-Regeln, Übergänge `/branch` `/rewind` `/clear` `/resume` `/compact` | **erledigt** — `786d012` | G0–G2 erfüllt; R4-WAIT-01 bleibt als Produktfix offen |
| B (Live-Probe) | Fork-Verhalten der installierten Claude-CLI empirisch belegen — isoliert im Scratch-Config-Root, kein Junk in echten Daten | **blockiert/fail-closed** — `9f7b13a`; Auth-Gate Exit 1 | `hostAssignedVerified` bleibt aus; Weg B ist Baseline, daher kein eigenständiger Gate-Blocker |
| C (G3) | Feature-Inventar ehrlich machen: AC-41/AC-52/AC-30 in Ist/Lücke/Soll trennen; R4-AS-11 als Persistenz-/Startup-Invariante aufnehmen; Snapshot-Privacy als offenes Gate | **erledigt** — `4a78f3d` | G3 erfüllt |
| D (G4) | Test-Spec vollständig auf W0/W1 (B18–B22, C07-Matrix, Runde-4-Oracles) | **erledigt** — `b902d41` plus Paket-F-Nachtrag | G4 erfüllt; alle gerouteten W0/W1-Maßnahmen besitzen ausführbare Verträge |
| E (G5) | Runde-4-Findings dedupliziert in Matrix/Roadmap verankern | **erledigt** — `cbf28cd`, `75cd5a9` plus Paket-F-Nachtrag | G5 erfüllt; 28 Quell-IDs in 27 eindeutigen Maßnahmen mit Roadmap- und Test-Gate |
| F (G6) | Referenzen nachziehen, formale Gate-Tabelle, unabhängiger Gegenleser | **erledigt** — [formale Gate-Abnahme](freigabe-gates-g0-g6.md), kein Commit | G6 technisch erfüllt; User-Go ausstehend |

Phase 1 blieb reine Spec-/Doku-Arbeit; aus der technischen Abnahme folgt noch
kein Produktcode-Go. Nächster Schritt ist die formale User-Abnahme; danach darf
zuerst W0.1 als Oracle-Welle starten, nicht pauschal W1 oder P0.3/P0.4.

### Phase 2 — Welle 0/1: Oracles, dann aktiven Schaden stoppen

1. **W0-Oracles** gemäß neuer Test-Spec.
2. **Datenintegrität:** N06 (Keychain kann einzigen API-Key löschen),
   N03/N04 (Output-Modi: Crash bzw. Totalverlust), N05 + R4-SCHEMA-01
   (Future-Schema-Downgrade), Skill-Ownership-Cluster
   R4-SKILL-01/R3-DEF-G01 (Overwrite ohne Guard/Backup),
   Lost-Update-Cluster R4-INSTALL-01/R4-AS-01/R4-SHELL-02.
3. **Recorder-Crashes:** C01/C02 (+N02-Quit-Schutz im gemeinsamen
   Termination-Contract mit Phase 3).
4. **Codex-Supervisor R2.4 (W1!):** N07/N08/N14 — Ready-Handshake,
   Stop-Latch, semantische Turn-Finalität.
5. **Environment-Fabrik P1.1:** ein Umbau, ~7 Findings (N09/N10-Secrets,
   C06/R4-CP-05-Profile u. a.); dazu Context-Profile fail-closed
   R4-CP-02/03 und Prozessbaum-/PID-Härtung R4-HCLI-01/02 + R4-PLUG-02.
6. **Chats-CLI-Härtung:** R4-AUTH-01/02, R4-IDEM-01, R4-CTRL-01/02,
   R4-SEC-01; dazu die Wait-/Stempel-Verträge R4-WAIT-01/02 + R4-PROF-01
   (W0-Oracle, Fix nach Paket A, da identitätsnah).
7. **Weitere W1/W2-Hochbefunde:** R4-PLUG-01 (Plugin-Secrets in argv),
   R4-SHELL-01 (`echo -e`-Zweitinterpretation), R4-STATUS-PROFILE-01
   (Profil-Symlink-Reconciliation, W2).
8. **GPT-Ship-Blocker** (solange GPT-Backend aktiv genutzt):
   Lifecycle-Automat (R3-PROXY-G01/02/04/05, R3-SEC-G04, R4-LIFE-01,
   R4-GPTL-02), Background-Spawn-Guard R3-PROXY-G03, Client-Auth
   R3-SEC-G02, Health-Identität R3-SEC-G01, Update-Vertrauenswurzel
   R4-GPTS-01, Contract-Fixtures R3-MIX-G07-Rest + R3-MIX-G01/G03
   (extern verifizierte Token-/History-Verträge, W0-Fixture zuerst),
   Usage-E2E R3-LIVE-G01-Rest.

Vollständige ID-Abdeckung bleibt Aufgabe der Matrix + des
Runde-4-Roadmap-Nachtrags (und wird in Paket E/G5 verankert) — dieser
Plan priorisiert und ersetzt keine Traceability.

### Phase 3 — Welle 2: Kern-Korrektheit (erst nach G6-Abnahme)

Identitäts-/Recovery-Umsetzung (P0.5/P0.6/P1.3/P1.4), gemeinsamer
Termination-Contract (N02 + C10 + Snapshot-Prüfpunkte), Auto-Paste-Intent
(N11), Job-State-CAS (N12/N13), Background-Reconciliation (C08 · P1.2),
Recorder-Isolation (C03).

### Phase 4 — Welle 3: Performance-Großbaustellen und Transcript-Vertrag

C12/C15 (Merge/Projektionen), P1.11 (N15/N16 Transcript-Korrelation +
Drift), Diktat-Stop-Reihenfolge (größter Diktat-Hebel), Tail-Reparse/
Report-I/O, P0.4b (Headless-Bestandsmigration), T1 (Terminal-Recording).
Danach W4 (Modulgrenzen) nach Bedarf.

## QA-Sammelliste (wartet gebündelt auf das nächste `make dev`)

1. **P0.4a:** Auto-Naming + Summary je einmal für Claude- und Codex-Chat →
   danach KEINE neue Session unter `~/.claude/projects/`, kein neues
   Rollout unter `~/.codex/sessions/`.
2. **C13:** Projektwechsel im Inspector mit großem/kaltem Repo — kein
   Freeze, kein Stale-Status.
3. **C14:** Multi-Window/Tabs/Grid unverändert; keine ausbleibenden
   UI-Updates durch das Diff-Gate.
4. **R4-RESUME-01:** `whisperm8 chats resume` auf Session mit gelöschtem
   Transcript → Fehlermeldung, und ein ZWEITER Versuch feuert wieder.
5. **Signpost-Messung** (Ship-Gate 4): Vorher/Nachher via `perf.sidebar`/
   `perf.store` für die C14/C12-Pfade.
6. **Parallel-Features** (andere Sessions): Tab-Management/`chats close`/
   Archiv-CLI und Statusline-Installation einmal durchklicken.
