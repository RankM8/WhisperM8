# Jarvis v1 — Plan-Dokumentation

Globaler Agent-Supervisor für WhisperM8: Status-Board, Codex-Brain-Chat und
Review-first-Actions im rechten Inspector des Agent-Chats-Fensters.

**Einstieg: `index.html` im Browser öffnen.** Der Hub enthält ein interaktives
Mockup des kompletten Fensters (Segment-Switcher Übersicht/Chat/Aktionen) und
verlinkt alle Detail-Pakete.

## Struktur

```
jarvis-supervisor/
├── index.html                            ← Hub: Produkt-Mockup, Trennung, Datenfluss, Pakete, Slices
├── README.md                             ← diese Datei
├── 2026-07-04-jarvis-supervisor-plan.md  ← technischer Plan (Rev 2) — Quelle des HTML-Pakets
├── 01-ux/
│   ├── 01-uebersicht-board.html          ← Board, Attention-Modell, Tier-1/2-Reports, Notifications
│   ├── 02-chat.html                      ← Chat, @-Mentions, Kontextbudget, Thinking/Fehler-States
│   └── 03-aktionen.html                  ← Action-Queue, Apply/Skip/Undo, Prompt-Drafts, PTY-Send
└── 02-system/
    ├── 01-architektur.html               ← Service-Landkarte, Digest, Codex-Aufruf, JSON-Vertrag, Gotchas
    └── 02-roadmap.html                   ← 4 Slices, Go/No-Go, Testplan, Failure Modes, v2-Liste
```

## Lineare Lese-Reihenfolge

1. `index.html` — Zielbild, Drei-Schichten-Trennung, Datenfluss
2. `01-ux/01-uebersicht-board.html` — das ambiente Mission Control
3. `01-ux/02-chat.html` — Supervisor-Chat und @-Mentions
4. `01-ux/03-aktionen.html` — Review-Layer und der Send-Loop
5. `02-system/01-architektur.html` — Services, Verträge, Gotchas
6. `02-system/02-roadmap.html` — Slices, Tests, Failure Modes

Jede Seite verlinkt am Ende auf die nächste; die letzte zurück zum Hub.

## Pakete-Übersicht

| Paket | Datei | Inhalt | Slices |
|---|---|---|---|
| 01 | `01-ux/01-uebersicht-board.html` | Attention-Modell, Board-Zustände, Tier-1/2-Report-Karten, Badge, Notifications + MenuBar | 1–2 |
| 02 | `01-ux/02-chat.html` | Mention-Picker, Kontextbudget (12k/200/60k), Thinking-UX, Quick-Replies, Codex-Fehler | 1–2 |
| 03 | `01-ux/03-aktionen.html` | 5 Action-Kinds, Apply-Pipeline mit Drift-Check, Undo, Bracketed-Paste-Send | 3–4 |
| 04 | `02-system/01-architektur.html` | Service-Landkarte (8 neue Services), Digest-Routing + LRU-Cache, `codex exec`-Aufruf, Strict-JSON-Vertrag, Persistenz, Gotchas | alle |
| 05 | `02-system/02-roadmap.html` | 4 Vertical Slices, Go/No-Go-Kriterien nach Slice 1, Testplan, Failure-Matrix, v2-Kandidaten | — |

## Kernentscheidungen (Rev 2, 2026-07-04)

- **Kein Read-only-Tool-Loop** — Kontext wird vorab injiziert, genau ein
  `codex exec`-Aufruf pro Turn. Tool-Loop = v2 als MCP-Server.
- **Zweistufige Reports** — Tier 1 sofort ohne LLM, Tier 2 (Codex) nur on demand.
- **Board-first UX** — Segmente Übersicht/Chat/Aktionen; Badge zählt „braucht
  mich", nicht Reports.
- **Inspector in jedem Fenster** — globaler State, fensterlokaler Toggle.
- **Review-first** — Mutationen nur als Action-Karten mit Apply/Skip/Undo.

## Hinweise

- Die HTML-Seiten sind self-contained (nur Google-Fonts extern) und lokal im
  Browser lauffähig — kein Server nötig.
- Für GDrive-Weitergabe: Ordner als ZIP hochladen; die Cross-Links zwischen den
  Seiten funktionieren in der GDrive-Preview nicht.
- Mockup-Farben entsprechen dem dunklen WhisperM8-Theme
  (`docs/design/transcription-bar-redesign.html` als Farbquelle).
- Quelle aller Inhalte: `2026-07-04-jarvis-supervisor-plan.md` (Revision 2).
  Bei Widersprüchen gilt das Markdown.
