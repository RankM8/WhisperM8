---
status: aktiv
updated: 2026-07-18
description: Technologievergleich zu Terminalkern, PTY-Persistenz und Terminalprotokollen für Agent Chats
---

# Terminalkern und Session-Persistenz – Technologie-Deep-Dive (Juli 2026)

## Auftrag und Kurzurteil

WhisperM8 soll weiterhin die **echte interaktive Claude-Code-/Codex-CLI** in
einem nativen macOS-Terminal hosten. Gegenstand ist deshalb weder eine
Chat-Eigen-UI noch eine Transcript-Nachbildung, sondern die belastbare Kette
`TUI ↔ PTY ↔ Terminalemulator ↔ native SwiftUI/AppKit-View`.

1. **Terminalkern:** SwiftTerm bleibt für die Produktions-App die realistische
   Wahl. Version 1.14.0 ist aktuell und adressiert gerade Backpressure,
   synchronisiertes Rendering und Scroll-Lock; die verbleibenden
   Selection-Probleme sind real, aber lokal begrenzt. `libghostty-vt` ist
   technisch sehr interessant und bereits benutzbar, hat im Juli 2026 jedoch
   noch **keinen versionierten Library-Release, keine stabile API-Signatur und
   kein offizielles Swift-SDK**. cmux beweist die Machbarkeit einer
   Ghostty-Einbettung, zugleich aber auch deren derzeit hohen Fork-, Build- und
   Lifecycle-Aufwand. ([SwiftTerm 1.14.0], [Ghostty-Status],
   `<cmux>/docs/ghostty-fork.md:1-22,107-145,585-613`)
2. **Persistenz:** Mittelfristiges Zielbild ist ein eigener, kleiner
   per-user-PTY-Broker unter `launchd`, nicht tmux als Pflichtabhängigkeit.
   Kurzfristig sollte WhisperM8 den Status quo zu einem inkrementellen,
   crash-sicheren ANSI/asciicast-Recording ausbauen; erst nach einem
   Feature-Flag-Spike darf der Broker produktiv werden. Das trennt bewusst den
   Erhalt des laufenden Prozesses vom ohnehin verfügbaren `claude --resume` und
   vom Scrollback. ([tmux-Manpage], [asciinema-Aufzeichnung],
   `<superset>/packages/pty-daemon/src/SessionStore/SessionStore.ts:4-29`)
3. **Protokolle:** Claude-Hooks bleiben die alleinige Quelle für
   `working/idle/needsInput`; OSC 133 ergänzt semantische Shell-Grenzen, und
   OSC 99 sowie 9/777 ergänzen portable Aufmerksamkeitssignale. Diese Signale
   sollen Navigation, Notifications und Diagnostik verbessern, aber niemals
   agenteninterne Lifecycle-Hooks durch eine Heuristik ersetzen. ([OSC 133],
   [kitty OSC 99], `<cmux>/docs/agent-hooks.md:46-54`)

Stand der Webrecherche: **18. Juli 2026**. Aufwand und Risiko in den Tabellen
sind eigene Architektur-Schätzungen, keine Aussagen der verlinkten Projekte.

## Quellenkonvention für lokale Klone

- `<cmux>` =
  `/private/tmp/claude-501/-Users-giulianocosta-repos-whisperm8/8b93468c-4cf1-41c0-a5fc-b852563d2a8d/scratchpad/vergleich/cmux`
- `<superset>` =
  `/private/tmp/claude-501/-Users-giulianocosta-repos-whisperm8/8b93468c-4cf1-41c0-a5fc-b852563d2a8d/scratchpad/vergleich/superset`
- Pfade ohne Präfix sind relativ zum WhisperM8-Repository.

## 1. Terminal-Emulations-Kerne

### 1.1 Was WhisperM8 tatsächlich benötigt

Die Auswahl darf nicht nur Parser-Durchsatz vergleichen. WhisperM8 benötigt
gemeinsam: korrekte VT/xterm-Emulation für Alternate Screen und Mouse-Mode,
Unicode/CoreText, stabile Auswahl während kontinuierlicher Repaints, großen
Scrollback, macOS-IME/Accessibility, Clipboard/Links, Kitty-Keyboard-Input,
eine native `NSView`-Einbettung und eine PTY-Schnittstelle, die später von
„lokaler Kindprozess“ auf „Broker-Socket“ umgestellt werden kann. SwiftTerms
öffentliche Trennung aus UI-agnostischem Kern, `TerminalView` und
`LocalProcessTerminalView` erfüllt diese Integrationsform grundsätzlich.
([SwiftTerm README])

Der aktuelle Stand ist bereits ungewöhnlich nah am Upstream: WhisperM8 pinnt
einen Fork auf Basis von SwiftTerm 1.14.0; von ehemals vier lokalen Patches
bleiben zwei Selection-Patches, während Resize, PTY-Backpressure,
Metal-Reparenting, Shift-Selection und Scroll-Lock upstream sind.
(`Package.swift:16-24`)

### 1.2 SwiftTerm

**Aktivität und Reife.** SwiftTerm ist eine MIT-lizenzierte, per SwiftPM direkt
einbettbare Swift-Bibliothek mit AppKit-, UIKit- und Headless-Frontend. Als
reale Nutzer nennt das Projekt unter anderem Secure Shellfish, La Terminal und
CodeEdit. Release 1.14.0 vom 10. Juli 2026 brachte unter anderem PTY-Read-
Backpressure, inhaltsproportionales Resize, 16-ms-Debounce für synchronized
output, eine Sperre gegen automatisches Scroll-to-bottom, öffentliche
Mouse-Overrides sowie Fixes für Retain-Cycles von `Terminal` und
`LocalProcess`. ([SwiftTerm README], [SwiftTerm 1.14.0])

**Bekannte Grenze.** Der Maintainer qualifiziert den eigenen Vergleich mit
xterm.js ausdrücklich mit „modulo Selection/Accessibility“. Dass Selection
kein theoretischer Randfall ist, zeigt auch v1.11.2: Der Release bestand im
Wesentlichen aus dem Fix, eine Auswahl bei neu eingehenden Newlines nicht zu
löschen. WhisperM8 trägt selbst nach 1.14.0 weiterhin zwei Selection-Patches.
Das ist ein Wartungsrisiko, aber ein eng umrissenes und upstreambares, kein
Beleg für einen grundsätzlich ungeeigneten Kern. ([SwiftTerm README],
[SwiftTerm 1.14.0], `Package.swift:16-24`)

