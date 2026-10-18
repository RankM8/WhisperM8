---
status: aktiv
updated: 2026-10-17
description: Aufbau der Workflows A (Befund) und B (Vergleich) — Finder, Zuschnitt, Regeln, Ablage. Freigegeben vom User am 17.10.2026.
---

# Arbeitsplan Workflows A und B

## Gemeinsame Regeln

- Workflows A und B liefen mit dem Agent-Typ `gpt` (nativer GPT-Subagent,
  gpt-6.1-sol). Ab Workflow C nutzen alle Agents **Sonnet 5.5** (User-Wunsch
  17.10.2026). Dass dann ein anderes Modell die GPT-Befunde gegenprüft, ist gewollt.
  Haiku wird nie verwendet.
- Nur lesen: kein Produktcode, kein `swift build`/`swift test`, kein `make`.
  Grund: ein paralleler Chat baut im Haupt-Checkout.
- Belege als `pfad:zeile` auf Commit `a8e0f35` (Worktree `audit/launch-readiness`).
- Ausgeklammert bis zum Delta-Lauf: Agent-Chats-UI (`Views/AgentChatsView*`,
  Grid, Tabs, Sidebar, Tab-Switcher, `Views/Workspace/`), `AgentWindowStore`,
  Jarvis-Board, Control-Server (`AgentControl*`), `CLI/Chats*`,
  `Resources/claude-plugin/`.
- Prüftiefe nach Launch-Klasse ([Feature-Inventar](00-scope/feature-inventar.md)):
  Kern = alle Dimensionen, Erweitert = P0/P1, Labs = Seiteneffekte auf
  Kern/Daten/Security, Intern = Security.
- Lösungsvorschläge respektieren: WhisperM8 hostet die echten CLIs (kein Ersatz
  durch Eigen-UI/SDK), kein Stack-Wechsel (ADR 0001), Feature-Erhalt vor Refactor.

## Workflow A „Befund"

| # | Finder | Rohbericht | Lagebild |
|---|---|---|---|
| A1 | Diktat + VoiceGate | `02-findings/A1-diktat.md` | `01-lagebild/diktat.md` |
| A2 | Agent-Kern: Daten | `02-findings/A2-agent-daten.md` | `01-lagebild/agent-daten.md` |
| A3 | Agent-Kern: Laufzeit | `02-findings/A3-agent-laufzeit.md` | `01-lagebild/agent-laufzeit.md` |
| A4 | Konten + GPT-Backend | `02-findings/A4-konten-gpt.md` | `01-lagebild/konten-gpt.md` |
| A5 | Onboarding, Settings, App-Hülle | `02-findings/A5-onboarding-shell.md` | `01-lagebild/onboarding-shell.md` |
| A6 | Shared-Infrastruktur, Querschnitt | `02-findings/A6-shared-infra.md` | `01-lagebild/shared-infra.md` |
| A7 | Build, Release, Tests | `02-findings/A7-build-release-tests.md` | `01-lagebild/build-release-tests.md` |
| A8 | Altlasten + Doku | `02-findings/A8-altlasten-doku.md` | — |
| A9 | Vollständigkeits-Kritiker | `02-findings/A9-vollstaendigkeit.md` | — |

Die Datei-Zuteilung je Finder steht im Workflow-Skript; A9 prüft sie gegen
`git ls-files`.

## Workflow B „Vergleich"

| # | Thema | Bericht |
|---|---|---|
| B1 | Diktat-Apps | `03-vergleich/B1-diktat-apps.md` |
| B2 | Session-Manager Claude/Codex | `03-vergleich/B2-session-manager.md` |
| B3 | macOS-Engineering + Terminal | `03-vergleich/B3-macos-engineering.md` |
| B4 | Verteilung + Rahmenbedingungen (E2–E5) | `03-vergleich/B4-verteilung-rahmen.md` |

## Danach

Ich führe die Befunde zusammen, vergebe IDs (`LR-…`) und fülle
`findings.jsonl`. Dann kommen Workflow C (Verifikation), die Synthese und der
Delta-Lauf.
