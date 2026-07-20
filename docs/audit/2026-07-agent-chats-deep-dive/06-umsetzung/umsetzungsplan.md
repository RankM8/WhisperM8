---
status: aktiv
updated: 2026-07-20
description: Die eine operative Datei zur Audit-Umsetzung — Handoff für neue Sessions, erledigte Maßnahmen mit Commits, Phasenplan, offenes Entscheidungsregister und QA-Sammelliste.
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
   G5/G6-Verifikationslauf fortgeschrieben.
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

**Suite: 1648 Tests, 0 Failures** — gemessen auf `269f8bc` (letzter
Code-Commit; alles danach ist reine Doku). Alle untenstehenden Fixes dort
integrationsgeprüft (C14-Diff-Gate auch gegen das parallel gelandete
Tab-Management verifiziert).

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

## Entscheidungsregister (offen — wird einzeln mit dem User besprochen)

Ohne E1–E5 startet Phase 1 nicht. Formulierung bewusst untechnisch;
keine gilt als getroffen.

| # | Frage (Klartext) | Warum wichtig | Empfehlung | Status |
|---|---|---|---|---|
| E1 | Wer vergibt die Chat-ID: Claude selbst (heute) oder WhisperM8 vorab? | Wurzel der Chat-Verbindungs-Bugs (verlorene Chats, falsche Resumes). Vorab-Vergabe hat real „No conversation found" erzeugt. | Beim heutigen Weg bleiben und absichern; Vorab-Vergabe nur nach bestandener Live-Probe der installierten CLI. | offen |
| E2 | Darf die App in Claudes eigene Daten (`~/.claude`) schreiben? | Reparatur-Ideen bräuchten das; Risiko: Claude-History beschädigen. | Nein — nur lesen; Reparaturen nur in WhisperM8-eigenen Daten vermerken. | offen |
| E3 | Testnetz vor dem Kern-Umbau: vollständig oder abgespeckt? | Der Umbau betrifft den Kern (Chat-Bindung); Lücken = Regressionsrisiko. | Vollständig (fehlende Verträge B18–B22 + C07-Fallmatrix). | offen |
| E4 | Terminal-Snapshots: Aufräumregel (Ablauf/Größenlimit) festschreiben? | Liegen unverschlüsselt und unbegrenzt auf der Platte, ggf. mit Secrets. | Ja, als verbindliches Soll-Gate (Umsetzung später, W2/T1). | offen |
| E5 | Unklare Chat↔Verlauf-Zuordnung: weiter raten oder markieren? | Heute wird der zeitlich nächste Kandidat geraten — kann falsch verbinden. | Nicht raten: Chat als „prüfen" markieren und sichtbar machen. | offen |

## Phasenplan

### Phase 0 — Restliche Sofort-Fixes (gate-frei, jederzeit)

| Maßnahme | Problem in Klartext | Aufwand |
|---|---|---|
| R4-VC-11 | Manipulierte Job-ID kann rekursives Löschen AUSSERHALB des Job-Ordners auslösen | M |
| R4-AS-03 | `git status` im Worktree-Manager kann dauerhaft hängen (Pipe-Deadlock; Muster seit C13 vorhanden) | S–M |
| R4-VC-03 | ffmpeg-Fallback der Transkriptions-CLI kann dauerhaft hängen (gleiches Muster) | S–M |

### Phase 1 — Gate-Arbeit G0–G6 (reine Spec-/Doku-Arbeit; braucht E1–E5)

Schaltet den gesperrten Kern-Umbau frei. Sechs delegierbare Pakete
(inhaltliche Definition: [Abschlusskritik](../02-findings/runde4-abschlusskritik.md)):

| Paket | Inhalt | Abhängigkeit |
|---|---|---|
| A (G0–G2) | Einheitlicher Identitätsvertrag: ID-Vergabe, Launch-Korrelation/Claim-Regeln, Übergänge `/branch` `/rewind` `/clear` `/resume` `/compact` | E1, E2, E5 |
| B (Live-Probe) | Fork-Verhalten der installierten Claude-CLI empirisch belegen — isoliert im Scratch-Config-Root, kein Junk in echten Daten | parallel möglich |
| C (G3) | Feature-Inventar ehrlich machen: AC-41/AC-52/AC-30 in Ist/Lücke/Soll trennen; R4-AS-11 als Persistenz-/Startup-Invariante aufnehmen (Codefix ersetzt das Oracle nicht); Snapshot-Privacy als offenes Gate | E4 |
| D (G4) | Test-Spec vollständig auf W0/W1 (B18–B22, C07-Matrix, Runde-4-Oracles) | E3, nach A |
| E (G5) | Runde-4-Findings dedupliziert in Matrix/Roadmap verankern (Konsolidierung, keine Neuanalyse) | teils parallel, Links nach D |
| F (G6) | Referenzen nachziehen, formale Gate-Tabelle, unabhängiger Gegenleser | nach allem |

Umfang: ~1.100–1.800 Doku-Zeilen; parallel delegiert ca. 3–5 h Wandzeit
plus User-Abnahme. Kein Produktcode.

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