**Jank-Einordnung.** 1.14.0 adressiert genau zwei frühere Engpässe —
Backpressure und synchronized-output-Frame-Takt — und bietet optional Metal.
Damit sollte WhisperM8 zuerst den gepinnten 1.14-Fork mit CoreText und Metal
gegen identische aufgezeichnete Claude-Streams messen, statt aus subjektivem
Scroll-Jank sofort eine Kernmigration abzuleiten. Ein Rendererwechsel löst
außerdem weder PTY-Persistenz noch Teardown; das sind getrennte
Architekturachsen. ([SwiftTerm 1.14.0], [SwiftTerm README])

**Urteil:** **Ja, Produktionspfad.** Kurzfristiger Aufwand **S–M**, Risiko
**niedrig bis mittel**: Patches upstreamen, Selection-/Streaming-Fixtures
ergänzen, Metal/CoreText mit demselben Workload messen und die View vom
PTY-Owner abstrahieren.

### 1.3 Ghostty und libghostty: „released“ heißt noch nicht stabil versioniert

Die Antwort auf die Kernfrage lautet im Juli 2026:

- **Ja, benutzbar:** `libghostty-vt` ist als eigenständiges, zero-dependency
  Zig-/C-Modul für macOS, Linux, Windows und WASM verfügbar. Es verarbeitet
  Escape-Sequenzen und hält Terminal-, Scrollback- und Render-State.
- **Nein, noch kein stabiler Library-Release:** Ghostty schreibt selbst, dass
  noch kein `libghostty`-Versionstag existiert und API-Signaturen im Fluss
  sind. Die Ghostty-App 1.3.x ist stabil; ihre Versionsnummer ist ausdrücklich
  **nicht** die Library-Version, denn beide Release-Zyklen wurden getrennt.
- **C/Zig ja, Swift nein:** Es gibt eine dokumentierte C-API und Zig-API, aber
  keine zugesagte offizielle Binding-Pflege jenseits dieser beiden Sprachen.
  Swift kann C importieren, erhält dadurch jedoch weder SwiftPM-Verpackung noch
  ABI-/Source-Stabilität.

Diese Aussagen kommen direkt aus dem Projektstatus, den Ghostty-1.3.0-
Release-Notes und dem Referenzprojekt Ghostling. ([Ghostty-Status],
[Ghostty 1.3.0], [Ghostling])

**Wer nutzt es?** Ghostty spricht von Dutzenden freien und kommerziellen
Projekten; öffentlich prüfbare Beispiele sind Ghostling als minimale C-
Referenz und cmux als große native Swift/AppKit-Integration. Dabei ist Ghostling
ein `libghostty-vt`-Beispiel, während cmux — wie unten gezeigt — eine erheblich
breitere, geforkte `GhosttyKit`-Laufzeit einbettet. ([Ghostty 1.3.0],
[Ghostling], `<cmux>/cmux-Bridging-Header.h:1-2`)

`libghostty-vt` ist außerdem **kein fertiger macOS-Terminal-View-Baustein**:
Ghostling stellt klar, dass die Library weder Fenster noch tatsächliches
Rendering, Tabs, Session-Management oder UI liefert; der Embedder baut diese
Schichten selbst. Ghostling nutzt Raylib nur als Demonstration und warnt, dass
die Demo nicht für den täglichen Einsatz gedacht ist. Für WhisperM8 hieße eine
reine `libghostty-vt`-Migration somit: Swift/C-Brücke, Metal/CoreText-Renderer,
AppKit-Input/IME, Auswahl, Accessibility, Clipboard, Links und PTY-Transport
selbst besitzen. ([Ghostling])

Ghostty und libghostty stehen unter **MIT**; lizenzrechtlich wäre eine
Einbettung in WhisperM8 daher grundsätzlich unproblematisch. Das aktuelle
Hindernis ist technische Produktreife des Embedding-Vertrags, nicht die
Lizenz. ([Ghostty-Lizenz])

#### Wie cmux Ghostty tatsächlich einbettet

cmux ist der relevante Machbarkeitsbeleg, aber kein Beleg für eine heute
wartungsfreie Standardintegration:

- Die native Swift/AppKit-App importiert `GhosttyKit` über einen Objective-C-
  Bridging-Header. (`<cmux>/cmux-Bridging-Header.h:1-2`,
  `<cmux>/README.md:86-94`)
- Sie bindet **einen eigenen Ghostty-Fork** als Submodule ein, nicht einfach
  einen stabilen Upstream-SPM-Release.
  (`<cmux>/.gitmodules:1-4`)
- Ihr Build lädt ein per Commit-Checksumme gepinntes
  `GhosttyKit.xcframework` aus Fork-Releases oder baut es mit Zig als
  universelles ReleaseFast-XCFramework selbst.
  (`<cmux>/scripts/ensure-ghosttykit.sh:129-205,207-229`)
- Der Host ruft die eingebettete C-API (`ghostty_app_new`,
  `ghostty_surface_*`) aus einer sehr großen nativen Integrationsschicht auf;
  allein `GhosttyTerminalView.swift` reicht über 6.500 Zeilen und koppelt
  AppKit, Metal, CoreText, IOSurface, Settings, Workspaces und weitere
  cmux-Module. (`<cmux>/Sources/GhosttyTerminalView.swift:1-24,823-1021,6563`)
- Das Fork-Log dokumentiert eigene Änderungen für Selection, komprimierten
  Voll-Scrollback, OSC-99, Viewport-Wiederherstellung und Synchronisierung von
  `ghostty_surface_new/free`; eine konkrete Änderung verhindert, dass ein
  off-main `ghostty_surface_free` mit einer main-actor-Erzeugung kollidiert.
  (`<cmux>/docs/ghostty-fork.md:107-145,348-359,585-613`)

Das ist wichtig: cmux verwendet praktisch die **vollständige eingebettete
Ghostty-macOS-Laufzeit als selbst gepflegtes XCFramework**, während das
öffentlich als erste Library-Stufe deklarierte `libghostty-vt` nur Kernzustand
und Render-State verspricht. cmux zeigt also, dass erstklassige native Qualität
möglich ist; sein Fork- und Lifecycle-Aufwand ist zugleich das stärkste
Argument gegen eine sofortige Kernabhängigkeit in WhisperM8.
([Ghostty-Status], `<cmux>/docs/ghostty-fork.md:1-22`)

**Urteil:** **Pilot ja, Produktionsmigration heute nein.** Aufwand **XL**,
Risiko **hoch**, solange kein versionierter libghostty-Release, kein belastbarer
Swift/XCFramework-Distributionsweg und kein stabiler Renderer-/Surface-
Lifecycle-Vertrag existieren. Ein späterer Wechsel wird neu bewertet, sobald
diese drei Gates erfüllt sind.

