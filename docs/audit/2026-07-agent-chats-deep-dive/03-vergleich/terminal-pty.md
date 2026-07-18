# Vergleich: Terminal-Emulation & PTY-Handling in Open-Source-Projekten

> Audit-Teil 03-Vergleich · Stand 2026-07-18 · Research-Agent
>
> Fokus: Wie hosten vergleichbare Tools PTYs (SwiftTerm vs. xterm.js-in-WebView vs.
> eigene Renderer), wie lösen sie Scroll-Jank bei Streaming und Selektionsverlust,
> welche Scrollback- und Teardown-Strategien fahren sie — und was davon ist auf
> WhisperM8 übertragbar.

WhisperM8-Ausgangslage: `QuietableTerminalView: LocalProcessTerminalView`
([AgentTerminalView.swift](../../../../WhisperM8/Views/AgentTerminalView.swift)) auf einem
**eigenen SwiftTerm-Fork**, seit Kurzem rebased auf **v1.14.0** (Branch
`whisperm8-v1.14-patches`, Pin `27f06d7e` in `Package.swift`). Von den ursprünglich vier
Fork-Patches verbleiben nur noch die zwei Selection-Patches (`feedPrepare` +
`linefeed` löschen die Selektion nicht mehr bei Streaming); Scroll-Lock (#587),
Shift-Force-Selection (#536), PTY-Backpressure (#574) und Metal-Fixes kamen mit
v1.14.0 upstream an.

---

## 1) Projektübersicht

| Projekt | Link | Sprache / Stack | Terminal-Engine | Aktivität (Stand 2026-07) |
|---|---|---|---|---|
| **SwiftTerm** | [github.com/migueldeicaza/SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | Swift (AppKit/UIKit) | Eigene VT100/xterm-Engine, CoreText-Renderer + optionaler Metal-Renderer | **Sehr aktiv**: v1.14.0 am 2026-07-10 mit ~40 PRs, 12 neuen Contributors |
| **xterm.js** | [github.com/xtermjs/xterm.js](https://github.com/xtermjs/xterm.js) | TypeScript (Browser) | Referenz-Engine des Web-Ökosystems (VS Code), DOM/Canvas/WebGL-Renderer | Sehr aktiv (v6), De-facto-Standard |
| **Superset** | [github.com/superset-sh/superset](https://github.com/superset-sh/superset) / [superset.sh](https://superset.sh) | Electron + React + TypeScript | xterm.js v6 + node-pty | Sehr aktiv; #1 Product Hunt Feb 2026; ELv2-Lizenz |
| **Crystal** (→ Nimbalyst) | [github.com/stravu/crystal](https://github.com/stravu/crystal) | Electron + React + TypeScript | @xterm/xterm + @homebridge/node-pty-prebuilt-multiarch | ⚠️ **Deprecated seit Feb 2026** — Nachfolger Nimbalyst (closed source). Code als Referenz weiter lesbar |
| **VibeTunnel** | [github.com/amantus-ai/vibetunnel](https://github.com/amantus-ai/vibetunnel) | Node/TS-Server + Swift-macOS-App; Client: LitElement | Server: headless Terminal-State-Tracking (vendored node-pty); Client: `ghostty-web` (WASM) statt xterm.js | Aktiv (Steipete/amantus) |
| **Conductor** | [conductor.build](https://www.conductor.build/) / [docs](https://docs.conductor.build/) | Tauri, Claude **Code SDK** (TypeScript-Wrapper, nicht CLI-PTY) | Kein PTY-first-UI; integriertes Terminal als Nebenfläche | Aktiv, **closed source** ($22M Series A) — nur Doku/Berichte auswertbar |
| **opcode** (ex-Claudia) | [github.com/winfunc/opcode](https://github.com/winfunc/opcode) / [opcode.sh](https://opcode.sh) | Tauri 2 + Rust + React | **Kein Terminal-Emulator**: rendert `claude` `stream-json`-Output als Chat-UI | Aktiv; Rename getAsterisk/claudia → opcode |
| **Ghostty / libghostty** | [github.com/ghostty-org/ghostty](https://github.com/ghostty-org/ghostty) · [ghostling](https://github.com/ghostty-org/ghostling) | Zig, macOS-UI in Swift | Eigene Engine, Metal-Renderer, SIMD-Parser; `libghostty` = embeddable C-API ([Ankündigung](https://mitchellh.com/writing/libghostty-is-coming)) | Sehr aktiv (1.3.0); libghostty in Extraktion, `ghostling` als MVP-Beispiel |
| **iTerm2** | [gitlab.com/gnachman/iterm2](https://gitlab.com/gnachman/iterm2) | Objective-C/Swift | Eigene Engine, [Metal-Renderer](https://gitlab.com/gnachman/iterm2/-/wikis/Metal-Renderer) | Sehr aktiv, Referenz für macOS-Terminal-UX |

Tote/nicht auswertbare Kandidaten: **Crystal** ist offiziell deprecated (Repo bleibt, keine Updates);
**Conductor** und **Nimbalyst** sind closed source — Architektur nur aus Doku/Blogposts ableitbar;
**libghostty** ist angekündigt, aber noch keine stabile Embedding-Option für Dritt-Apps.

### Drei Architektur-Familien

1. **Native Embedded-Engine** (WhisperM8 + SwiftTerm): Terminal-Emulation im App-Prozess, PTY via `forkpty`. Kein IPC, geringste Latenz, aber an die Reife der Engine gebunden.
2. **Electron + xterm.js + node-pty** (Superset, Crystal, VS Code): PTY im Main-Prozess, Bytes per IPC zum Renderer, xterm.js emuliert + rendert (WebGL). Reifste Engine, dafür IPC-Batching nötig (Supersets DataBatcher, 16 ms) und Electron-Footprint.
3. **Headless-Server + Remote-Renderer** (VibeTunnel): PTY-Prozesse überleben unabhängig vom UI; Server hält den Terminal-State, Clients (Browser/App) rendern Snapshots + Deltas. Maximale Entkopplung (Sessions überleben UI-Crash), dafür eigenes Sync-Protokoll.

opcode zeigt eine vierte Option: **gar kein Terminal** — `claude -p --output-format stream-json` parsen und als natives Chat-UI rendern. Für WhisperM8 nur als ergänzender Read-Modus interessant (existiert de facto schon als Transcript-View), nicht als Ersatz der interaktiven TUI.

---

## 2) Wie lösen die Projekte die Kernprobleme?

### 2.1 Scroll-Jank bei Streaming (Scroll-Lock)

**xterm.js** (Referenzsemantik): `BufferService` setzt `isUserScrolling = true` bei **jedem**
`scrollLines(disp < 0)` — also auch Trackpad/Wheel, nicht nur Scrollbar-Drag. Output rückt
`yDisp` dann nicht nach. Komplementär: [`scrollOnUserInput`](https://github.com/xtermjs/xterm.js/pull/4289)
(Default `true`) scrollt bei Tastatureingabe ans Ende — die zweite Hälfte der Semantik,
die „blindes Tippen im Scrollback" verhindert. Superset und Crystal erben das schlicht
über xterm.js-Defaults und müssen nichts selbst bauen.

**SwiftTerm**: Exakt WhisperM8s Bug 1 wurde upstream als
[Issue #559](https://github.com/migueldeicaza/SwiftTerm/issues/559) gemeldet
(„Viewport snaps back to bottom on new output — `userScrolling` is never set to true",
geschlossen 2026-07-10) und mit [PR #587](https://github.com/migueldeicaza/SwiftTerm/pull/587)
gefixt: `yDisp` ist jetzt Source of Truth für den Viewport, `scrollTo(row:)` setzt
`terminal.userScrolling`, Manual-Scrolling wird beim Erreichen des Endes, bei
Buffer-Switches (Alt-Screen) und bei Keyboard-Input (`ensureCaretIsVisible()`)
zurückgesetzt. Damit deckt Upstream auch die „scroll to bottom on user input"-Hälfte ab,
die als WhisperM8-Fork-Patch 6 geplant war — **allerdings ist der PR primär am
iOS-Pfad beschrieben; für den macOS-`scrollWheel`-Pfad gehört das nach dem
v1.14-Rebase empirisch verifiziert.**

**VibeTunnel** umgeht das Problem architektonisch: Der Client-Emulator (`ghostty-web`,
WASM) rendert aus Buffer-Snapshots/Deltas; Scroll-Position ist reiner Client-State und
wird von Server-Output nie angefasst.

### 2.2 Selektionsverlust bei Streaming

**xterm.js**: Selektion lebt im `SelectionModel` mit **absoluten Buffer-Koordinaten** —
`write()` löscht sie prinzipiell nie; neue Zeilen verschieben nur den Anker mit. Zusätzlich
`shouldForceSelection` (SelectionService): Shift-Klick (bzw. Option via
`macOptionClickForcesSelection`) erzwingt native Selektion, auch wenn die App
(Claude Code im Alt-Screen mit Mouse-Tracking 1003) Maus-Events beansprucht.

**SwiftTerm**: Zwei relevante Upstream-Schritte:
- v1.11.2: „Make it so that selection is not reset when newlines are added to the screen" ([Releases](https://github.com/migueldeicaza/SwiftTerm/releases)) — Upstream hat das Problem also erkannt, WhisperM8s Fork-Analyse zeigte aber, dass **zwei** Output-Pfade patchen sind (`linefeed(source:)` als Haupttäter **und** `feedPrepare()`); genau diese zwei Patches trägt der Fork weiterhin.
- v1.14.0 / [PR #536](https://github.com/migueldeicaza/SwiftTerm/pull/536): „Shift+mouse support to temporarily bypass application mouse reporting" — das ist WhisperM8s früherer Fork-Patch 3 (Shift-Force-Selection à la Superset/xterm.js), jetzt upstream. Dazu öffnete [PR #535](https://github.com/migueldeicaza/SwiftTerm/pull/535) die macOS-Mouse-Overrides für Subklassen — künftige Eingriffe gehen ohne Fork.

**Superset/Crystal**: kein eigener Code nötig — xterm.js-Verhalten out of the box.
Genau dieser Unterschied (Selektions-/Scroll-State entkoppelt vom Output-Pfad vs.
gekoppelt an `feed()`/`scroll()`) war die Root-Cause-Erkenntnis des früheren
WhisperM8-Deep-Dives; SwiftTerm holt die Entkopplung seit v1.11.2/v1.14.0 schrittweise nach.

### 2.3 Rendering-Strategie (Jank-Ursache Nr. 2)

- **xterm.js**: WebGL-Renderer (GPU), Renderer entkoppelt vom Parser. Supersets `DataBatcher` (16 ms) löst ein reines Electron-IPC-Problem (Main↔Renderer), kein Engine-Problem.
- **Ghostty**: pro Terminal eigene Read-/Write-/Render-Threads, SIMD-Parser, Metal-Renderer mit Ligaturen ([Repo](https://github.com/ghostty-org/ghostty)). Renderer arbeitet gegen eine minimale „render state"-API — dieselbe, die libghostty exportieren wird.
- **iTerm2**: [Metal-Renderer](https://gitlab.com/gnachman/iterm2/-/wikis/Metal-Renderer) seit 3.2, Cursor wird render-synchron im GPU-Frame gezeichnet (kein separater blinkender NSView → kein Caret-Flackern).
- **SwiftTerm**: CoreText-CPU-Renderer als Default; ein **optionaler Metal-Renderer** existiert seit [PR #479](https://github.com/migueldeicaza/SwiftTerm/pull/479), v1.14.0 fixte dort „stale cursors, window reparenting, color space, margins, restricted-region scroll artifacts" (#546–#548, #541, #582) und reduzierte den Synchronized-Output-Debounce auf 16 ms, jetzt public ([#526](https://github.com/migueldeicaza/SwiftTerm/pull/526)). **Aber:** offene Issues [#596](https://github.com/migueldeicaza/SwiftTerm/issues/596)/[#597](https://github.com/migueldeicaza/SwiftTerm/issues/597) zeigen CJK-Artefakte im Metal-Pfad (Juli 2026) — noch nicht produktionsreif für alle Inhalte.
- **WhisperM8s Caret-Flackern** (Patch-Kandidaten 4/5: `showCursor` ohne Offscreen-Guard, NSView-Caret mit CABasicAnimation) ist strukturell dieselbe Klasse Problem, die iTerm2/Ghostty durch render-synchrone Cursor lösen; SwiftTerms „stale cursor"-Fixes in v1.14 betreffen den Metal-Pfad, der CoreText-Caret-NSView-Tanz bleibt.

### 2.4 Scrollback-Puffer-Strategien

| Projekt | Strategie |
|---|---|
| **xterm.js** | `CircularList` über Typed-Array-`BufferLine`s (kompakte ArrayBuffers statt JS-Objekte, [Issue #791](https://github.com/xtermjs/xterm.js/issues/791)); festes `scrollback`-Limit (Default 1000), älteste Zeilen werden überschrieben; Reflow bei Resize über das Mapping CircularList↔gewrappte Zeilen ([PR #1864](https://github.com/xtermjs/xterm.js/pull/1864)). Memory-Kalkül dokumentiert: 160×24 mit 5000 Zeilen Scrollback ≈ 34 MB |
| **iTerm2** | Konfigurierbares Limit oder unlimited; **Scrollback-Kompression bei Idle** („compressed when the app is idle … can significantly reduce memory usage", [Doku](https://iterm2.com/documentation-preferences-profiles-terminal.html)) |
| **Ghostty** | Paged-Memory-Scrollback mit festem Byte-Budget (`scrollback-limit`); Scrollback-**Suche** läuft auf eigenem Thread, der den Terminal-Lock nur in kleinen Zeitscheiben nimmt ([1.3.0 Release Notes](https://ghostty.org/docs/install/release-notes/1-3-0)) — Suche jankt weder I/O noch Rendering |
| **VibeTunnel** | Zweigleisig: Der Server hält den **Live-State** (TerminalManager) und schreibt parallel eine **asciinema-Aufzeichnung** (`asciinema-writer.ts`) als vollständige History auf Platte; Clients bekommen Snapshot + Deltas über das Binärprotokoll (`BufferAggregator`, 50-ms-Fenster, Magic `VTW3`) |
| **Crystal** | Session-Output zusätzlich in **SQLite** persistiert — Scrollback der UI ist Replay aus der DB, nicht nur der Emulator-Puffer |
| **SwiftTerm / WhisperM8** | `TerminalOptions.scrollback` Default **500 Zeilen** (WhisperM8 setzt nichts Eigenes → 500); v1.14 exponiert `totalLinesTrimmed` ([#569](https://github.com/migueldeicaza/SwiftTerm/pull/569)) und `searchMatchSummary` ([#572](https://github.com/migueldeicaza/SwiftTerm/pull/572)). WhisperM8 kompensiert mit dem **Terminal-Snapshot** (Plaintext des Normal-Buffers bei Teardown, `TerminalSnapshotStore`) und der Transcript-View aus JSONL als „unendlichem" History-Ersatz |

Gemeinsames Muster der Großen: hartes Limit im Emulator + **separater, billigerer
Persistenz-Kanal für Vollhistorie** (asciinema-Datei, SQLite, JSONL). WhisperM8 folgt
diesem Muster bereits (JSONL-Transcripts + Snapshot), nur das Emulator-Limit (500) ist
knapp bemessen für „hochscrollen während Claude streamt".

### 2.5 Prozess-Teardown

- **VibeTunnel** (`pty-manager.ts`, [Repo](https://github.com/amantus-ai/vibetunnel)): explizite **SIGTERM→SIGKILL-Eskalation** (`killSessionWithEscalation`) mit Grace-Period; tmux-Sessions werden erst graceful detached; bewusst **kein** Kill der ganzen Prozessgruppe („to avoid affecting other sessions"); Liveness-Check vor Nach-Kill per PID.
- **Superset/Crystal** (node-pty): `pty.kill()` schließt den PTY-Master → Kernel schickt SIGHUP an die Foreground-Prozessgruppe; Crystal supervised die CLI-Prozesse zentral im Main-Prozess (Bull-Task-Queue), Session-State in SQLite überlebt App-Restart.
- **SwiftTerm v1.14** fixt zwei **Retain-Cycles, die `Terminal`/`LocalProcess`-Instanzen leakten** ([#538](https://github.com/migueldeicaza/SwiftTerm/pull/538), [#551](https://github.com/migueldeicaza/SwiftTerm/pull/551)) — für WhisperM8 mit viel Tab-/Session-Churn direkt relevant (vor dem Rebase leakte potenziell jeder geschlossene Chat ein Terminal-Objekt).
- **WhisperM8** ([AgentTerminalView.swift](../../../../WhisperM8/Views/AgentTerminalView.swift), `terminate()` / `captureAllSnapshotsForAppQuit()`): TUI-bewusster Teardown — 2× Ctrl+C (0x03) mit 80/180 ms Wartezeit, damit Claude/Codex ihre Exit-Routine (Resume-Hinweis, JSONL-Flush) fahren, dann `flushPendingOutput()` → Snapshot → `terminal.terminate()`; beim App-Quit eine **gemeinsame** Wartezeit für alle Chats (~260 ms konstant). Das ist differenzierter als alles, was die Vergleichsprojekte für TUI-Kinder tun — aber es fehlt die Eskalationsstufe: hängt die TUI nach 2× Ctrl+C, folgt direkt der harte PTY-Teardown ohne SIGTERM-Zwischenschritt und ohne Verifikation, dass das Kind wirklich weg ist (Zombie-/Orphan-Fenster).

---

## 3) Direkter Vergleich zu WhisperM8s Ansatz

### Was WhisperM8 besser macht

- **Root-Cause-Tiefe statt Workarounds**: Die Fork-Patches setzen an denselben Stellen an, die Upstream später selbst fixte (Scroll-Lock #587, Shift-Selection #536 — beide waren zuerst WhisperM8-Patches bzw. deckungsgleich mit ihnen). Der Fork-Ansatz mit Commit-Pin + Rebase auf v1.14 ist sauber dokumentiert und upstream-PR-fähig.
- **TUI-bewusster Teardown**: 2× Ctrl+C + Flush + Snapshot vor dem Kill respektiert die Exit-Routinen von Claude/Codex (Resume-Hinweis, JSONL-Flush). Superset/Crystal killen den PTY generisch; VibeTunnel eskaliert generisch. Kein Vergleichsprojekt sichert den sichtbaren Terminal-Endstand als Snapshot.
- **Kein IPC-Tax**: Als Single-Prozess-App entfällt Electrons Main↔Renderer-Batching-Problem komplett; SwiftTerms `queuePendingDisplay` throttled Renders bereits auf 60 fps (frühere Annahme „fehlendes Batching" war widerlegt).
- **Doppelte History-Quelle**: JSONL-Transcript-Reader (streamed, >50 MB-fähig) + Terminal-Snapshot sind zusammen mächtiger als Crystals SQLite-Replay — Vollhistorie plus echter Terminal-Look des Endstands.
- **Event-getriebene Runtime-Statusarchitektur** (vnode/FSEvents/Hooks statt Polling) hat in keinem der Vergleichsprojekte ein Äquivalent dieser Tiefe; Crystal/Superset pollen bzw. verlassen sich auf Prozess-Exit-Events.

### Was andere besser machen

- **Engine-Reife**: xterm.js hatte Scroll-Lock-, Selektions- und Force-Selection-Semantik seit Jahren; SwiftTerm zieht erst seit v1.11–v1.14 nach, und WhisperM8 musste die Lücken selbst diagnostizieren und patchen. Superset/Crystal bekamen dieselbe UX gratis.
- **GPU-Rendering**: xterm.js (WebGL), Ghostty/iTerm2 (Metal, render-synchroner Cursor) flackern nicht; WhisperM8s CoreText-Pfad mit NSView-Caret + CABasicAnimation bleibt die strukturelle Ursache des Caret-Flackerns (Fork-Patch 4/5 weiter offen).
- **Scrollback-Ökonomie**: 500 Zeilen Default sind wenig; Ghostty (Byte-Budget), iTerm2 (Idle-Kompression) und xterm.js (Typed-Array-Puffer, dokumentiertes Memory-Kalkül) budgetieren bewusster. WhisperM8 hat dafür bisher kein explizites Konzept — es nutzt schlicht den Default.
- **Teardown-Eskalation & Liveness**: VibeTunnels SIGTERM→SIGKILL mit Verifikation ist robuster gegen hängende Kinder als „Ctrl+C zweimal und dann hart".
- **UI-unabhängige Session-Prozesse**: Bei VibeTunnel (Server-Prozess) und Crystal (Main-Prozess + SQLite) überleben laufende Agenten einen UI-Crash. Bei WhisperM8 sterben Foreground-PTY-Chats mit der App (App-Quit-Snapshot mildert das nur); die Ausnahme sind die `claude --bg`-Background-Agents, die dem VibeTunnel-Muster (Supervisor-Daemon + Attach) bereits entsprechen.

---

## 4) Übertragbare Muster — priorisierte Empfehlungen

**P1 — v1.14-Verhalten empirisch abnehmen und die 2 Rest-Patches upstreamen.**
Der Rebase ist da, aber laut Memory sind Scroll-Lock im macOS-Wheel-Pfad (PR #587 ist
iOS-zentriert beschrieben) und Shift-Selection nach dem Rebase nicht empirisch bestätigt.
Konkrete QA-Matrix: (a) Hochscrollen während Claude streamt, (b) Shift+Drag im
Alt-Screen + Cmd+C, (c) Tippen im Scrollback → springt ans Ende. Danach die zwei
Selection-Patches (`linefeed` + `feedPrepare`) als Upstream-PR einreichen — Upstream hat
mit v1.11.2 dasselbe Ziel formuliert, WhisperM8s Erkenntnis „beide Pfade nötig" ist der
fehlende Baustein. Ziel: Fork eliminieren, zurück auf `migueldeicaza/SwiftTerm`.

**P2 — Teardown um Eskalation + Liveness-Check ergänzen (VibeTunnel-Muster).**
Nach 2× Ctrl+C: prüfen ob das Kind lebt (`kill(pid, 0)` — Helfer existiert schon in
`AgentJobStore`), sonst SIGTERM an die PTY-Kindprozessgruppe, kurze Grace-Period,
dann erst harter Teardown. Verhindert Orphans, wenn eine TUI auf Ctrl+C nicht reagiert
(z. B. hängender MCP-Server). Kleiner, lokal begrenzter Eingriff in
`AgentTerminalSessionController.terminate()`.

**P3 — Scrollback-Budget explizit setzen statt Default 500.**
`TerminalOptions(scrollback:)` auf z. B. 5000–10000 für Agent-Chats heben und das
Memory-Budget bewusst rechnen (xterm.js-Faustformel: Zeilen × Spalten × ~2 Byte-Zellen;
10k×200 ≈ niedrige zweistellige MB pro aktivem Terminal). Mit v1.14s
`totalLinesTrimmed` lässt sich im UI ehrlich anzeigen, wenn History abgeschnitten wurde
(„ältere Ausgabe im Transcript"). Die Kombination mit JSONL-Transcript als Vollhistorie
entspricht dann exakt dem Branchen-Muster (Limit im Emulator + billiger Vollkanal).

**P4 — Caret-Flackern: erst Upstream-Fix versuchen, Metal nur beobachten.**
Fork-Patch-5-Kandidat (`showCursor` → `updateCursorPosition()` statt bedingungslosem
`addSubview`) ist klein, objektiv und upstream-würdig — als PR einreichen. Der
SwiftTerm-Metal-Renderer wäre die strukturelle Lösung (render-synchroner Cursor wie
iTerm2/Ghostty), ist aber wegen offener CJK-Artefakte (#596/#597) noch nicht reif;
als Beobachtungspunkt für 1.15+ vormerken, nicht jetzt aktivieren.

**P5 — Synchronized-Output-Debounce (jetzt public) mit eigener Feed-Drosselung abgleichen.**
v1.14 exponiert den 16-ms-Debounce (#526) und bringt PTY-Read-Backpressure (#574).
WhisperM8s eigene Feed-Drosselung für Hintergrund-Panes (`flushPendingOutput`,
`OutputPriority`) sollte gegen diese neuen Upstream-Mechanismen geprüft werden —
möglicherweise ist ein Teil der Eigenlogik redundant geworden (gleiches Muster wie beim
redundanten `isFollowingTail`-Workaround nach Patch 1).

**P6 — Snapshot-Konzept ausbauen statt Architekturwechsel.**
Ein Wechsel auf xterm.js-in-WKWebView oder das VibeTunnel-Servermodell ist für
WhisperM8 nicht gerechtfertigt: Die zwei UX-Killer (Scroll, Selektion) sind upstream
gelöst bzw. im Fork gepatcht, und der Single-Prozess-Vorteil (keine IPC-Schicht, natives
Look-and-feel) bliebe sonst auf der Strecke. Das VibeTunnel-Muster „Sessions überleben
das UI" ist punktuell übernehmbar: Für langlaufende Arbeiten konsequenter auf
`claude --bg` + Attach lenken (existiert bereits), statt Foreground-PTYs
unsterblich machen zu wollen. Optional Stufe 2 des Snapshots: statt Plaintext den
Buffer mit Attributen sichern (SwiftTerm `getBufferAsData`), um beendete Chats
farbtreu zu rendern.

**P7 — libghostty im Auge behalten (Horizont 12+ Monate).**
Wenn libghostty eine stabile C-API für macOS-Embedding liefert (ghostling zeigt die
Richtung), wäre das der einzige realistische Kandidat, der GPU-Rendering + gereifte
Engine + natives Embedding vereint. Bis dahin ist SwiftTerm-Upstream-Nähe (P1) die
richtige Strategie.

---

## Quellen

- SwiftTerm: [Releases](https://github.com/migueldeicaza/SwiftTerm/releases), [v1.14.0-Notes](https://github.com/migueldeicaza/SwiftTerm/releases/tag/v1.14.0), [Issue #559](https://github.com/migueldeicaza/SwiftTerm/issues/559), [PR #587](https://github.com/migueldeicaza/SwiftTerm/pull/587), [PR #536](https://github.com/migueldeicaza/SwiftTerm/pull/536), [PR #479](https://github.com/migueldeicaza/SwiftTerm/pull/479), Issues [#596](https://github.com/migueldeicaza/SwiftTerm/issues/596)/[#597](https://github.com/migueldeicaza/SwiftTerm/issues/597), [#583](https://github.com/migueldeicaza/SwiftTerm/issues/583)
- xterm.js: [Buffer-Performance #791](https://github.com/xtermjs/xterm.js/issues/791), [Reflow PR #1864](https://github.com/xtermjs/xterm.js/pull/1864), [scrollOnUserInput PR #4289](https://github.com/xtermjs/xterm.js/pull/4289), [Scrollback #518](https://github.com/xtermjs/xterm.js/issues/518)
- Superset: [Repo](https://github.com/superset-sh/superset), [superset.sh](https://superset.sh/), [Architektur-Analyse (typevar.dev)](https://typevar.dev/articles/superset-sh/superset)
- Crystal: [Repo](https://github.com/stravu/crystal), [CLAUDE.md](https://github.com/stravu/crystal/blob/main/CLAUDE.md), [DeepWiki](https://deepwiki.com/stravu/crystal)
- VibeTunnel: [Repo](https://github.com/amantus-ai/vibetunnel), [Steipete-Blogpost](https://steipete.me/posts/2025/vibetunnel-turn-any-browser-into-your-mac-terminal), [DeepWiki](https://deepwiki.com/amantus-ai/vibetunnel), `web/src/server/pty/pty-manager.ts` (SIGTERM-Eskalation), `asciinema-writer.ts`
- Conductor: [conductor.build](https://www.conductor.build/), [Docs](https://docs.conductor.build/), [Show HN](https://news.ycombinator.com/item?id=44594584)
- opcode: [Repo](https://github.com/winfunc/opcode), [DeepWiki AI Output Visualization](https://deepwiki.com/getAsterisk/opcode/4.2-ai-output-visualization)
- Ghostty: [Repo](https://github.com/ghostty-org/ghostty), [ghostling](https://github.com/ghostty-org/ghostling), [libghostty-Ankündigung](https://mitchellh.com/writing/libghostty-is-coming), [1.3.0 Release Notes](https://ghostty.org/docs/install/release-notes/1-3-0)
- iTerm2: [Terminal-Preferences-Doku](https://iterm2.com/documentation-preferences-profiles-terminal.html) (Idle-Kompression), [Metal-Renderer-Wiki](https://gitlab.com/gnachman/iterm2/-/wikis/Metal-Renderer)
- WhisperM8 intern: `WhisperM8/Views/AgentTerminalView.swift`, `Package.swift` (Fork-Pin-Kommentar), Memory `terminal-ux-root-causes.md`
