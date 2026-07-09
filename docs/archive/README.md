---
status: archiv
stand: 2026-07-09
---

# Archiv

Historische Dokumentation — **Quellenlager, kein Endlager**: Aktuelle Feature-Docs verlinken bei Bedarf hierher (z. B. Whisper-Wortlisten-Recherche aus `features/dictation/transcription/`). Nichts hier beschreibt den aktuellen Zustand der App; nichts wurde gelöscht, alles per `git mv` verschoben (Historie erhalten).

| Ordner | Inhalt | Warum archiviert |
|---|---|---|
| `2026-02-planung/` | Projekt-Übersicht, Technologie-Beratung, Komponenten-Architektur, Implementierungsplan, Polishing-TODO (alle 2026-02) | Beschreiben die App *vor* der Implementierung; Scope („Was wir NICHT bauen") längst überholt |
| `recherche/` | 24 Recherche-Prompts + -Ergebnisse (Hotkeys, Audio, Whisper-API, Overlay, Distribution, STT-Modelle …) | Grundlagenrecherche Feb 2026, abgeschlossen; Preise/Modelle teils überholt |
| `strategie/` | Technologie-Analyse + Refactor-Masterplan (2026-06-10) | Entscheidungen in ADR 0001 bzw. `refactor/REFACTORING-AUDIT.md` überführt |
| `plaene/` | Claude-Resume/Terminal-Persistenz-Plan (Mai), Codex-Subagents-Plan (HTML, Juli) | Umgesetzt — Feature-Doku ersetzt die Pläne |
| `settings-legacy/` | Alte 15-Seiten-Settings-Doku + Redesign-Beratung + Umsetzungsplan | Ersetzt durch die 10-Seiten-Struktur (`features/settings/`, 2026-07-06); referenzieren tote Code-Pfade |
| `claude-code-integration/` | WhisperM8-Integrationsstand (Mai), Beratungs-Optionen, Integrationsplan-HTML | Stand Mai 2026 — flache `Services/`-Struktur, viele heutige Services fehlen; ersetzt durch `features/agent-chats/` |
| `agent-chats-redesign/` | Redesign-Plan-Index + Chat-Persistenz-Plan (2026-06-24) | Umgesetzt (Phasen ✅); offener Rest lebt in `plans/sidebar-feinschliff.md` |
| `design/` | 4 Agent-Chats-Redesign-Prototypen (HTML, Juni-Generation) | Vom umgesetzten Redesign überholt; aktive Prototypen liegen in `docs/design/` |
| `design-prompts/` | Claude-Design-Prompt für die Agent-Chat-UX + Referenz-Screenshot (2026-05-12, ehem. Top-Level `Dokumentation/`) | Einmaliges Prompt-Material, UX längst umgesetzt |
| `analyse/` | Zwei Iterationen der Refactoring-Analyse vom 2026-05-11 (ehem. Top-Level `analysis/` + `analysis-refactoring/`) | Vorgänger des Juni-Audits `docs/refactor/REFACTORING-AUDIT.md` |