### 1.4 Alternativen

| Kern | Faktenstand Juli 2026 | Native Einbettung in WhisperM8 | Eigene Schätzung |
|---|---|---|---|
| **Alacritty / `alacritty_terminal`** | Aktiver Rust/OpenGL-Terminal; Projekt bezeichnet den App-Reifegrad weiterhin als Beta. MIT/Apache-2.0. Der Terminalkern liegt als Rust-Crate im Monorepo, aber ohne offiziellen C-/Swift-/AppKit-Vertrag. ([Alacritty], [`alacritty_terminal`-Quellbaum]) | **Nein als Migrationsziel.** Parser/Grid wären verwendbar, Renderer, Rust-FFI und komplette macOS-View blieben bei WhisperM8. Kein Vorteil gegenüber dem reiferen libghostty-Pfad. | XL / hoch |
| **WezTerm `term`** | Reifer Rust-Terminal plus eigener Multiplexer; `term` ist ein interner Rust-Baustein, kein ausgeliefertes C-/Swift-SDK. Das öffentliche Produkt ist die ganze WezTerm-Laufzeit. ([WezTerm], [WezTerm-`term`]) | **Nein als Library.** Als externe Mux-Laufzeit technisch möglich, aber viel zu groß und UX-fremd als Kernabhängigkeit. | XL / hoch |
| **kitty** | Sehr aktiver GPU-Terminal, aber vollständige App aus C/Python/Go und GPL-3.0; kein unterstütztes AppKit-/C-SDK zur Einbettung. ([kitty]) | **Nein.** Fehlender Library-Vertrag und Copyleft-Risiko für eine Kernintegration. Die Protokolle sind dagegen relevant. | XL / sehr hoch |
| **Rio** | Aktiver MIT-lizenzierter Rust/wgpu-Terminal; nutzt weiterhin wesentliche Alacritty-Komponenten. Release 0.4.5 erschien im Mai 2026; die Browser-Portierung ist noch nicht fertig. ([Rio]) | **Nein.** App, kein stabiles Swift-SDK; dieselbe Rust-FFI-/Renderer-Eigenarbeit wie Alacritty. | XL / hoch |
| **Warp intern** | Seit 28. April 2026 offen, überwiegend Rust, eigener Metal-/GPU-Renderer und Block-Modell; der Großteil des Repos ist AGPL-3.0. ([Warp Open Source], [Warp-Architektur], [Warp-Repo]) | **Nein.** Das Block-Modell ist Produktarchitektur statt embeddable Terminalkern; AGPL und fehlende Library-Grenze schließen eine Kernübernahme aus. | XL+ / sehr hoch |

#### Realistischer Migrationspfad

1. **Jetzt:** SwiftTerm 1.14-Fork behalten; Selection-Fixes upstreamen; Jank
   reproduzierbar mit `.cast`-/Raw-PTY-Fixtures, CoreText- und Metal-Backend
   messen. SwiftTerm selbst unterstützt termcast/asciicast und ein optionales
   Metal-Backend. ([SwiftTerm README])
2. **Architektur-Naht:** `AgentTerminalView` soll nicht mehr voraussetzen, dass
   die View den Prozess besitzt. Ein schmales internes Interface für
   `receive(bytes)`, `send(bytes)`, `resize`, `close/detach` und
   Terminal-Metadaten erlaubt sowohl heutigen `LocalProcess` als auch späteren
   Broker; SwiftTerms `TerminalViewDelegate` ist dafür vorgesehen.
   ([SwiftTerm README])
3. **Ghostty-Spike, nicht Produktabhängigkeit:** Ein isolierter Benchmark baut
   dieselben Claude-Code-Streams mit Ghostling/libghostty-vt nach. Er zählt
   Integrationscode, Selection-Korrektheit, CPU/GPU, Memory, IME und
   Accessibility. Keine cmux-Fork-Kopie und kein unversionierter Core im
   Release-Build.
4. **Reife-Gates:** Erst neu entscheiden, wenn libghostty (a) versionierte
   Releases/Kompatibilitätsregeln, (b) einen reproduzierbaren macOS-
   Distributionsweg und (c) dokumentierte Surface-/Thread-Lifecycle-Garantien
   besitzt. Ghostty nennt Stabilisierung und ersten Tag selbst als nächste
   Aufgabe. ([Ghostty 1.3.0])

## 2. PTY-Session-Persistenz über App-Neustarts

### 2.1 Vier verschiedene Versprechen

„Session wieder da“ kann vier Dinge meinen, die nicht vermischt werden dürfen:

1. **Live-Prozess-Erhalt:** Derselbe Claude-Prozess und seine Kindprozesse
   laufen nach App-Quit weiter.
2. **Terminalzustand:** VT-Screen, Alternate Screen, Cursor, Modes und
   Scrollback erscheinen nach Reconnect korrekt.
3. **Agent-Resume:** Ein neuer Claude-Prozess lädt dieselbe logische Agent-
   Session per `claude --resume <id>`.
4. **Reboot-Resurrection:** Nach Maschinenneustart werden Layout, Ausgabe und
   Befehle rekonstruiert; derselbe Prozess kann naturgemäß nicht überleben.

WhisperM8 erfüllt heute vor allem (3) und einen begrenzten Teil von (2): Beim
Teardown werden gepufferte Bytes geflusht, der Normal-Buffer als Plaintext
gesichert und auf die letzten 2.000 Zeilen begrenzt. Beim App-Quit sendet die
Registry zweimal Ctrl+C, wartet zusammen rund 260 ms und friert dann alle
Snapshots ein; danach sterben die App-eigenen PTY-Kinder.
(`WhisperM8/Services/AgentChats/TerminalSnapshotStore.swift:3-29,48-60`,
`WhisperM8/Views/AgentTerminalView.swift:385-401,775-819`,
`WhisperM8/WhisperM8App.swift:343-351`)

### 2.2 Vergleich der Persistenzmodelle

#### tmux

tmux ist die ausgereifte Referenz: Ein separater Server besitzt Sessions und
PTYs; Clients und Server sind getrennte Prozesse und sprechen über einen
Socket. Detach oder Client-Verlust lässt Session und Prozess leben, bis die
Session explizit beendet wird; tmux hält dabei seinen eigenen Screen und
Scrollback. ([tmux-Manpage])

