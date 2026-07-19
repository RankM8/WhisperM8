# whisperm8 chats — CLI-Plan (Jarvis als CLI + Skill)

Vollständiger Umsetzungsplan für den CLI-Namespace `whisperm8 chats`: Jede
Claude-Code-Session kann alle anderen Agent-Sessions sehen und verwalten
(Supervisor-/„Jarvis"-Pattern) — ohne neues UI, gesteuert über einen Skill.
Löst den Plan `../jarvis-supervisor/` (Rev 2, 2026-07-04) ab.

**Einstieg: `index.html` im Browser öffnen.** Der Hub enthält eine interaktive
Terminal-Demo (overview/tail/send), die Drei-Schichten-Trennung, den Datenfluss
und die Slice-Roadmap; die Pakete verlinken linear aufeinander.

## Struktur

```
whisperm8-chats-cli/
├── index.html                        ← Hub: Demo, Trennung, Datenfluss, Pakete, Slices, Entscheidungen
├── README.md                         ← diese Datei
├── 01-cli/
│   ├── 01-befehlsreferenz.html       ← alle 12 Befehle: Syntax, Flags, JSON-Schemas, Exit-Codes, Guards
│   └── 02-adressierung-status-wait.html ← SessionRefResolver, Status-One-Shot, Attention-Modell, wait-Engine
├── 02-system/
│   ├── 01-architektur.html           ← Service-Landkarte, Control-Socket (BSD-UDS/NDJSON), Identität, Send-Pipeline, Gotchas
│   └── 02-skill.html                 ← Skill whisperm8-chats: Autonomie-Stufen, Supervisor-Loop, SKILL.md-Entwurf, Allowlist
└── 03-umsetzung/
    └── 01-slices-tests.html          ← 4 Slices mit Tasks/DoD, Go/No-Go, Testplan, Failure-Matrix, Rollout
```

## Lineare Lese-Reihenfolge

1. `index.html` — Zielbild, Trennung, Datenfluss, Entscheidungen
2. `01-cli/01-befehlsreferenz.html` — der Befehlsvertrag (Abnahme-Grundlage)
3. `01-cli/02-adressierung-status-wait.html` — die puren Kerne
4. `02-system/01-architektur.html` — Socket, Identität, Send-Pipeline
5. `02-system/02-skill.html` — Verhalten und Autonomie
6. `03-umsetzung/01-slices-tests.html` — Slices, Tests, Failure-Modes

Jede Seite verlinkt am Ende auf die nächste; die letzte zurück zum Hub.

## Kernentscheidungen (2026-07-19)

- **Namespace `whisperm8 chats`** — kein `jarvis`-Alias in v1; `agent` bleibt
  den Codex-Subagent-Jobs vorbehalten.
- **Kein Jarvis-UI, kein MCP, kein Codex-Brain** — der supervisierende Chat IST
  der Tool-Loop; die CLI liefert Augen (Disk-Reads) und Hände (Control-Socket).
- **Send-Autonomie über den Skill**: vor `send`/`archive` AskUserQuestion bzw.
  aktive Rückfrage; Claude-Code-Permissions als zweites Netz; CLI-Guards
  (Selbst-Send, working-Ziel, tote PTY) als drittes.
- **Lese-Pfad app-unabhängig** (Workspace-JSON read-only + Transcript-Parsing
  mit den bestehenden puren Bausteinen), **Schreib-/Live-Pfad nur über die
  laufende App** (BSD-UDS, NDJSON, atomare Guards auf dem MainActor —
  Workspace-Single-Writer bleibt die App).
- **Identität**: App injiziert `WHISPERM8_SESSION_ID` + Zufalls-Token in jede
  PTY; Selbst-Send-Schutz, „(du)"-Markierung, Audit-Log.
- **Alignment-Runde (2026-07-19, Grilling)**: Send-Freigaben pro Session &
  Konversation; alle drei Send-Arten (Antwort/Auftrag/Steering) hinter Gates;
  automatische Marker-Zeile `[via whisperm8 chats · …]` + Ein-Hop-Regel;
  Agent-Dialog in v1 über Transcript (Push-Rückkanal = v2 mit Loop-Guards);
  `new`-Eigeninitiative nur als Vorschlag; Aufräumen als Batch-Bestätigung
  (Multi-Select); Lesen ohne Projekt-Scoping; Supervisor-Loop bis Stopp;
  destruktives Maximum ist `archive` (kein delete, kein PTY-Kill).

## Recherche-Grundlage

- Code-Fakten (PTY-Spawn, Send-Pfade, Persistenz, Status-Decider, Reader,
  CLI-Konventionen) per Explore-Agents verifiziert, Stand 2026-07-19.
- Architektur-Review (GPT): TOCTOU-Analyse, UDS-Härtung, tmux/zellij/VS-Code-
  Prior-Art, Exit-Code-Vertrag — Empfehlungen sind eingearbeitet.

## Hinweise

- HTML-Seiten sind self-contained (nur Google Fonts extern), lokal lauffähig.
- Für GDrive-Weitergabe: Ordner als ZIP; Cross-Links funktionieren in der
  GDrive-Preview nicht.
- Terminal-Mockups nutzen die dunkle WhisperM8-Palette
  (`docs/design/transcription-bar-redesign.html` als Farbquelle).
- Nach Umsetzung (Slice 4): Plan → `docs/archive/`, Feature-Doku →
  `docs/features/agent-chats-cli.md`.
