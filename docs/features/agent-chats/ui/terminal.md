---
status: aktiv
updated: 2026-10-22
---

# Terminal

Das Agent-Chat-Terminal ist ein eingebettetes SwiftTerm-PTY um
`LocalProcessTerminalView`. Es läuft in `AgentSessionDetailView`, wird über
`AgentTerminalRegistry` pro Session-ID registriert und bleibt dadurch auch bei
View-Rebuilds oder mehreren Fenstern derselbe Controller.

## Laufzeitmodell

`AgentTerminalRegistry.shared` hält `AgentTerminalController`-Instanzen nach
Session-ID. `startController` ist idempotent für bereits laufende Controller,
`terminate(sessionID:)` beendet eine Session und `terminateAll()` beendet alle
laufenden Vordergrund-PTYs über einen Snapshot.

`AgentTerminalController` besitzt die `QuietableTerminalView`, das
`AgentLaunchCommand`, Runtime-Flags, Theme-Observer, Keyboard-Handler,
Scroll-Guard und Link-Interceptor. `start()` ruft
`terminal.startProcess(...)` mit ausführbarem Pfad, Argumenten,
Arbeitsverzeichnis und `LoginShellEnvironment.shared.terminalEnvironmentArray()`
auf. Das rohe GUI-Environment wird nicht verwendet.

`AgentTerminalView` ist der `NSViewRepresentable`-Wrapper. Er hängt die
SwiftTerm-View in einen `AgentTerminalContainerView`, der zusätzlich
Finder-Datei-Drops akzeptiert und die Pfade shell-escaped ins PTY schreibt,
ohne automatisch Enter zu senden.

## Ressourcenmonitor

Für laufende Sessions mit registriertem Controller übernimmt dessen
`processID` die Rolle der Root-PID. `AgentResourceMonitor` liest mit `/bin/ps`
PID, Parent-PID, CPU, RSS und Kommando aller Prozesse, traversiert den
Nachfahrenbaum der Root-PID und summiert CPU und RAM pro Session. Die
`AgentResourceSummaryButton`-UI aggregiert weiter nach Projekt und insgesamt;
über das gecachte `hw.memsize` zeigt das Popover zusätzlich den RAM-Anteil.

Das geschlossene Badge aktualisiert alle 10 Sekunden, das offene Popover alle
2 Sekunden. Bei einem inaktiven Fenster stoppt die Polling-Schleife vollständig,
und ein paralleler Refresh wird nicht gestartet. Die `ps`-Ausführung liest
stdout und stderr sequenziell vor `waitUntilExit()` leer — das vermeidet den
häufigsten Deadlock, schützt aber nicht, wenn ein Child zuerst den
stderr-Puffer füllt, während stdout noch bis EOF gelesen wird.

## SwiftTerm-Anpassungen

`QuietableTerminalView` unterdrückt Window-Dragging im Terminalbereich und
fängt den Bell abhängig von `AppPreferences.shared.isTerminalBellEnabled` ab.
Der Metal-Renderer ist ein Opt-in und wird erst aktiviert, wenn die View in
einem Fenster hängt.

Der Scroll-Lock trennt Output-Scrolls von User-Scrolls. Wenn der User im
normalen Buffer vom Tail wegscrollt, merkt die View die gewünschte `yDisp` und
korrigiert output-getriebene Sprünge zurück. Im Alternate Buffer wird immer
Tail-Following erzwungen, weil dort kein normaler Scrollback existiert.

„Am Tail“ heißt zeilengenau am Ende (`TerminalTailFollow`, pur und getestet).
Ein Abwärts-Scroll, der bis zu drei Zeilen vor dem Ende stehen bleibt, rastet
exakt ein. Erst dort beendet SwiftTerm seinen `userScrolling`-Zustand. Die
frühere Toleranz `position >= 0.985` ließ den Viewport dauerhaft ein paar
Zeilen über dem Ende stehen. Dort zeichnete SwiftTerm v1.15 Neuzeichnungen an
Ort und Stelle in die falschen Zeilen: Prompt und Statusblock von Claude Code
blieben stehen, bis ein Klick alles neu zeichnete. Behoben im Fork durch den
Backport von Upstream #620 (Commit `5365a76`). Analyse vom 22.10.2026.