Für WhisperM8 löst das Live-Prozess und Scrollback schnell, führt aber einen
zweiten Terminalemulator zwischen Claude und SwiftTerm ein. Daraus folgen
tmux-eigene `TERM`-/terminfo-, Keybinding-, Mouse-, Copy-Mode-, Resize- und
Escape-Passthrough-Semantiken. shpool benennt genau den UX-Unterschied:
tmux rendert serverseitig und schickt eine Sicht, während ein Raw-Relay die
native Scrollback-/Copy-Semantik des äußeren Terminals erhält. ([shpool])

#### Zellij und Session Resurrection

Eine laufende Zellij-Session ist wie tmux detachbar. „Session Resurrection“
geht zusätzlich über Server-/Reboot-Grenzen, ist aber **Rekonstruktion, kein
Prozess-Checkpoint**: Zellij serialisiert standardmäßig jede Sekunde Layout und
erkannte Pane-Kommandos; optional auch Viewport und eine konfigurierbare Zahl
Scrollback-Zeilen. Beim Resurrection werden Kommandos hinter einer
„Press ENTER to run“-Schranke erneut ausgeführt. ([Zellij Resurrection],
[Zellij Commands])

Für Claude wäre Zellij-Resurrection daher semantisch ähnlich zu
`claude --resume` plus Scrollback-Snapshot, nur mit einem kompletten zusätzlichen
Multiplexer. Sie ist kein Grund, Zellij in die native App einzubauen.

#### shpool

shpool 0.11.0 ist konzeptionell näher am gewünschten Broker: Der Dienst besitzt
benannte Shells und leitet Raw-Bytes weiter, wodurch native Scrollback- und
Copy/Paste-Semantik erhalten bleiben. Für Reattach hält er zusätzlich einen
in-memory VT-Zustand und kann den Screen einschließlich Output aus der
Disconnect-Phase neu zeichnen. Es gibt TTL und Homebrew-Service-Setup.
([shpool])

Der Haken ist die Plattformreife: Linux ist primär unterstützt; die eigene
Dokumentation sagt ausdrücklich, dass auf macOS noch Tests fehlschlagen.
Damit ist shpool ein sehr guter Architektur-Referenzpunkt, aber keine
vertretbare Beta-Abhängigkeit im Kern von WhisperM8. ([shpool])

#### WezTerm mux

WezTerm kann einen Multiplexer-Server hinter einem Unix-Domain-Socket bei Bedarf
starten und die GUI beim Launch verbinden; Remote-/TLS-Verbindungen können
automatisch reconnecten. Das öffentliche `wezterm cli` bezeichnet die
Dokumentation jedoch weiterhin als Schnittstelle zu einem **experimentellen**
Mux-Server. ([WezTerm Multiplexing], [WezTerm CLI])

Technisch ist das ein vollständiges Vorbild für Client/Server-Trennung, aber
als WhisperM8-Abhängigkeit wäre es die Einbettung einer zweiten großen
Rust-Terminal-App samt eigenem Protokoll, Konfiguration und Release-Zyklus.

#### dtach

dtach ist der Minimalpol: Es schützt genau einen Prozess vor Verlust des
steuernden Terminals und relayed Bytes, interpretiert sie aber nicht. Das
Projekt sagt ausdrücklich, dass es **keinen Screen-Inhalt und keine
Terminalemulation** hält und deshalb nur mit Programmen gut funktioniert, die
sich selbst neu zeichnen. Für Claude könnte derselbe Prozess überleben, der
verpasste Scrollback aber nicht. ([dtach])

### 2.3 Wie GUI-Agent-Apps es konkret lösen

#### cmux: Snapshot plus natives Agent-Resume, kein Live-Checkpoint

cmux speichert beim Beenden Layout, Arbeitsverzeichnisse, best-effort
Scrollback und Browserzustand. Es dokumentiert ausdrücklich, dass beliebige
Live-Prozesse **nicht** gecheckpointet werden. Hooks speichern native Agent-
Session-IDs; nach dem Layout-Restore startet cmux etwa
`claude --resume <id>` oder `codex resume <id>` in einem neuen Terminal. Ein
tmux-Attach kann als benutzerfreigegebener Custom-Resume-Befehl hinterlegt
werden. (`<cmux>/README.md:249-318`, `<cmux>/docs/agent-hooks.md:18-50,110-132`,
[cmux Session Restore])

Das ist näher am heutigen WhisperM8-Status als an einem Broker. Es liefert eine
gute UX nach Neustart und Reboot, erhält aber weder PID noch in-flight
Terminalprogramm. Seine Sicherheitsdetails sind übernehmbar: gespeicherte
Resume-Kommandos werden sanitisiert; fremd vorgeschlagene Kommandos dürfen erst
nach User-Freigabe automatisch laufen. (`<cmux>/README.md:276-293`,
`<cmux>/docs/agent-hooks.md:46-50,110-114`)

#### Superset: echter detached PTY-Daemon, mit realen Betriebskosten

Superset verspricht Terminals, die Restarts überleben, und implementiert dafür
in Produktion einen detached PTY-Daemon. Ein Manifest plus Unix-Socket erlaubt
dem neu gestarteten Host-Service, den vorhandenen Daemon zu adoptieren; der
Daemon wird detached gespawnt und `unref()`t. Beim normalen Produktions-Quit
wird der Terminal-Host gerade **nicht** destruktiv beendet.
(`<superset>/README.md:74-78`,
`<superset>/packages/host-service/src/daemon/DaemonSupervisor.ts:819-853,1046-1072,1126-1132`,
`<superset>/apps/desktop/src/main/index.ts:225-255`)

Der Daemon hält Sessions nur in einer in-memory Map und pro Session einen
64-KiB-Ringpuffer für Reattach; größeren Scrollback hält xterm.js im Renderer.
Für ein Daemon-Upgrade kann Superset die PTY-Master-FDs an den Nachfolger
vererben und überträgt dazu einen transienten Snapshot aus Metadaten und
Ringpuffer. Das ist keine langfristige Disk-Persistenz, sondern Live-FD-
Handoff. (`<superset>/packages/pty-daemon/src/SessionStore/SessionStore.ts:4-36,87-103`,
`<superset>/packages/pty-daemon/src/SessionStore/snapshot.ts:1-22,38-63,74-97`,
`<superset>/packages/pty-daemon/src/main.ts:139-190`)

Besonders wertvoll ist Supersets aktuelles internes Fehlerbild: Ein M1 Max
erreichte nach mehreren Workspaces das macOS-PTY-Limit von etwa 509/511; der
Plan dokumentiert fehlende TTL/Session-Caps, fire-and-forget-Dispose,
daemonisierte Kindprozesse außerhalb des Kill-Baums und versteckte Renderer,
die trotz Parken weiter WebSocket-Output parsen. Vorgeschlagen werden
SIGHUP plus wiederholte SIGKILL-Eskalation, langlebige Kill-Timer, TTL/Cap,
Reaper und „park = disconnect“ mit 64-KiB-Replay.
(`<superset>/plans/pty-lifecycle-cleanup.md:1-20,24-65,84-95`)

