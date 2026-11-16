---
status: aktiv
updated: 2026-11-15
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

## Hänger mit Verursacher (WM8-101)

Seit 15.11.2026 nennt jede Hänger-Meldung, was in ihrem Zeitfenster lief:
`main_thread_freeze durationMs=1340 recent=chat.switch:1310,sidebar.modelBuild:62 open=-`.
`recent` sind gemessene Intervalle ab 50 ms, die auf dem Main Thread begannen und
sich mit dem Hänger überschneiden, längstes zuerst (höchstens fünf); `open` die bei
der Meldung noch offenen. `main_thread_blocked_ongoing` nennt mit `open=`, welches
Intervall WÄHREND einer laufenden Blockade offen ist. Buch führt
`MainThreadIntervalLedger`, gefüttert von `PerformanceBudget.begin/end`; es kostet
je Main-Thread-Intervall zwei kurze Lock-Abschnitte. Steht `recent=-`, lief eine
Stelle ohne Messpunkt. Ein Token, das nie beendet wird, schließt sich in seinem
`deinit` im Register.

Budgets mit `measuresWaiting: true` messen Wartezeit statt Arbeit und kommen nicht
ins Register: `sidebar.statusPollLatency`, `grid.build`, `grid.focusSwitch`,
`pill.morph`, `recording.start`, `recording.stop` (laufen über `await` hinweg, beim
ersten Start bis zum Mikrofon-Dialog) und `tickets.fetch` (Netzabruf). Sie sind die Folge eines Hängers, nicht die Ursache (Messlauf
15.11.2026: `statusPollLatency` stand bei 20 von 31 Hängern vorn).

Hänger in den ersten 15 s nach dem Aufwachen des Macs heißen
`main_thread_wake_stall` (Stufe info), damit sie in keiner Hänger-Zählung landen; der
Watchdog schweigt in dieser Zeit. Den Schlaf erkennen Monitor und Watchdog selbst
(`SleepGap`: `mach_continuous_time` läuft im Schlaf weiter, `mach_absolute_time`
nicht); die Aufwach-Meldung von `NSWorkspace` käme erst über den Main Thread, also
nach dem ersten Aufhol-Hänger. Am 14.11. waren das 18 von 21 Meldungen eines
Vormittags.

Neue Messpunkte, Kategorie `perf.chats`:

| Name | Budget | Stufe | misst |
| -- | -- | -- | -- |
| `chat.switch` | 100 ms | immer | Auswahl-, Raster- oder Workspace-Wechsel im `AgentWindowStore` bis nach dem nächsten Commit von Core Animation: Body, Layout und Zeichnen des Fensters samt Seitenleiste |
| `workspace.apply` | 50 ms | Detail | neuer Workspace-Stand in `AgentWorkspaceUIModel` bis nach dem nächsten Commit (Fensterbody ohne Auswahlwechsel) |
| `launch.firstWindow` | 500 ms | immer | Ende von `applicationDidFinishLaunching` bis nach dem ersten Commit des Agent-Chats-Fensters (verworfen nach 30 s) |
| `pane.attach` | 50 ms | Detail | Umhängen einer Terminal-Ansicht bis nach dem nächsten Commit |
| `terminal.resize` | 16 ms | Detail | `setFrameSize` einer Terminal-Ansicht samt Umbruch des Puffers |

„Nach dem nächsten Commit“ heißt: ein einmaliger `beforeWaiting`-Beobachter mit
höchster Ordnungszahl (`MainRunLoopCommit`). Ein `DispatchQueue.main.async` endete zu
früh, weil die Main-Queue vor dem Commit geleert wird.

Reißt `workspace.apply` sein Budget, folgt eine Zeile `workspace_apply_sources
durationMs=… sources=…` mit den Aufrufern, die den Chat-Bestand in diesem
Durchgang geändert haben (WM8-101). Jede ändernde Mutation trägt dazu ihren
Aufrufer ein: `AgentWorkspaceStore.mutate`/`mutateIfChanged` nehmen `#function`
mit, die Fassade `AgentSessionStore.mutateWorkspace` reicht den Namen ihrer
eigenen Methode durch (etwa `setTitle(_:for:)`). Mehrfache stehen als `×n`.
Nur mit der Detail-Stufe; sonst kostet ein Eintrag einen Bool-Vergleich.

```bash
/usr/bin/log show --last 1h --predicate 'subsystem == "com.whisperm8.app" AND process == "WhisperM8"' --info \
  | grep -E 'workspace_apply_sources'
```

Auswerten, welcher Verursacher wie viel Hängerzeit hat:

```bash
/usr/bin/log show --last 6h --predicate 'subsystem == "com.whisperm8.app" AND process == "WhisperM8"' --info \
  | grep -oE 'main_thread_freeze durationMs=[0-9]+ recent=[^ ,:]+' | awk '{print $3}' | sort | uniq -c | sort -rn
```

## Statistik-Protokollleser

Kategorie `perf.statistics`, Budget `statistics.scan` (1,5 s): ein
inkrementeller Lauf des `StatisticsLogScanner` — alle Claude- und
Codex-Protokolle auflisten und `stat`en, neue Bytes lesen, einmal in den
Store schreiben. Er läuft auf einer eigenen Queue (`.utility`), die Zahl ist
also Hintergrundzeit, keine Main-Thread-Zeit. Das erste Einlesen der Historie
(Backfill) wird nicht gemessen, es ist gewollt gedrosselt (`.background`,
Pause zwischen Dateien, wartet bei Diktat, Stromsparmodus und Hitze). Läufe,
die wegen eines Diktats gewartet haben, werden verworfen statt bewertet.

## Ticket-Ansicht

Kategorie des Stores, Stufe `.detail`, nur solange die Ticket-Ansicht sichtbar ist: `tickets.fetch` (3 s) ist
ein Abruf bei Linear, also Netz-Latenz und keine Main-Thread-Zeit; er läuft alle 120 Sekunden. `tickets.chats`
(4 ms) liest je neuem Abzug die Liste der Chats auf dem Main Thread, `tickets.build` (30 ms) gleicht Abzug und
Chats abseits des Main Threads ab. Alle drei sind Startwerte ohne Messung an Realdaten. Fehlt `tickets.fetch` im
Log, obwohl das Board offen ist, ist das Fenster verdeckt oder der Schalter aus.

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
