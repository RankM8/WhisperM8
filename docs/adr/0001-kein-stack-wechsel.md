# ADR 0001: Kein Stack-Wechsel — nativ Swift/SwiftUI/SwiftTerm bleibt

**Status:** Akzeptiert (10. Juni 2026)
**Kontext:** docs/archive/strategie/2026-06-10-technologie-analyse.md (Markt-Recherche + drei unabhängige Architektur-Gutachten mit adversarialer Faktenprüfung)

## Entscheidung

WhisperM8 bleibt auf dem nativen Stack: Swift 5.9+, SwiftUI (mit gezieltem
AppKit-Bridging wo nötig), SwiftTerm für PTY-Terminals, pures SwiftPM.
Eine Migration zu Electron oder Tauri findet nicht statt.

## Begründung (Kurzform)

1. **Die Electron-Konkurrenz belegt das Gegenteil einer Verbesserung:**
   Superset (Electron 40 + xterm.js + node-pty) hat ein offenes Issue, in dem
   Terminals ab 10 Workspaces auf einem M3 Max als „borderline unusable"
   beschrieben werden (~2 GB RAM); Wispr Flows Electron-Client idlet bei
   ~800 MB. Native Terminal-Apps liegen bei 14–100 MB.
2. **Der wertschöpfende Kern ist nativ:** AX-API, CGEvent, ScreenCaptureKit,
   CoreAudio, TCC-Handling und PTY-Management müssten bei jeder Migration
   ohnehin als nativer Helper neu gebaut werden.
3. **Migrationskosten ohne Gegenwert:** ~6–12 Personenmonate Rewrite, Verlust
   von ~360 Tests, und der Diktat-Markt hat entschieden — alle ernsthaften
   Mac-Diktat-Apps (Superwhisper, VoiceInk, MacWhisper, Handy) sind nativ.
4. **Die realen Performance-Probleme waren Implementierungsmuster** (Polling,
   synchrones Voll-Load/Voll-Save, Main-Thread-I/O) — behoben durch die
   Refactor-Pakete P1–P6 (siehe docs/archive/strategie/2026-06-10-refactor-plan.md),
   ohne Stack-Wechsel.

## Re-Evaluations-Trigger

Diese Entscheidung wird NUR neu bewertet, wenn einer der folgenden Punkte
eintritt:

1. **libghostty** erscheint als getaggtes, stabiles Release mit
   Embedding-API/Swift-Surface — dann als möglicher SwiftTerm-Ersatz
   evaluieren (Benchmark gegen das bestehende SwiftTerm-Metal-Opt-in,
   `agentTerminalMetalEnabled`).
2. **Windows-Nachfrage** in strategisch relevanter Größenordnung — dann
   Tauri/Rust-Core für eine Zweitplattform prüfen (nicht als Mac-Ersatz).
3. SwiftTerm wird unmaintained UND ein konkreter Blocker-Bug bleibt >6 Monate
   offen.

## Konsequenzen

- Performance-Claims werden gemessen statt behauptet: os_signpost-Budgets
  (`PerfBudgets`) auf den Hot-Paths, `perf_budget_exceeded`-Warnungen im
  log stream.
- UI-Performance-Probleme werden zuerst mit SwiftUI-Mitteln gelöst
  (Equatable-Rows, Per-Item-Publisher), AppKit-Bridging (NSOutlineView) bleibt
  dokumentierte Stufe 2.