Das zitierte Superset-Dokument ist ein lokaler Arbeitsplan mit Stand
17. Juli 2026 und weist selbst noch nicht begonnene Backstops aus; es ist damit
Evidenz für gefundene Failure-Modes und geplante Gegenmaßnahmen, nicht der
Nachweis, dass alle Gegenmaßnahmen bereits ausgeliefert sind.
(`<superset>/plans/pty-lifecycle-cleanup.md:5-9,67-95`)

Superset beweist damit **beides**: Der Broker funktioniert, und ein „kleiner
Daemon“ wird ohne harte Ownership-, Reaping- und Update-Regeln schnell zur
größeren Teardown-Fehlerquelle als das heutige App-Kindmodell.

#### VibeTunnel: Servergrenze und Recording, aber kein belegter App-Restart-Erhalt

VibeTunnel trennt native Swift-Menüleisten-App, Bun/Node-Server und Web/iOS-
Clients. Der Server besitzt PTYs; sämtliche Sessions werden im asciinema-Format
aufgezeichnet. Die öffentliche Architektur sagt zugleich, dass die Mac-App den
Server **als Kindprozess spawnt und verwaltet** und beschreibt beim
Server-Shutdown PTY-Cleanup. Deshalb ist aus den öffentlichen Quellen kein
Versprechen ableitbar, dass von der Mac-App gestartete PTYs einen App-Neustart
als derselbe Prozess überleben. Browser-Reconnect und Recording sichern Zugriff
beziehungsweise Historie, nicht automatisch den Serverprozess. ([VibeTunnel],
[VibeTunnel-Architektur], [VibeTunnel-Performance])

Das übernehmbare Muster ist das append-only `.cast`-Recording mit getrennten
Output- und Resize-Ereignissen. Es kann nach Crash bis zum letzten Flush
replayed werden und ist wesentlich aussagekräftiger als ein einmaliger
Plaintext-Endsnapshot. ([VibeTunnel-Protokolle], [asciinema-Aufzeichnung])

### 2.4 Drei Architekturen für WhisperM8

| Option | Live-Prozess nach App-Quit | Scrollback | Produktwirkung | Aufwand/Risiko | Urteil |
|---|---:|---|---|---|---|
| **(i) tmux als Abhängigkeit** | Ja, solange tmux-Server lebt | tmux-eigen, vollständig innerhalb seines Limits | Zusätzliche sichtbare Mux-Semantik; Installation/Versionierung und Escape-Passthrough werden Produktbestandteil. ([tmux-Manpage], [shpool]) | M / mittel bis hoch | **Nicht als Pflicht.** Optionaler Expertenmodus oder expliziter Custom-Attach ist vertretbar. |
| **(ii) eigener launchd-PTY-Broker** | Ja | Broker zeichnet Raw-Output/Resize auf; SwiftTerm baut State beim Reconnect wieder auf | Unsichtbare, WhisperM8-eigene Persistenz; echte TUI und native Selection bleiben außen unverändert. Superset belegt Machbarkeit und Lifecycle-Risiken. (`<superset>/packages/host-service/src/daemon/DaemonSupervisor.ts:819-853`, `<superset>/plans/pty-lifecycle-cleanup.md:1-20`) | L–XL / anfangs hoch | **Strategisches Ziel**, aber nur gestuft und hinter Reife-Gates. |
| **(iii) Status quo plus besserer Snapshot** | Nein | Ja, crash-sicher bis zum letzten Recording-Flush; neuer Prozess per Agent-Resume | Geringste Komplexität, funktioniert auch nach Reboot, verliert aber in-flight Prozess/Tool. cmux nutzt dasselbe Grundmodell. (`WhisperM8/Services/AgentChats/TerminalSnapshotStore.swift:14-29`, `<cmux>/README.md:249-318`) | S–M / niedrig | **Sofortmaßnahme und Fallback**, nicht Endzustand bei echtem Prozess-Erhalt. |

### 2.5 Empfehlung: Broker als Ziel, Recording als sichere erste Stufe

#### Stufe A — jetzt: inkrementelles Recording statt nur Endsnapshot

- Pro PTY append-only Output- und Resize-Ereignisse im asciicast-v2-ähnlichen
  Format schreiben; **keine Eingaben standardmäßig mitschreiben**, weil Prompts,
  Tokens und Secrets darin stehen können. Asciinema selbst zeichnet stdin
  standardmäßig nicht auf. ([asciinema-Aufzeichnung],
  [asciinema Input-Policy])
- Dateien mit `0600`, Größen-/Alterslimit und atomarem Metadatenindex halten.
  Der bestehende 2.000-Zeilen-Plaintext-Snapshot bleibt schneller UI-Fallback,
  während `.cast` für farbigen, semantisch korrekteren Replay dient.
  (`WhisperM8/Services/AgentChats/TerminalSnapshotStore.swift:14-29,75-106`)
- Bei sauberem Quit weiterhin `claude --resume`-ID sichern; bei Crash steht
  wenigstens der bis dahin geflushte Output bereit. cmux belegt den Nutzen der
  Kombination „Scrollback-Snapshot + native Agent-ID“. (`<cmux>/README.md:249-318`)

Diese Stufe verbessert Scrollback/Crash-Recovery, behauptet aber bewusst keinen
Prozess-Erhalt.

#### Stufe B — Feature-Flag-Spike: minimaler Brokervertrag

```text
SwiftTerm/AppKit-View
       │  Unix-Domain-Socket: attach/input/resize/detach/close + Sequenznummern
       ▼
per-user launchd Agent (PTY-Owner, Ringpuffer, append-only .cast, Reaper)
       │
       └── PTY master ⇄ Login-Shell ⇄ echte Claude-/Codex-TUI
```

Der Broker besitzt PTY-Master und Prozessgruppe; die App besitzt Darstellung,
Auswahl und Accessibility. Beim Reconnect spielt der Broker Raw-Output samt
Resize-Ereignissen bis zu einer Sequenznummer nach und schaltet dann atomar auf
Live-Output. Damit bleibt SwiftTerm der einzige Terminalemulator im normalen
Pfad. Das Design folgt der Raw-Relay-Idee von shpool, ergänzt aber disk-backed
Replay für Scrollback. ([shpool], [asciinema-Aufzeichnung])

