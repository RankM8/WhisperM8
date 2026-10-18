---
status: aktiv
updated: 2026-10-18
description: Einstieg und Status des Launch-Readiness-Audits (Oktober 2026) — Ziel, Phasen, Ordnerstruktur, nächste Entscheidung.
---

# Launch-Readiness-Audit (2026-10)

**Ziel:** WhisperM8 so weit bringen, dass ein Mensch ohne Entwickler-Hintergrund
die App über `brew install --cask rankm8/tap/whisperm8` installiert, geführt
einrichtet und Diktat wie Agent Chats ohne Terminal-Wissen zuverlässig nutzt.
Maßstab ist die [Launch-Definition](00-scope/launch-definition.md), nicht
„alles finden".

**Analyse-Stand:** Commit `a8e0f35` (Worktree `audit/launch-readiness`). Alle
`file:line`-Belege beziehen sich auf diesen Commit, bis ein Delta-Lauf ihn
ausdrücklich anhebt.

## Status

| Schritt | Inhalt | Stand |
|---|---|---|
| 0 | Scope: [Launch-Definition](00-scope/launch-definition.md), [Feature-Inventar](00-scope/feature-inventar.md) | **beschlossen 17.10.2026** (alle Vorschläge E1–E6 übernommen) |
| 1 | Workflow A „Befund" (Subsysteme × Dimensionen) | fertig 17.10.: 123 Befunde (106 eigenständig), [Register](findings.jsonl), [Rohberichte](02-findings/) |
| 2 | Workflow B „Vergleich" (externe Repos, Best Practices) | fertig 17.10.: [4 Berichte](03-vergleich/), [Faktenprüfung VB](04-verifikation/VB-faktenpruefung.md) |
| 2b | Lagebild + Oracle-Update + Lokalisierungs-Inventar (LO) | fertig 17.10.: [Lagebild](01-lagebild/), [Oracle](00-scope/oracle/), [Lokalisierung](00-scope/lokalisierung-inventar.md) |
| 3 | Workflow C „Verifikation" (80 P0/P1, Sonnet) | fertig 17.10.: [Urteile](04-verifikation/C-urteile.md) |
| 3a | C2 Schiedssprüche (17 Extremfälle, Sonnet) | fertig 17.10.: [Sprüche](04-verifikation/C2-schiedsspruch.md) — 14× Prüfer, 3× dazwischen, kein P0 |
| 3a | O Opus-Review (Kalibrierung, P2-Prüfung, Red Team, Testmatrix) | fertig 17.10.: [Review](04-verifikation/O-opus-review.md), 13 neue Befunde, [Testmatrix](05-plan/anforderungs-testmatrix.md), [QA-Liste](05-plan/manuelle-qa-liste.md); Register 136 Befunde, 24 Launch-Blocker |
| 3b | Delta-Lauf (Agent-UI, Grid/Notizen, Control, Chats-CLI, Board, Mod, Delta seit a8e0f35) | fertig 17.10. auf `76256ad`: [Bericht](02-findings/D-delta.md), 52 Befunde (2 P1, davon 1 sofort behoben), Register 192 Einträge, 25 offene Launch-Blocker |
| 3c | CPU-Last unter Betrieb | fertig 17.10.: [Bericht](02-findings/P1-cpu-last.md), 4 Befunde nach Nutzen |
| 4 | Synthese → Wellenplan | **freigegeben 18.10.2026**: [Wellenplan](05-plan/wellenplan.md), 11 Wellen, 163 Befunde `geplant`, 28 Launch-Blocker, D1–D5 wie empfohlen |
| 5 | Umsetzung in Wellen | W0 umgesetzt 18.10. (19 Befunde, auf `main`), E2E automatisch grün, manuelle QA offen ([Protokoll](06-umsetzung/W0.md)) |
| 6 | Launch-Abnahme gegen die Definition of Done | offen |

**Zurückgestellt bis zum Merge der Jarvis-Randnotizen** (anderer Chat arbeitet
dort): Agent-Chats-UI (Grid, Kacheln, `AgentChatsView`), Jarvis-Board,
Control-Server, Board-CLI, Plugin-Mod. Diese Bereiche bekommen einen eigenen
Delta-Lauf auf dem dann aktuellen Commit.

## Ordnerstruktur

```
README.md                 dieser Index
00-scope/                 Launch-Definition, Feature-Inventar (Schritt 0)
01-lagebild/              eine Karte pro Subsystem
02-findings/              Rohberichte der Finder
findings.jsonl            DAS Befund-Register (Schema: register-schema.md)
03-vergleich/             externe Repos, Best Practices
04-verifikation/          Urteile pro Finding-ID
05-plan/                  Wellen, Abnahmekriterien, Testspezifikationen
06-umsetzung/             Protokoll pro Welle
```

## Regeln

- **Eine Quelle:** Jeder Befund lebt mit fester ID in `findings.jsonl`;
  Matrix, Roadmap und Fortschritt werden daraus abgeleitet.
- **Alte Audits werden übernommen, nicht neu entdeckt:**
  [Refactoring-Audit 06/2026](../../refactor/REFACTORING-AUDIT.md) und
  [Deep Dive 07/2026](../2026-07-agent-chats-deep-dive/README.md). Offene
  Punkte werden im Register mit `legacy_ref` nachgeprüft.
- **Regressions-Oracle bleibt gültig:** Die Feature-Inventare aus dem Juli
  (`../2026-07-agent-chats-deep-dive/06-umsetzung/feature-inventar-*.md`)
  beschreiben Invarianten auf Code-Ebene und werden vor jeder Welle
  nachgezogen. Das Inventar hier liegt eine Ebene darüber (Produktumfang).
- **Nur Analyse bis Schritt 5:** Bis zum Wellenplan wird kein Produktcode
  geändert.
