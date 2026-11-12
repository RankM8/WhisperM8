---
status: aktiv
updated: 2026-11-05
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

## Statistik-Protokollleser

Kategorie `perf.statistics`, Budget `statistics.scan` (1,5 s): ein
inkrementeller Lauf des `StatisticsLogScanner` — alle Claude- und
Codex-Protokolle auflisten und `stat`en, neue Bytes lesen, einmal in den
Store schreiben. Er läuft auf einer eigenen Queue (`.utility`), die Zahl ist
also Hintergrundzeit, keine Main-Thread-Zeit. Das erste Einlesen der Historie
(Backfill) wird nicht gemessen, es ist gewollt gedrosselt (`.background`,
Pause zwischen Dateien, wartet bei Diktat, Stromsparmodus und Hitze). Läufe,
die wegen eines Diktats gewartet haben, werden verworfen statt bewertet.

## Raster: Aufbau und Fokuswechsel

Kategorie `perf.grid`, Budgets `grid.build` (50 ms) und `grid.focusSwitch`
(33 ms), gemessen von `GridPerformanceTracker`. `grid.build` beginnt beim
Wechsel ins Raster und endet einen Runloop-Durchgang, nachdem alle Panes mit
lebendem Terminal eingehängt sind (Event `grid.build.allAttached`).
`grid.focusSwitch` reicht vom Selektionswechsel bis zum erfolgreichen
`makeFirstResponder` der neuen Pane.

**Befund 12.11.2026** (echte App, Log der letzten 24 h, nur Überschreitungen):
`grid.build` 117-mal über Budget, Median 318 ms, p90 629 ms; `grid.focusSwitch`
154-mal, Schnitt 93 ms. 71 der 117 langsamen Aufbauten hatten keine andere
Budget-Verletzung in der Nähe — die Zeit steckt im Aufbau selbst. Ein voll
aufgezeichneter Aufbau (232 ms) zeigte zwei komplette Durchläufe des
Fensterbodys samt Seitenleiste (`sidebar.bodyEval.chats` zweimal), je rund
70–80 ms Pane-Aufbau danach, und nur 33 ms nach dem Einhängen. Der zweite
Durchlauf kam vom Schreiben der gemessenen Raster-Größe in einen `@State` des
Fensters; sie liegt jetzt in `GridAreaSizeBox`, die nur der Stufenwähler
beobachtet (`GridCapacityPicker`). Offen ist der Pane-Aufbau selbst und dass
der Fensterbody bei jedem Fokuswechsel die Seitenleiste mitrechnet.

**Messlauf** (mit `make dev-release`, Detail-Stufe an:
`defaults write com.whisperm8.app agentPerfDetailEnabled -bool YES`, Neustart):
einen Workspace mit 4 und einen mit 9 laufenden Chats je zehnmal öffnen
(aus der Einzelansicht per „Zurück zum Workspace" und per Klick auf den
Workspace), dann im 9er-Raster zwanzigmal die Pane wechseln (⌃⌘-Pfeile).
Auswerten mit

```bash
/usr/bin/log show --signpost --last 15m --predicate 'subsystem == "com.whisperm8.app" AND category IN {"perf.grid","perf.sidebar"}' --style compact
```

Pro Aufbau zählen: Abstand `grid.build.requested` → `grid.build.allAttached`,
Zahl der `sidebar.bodyEval.chats` dazwischen (Ziel: eine), Zahl der
`grid.bodyEval.slot` (Ziel: eine je Pane) und die Abstände der
`grid.build.paneAttached`.