Der Vertrag braucht von Beginn an:

- **Semantik:** App-Quit = `detach`, Tab explizit schließen = `close`, Agent
  stoppen = kontrollierter Interrupt; diese Aktionen dürfen nicht denselben
  Codepfad haben.
- **Teardown:** Prozessgruppe mit SIGHUP/TERM, nach Frist wiederholt SIGKILL;
  Exit erst nach Drain der Eskalation. Superset zeigt, warum einmalige Signale,
  `unref()`-Timer und nur PPID-basierte Bäume lecken.
  (`<superset>/plans/pty-lifecycle-cleanup.md:24-36,71-80`)
- **Backstops:** subscriber-loser Idle-TTL, hartes Session-Limit deutlich unter
  dem System-PTY-Limit, periodischer Reaper, persistierter Close-Intent und
  Orphan-Reconciliation. (`<superset>/plans/pty-lifecycle-cleanup.md:45-56,84-95`)
- **Transport:** Unix-Socket nur für den aktuellen User, `0600`,
  Protokollversion/Handshake, monotone Sequenznummern, Backpressure und genau
  ein Input-/Resize-Lease pro Session. Supersets Event-Doku warnt, dass Daten
  bei Socket-Disconnect fehlen können; Replay darf daher nicht allein auf dem
  Client-Buffer beruhen.
  (`<superset>/apps/desktop/docs/TERMINAL_HOST_EVENTS.md:17-31,38-49`)
- **Upgrade:** Version 1 darf bei laufenden Sessions ein Broker-Update
  aufschieben. FD-Handoff wie Superset ist möglich, aber kein MVP: Es bringt
  transienten Disk-Snapshot, FD-Vererbung, Ack und Socket-Rebind-Races mit.
  (`<superset>/packages/pty-daemon/src/SessionStore/snapshot.ts:1-22`,
  `<superset>/packages/pty-daemon/src/main.ts:159-190`)
- **Ressourcen:** Unsichtbare Tabs trennen den UI-Stream und holen beim
  Aktivieren Replay; sie dürfen nicht dauerhaft rendern. Genau das adressiert
  Supersets „park = disconnect“-Plan.
  (`<superset>/plans/pty-lifecycle-cleanup.md:51-56,91-95`)

#### Produkt-Gates vor Default-Aktivierung

Der Broker wird erst Standard, wenn automatisierte Tests nachweisen:

1. App-Crash und App-Update lassen dieselbe Claude-PID und alle erwarteten
   Kinder weiterleben.
2. Reconnect unter parallelem Output erzeugt keine Lücke/Dopplung; Screen und
   Scrollback stimmen nach Replay bei aufgezeichneten Resize-Folgen.
3. „Tab schließen“, „Agent stoppen“, Logout und Deinstallation hinterlassen
   weder PTY noch Prozessgruppe.
4. TTL/Cap greifen unter Hunderten künstlichen Sessions; keine lineare Arbeit
   in unsichtbaren Views.
5. Ein alter Broker bleibt kompatibel oder verweigert sicher; ein Update
   zerstört nie stillschweigend Sessions.

Bis diese Gates erfüllt sind, bleibt Stufe A der Default. tmux kann parallel
als **explizite** fortgeschrittene Option angeboten werden, aber WhisperM8 darf
seine Basis-UX und Korrektheit nicht von einer externen tmux-Konfiguration
abhängig machen.

## 3. Neue Standards und Protokolle

### 3.1 OSC 133: semantische Shell-Grenzen

OSC 133 markiert `A` Promptbeginn, `B` Kommandozeilenbeginn, `C` Beginn der
Ausgabe und `D;<exit>` Kommandoende. iTerm2/FinalTerm dokumentiert damit genau
die semantische Grenze zwischen Prompt, eingegebenem Kommando und Output;
Windows Terminal unterstützt dieselben stabilen Marks. ([OSC 133],
[Windows Terminal OSC 133])

Für WhisperM8 lohnt sich OSC 133 in **Plain-Shell-Sessions** für:

- Sprungmarken und „Output des letzten Kommandos“ statt Zeilenheuristik,
- Exitstatus und Laufzeit eines Shell-Kommandos,
- robustere Snapshot-Segmentierung sowie
- Click-to-move/Prompt-Navigation, falls der Kern es unterstützt.

iTerm2 belegt diese UX-Funktionen mit Marks, Output-Selektion, Exitstatus,
Working Directory und Laufzeit. ([iTerm2 Shell Integration])

OSC 133 erkennt jedoch **keinen Claude-Turn innerhalb der laufenden TUI**:
Aus Sicht der Shell ist `claude` ein einziges lang laufendes Kommando zwischen
`C` und `D`. Deshalb darf OSC 133 den Agentenstatus nicht setzen. Es kann nur
„Shell wartet“ versus „Foreground-Kommando läuft“ ergänzen.

Empfehlung: Shell-Integration als von WhisperM8 injizierten, temporären
Launch-Shim für zsh/bash/fish anbieten und keine User-Dotfiles ungefragt
ändern. Ereignisse als Terminal-Metadaten halten, nicht als sichtbaren Text.

### 3.2 OSC 9, OSC 777 und OSC 99: Notifications

- **OSC 9** ist das einfache Legacy-Notification-Signal; kitty unterstützt es
  weiterhin. ([kitty OSC 99])
- **OSC 777** (`notify;title;body`) ist die verbreitete rxvt-Variante mit
  separatem Titel und Body; cmux akzeptiert sie neben 9/99.
  ([cmux Notifications], `<cmux>/README.md:127,350`)
- **OSC 99** ist kittys reichere Variante mit IDs, Titel/Body, Updates,
  Capability-Query und optionalen Aktionen. ([kitty OSC 99])

cmux kombiniert diese generischen Terminalsequenzen mit CLI und
anbieterbezogenen Agent-Hooks. Seine Hooks speichern Lifecycle und native
Session-ID; OSC/CLI liefern User-Aufmerksamkeit. Für Claude `PushNotification`
unterdrückt cmux sogar das rohe OSC, wenn eine Hook-Integration dasselbe
Ereignis präziser in die eigene Notification-Pipeline bridged. Genau diese
Priorität sollte WhisperM8 übernehmen.
(`<cmux>/docs/agent-hooks.md:46-54`, `<cmux>/README.md:127,350`)

**Entscheidung:** OSC 99 + 9/777 parsen und in die bestehende deduplizierte
Notification-Pipeline einspeisen, aber als `source = terminalOSC` markieren.
Hook-Events gewinnen bei derselben Session und demselben Zeitfenster. Titel,
Body, URLs und Aktionen sind untrusted PTY-Output: Längenlimit, Rate-Limit,
keine ungefragte Shell-Ausführung und Fokus-Suppression sind Pflicht.