`TerminalScrollGuard` ist ein lokaler ScrollWheel-Monitor. Trifft ein
Scroll-Event das Terminal im Alternate Buffer, sendet er XTerm-SGR-Wheel-Bytes
an das PTY und verschluckt das Original-Event, damit Sidebar oder Tab-Strip
nicht mitschrollen. Im normalen Buffer lässt er das Event an SwiftTerm durch.
Der Repo-Code belegt nur das Senden dieser Bytes; die Reaktion darauf ist
externes Laufzeitverhalten der jeweiligen TUI.

## Keyboard-Profile

`TerminalKeyboardProfile` beschreibt, welche TUI im PTY läuft:
`claudeCodeChat`, `codexChat`, `claudeAgentsView` oder `plainShell`.
`AgentCommandBuilder` setzt das Profil im `AgentLaunchCommand`; der
`TerminalKeyboardShortcutHandler` liest es und übersetzt macOS-Shortcuts in
Bytes.

Die pure `TerminalShortcut.bytes(...)`-Logik mappt unter anderem
Option-Backspace auf `Ctrl+W`, Command-Backspace auf `Ctrl+U`, Command-Z auf
`Ctrl+_`, Option-Pfeile auf `Esc+B`/`Esc+F`, reine Command-Pfeile auf
`Ctrl+A`/`Ctrl+E` und Ctrl-Minus auf `Ctrl+_`. Shift-Enter ist profilabhängig:
Claude-Code- und Codex-Chats bekommen Backslash plus Return für
Multi-Line-Input, `claude agents` bekommt die CSI-u-Sequenz für Shift-Enter,
und `plainShell` lässt Shift-Enter durch.

Option wird nicht global als Meta-Taste aktiviert, damit deutsche
macOS-Sonderzeichen wie `@` oder `{` weiterhin eingegeben werden können.
Einzelne Meta-Kombinationen wie Option-P für Claude/Codex werden deshalb
explizit gemappt.

## Link-Klicks

Die WhisperM8-Integration installiert einen `AgentTerminalLinkInterceptor`,
weil die externe SwiftTerm-Bibliothek `requestOpenLink` nur über den
`terminalDelegate` meldet und nicht an den `processDelegate` weiterreicht
(SwiftTerm-Verhalten, empirisch bestätigt).
Der Interceptor ersetzt den `terminalDelegate`, proxied alle relevanten
Callbacks an die Basis-View und behandelt nur `requestOpenLink` selbst.

`TerminalLinkResolver` ist pure, getestete Routing-Logik. Er unterscheidet
Web-URLs, `file:`-URLs, absolute Pfade, `~`-Pfade, relative Pfade gegen das
Arbeitsverzeichnis, `path:line`/`path:line:col`-Suffixe, nicht vorhandene
Ziele und ungültige Links. Datei-Existenz und Verzeichnistyp kommen als
Closure, damit die Entscheidung ohne echtes Dateisystem testbar bleibt.

Der Controller führt die Action aus: Web-URLs gehen an `NSWorkspace`,
existierende Ordner öffnen im Finder, nicht editorartige Dateien in der
Standard-App, Code-/Text-/Markdown-Dateien über `PhpStormLauncher.open(path:)`
und bei fehlendem PhpStorm per Fallback über `NSWorkspace`. Cmd+Alt-Klick wird
als `revealInFinder` behandelt und markiert das Ziel im Finder statt es zu
öffnen. Fehlende Ziele erzeugen eine eigene Warnung statt des kryptischen
Finder-Fehlers.

## Terminal-Palette

