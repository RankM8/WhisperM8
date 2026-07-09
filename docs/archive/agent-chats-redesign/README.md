# Agent-Chats Redesign & Robustheit

Sammelordner für die laufende Überarbeitung der Agent-Chats (Sidebar-Redesign + Persistenz-
Robustheit). Stand: 2026-06-24.

## Pläne (nach Priorität)

| # | Dokument | Thema | Status |
|---|----------|-------|--------|
| 1 | [01-chat-persistenz-datenverlust.md](01-chat-persistenz-datenverlust.md) | **Datenverlust beheben** — frisch erstellte Chats verschwinden / sind nicht resumebar | Phase 0–2 + 4 umgesetzt |
| 3 | [03-claude-code-cli-session-verhalten.md](03-claude-code-cli-session-verhalten.md) | **Claude-Code-CLI-Session-Verhalten** — Persistenz/Resume autoritativ + Superset-Vergleich + „nie --resume ohne Transkript"-Fix | Referenz + Fix |
| 2 | [02-sidebar-feinschliff.md](02-sidebar-feinschliff.md) | Sidebar-Ausrichtung, grauer „Neuer Chat"-Button, korrekte Status-Indikatoren (Hooks), optionaler Ton | Freigegeben, **zurückgestellt** |

## Reihenfolge & Begründung

**Zuerst #1 (Datenverlust).** Ein verschwindender Chat ist gravierender als jede Kosmetik.
Außerdem berühren die Status-Hooks aus #2 (Teil C/D) denselben Hook-/Session-Bereich — eine
stabile Persistenz-Basis zuerst vermeidet, dass wir auf wackeligem Fundament weiterbauen.

Die rein **visuellen** Teile von #2 (A: Ausrichtung, B: grauer Button) sind unabhängig und
könnten bei Bedarf vorgezogen werden.

## Verwandte Doku (bereits vorhanden)

- [`../ROBUST_CLAUDE_RESUME_TERMINAL_PERSISTENCE_PLAN.md`](../ROBUST_CLAUDE_RESUME_TERMINAL_PERSISTENCE_PLAN.md)
  — Terminal-Snapshot, `/resume`-ID-Rebinding, Recovery-UI. **Komplementär** zu #1
  (dort: Anzeige/Resume-Identität; hier: zuverlässige Persistenz der Session-Einträge selbst).
- [`../design/agent-chats-linear-redesign.html`](../design/agent-chats-linear-redesign.html)
  — interaktiver HTML-Zielentwurf der Sidebar (Referenz für #2).

## Kernbefund (Datenverlust)

Verifiziert: Pruning (`removeUnresumableClaudeSessions`) löscht **keine** manuellen Chats — die
sind durch `createdManually=true` + gesetzte `externalSessionID` doppelt geschützt. Die echte
Ursache ist mit hoher Wahrscheinlichkeit die **0,5-s-Debounce-Persistenz** ohne synchrones
Schreiben bei nicht-graceful Beendigung (Crash/Force-Quit/`make kill`/Shutdown). Details +
evidenzbasierter Fix-Plan in #1.