### 3.3 Kitty- und iTerm2-Protokolle

| Protokoll | Nutzen für WhisperM8 | Entscheidung |
|---|---|---|
| **Kitty Keyboard Protocol / CSI-u** | Eindeutige Modifier-/Key-Up-/Sondertasten-Codierung; relevant für TUIs. WhisperM8 sendet für `claude agents` bereits CSI-u für Shift+Enter, SwiftTerm 1.14 repariert Modifierfälle. (`WhisperM8/Views/AgentTerminalView.swift:404-415`, [SwiftTerm 1.14.0]) | **Behalten und mit TUI-Fixtures testen.** Kein Statussignal. |
| **Kitty Graphics** | Inline-Rastergrafik in modernen TUIs; `libghostty-vt` und SwiftTerm unterstützen das Protokoll. ([Kitty Graphics], [Ghostling], [SwiftTerm README]) | **Kompatibilität erhalten**, keine eigene UI darum bauen. Payload-, Memory- und Dateizugriff begrenzen. |
| **iTerm2 OSC 1337 Inline Files/Images** | Alternative für `imgcat` und Datei-/Bilddarstellung; SwiftTerm nennt iTerm2-style graphics als unterstützt. ([iTerm2 Escape Codes], [SwiftTerm README]) | **Bestehende Kernunterstützung absichern**, nicht als WhisperM8-spezifische API ausbauen. Remote-Dateipfade nie ungeprüft öffnen. |
| **OSC 7 / OSC 8** | OSC 7 meldet CWD, OSC 8 explizite Hyperlinks. WezTerm bietet sogar einen CLI-Helfer für OSC 7; SwiftTerm kann explizite OSC-8-Links an den Delegate melden. ([WezTerm CLI], [SwiftTerm README]) | **Übernehmen/weiterführen:** CWD für Resume/Snapshot-Metadaten, Links über bestehende sichere Öffnungslogik. |
| **DEC synchronized output (Mode 2026)** | Claude-Code-Streaming zeichnet Frames atomar; cmux hat bei Claude 2.1 genau diese Frame-Struktur beobachtet. SwiftTerm 1.14 taktet sie mit 16 ms. (`<cmux>/docs/streaming-agent-updates.md:22-26`, [SwiftTerm 1.14.0]) | **Performancekritisch erhalten**, aber nicht als Lifecycle-Signal missbrauchen. |

OSC 52 (Clipboard) gehört in denselben Security-Audit, auch wenn es kein
Statusprotokoll ist: PTY-Output darf nicht ohne Policy beliebige Clipboard-
Inhalte lesen oder schreiben. Ghostty zählt Clipboard-Sequenzen zu seinen
modernen Protokollen; eine Kernmigration darf diese Host-Policy nicht
versehentlich auf „immer erlauben“ setzen. ([Ghostty-Status])

### 3.4 Statusquellen: empfohlene Priorität

WhisperM8 besitzt bereits die richtige Grundregel: Sobald eine Claude-Session
nachweislich Hook-Events liefert, sind Hooks die alleinige Statusquelle;
Transcript-Heuristiken dürfen `working/idle` nicht überschreiben. Getrackt
werden SessionStart/End, UserPromptSubmit, Tool-Lifecycle,
PermissionRequest und Stop; `Notification` ist absichtlich ausgeschlossen,
weil ein generisches `idle_prompt` sonst fälschlich „braucht Handlung“ ergäbe.
(`WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:24-34,63-69,198-247`,
`WhisperM8/Services/AgentChats/ClaudeHookSettingsBuilder.swift:3-24`)

Die erweiterte Rangfolge lautet:

1. **Agent-Hooks:** verbindlich für Turn-Lifecycle, Permission und native
   Session-ID.
2. **Prozess-/PTY-Lifecycle:** verbindlich für Spawn, Exit, Disconnect und
   Broker-Attach.
3. **OSC 133:** verbindlich nur für Shell-Prompt-/Kommando-Grenzen außerhalb
   der Agent-TUI.
4. **OSC 99/9/777:** User-Notification, nicht Zustandsautomat; deduplizieren
   und gegen Hooks nachrangig behandeln.
5. **Transcript-/I/O-Heuristik:** Fallback bei fehlenden Hooks; nie eine
   stärkere Quelle überschreiben.

cmux bestätigt dasselbe Muster praktisch: Hook-Dateien halten
`running/idle/needsInput` und Resume-ID, während OSC 9/99/777 und CLI die
Notification-Oberfläche bedienen. (`<cmux>/docs/agent-hooks.md:18-54`,
`<cmux>/README.md:127,350`)

## 4. Priorisierte Entscheidung

| Priorität | Entscheidung | Erfolgskriterium |
|---:|---|---|
| **P0** | SwiftTerm 1.14-Fork stabilisieren, Selection-Patches upstreamen und CoreText/Metal mit denselben Claude-Streams benchmarken. | Kein Selection-Verlust; quantifizierte Frame-Time/CPU statt subjektiver Jank-Vergleich. |
| **P0** | Endsnapshot um inkrementelles, output-only ANSI/asciicast-Recording ergänzen. | Scrollback nach Crash/Neustart bis zum letzten Flush replaybar; Größen-/Privacy-Limits getestet. |
| **P1** | Terminaltransport vom Renderer entkoppeln und launchd-Broker hinter Feature Flag prototypen. | Gleiche Claude-PID nach App-Kill/Reopen; lückenloser Replay→Live-Übergang. |
| **P1** | OSC 133 sowie OSC 99/9/777 als nachrangige Metadatenquellen implementieren. | Shell-Marks/Notifications funktionieren, ohne Hook-Status zu verändern oder doppelte Alerts zu erzeugen. |
| **P2** | Broker erst nach Reaper-, Cap-, Teardown-, Upgrade- und Stresstests standardmäßig aktivieren. | Keine PTY-/Prozessleaks; App-Quit detach und Tab-Close kill sind beweisbar verschieden. |
| **Watch** | libghostty-Releases und offiziellen macOS-/Swift-Embedding-Vertrag beobachten. | Versionierter Release + kompatible Distribution + dokumentierter Surface-Lifecycle; erst dann Migrations-RFC. |

**Keine Beta-Abhängigkeit im Kern:** shpool, WezTerm-mux und unversioniertes
libghostty bleiben Referenzen oder isolierte Spikes. tmux bleibt optional. Der
Produktionspfad setzt bis zur Erfüllung der Gates auf SwiftTerm und eigene,
kleine System-API-Komponenten.

