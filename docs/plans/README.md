---
status: aktiv
stand: 2026-07-12
---

# Offene Pläne

Vorhaben, die beschlossen oder in Beratung, aber **noch nicht (vollständig) umgesetzt** sind. Klare Trennung: `features/` dokumentiert den Ist-Zustand, hier liegt die Zukunft. Umgesetzte Pläne wandern nach `../archive/`.

| Plan | Status | Inhalt |
|---|---|---|
| [`whisperm8-chats-cli/`](whisperm8-chats-cli/) | **Umgesetzt** (2026-07-19), Feature-Doku: [`../features/agent-chats-cli.md`](../features/agent-chats-cli.md) | Jarvis als CLI + Skill: Namespace `whisperm8 chats` (13 Befehle inkl. interrupt), Control-Socket in der App, Supervisor-Skill. Slices 1–4 gebaut + getestet (1582 Tests grün); Live-Test send/wait/interrupt nach App-Neustart durch User |
| [`jarvis-supervisor/`](jarvis-supervisor/) | **Abgelöst** durch `whisperm8-chats-cli/` (2026-07-19) | Supervisor-Board über allen Agent-Sessions: Tier-1/2-Reports, Board-first UX, Vertical Slices; HTML-Doku mit UX-Mockups — bleibt als Konzept-Referenz (Attention-Modell, Digest-Routing) |
| [`kompakt-chat-fenster.md`](kompakt-chat-fenster.md) | **Verworfen** (2026-07-12, Missverständnis; Code revertiert) | „Make window small": Kompakt-Zustand mit Projekt-Chat-Übersicht — gewollt war nur die Grid-View |
| [`split-grid-agenten.md`](split-grid-agenten.md) | **V2.1 umgesetzt** (2026-07-13); V3 (Projekt/Running-Automatik) offen | Split-Grid mit Maximize/Minimize + Grid-Mitgliedschaft (⊖/Kontextmenü/Drag wählt die Chats, Auto-Layout aus Mitglieder-Zahl, bündige Panes); Konzept: [`grid-maximize-minimize-konzept.html`](grid-maximize-minimize-konzept.html) |
| [`fenster-modi-plan.html`](fenster-modi-plan.html) | HTML-Plan-Seite (2026-07-12) | Visuelle Ein-Seiten-Doku beider Fenster-Modi mit UI-Mockups, Architektur-Fluss, Datenmodell, Umsetzungs-Reihenfolge und Entscheidungs-Stand |
| [`sidebar-feinschliff.md`](sidebar-feinschliff.md) | Freigegeben, zurückgestellt (2026-06-24) | Feinschliff-Paket für die Agent-Chats-Sidebar |
| [`lokale-stt-spike.md`](lokale-stt-spike.md) | Spike mit GO (2026-06-10), nicht umgesetzt | Lokale Speech-to-Text via FluidAudio als Alternative zu Cloud-STT |