`AgentTerminalPalette` liefert Light- und Dark-Paletten mit Background,
Foreground und ANSI-16-Farben. `AgentTerminalController.applyTheme(for:)`
setzt `nativeBackgroundColor`, `nativeForegroundColor`, Layer-Background und
`installColors(...)` zur Laufzeit. Der Code tauscht die Palette im laufenden
SwiftTerm-Prozess ohne Subprocess-Restart; dass Claude Code, Codex CLI oder
andere TUIs ihre Farben als ANSI-Indizes nutzen, ist externes beziehungsweise
empirisches Laufzeitverhalten und nicht aus den WhisperM8-Quellen ableitbar.

## Grenzen

Scroll bei Streaming ist best effort gegen SwiftTerms Buffer-Verhalten
implementiert. Im normalen Buffer hält WhisperM8 die User-Position, wenn der
User nicht am Tail ist; im Alternate Buffer gibt es keinen Scrollback, daher
wird Wheel-Input an die TUI weitergereicht. Ob Claude Code, Codex oder eine
andere TUI daraus eine interne Viewport-Bewegung macht, ist externes
Laufzeitverhalten.

Selektion und Mouse-Reporting konkurrieren im Terminal grundsätzlich um
Mausereignisse. WhisperM8 verhindert nur, dass Terminal-Textselektion als
Fenster-Drag interpretiert wird, und verschluckt Alternate-Buffer-Scrolls, die
sonst in SwiftUI weiterwandern könnten. Die interne Interpretation von
Klicks, Drags und Wheel-Bytes bleibt bei SwiftTerm beziehungsweise der
laufenden TUI.

Beendete Controller können für Scrollback weiterleben. Deshalb bauen
`releaseEventMonitors()` und `terminate()` Keyboard- und Scroll-Monitore ab,
damit tote PTYs nicht weiter jedes App-Event durchlaufen.

## Schlüsseldateien

- `WhisperM8/Views/AgentTerminalView.swift` enthält SwiftTerm-View, Registry, Controller, Keyboard-Profile, Shortcut-Handler, Scroll-Guard, Link-Ausführung und Datei-Drop.
- `WhisperM8/Views/AgentTerminalPalette.swift` definiert die Light-/Dark-Terminalpaletten und ANSI-16-Farben.
- `WhisperM8/Views/AgentTerminalLinkInterceptor.swift` proxied SwiftTerms `terminalDelegate` und fängt nur Link-Klicks ab.
- `WhisperM8/Views/TerminalLinkResolver.swift` entscheidet pure und getestet, ob ein Terminal-Link als Web-URL, Editor-Datei, Datei, Ordner, Finder-Reveal, Not-Found oder Reject behandelt wird.
- `WhisperM8/Services/AgentChats/AgentResourceMonitor.swift` aggregiert CPU und RSS über den Prozessbaum einer Controller-Root-PID.
- `WhisperM8/Views/AgentResourceSummaryButton.swift` rendert Ressourcen-Badge und Popover und steuert das 10-s-/2-s-Polling.
- `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift` baut `AgentLaunchCommand` inklusive ausführbarem Pfad, Argumenten, Arbeitsverzeichnis und Keyboard-Profil.
- `WhisperM8/Views/AgentSessionDetailView.swift` startet und bindet interaktive Terminal-Sessions in der Agent-Chat-Detailfläche.

## Keywords

