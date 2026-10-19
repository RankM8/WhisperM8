---
status: aktiv
updated: 2026-10-19
description: Performance-Messung in WhisperM8 — Signposts, Budgets, Messstufen, Stall-Monitor und Watchdog, Messskripte.
---

# Performance-Messung

Wie WhisperM8 seine Hot-Paths misst und wo Befunde liegen (`docs/plans/workspace-performance/`).

## Betriebswissen aus CLAUDE.md

*Am 19.10.2026 wörtlich aus der Projekt-CLAUDE.md übernommen (LR-DOK-008); dort stehen nur noch die Arbeitsregeln. Beim nächsten Überarbeiten dieser Seite in den Fließtext einarbeiten.*

Drei Hot-Paths sind mit `os_signpost`-Intervallen + Budgets instrumentiert
(`Services/Shared/PerformanceSignposts.swift`): Kategorien `perf.recording`
(Hotkey→Aufnahme 400 ms, Stop→Transkription 300 ms, Kontext-Teilschritte),
`perf.store` (Mutation 30 ms, Load 15 ms, Save 20 ms) und `perf.sidebar`
(Workspace-Load 50 ms, Status-Poll 100 ms, plus `sidebar.statusChanged`-Events
= Re-Render-Trigger). Budget-Überschreitungen erscheinen als
`perf_budget_exceeded`-Warnungen im `log stream`-Befehl oben; in Instruments
über das os_signpost-Template auswertbar. Budgets sind Startwerte — bei
Anpassungen `PerfBudgets` ändern.

**Zwei Messstufen** (`PerfTier`, seit 01.08.2026): `.always` läuft immer und
sitzt nur an seltenen Ereignissen; `.detail` nur bei
`defaults write com.whisperm8.app agentPerfDetailEnabled -bool YES`. Grund ist
gemessen: ein os_signpost-Intervall kostet ~686 ns — auch ohne Instruments, denn
`OSSignposter.isEnabled` ist immer `true`. **Regel: nie pro Byte/Zeichen/Zeile
messen** — dort gehören Zähler hin (`PerformanceCounters`, ~1 ns, Ausgabe im
Sekundentakt). `MainThreadStallMonitor` misst zusätzlich, wie lange der Main
Thread am Stück nicht reagiert hat — unabhängig vom Verursacher, deshalb findet
er auch uninstrumentierte Stellen. Sein Timer läuft aber SELBST auf dem Main
Thread und kann eine Blockade darum erst melden, wenn sie vorbei ist; bei einer
endlosen schwieg er ganz (Vorfall 01.08.2026: App stand, im Log keine Zeile).
Deshalb stempelt er zusätzlich einen Herzschlag, den `StallWatchdog` auf einer
eigenen Queue beobachtet — der meldet `main_thread_blocked_ongoing`, WÄHREND
die App steht, gestaffelt bei Verdopplung der Dauer (1 s, 2 s, 4 s …), damit
das Log nicht überläuft. Messläufe: `scripts/perf-load.sh` (Last mit
definierter Rate, im Chat-Terminal starten) und `scripts/perf-report.sh`
(Log → Tabelle). Befunde: `docs/plans/workspace-performance/`.