## Webquellen

- [SwiftTerm README] — <https://github.com/migueldeicaza/SwiftTerm>
- [SwiftTerm 1.14.0] — <https://github.com/migueldeicaza/SwiftTerm/releases/tag/v1.14.0>
- [Ghostty-Status] — <https://github.com/ghostty-org/ghostty#cross-platform-libghostty-for-embeddable-terminals>
- [Ghostty 1.3.0] — <https://ghostty.org/docs/install/release-notes/1-3-0#libghostty>
- [Ghostty-Lizenz] — <https://github.com/ghostty-org/ghostty/blob/main/LICENSE>
- [Ghostling] — <https://github.com/ghostty-org/ghostling>
- [Alacritty] — <https://github.com/alacritty/alacritty>
- [`alacritty_terminal`-Quellbaum] — <https://github.com/alacritty/alacritty/tree/master/alacritty_terminal>
- [WezTerm] — <https://github.com/wezterm/wezterm>
- [WezTerm-`term`] — <https://github.com/wezterm/wezterm/tree/main/term>
- [WezTerm Multiplexing] — <https://wezterm.org/multiplexing.html#unix-domains>
- [WezTerm CLI] — <https://wezterm.org/cli/general.html>
- [kitty] — <https://github.com/kovidgoyal/kitty>
- [Rio] — <https://github.com/raphamorim/rio>
- [Warp Open Source] — <https://www.warp.dev/blog/warp-is-now-open-source>
- [Warp-Architektur] — <https://www.warp.dev/blog/how-warp-works>
- [Warp-Repo] — <https://github.com/warpdotdev/warp>
- [tmux-Manpage] — <https://man7.org/linux/man-pages/man1/tmux.1.html>
- [Zellij Resurrection] — <https://zellij.dev/documentation/session-resurrection.html>
- [Zellij Commands] — <https://zellij.dev/documentation/commands>
- [shpool] — <https://docs.rs/crate/shpool/latest>
- [dtach] — <https://dtach.sourceforge.net/>
- [cmux Session Restore] — <https://cmux.com/docs/session-restore>
- [cmux Notifications] — <https://cmux.com/docs/notifications>
- [VibeTunnel] — <https://github.com/amantus-ai/vibetunnel>
- [VibeTunnel-Architektur] — <https://docs.vibetunnel.sh/docs/core/architecture>
- [VibeTunnel-Performance] — <https://docs.vibetunnel.sh/web/docs/performance>
- [VibeTunnel-Protokolle] — <https://docs.vibetunnel.sh/docs/core/protocols>
- [asciinema-Aufzeichnung] — <https://docs.asciinema.org/how-it-works/>
- [asciinema Input-Policy] — <https://docs.asciinema.org/manual/cli/configuration/v2/#record-stdin>
- [OSC 133] — <https://iterm2.com/documentation-escape-codes.html#shell-integrationfinalterm>
- [iTerm2 Shell Integration] — <https://iterm2.com/documentation-shell-integration.html>
- [iTerm2 Escape Codes] — <https://iterm2.com/documentation-escape-codes.html>
- [Windows Terminal OSC 133] — <https://learn.microsoft.com/en-us/windows/terminal/tutorials/shell-integration>
- [kitty OSC 99] — <https://sw.kovidgoyal.net/kitty/desktop-notifications/>
- [Kitty Graphics] — <https://sw.kovidgoyal.net/kitty/graphics-protocol/>

[SwiftTerm README]: https://github.com/migueldeicaza/SwiftTerm
[SwiftTerm 1.14.0]: https://github.com/migueldeicaza/SwiftTerm/releases/tag/v1.14.0
[Ghostty-Status]: https://github.com/ghostty-org/ghostty#cross-platform-libghostty-for-embeddable-terminals
[Ghostty 1.3.0]: https://ghostty.org/docs/install/release-notes/1-3-0#libghostty
[Ghostty-Lizenz]: https://github.com/ghostty-org/ghostty/blob/main/LICENSE
[Ghostling]: https://github.com/ghostty-org/ghostling
[Alacritty]: https://github.com/alacritty/alacritty
[`alacritty_terminal`-Quellbaum]: https://github.com/alacritty/alacritty/tree/master/alacritty_terminal
[WezTerm]: https://github.com/wezterm/wezterm
[WezTerm-`term`]: https://github.com/wezterm/wezterm/tree/main/term
[WezTerm Multiplexing]: https://wezterm.org/multiplexing.html#unix-domains
[WezTerm CLI]: https://wezterm.org/cli/general.html
[kitty]: https://github.com/kovidgoyal/kitty
[Rio]: https://github.com/raphamorim/rio
[Warp Open Source]: https://www.warp.dev/blog/warp-is-now-open-source
[Warp-Architektur]: https://www.warp.dev/blog/how-warp-works
[Warp-Repo]: https://github.com/warpdotdev/warp
[tmux-Manpage]: https://man7.org/linux/man-pages/man1/tmux.1.html
[Zellij Resurrection]: https://zellij.dev/documentation/session-resurrection.html
[Zellij Commands]: https://zellij.dev/documentation/commands
[shpool]: https://docs.rs/crate/shpool/latest
[dtach]: https://dtach.sourceforge.net/
[cmux Session Restore]: https://cmux.com/docs/session-restore
[cmux Notifications]: https://cmux.com/docs/notifications
[VibeTunnel]: https://github.com/amantus-ai/vibetunnel
[VibeTunnel-Architektur]: https://docs.vibetunnel.sh/docs/core/architecture
[VibeTunnel-Performance]: https://docs.vibetunnel.sh/web/docs/performance
[VibeTunnel-Protokolle]: https://docs.vibetunnel.sh/docs/core/protocols
[asciinema-Aufzeichnung]: https://docs.asciinema.org/how-it-works/
[asciinema Input-Policy]: https://docs.asciinema.org/manual/cli/configuration/v2/#record-stdin
[OSC 133]: https://iterm2.com/documentation-escape-codes.html#shell-integrationfinalterm
[iTerm2 Shell Integration]: https://iterm2.com/documentation-shell-integration.html
[iTerm2 Escape Codes]: https://iterm2.com/documentation-escape-codes.html
[Windows Terminal OSC 133]: https://learn.microsoft.com/en-us/windows/terminal/tutorials/shell-integration
[kitty OSC 99]: https://sw.kovidgoyal.net/kitty/desktop-notifications/
[Kitty Graphics]: https://sw.kovidgoyal.net/kitty/graphics-protocol/