Terminal, SwiftTerm, LocalProcessTerminalView, PTY, Terminal-Controller,
Terminal-Registry, Keyboard-Profil, Claude Code Terminal, Codex Terminal,
Claude Agent View, Shell beendet, Datei-Drop, Link-Klick, Cmd-Klick,
Cmd+Alt-Klick, Finder Reveal, PhpStorm, Terminal-Palette, Light Mode,
Dark Mode, ANSI-16, Scroll-Lock, Streaming-Scroll, Alternate Buffer,
Mouse-Reporting, `AgentTerminalView`, `AgentTerminalController`,
`AgentTerminalRegistry`, `QuietableTerminalView`, `TerminalScrollGuard`,
`TerminalKeyboardProfile`, `TerminalKeyboardShortcutHandler`,
`TerminalShortcut`, `TerminalDropPayload`, `AgentTerminalContainerView`,
`AgentTerminalPalette`, `AgentTerminalLinkInterceptor`,
`TerminalLinkResolver`, `PhpStormLauncher`, `AgentLaunchCommand`,
`AgentCommandBuilder`, `AgentSessionDetailView`, Ressourcenmonitor,
CPU-Monitoring, RAM-Monitoring, RSS, RAM Share, Prozessbaum, Root-PID,
`/bin/ps`, `hw.memsize`, `AgentResourceMonitor`,
`AgentResourceSummaryButton`, 10-Sekunden-Polling, 2-Sekunden-Polling,
inaktives Fenster, Pipe-Drain, `waitUntilExit()`, Child-Deadlock.

## Betriebswissen aus CLAUDE.md

*Am 19.10.2026 wörtlich aus der Projekt-CLAUDE.md übernommen (LR-DOK-008); dort stehen nur noch die Arbeitsregeln. Beim nächsten Überarbeiten dieser Seite in den Fließtext einarbeiten.*

- **Foreground chats**: SwiftTerm `LocalProcessTerminalView` PTYs, managed by `AgentTerminalRegistry` (in `Views/AgentTerminalView.swift`). `AgentCommandBuilder` builds argv (claude/codex, resume vs. new session, keyboard profile per TUI type). **Link-Klicks** (Cmd-Klick; Cmd+Alt = im Finder zeigen): SwiftTerm reicht `requestOpenLink` NICHT an den `processDelegate` weiter, und der Extension-Default (`URL(string:)+NSWorkspace.open`) scheitert bei schemelosen Dateipfaden mit `-50`. Deshalb ersetzt `AgentTerminalLinkInterceptor` den `terminalDelegate` (proxied alle Callbacks 1:1 an die Basis — so bleibt z. B. der Scroll-Lock erhalten — und fängt nur Links ab). **Der Proxy bleibt auch nach SwiftTerm 1.15 nötig**, obwohl PR #599 `requestOpenLink` inzwischen als `open` nachreicht: er verweigert zusätzlich `clipboardRead` (OSC 52), das sonst jeder TUI den Klartext der Zwischenablage gäbe — und das ist `public`, nicht `open`, also per Subclass nicht abschaltbar und routet über den puren, getesteten `TerminalLinkResolver` (Views/): Web→Browser, Code/Markdown→PhpStorm (`PhpStormLauncher`, Services/Shared), sonstige Datei→Standard-App, Ordner→Finder, fehlend→klare `NSAlert`; relative Pfade gegen `command.workingDirectory`, `~` und `path:line`-Suffixe aufgelöst.
- **SwiftTerm** — PTY terminal views for Agent Chats. Eigener Fork, gepinnt auf v1.15.0 + 2 Selection-Patches (Branch `whisperm8-v1.15-patches`); Begründung im Kommentar in `Package.swift`. Der **Metal-GPU-Renderer bleibt Opt-in (Default aus)**: die Absturzgründe sind mit v1.15 weg (#593, #598), aber im Feldtest 01.08.2026 litt das Schriftbild sichtbar („low resolution") — nicht die Auflösung (die stimmt), vermutlich Font-Smoothing auf transparentem Grund plus Pixel-Rundung der Glyph-Positionen. Der Gewinn ist mangels A/B-Messung unbelegt; Rückkehr erst, wenn das Messgerüst (docs/plans/workspace-performance/, Paket A4) einen Gewinn zeigt. Einschalten zum Vergleichen: `defaults write com.whisperm8.app agentTerminalMetalEnabled -bool YES` (wirkt nach App-Neustart). `TerminalMetalWarmup` übersetzt SwiftTerms Shader — die als Quelltext ausgeliefert werden — beim Start im Hintergrund vor, sonst kostet der erste Chat einmalig ~262 ms auf dem Main Thread; es läuft nur bei aktivem Metal.
