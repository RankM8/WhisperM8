# Plan: Sidebar-Feinschliff (Ausrichtung, grauer Button, Status-Indikatoren, Ton)

Stand: 2026-06-24 · Status: **vom User freigegeben, aber zurückgestellt** hinter dem
Datenverlust-Fix ([01-chat-persistenz-datenverlust.md](../archive/agent-chats-redesign/01-chat-persistenz-datenverlust.md)).

> Hinweis: Teil C/D (Status-Hooks + Ton) berühren denselben Hook-/Session-Bereich wie der
> Datenverlust-Fix. Reihenfolge daher: **erst 01 (Persistenz) stabilisieren**, dann dieser Plan.
> Die rein visuellen Teile A/B sind unabhängig und können jederzeit vorgezogen werden.

## Context

Das Linear-Sidebar-Redesign steht (Indigo-Akzent, animierte Indikatoren, „zuletzt aktiv"-Zeiten,
einzeiliger Header, dichtere Sektionen). Im Praxistest bleiben Probleme:

- **A — Ausrichtung:** Kopfbereich (Neuer Chat, Filter, Scope) ist nicht mit den Chat-Zeilen
  bündig (Einzüge 6/8/16/18px) → wirkt „reingeworfen". Filter soll volle Breite.
- **B — „Neuer Chat" zu auffällig:** lila Indigo-Gradient lenkt ab → grau. Indigo nur für Auswahl.
- **C — Status-Indikatoren stimmen nicht:** working/idle/„braucht Handlung" werden verwechselt
  (8-Sekunden-Heuristik in `AgentSessionTranscript.swift:198` hält langes Arbeiten für Warten).
- **D — Optionaler Ton**, wenn Claude fertig ist (am `Stop`-Hook).

## Teil A — Einheitliche horizontale Ausrichtung (8px)
Alle interaktiven Hintergrund-Kanten auf **8px**. Labels/Caption 14px (Hierarchie).
- `AgentChatsView.swift`: `hashboardSidebar` (~Z. 675) `sidebarCommandRows.padding(.horizontal, 8)`
  **entfernen**; `sidebarCommandRows` (~Z. 1020) Button-Reihe `10→8`, Filter
  `.frame(maxWidth: .infinity)` + äußeres `10→8`; `sidebarScopeBar` (~Z. 1204) `18→8`;
  `sidebarSectionLabel` (~Z. 822) `16→14`.
- `AgentChatsSidebarViews.swift`: Zeilen-Hintergründe `6→8` in `SessionListButton`,
  `PinnedSessionRow`, `ProjectChatGroup`-`groupHeader`.

## Teil B — „Neuer Chat"-Button in Grau
`AgentChatsView.swift`, `sidebarCommandRows`: `LinearGradient(accent→accentStrong)` + weiß →
`AgentTheme.control`-Füllung + `AgentTheme.textPrimary`. Dezent über den Icon-Buttons
(`AgentTheme.hover`) erhaben. `disabled` via reduzierter Deckkraft. `accentStrong` ggf. ungenutzt.

## Teil C — Korrekte Status-Erkennung (Hooks statt Zeitheuristik)
**Reichweite (entschieden): nur WhisperM8-gestartete Sessions** (Hooks reiten per
`claude --settings <pro-Session.json>` mit; `~/.claude` bleibt unberührt). Extern gestartete
Terminal-Sessions zeigen über das Transkript nur working/idle (kein „braucht Handlung") — bewusst
akzeptiert.
- **C1** `AgentSessionTranscript.swift` (~Z. 198): `.assistantMessageOngoing` → **immer
  `.working`** (8-s-Eskalation streichen); `awaitingInputAfterSeconds` entfernen; `idleAfterSeconds`
  bleibt.
- **C2** `ClaudeHookSettingsBuilder.swift`: zusätzlich **`UserPromptSubmit`, `PostToolUse`, `Stop`**
  registrieren (gleiches Append-Muster).
- **C3** `ClaudeHookEventStore.swift`: `EventName` um `userPromptSubmit`, `postToolUse`, `stop`
  erweitern (PreToolUse-Throttling ausdehnen).
- **C4** `AgentChatsView.swift` `handleClaudeHookEvent`: `Notification` → awaiting-Set insert;
  `UserPromptSubmit`/`PreToolUse`/`PostToolUse` → awaiting-Set remove; `Stop` → remove +
  `runtimeStatusStore.setStatus(.idle)`; `SessionEnd` → wie bisher.
- **C5** Tests: `...EscalatesOngoingToAwaitingInputAfterTimeout` erwartet jetzt `.working`; neuer
  Hook→Status-Mapping-Test.

## Teil D — Optionaler Ton, wenn Claude fertig ist
Am `Stop`-Hook (Teil C4): `NSSound(named: "Glass")?.play()`. Flag `AppPreferences.agentStopSoundEnabled`
(Default an, Toggle in `SettingsView`). Drossel: kein zweiter Ton < ~2 s. Optional: nur wenn Fenster
nicht im Vordergrund. Mögliche Erweiterung später: Ton auch bei `Notification`.

## Verifikation
- A/B: linke/rechte Kanten von „Neuer Chat", Filter, Zeilen bündig; Filter volle Breite; Button
  grau; Auswahl-Pille so breit wie der Button. Abgleich gegen
  `docs/design/agent-chats-linear-redesign.html`. Dark + Light.
- C: working bleibt working bei langem Tool; Permission → amber; Turn fertig → idle.
- D: Toggle an → Ton bei Turn-Ende; aus → kein Ton.
- `swift build` + `swift test` (424+) grün.

## Stand der Umsetzung
- Bereits umgesetzt (vor diesem Feinschliff): Indigo-Tokens, `AgentStatusIndicator` (animiert),
  ago-Zeiten, einzeiliger Header, Sektions-Spacing 8→2.
- **Offen:** A, B, C, D (dieser Plan) — nach dem Datenverlust-Fix.
