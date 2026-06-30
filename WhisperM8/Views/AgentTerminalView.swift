import AppKit
import SwiftTerm
import SwiftUI

/// `LocalProcessTerminalView`-Subklasse die den Bell-Sound abfaengt.
/// `scrollWheel` ist in SwiftTerm leider `public override` (nicht `open`) —
/// daher kann es nicht via Subclass abgefangen werden. Stattdessen nutzt
/// `TerminalScrollGuard` (siehe unten) einen NSEvent-Monitor.
///
/// **Scroll-Lock waehrend Streaming:** SwiftTerm's `Terminal.userScrolling`-
/// Flag entscheidet, ob neuer Output `yDisp` (Display-Top) auf `yBase`
/// (Cursor-Position) zurueckzieht. Das Flag wird aber NUR beim Scrollbar-Drag
/// gesetzt — beim Trackpad-Wheel-Scroll bleibt es false. Folge: liest der User
/// gerade aelteren Output, springt die View bei jeder neuen Zeile zurueck
/// nach unten. Wir machen das selber, indem wir die beiden Delegate-Pfade
/// trennen: `scrolled(source: Terminal, yDisp:)` feuert nur bei Output
/// (Terminal.scroll()), `scrolled(source: TerminalView, position:)` feuert
/// auch bei User-Wheel/Scrollbar. Daraus laesst sich rekonstruieren, wann
/// der User „weg vom Tail" gegangen ist, und wir korrigieren die
/// Output-getriebenen Spruenge zurueck zur User-Position.
final class QuietableTerminalView: LocalProcessTerminalView {
    /// The Agent Chats window is movable by its background because the titlebar
    /// is hidden. Terminal text selection must never fall through to that
    /// window-drag behavior.
    override var mouseDownCanMoveWindow: Bool { false }

    /// P6 S5: SwiftTerms Metal-GPU-Renderer als Opt-in (Default: aus).
    /// Einmal pro Prozess gelesen — Umschalten erfordert App-Neustart.
    private static let metalRendererOptIn = AppPreferences.shared.isAgentTerminalMetalRendererEnabled

    /// Aktivierung erst, wenn die View im Window hängt — in makeNSView ist
    /// der Container noch fensterlos und die MTKView hätte keine Surface.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard Self.metalRendererOptIn, window != nil, !isUsingMetalRenderer else { return }
        do {
            try setUseMetal(true)
            Logger.agentPerformance.info("terminal_metal_renderer_enabled")
        } catch {
            Logger.agentPerformance.warning("terminal_metal_renderer_failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    /// `true`, solange der User nahe genug am Buffer-Ende ist, dass neuer
    /// Output sichtbar bleiben soll. Faellt auf `false`, sobald der User
    /// hochscrollt; wird wieder `true`, sobald er bewusst ans Ende
    /// zurueckkehrt.
    private var isFollowingTail: Bool = true

    /// Die Display-Row, an der der User stehen wollte, als er das Tail-
    /// Following verlassen hat. Nach jedem Output-getriggerten Scroll
    /// stellen wir sie wieder her.
    private var preservedYDisp: Int?

    /// Reentry-Guards: `scrollTo(row:)` ruft die TerminalView-Variante von
    /// `scrolled` rekursiv auf — wir wollen den Status dann NICHT als
    /// User-Scroll werten.
    private var isRestoringScroll: Bool = false
    private var isOutputScrollInFlight: Bool = false

    /// Toleranz: ab `scrollPosition >= bottomThreshold` gilt der User als
    /// „am Tail". Wir lassen ein bisschen Luft, damit Sub-Pixel-Float-
    /// Vergleiche nicht jeden Klick als „nicht ganz unten" markieren.
    private static let bottomThreshold: Double = 0.985

    override func bell(source: Terminal) {
        guard AppPreferences.shared.isTerminalBellEnabled else { return }
        super.bell(source: source)
    }

    /// Wird AUSSCHLIESSLICH vom Output-Pfad (`Terminal.scroll()`) gerufen —
    /// SwiftTerm hat fuer User-getriggerte Scrolls einen anderen Code-Pfad,
    /// der diese Variante nicht feuert. Damit ist hier garantiert: jedes
    /// Eintreffen bedeutet „neue Output-Zeile, yDisp wurde gerade auf yBase
    /// gezogen". Wenn der User vorher oben stand, korrigieren wir den
    /// Sprung sofort wieder zurueck.
    override func scrolled(source terminal: Terminal, yDisp: Int) {
        isOutputScrollInFlight = true
        super.scrolled(source: terminal, yDisp: yDisp)
        isOutputScrollInFlight = false

        // Alt-Buffer (TUI-Modus) hat keinen Scrollback — Auto-Follow ist
        // die einzige sinnvolle Option. Trackpad-Wheel-Events werden ueber
        // `TerminalScrollGuard` als XTerm-SGR-Bytes an die TUI weitergegeben.
        if terminal.isCurrentBufferAlternate {
            isFollowingTail = true
            preservedYDisp = nil
            return
        }

        guard !isFollowingTail,
              let preserved = preservedYDisp,
              preserved < yDisp,
              !isRestoringScroll
        else { return }

        // scrollTo(row:) feuert wieder die TerminalView-Variante; ohne den
        // Reentry-Guard wuerde sie dort die User-Position ueberschreiben.
        isRestoringScroll = true
        scrollTo(row: preserved, notifyAccessibility: false)
        isRestoringScroll = false
    }

    /// Feuert bei JEDEM Scroll (User UND Output). Wir filtern Output-
    /// Reentrys ueber die Flags und behandeln nur „echte" User-Aktionen
    /// (Trackpad-Wheel, Scrollbar-Drag, Page-Up/Down).
    override func scrolled(source: TerminalView, position: Double) {
        super.scrolled(source: source, position: position)

        if isRestoringScroll || isOutputScrollInFlight { return }
        if getTerminal().isCurrentBufferAlternate {
            isFollowingTail = true
            preservedYDisp = nil
            return
        }

        if position >= Self.bottomThreshold {
            isFollowingTail = true
            preservedYDisp = nil
        } else {
            isFollowingTail = false
            preservedYDisp = getTerminal().getTopVisibleRow()
        }
    }
}

/// Faengt Mausrad-Events VOR der Dispatch zur SwiftTerm-View ab.
///
/// **Problem 1 — Propagation-Leak:** TUIs wie `claude agents` rendern im
/// Alternate-Screen-Buffer der per Definition keinen Scrollback hat.
/// SwiftTerm's Default-`scrollWheel` macht in Alt-Buffer-Mode zwar visuell
/// nichts, aber das Event kann in unerwartete SwiftUI/NSResponder-Stellen
/// propagieren (User berichtet: Trackpad-Scroll im `claude agents`-Chat
/// bewegt die Sidebar/Prompt-History).
///
/// **Problem 2 — Stuck im Viewport:** der User kann lange Claude-Antworten
/// nicht hochscrollen, weil Alt-Buffer = kein Scrollback.
///
/// **Strategie:**
/// 1. Wenn Terminal die scroll-Target-View ist UND wir im Alt-Buffer sind:
/// 2. Wir senden XTerm-SGR-Mouse-Wheel-Bytes ans PTY (Button 64/65) — das
///    folgt dem XTerm/iTerm-Standard fuer Wheel-Reporting. Apps wie Claude
///    Code / Ink koennen darauf reagieren (Scroll der eigenen Viewport).
/// 3. Wir verschlucken das Original-Event hart (return nil) — keine
///    Propagation zur Sidebar.
///
/// Im normalen Buffer (echter Scrollback): Event durchreichen damit
/// SwiftTerm's natuerliches Scrollen weiterhin funktioniert.
@MainActor
final class TerminalScrollGuard {
    private weak var terminalView: LocalProcessTerminalView?
    private var monitor: Any?
    /// Akkumulator fuer kontinuierliche Trackpad-Deltas — wir feuern erst
    /// einen SGR-Event pro "Schwelle", damit wir Claude nicht mit
    /// Mikro-Bytes ueberfluten.
    private var pendingDeltaY: CGFloat = 0
    private static let scrollThreshold: CGFloat = 1.0

    init(attachedTo terminalView: LocalProcessTerminalView) {
        self.terminalView = terminalView
        self.monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    /// P6 S4: Expliziter Abbau — Controller beendeter Prozesse leben für den
    /// Scrollback weiter, ihre app-weiten Monitore sollen das nicht.
    func detach() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    /// Liefert `nil` zurueck, wenn das Event verschluckt wurde (Alt-Buffer-Mode).
    /// Sonst das Original-Event fuer den normalen Dispatch.
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let terminal = terminalView,
              let window = terminal.window,
              event.window === window
        else {
            return event
        }

        // Nur greifen wenn das Terminal-View die scroll-Target-View ist —
        // sonst sollen Sidebar / Tab-Strip ihre eigene Scrolls bekommen.
        guard isEventTargetingTerminal(event: event, window: window, terminal: terminal) else {
            return event
        }

        // Alt-Buffer? Dann XTerm-SGR-Wheel-Bytes ans PTY senden und
        // Original-Event verschlucken.
        if terminal.getTerminal().isCurrentBufferAlternate {
            forwardWheelToTerminal(event: event, terminal: terminal)
            return nil
        }

        return event
    }

    /// Sendet XTerm-SGR-Mouse-Wheel-Sequenzen ans PTY. SwiftTerm's eigene
    /// Mouse-Reporting-Pipeline reagiert nur auf Click+Drag — Wheel ist
    /// nicht im Default-Pfad. Wir bauen die Bytes selbst:
    ///
    ///   `ESC [ < 64 ; col ; row M`  (Wheel Up, Press)
    ///   `ESC [ < 65 ; col ; row M`  (Wheel Down, Press)
    ///
    /// Spalte/Reihe sind 1-basiert. Wir nehmen die Cursor-Position als
    /// Approximation — Ink-TUIs ignorieren die Koordinaten ohnehin und
    /// nutzen nur den Button-Code.
    ///
    /// Wir akkumulieren Trackpad-Deltas und feuern erst bei Schwellen-
    /// Erreichen, damit das PTY nicht mit Mikro-Bytes ueberflutet wird.
    private func forwardWheelToTerminal(event: NSEvent, terminal: LocalProcessTerminalView) {
        // Trackpad liefert oft Sub-Linien-Deltas; mit `scrollingDeltaY` (Float)
        // statt `deltaY` (Int) bleiben wir praeziser.
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY * 10
        guard delta != 0 else { return }

        pendingDeltaY += delta
        while abs(pendingDeltaY) >= Self.scrollThreshold {
            let direction: Int = pendingDeltaY > 0 ? 64 : 65
            sendWheelByte(button: direction, terminal: terminal)
            pendingDeltaY -= (pendingDeltaY > 0 ? Self.scrollThreshold : -Self.scrollThreshold)
        }
    }

    private func sendWheelByte(button: Int, terminal: LocalProcessTerminalView) {
        // 1-basierte Koordinaten — die meisten TUIs ignorieren sie bei Wheel.
        let col = 1
        let row = 1
        let press = "\u{1b}[<\(button);\(col);\(row)M"
        terminal.send(txt: press)
    }

    /// Wir laufen den Hit-Test im Window-Koordinaten-System um zu pruefen
    /// ob die scroll-Maus-Position innerhalb des Terminal-NSViews liegt.
    private func isEventTargetingTerminal(
        event: NSEvent,
        window: NSWindow,
        terminal: LocalProcessTerminalView
    ) -> Bool {
        let pointInWindow = event.locationInWindow
        guard let hitView = window.contentView?.hitTest(pointInWindow) else { return false }
        // hitView kann das Terminal direkt sein oder eine Subview davon
        // (z. B. SwiftTerm's CaretView). Wir checken die Parent-Hierarchie.
        var current: NSView? = hitView
        while let v = current {
            if v === terminal { return true }
            current = v.superview
        }
        return false
    }
}

@MainActor
final class AgentTerminalRegistry: ObservableObject {
    /// Geteilte Instanz, damit View-Bäume außerhalb von `AgentChatsView`
    /// (insbesondere der MenuBarExtra) dieselben laufenden Vordergrund-PTYs
    /// erreichen — Voraussetzung für ein globales "Stop all".
    static let shared = AgentTerminalRegistry()

    @Published private var controllers: [UUID: AgentTerminalController] = [:]

    var activeSessionIDs: Set<UUID> {
        Set(controllers.values.filter(\.isRunning).map(\.sessionID))
    }

    var runningControllers: [AgentTerminalController] {
        controllers.values
            .filter(\.isRunning)
            .sorted { $0.sessionID.uuidString < $1.sessionID.uuidString }
    }

    func controller(for sessionID: UUID) -> AgentTerminalController? {
        controllers[sessionID]
    }

    @discardableResult
    func startController(
        sessionID: UUID,
        command: AgentLaunchCommand,
        onLaunched: @escaping () -> Void,
        onTerminated: @escaping (Int32?) -> Void
    ) -> AgentTerminalController {
        if let controller = controllers[sessionID], controller.isRunning {
            return controller
        }

        let controller = AgentTerminalController(
            sessionID: sessionID,
            command: command,
            onLaunched: onLaunched,
            onTerminated: onTerminated
        )
        controllers[sessionID] = controller
        controller.start()
        return controller
    }

    func terminate(sessionID: UUID) {
        controllers[sessionID]?.terminate()
        controllers[sessionID] = nil
    }

    /// Terminiert alle laufenden Vordergrund-PTYs (je Controller graceful:
    /// 2× Ctrl+C → Kill) und gibt die betroffenen Session-IDs zurück. Iteriert
    /// über einen Snapshot der IDs, damit das Mutieren von `controllers`
    /// während des Loops sicher ist.
    @discardableResult
    func terminateAll() -> [UUID] {
        let ids = runningControllers.map(\.sessionID)
        for id in ids {
            terminate(sessionID: id)
        }
        return ids
    }
}

/// Welche TUI laeuft im PTY? Bestimmt die Byte-Sequenzen, die wir fuer
/// bestimmte Combos schicken (insbesondere Shift+Enter).
///
/// - `claudeCodeChat` / `codexChat`: interaktive Chat-TUIs, die Multi-Line-
///   Input via Backslash-Continuation (`\<CR>`) akzeptieren.
/// - `claudeAgentsView`: `claude agents` Dashboard mit eigenem Input-Field
///   ohne Backslash-Konvention. Erwartet die moderne CSI-u-Sequenz fuer
///   Shift+Enter (`ESC [ 13 ; 2 u`, kitty keyboard protocol).
enum TerminalKeyboardProfile: Equatable {
    case claudeCodeChat
    case codexChat
    case claudeAgentsView
}

/// Reine Übersetzungs-Logik von macOS-Tastenkombinationen in die TUI-üblichen
/// Control-Sequences, wie sie Claude Code, Codex CLI (beide Ink-basiert) und
/// Readline-Tools erwarten. Window-frei testbar.
///
/// **Mappings (siehe Plan-File):**
/// - `Option+Backspace` → `Ctrl+W` (`0x17`) — backward-kill-word
/// - `Command+Backspace` → `Ctrl+U` (`0x15`) — unix-line-discard
/// - `Command+Z` (ohne Shift) → `Ctrl+_` (`0x1f`) — readline-undo
/// - `Option+←` / `→` → `Esc+B` / `Esc+F` — Wort-Cursorbewegung
/// - `Command+←` / `→` (ohne Option) → `Ctrl+A` / `Ctrl+E` — Zeilenanfang / -ende
///   (`Command+Option+←` / `→` wird bewusst durchgereicht — der Agent-Chats-
///   Window-Monitor nutzt es für den Tab-Wechsel)
/// - `Shift+Enter` (Chat-Profile) → `\` + `CR` — Backslash-Continuation
/// - `Shift+Enter` (Agents-View) → `ESC [ 13 ; 2 u` — kitty/CSI-u
enum TerminalShortcut {
    /// Virtual-Key-Codes (NSEvent.keyCode) der relevanten Tasten.
    enum KeyCode {
        public static let z: UInt16 = 6
        public static let p: UInt16 = 35
        public static let returnKey: UInt16 = 36
        public static let delete: UInt16 = 51   // Backspace
        public static let leftArrow: UInt16 = 123
        public static let rightArrow: UInt16 = 124
    }

    /// Übersetzt eine Tastenkombination in Bytes für das Terminal.
    /// Liefert `nil`, wenn die Combo nicht abgefangen werden soll
    /// (Original-Event geht dann durch zur NSResponder-Pipeline).
    static func bytes(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        characters: String?,
        profile: TerminalKeyboardProfile = .claudeCodeChat
    ) -> [UInt8]? {
        let hasOption = modifiers.contains(.option)
        let hasCommand = modifiers.contains(.command)
        let hasControl = modifiers.contains(.control)
        let hasShift = modifiers.contains(.shift)

        // Ctrl+- (bzw. Ctrl+_) → Readline-Undo (`Ctrl+_` = 0x1f).
        // SwiftTerm sendet Ctrl+_ nur, wenn `charactersIgnoringModifiers == "_"`.
        // Auf deutscher Tastatur liefert die Minus-Taste aber "-" und SwiftTerm
        // verwirft das Event komplett — Undo per Ctrl+- funktioniert dadurch nie.
        if hasControl && !hasCommand && !hasOption,
           let ch = characters,
           ch == "-" || ch == "_" {
            return [0x1f]
        }

        // Cmd-Combos kollidieren mit Ctrl-Combos auf TUI-Ebene → wenn Control gehalten
        // wird, immer durchreichen (User will die Standard-Control-Sequence).
        guard !hasControl else { return nil }

        switch keyCode {
        case KeyCode.delete:
            if hasOption && !hasCommand { return [0x17] }   // Ctrl+W
            if hasCommand { return [0x15] }                  // Ctrl+U
        case KeyCode.leftArrow:
            if hasOption && !hasCommand { return [0x1b, 0x62] }  // Esc+B
            // Nur reines Cmd+← → Ctrl+A. Cmd+Option+← bleibt frei für den
            // Tab-Wechsel (vom Agent-Chats-Window-Monitor abgefangen).
            if hasCommand && !hasOption { return [0x01] }         // Ctrl+A
        case KeyCode.rightArrow:
            if hasOption && !hasCommand { return [0x1b, 0x66] }  // Esc+F
            // Nur reines Cmd+→ → Ctrl+E. Cmd+Option+→ bleibt frei für den
            // Tab-Wechsel (vom Agent-Chats-Window-Monitor abgefangen).
            if hasCommand && !hasOption { return [0x05] }         // Ctrl+E
        case KeyCode.z:
            // Cmd+Shift+Z (Redo) bewusst durchreichen — Readline kennt kein Redo.
            if hasCommand && !hasShift,
               characters?.lowercased() == "z" {
                return [0x1f]   // Ctrl+_ (Readline-undo)
            }
        case KeyCode.returnKey:
            // Shift+Enter braucht je nach TUI unterschiedliche Sequenzen.
            // Ohne Eingriff sendet SwiftTerm bei Enter und Shift+Enter
            // identisch nur `\r`.
            if hasShift && !hasOption && !hasCommand {
                switch profile {
                case .claudeCodeChat, .codexChat:
                    // Backslash-Continuation: Claude Code und Codex CLI
                    // akzeptieren `\<CR>` als Multi-Line-Input.
                    return [0x5c, 0x0d]
                case .claudeAgentsView:
                    // `claude agents` hat ein eigenes Input-Field ohne
                    // Backslash-Konvention. Es nutzt das kitty keyboard
                    // protocol (`/terminal-setup` aktiviert es automatisch
                    // bei Claude Code installs) und erwartet die CSI-u-
                    // Sequenz `ESC [ 13 ; 2 u` fuer Shift+Enter.
                    return [0x1b, 0x5b, 0x31, 0x33, 0x3b, 0x32, 0x75]
                }
            }
        case KeyCode.p:
            // Alt+P → `ESC p` (Meta-P), Claude Codes Model-Switch.
            // Ohne Mapping würde `optionAsMetaKey=false` das macOS-Sonderzeichen
            // `π` an die TUI schicken, statt der erwarteten Meta-Sequenz.
            if hasOption && !hasCommand && !hasShift {
                return [0x1b, 0x70]
            }
        default:
            break
        }

        return nil
    }
}

/// Bindet `TerminalShortcut` an einen konkreten `LocalProcessTerminalView` an.
/// Verantwortlich für NSEvent-Monitor-Lifecycle, Window-/firstResponder-Gating
/// und das eigentliche Senden der Bytes ans Terminal.
///
/// Wird genutzt anstelle eines `keyDown`-Subclass-Overrides, weil SwiftTerms
/// `keyDown` zwar `public override`, aber nicht `open` ist — externes
/// Subclassing scheidet aus.
@MainActor
final class TerminalKeyboardShortcutHandler {
    private weak var terminalView: LocalProcessTerminalView?
    private let profile: TerminalKeyboardProfile
    private var monitor: Any?

    /// Wird bei jedem KeyDown gerufen, der an unsere Terminal-View geht
    /// (also wenn die View `firstResponder` ist) — unabhaengig davon, ob das
    /// Event von unserem Shortcut-Handler konsumiert oder von SwiftTerms
    /// Default-Pfad weiterverarbeitet wird. Dient als „User tut gerade was
    /// in der TUI"-Signal fuer externe Observer (z. B. den
    /// `ActiveBackgroundSessionTracker`, der dadurch sofort refreshen kann).
    var onAnyTerminalKeyDown: (() -> Void)?

    init(
        attachedTo terminalView: LocalProcessTerminalView,
        profile: TerminalKeyboardProfile
    ) {
        self.terminalView = terminalView
        self.profile = profile
        self.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    /// P6 S4: Expliziter Abbau — siehe TerminalScrollGuard.detach().
    func detach() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    /// Liefert `nil` zurück, wenn das Event konsumiert wurde (Sequence wurde an die PTY geschickt),
    /// ansonsten das Original-Event für die normale NSResponder-Pipeline.
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let terminal = terminalView,
              let window = terminal.window,
              event.window === window,
              window.firstResponder === terminal
        else {
            return event
        }

        // Listener feuert unabhaengig davon, ob unser Shortcut-Mapping greift —
        // SwiftTerm verarbeitet Standardtasten (Pfeil, Enter, Buchstabe) selbst,
        // wir wollen aber auch DIESE Aktionen als "User-Aktivitaet" wissen.
        onAnyTerminalKeyDown?()

        guard let bytes = TerminalShortcut.bytes(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags,
            characters: event.charactersIgnoringModifiers,
            profile: profile
        ) else {
            return event
        }

        terminal.send(bytes)
        return nil
    }
}

@MainActor
final class AgentTerminalController: NSObject, ObservableObject, Identifiable, @preconcurrency LocalProcessTerminalViewDelegate {
    let id = UUID()
    let sessionID: UUID
    let terminal = QuietableTerminalView(frame: .zero)
    let command: AgentLaunchCommand
    private var keyboardShortcutHandler: TerminalKeyboardShortcutHandler?
    private var scrollGuard: TerminalScrollGuard?

    @Published private(set) var isRunning = false
    @Published private(set) var hasStarted = false
    @Published private(set) var exitCode: Int32?

    var processID: Int32? {
        let pid = terminal.process.shellPid
        return pid > 0 ? pid : nil
    }

    private var onLaunched: () -> Void
    private var onTerminated: (Int32?) -> Void
    private var themeObserver: NSObjectProtocol?

    init(
        sessionID: UUID,
        command: AgentLaunchCommand,
        onLaunched: @escaping () -> Void,
        onTerminated: @escaping (Int32?) -> Void
    ) {
        self.sessionID = sessionID
        self.command = command
        self.onLaunched = onLaunched
        self.onTerminated = onTerminated
        super.init()
        terminal.processDelegate = self

        // Initial-Theme an die aktuelle ColorScheme koppeln. Wird bei jedem
        // macOS-Erscheinungsbild-Wechsel oder User-Override-Toggle aktualisiert.
        applyTheme(for: ThemeManager.shared.resolvedColorScheme)
        themeObserver = NotificationCenter.default.addObserver(
            forName: AgentTerminalController.themeDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let scheme = notification.userInfo?["scheme"] as? ColorScheme else { return }
            Task { @MainActor [weak self] in
                self?.applyTheme(for: scheme)
            }
        }

        // Option-Taste NICHT als Meta-Modifikator behandeln, sonst schluckt
        // SwiftTerm die deutschen Sonderzeichen (Option+L=@, Option+8={, …).
        terminal.optionAsMetaKey = false

        // macOS-Edit-Shortcuts (Option/Command+Backspace, Word-Move, Undo) in
        // Claude-Code-/Codex-/Readline-kompatible Control-Sequences übersetzen.
        // Profil aus dem Launch-Command — bestimmt z. B. ob Shift+Enter als
        // Backslash-Continuation (Chat-TUIs) oder als CSI-u (`claude agents`)
        // an die TUI geht.
        keyboardShortcutHandler = TerminalKeyboardShortcutHandler(
            attachedTo: terminal,
            profile: command.keyboardProfile
        )

        // Scroll-Guard: blockt Trackpad-Scrolls in Alt-Buffer-Mode (z. B.
        // `claude agents` TUI) damit das Event nicht in die SwiftUI-Sidebar
        // bzw. Tab-Strip propagiert, und forwardet sie als XTerm-SGR-Wheel-
        // Bytes an die TUI. Im normalen Buffer (echter Scrollback) bleibt
        // das Default-Scroll von SwiftTerm aktiv.
        scrollGuard = TerminalScrollGuard(attachedTo: terminal)
    }

    deinit {
        if let themeObserver {
            NotificationCenter.default.removeObserver(themeObserver)
        }
    }

    /// Wird vom Caller aufgerufen, wenn die externe Session-ID (Claude
    /// conversation UUID / Codex rollout id) waehrend der Laufzeit gebunden
    /// oder umgebunden wird. Aktuell ein No-op — wir speichern die ID nur
    /// im Store, die Transcript-Ansicht liest sie von dort.
    func updateExternalSessionID(_ id: String?) {
        _ = id
    }

    /// Wechselt Terminal-Background + Foreground + 16-Color-ANSI-Palette zur
    /// Laufzeit, ohne den Subprocess neu zu starten. Claude Code / Codex CLI
    /// emittieren ANSI-Color-Indizes (z. B. `ESC[31m` für Rot) — der
    /// tatsächliche RGB-Wert kommt aus `installColors`, daher reicht ein
    /// In-Process-Palette-Swap.
    func applyTheme(for scheme: ColorScheme) {
        let palette = AgentTerminalPalette.palette(for: scheme)
        terminal.nativeBackgroundColor = palette.background
        terminal.nativeForegroundColor = palette.foreground
        terminal.layer?.backgroundColor = palette.background.cgColor
        terminal.installColors(palette.ansi16)
        terminal.needsDisplay = true
    }

    /// Broadcast vom `ThemeManager`, wenn sich das resolved Color-Scheme
    /// ändert (System-Wechsel oder User-Override).
    static let themeDidChangeNotification = Notification.Name("AgentTerminalController.themeDidChange")

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        isRunning = true
        // Korrigierter PATH (siehe LoginShellEnvironment) verhindert, dass
        // Claude/Codex in einem Subprocess landen, der `git`, `npm`, `mise`-shims
        // nicht findet, weil macOS' launchd uns mit minimalem ENV gestartet hat.
        terminal.startProcess(
            executable: command.executablePath,
            args: command.arguments,
            environment: LoginShellEnvironment.shared.terminalEnvironmentArray(),
            currentDirectory: command.workingDirectory
        )
        onLaunched()
    }

    func terminate() {
        // Graceful Claude/Codex-Quit: zwei Ctrl+C senden + kurze Wartezeit,
        // damit die TUI ihre eigene Exit-Routine durchlaeuft (Resume-Hinweis,
        // letzter JSONL-Flush) bevor wir den Subprocess hart killen.
        if isRunning {
            terminal.send([0x03])
            usleep(80_000)
            terminal.send([0x03])
            usleep(180_000)
        }
        terminal.terminate()
        isRunning = false
        releaseEventMonitors()
    }

    /// P6 S4: Die app-weiten NSEvent-Monitore (Keyboard-Shortcuts +
    /// Scroll-Guard) werden beim Prozess-Ende abgebaut. Der Controller lebt
    /// fuer den Scrollback weiter — aber ein totes PTY braucht weder
    /// Shortcut-Mapping noch Alt-Buffer-Scroll-Forwarding, und vorher lief
    /// jedes Event der App durch die Monitore ALLER jemals beendeten Tabs.
    private func releaseEventMonitors() {
        keyboardShortcutHandler?.detach()
        keyboardShortcutHandler = nil
        scrollGuard?.detach()
        scrollGuard = nil
    }

    /// Setzt einen Listener auf jeden User-Tastendruck, der an die Terminal-
    /// View geht. Wird vom `AgentChatsView` fuer `.agentView`-TUI-Tabs
    /// benutzt, um den `ActiveBackgroundSessionTracker` sofort zu
    /// "nudgen", wenn der User in der TUI navigiert/attached — statt nur
    /// alle paar Sekunden zu pollen. `nil` setzen entfernt den Listener.
    func setUserKeystrokeListener(_ closure: (() -> Void)?) {
        keyboardShortcutHandler?.onAnyTerminalKeyDown = closure
    }

    /// Macht die `LocalProcessTerminalView` zum Window-`firstResponder`, sodass
    /// Tasteneingaben direkt im PTY landen statt z. B. im Sidebar-Filter-Feld
    /// hängen zu bleiben. Async-dispatch, damit der Aufruf nach dem aktuellen
    /// SwiftUI-Render-Cycle ausgeführt wird — sonst kann das Terminal-NSView
    /// noch gar nicht in der Window-Hierarchie sein, und `makeFirstResponder`
    /// greift ins Leere.
    func focusTerminal() {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let window = self.terminal.window else { return }
            window.makeFirstResponder(self.terminal)
        }
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    /// Cmd-Klick auf einen erkannten Link/Pfad im Terminal. SwiftTerms
    /// Default-Implementierung würde den rohen String durch `URL(string:) +
    /// NSWorkspace.open` schicken — was bei schemelosen Dateipfaden mit `-50`
    /// (paramErr) scheitert und bei Leerzeichen/Umlauten still nichts tut. Wir
    /// routen stattdessen sauber (`TerminalLinkResolver`): Browser-Links bleiben
    /// Browser-Links, Dateien öffnen mit der Standard-App, Ordner im Finder,
    /// fehlende Ziele bekommen eine klare Meldung. **Cmd+Alt** zeigt das Ziel
    /// nur im Finder, statt es zu öffnen.
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        let revealInFinder = NSEvent.modifierFlags.contains(.option)
        let action = TerminalLinkResolver.resolve(
            link: link,
            workingDirectory: command.workingDirectory,
            revealInFinder: revealInFinder,
            fileStatus: { path in
                var isDir: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
                return TerminalLinkResolver.FileStatus(exists: exists, isDirectory: isDir.boolValue)
            }
        )
        perform(action)
    }

    private func perform(_ action: TerminalLinkResolver.Action) {
        switch action {
        case .openWeb(let url), .openFile(let url), .openFolder(let url):
            // Datei → Standard-App, Ordner → Finder, Web → Browser: alles über
            // denselben sauberen Open-Pfad (im Gegensatz zu SwiftTerms `URL(string:)`).
            NSWorkspace.shared.open(url)
        case .revealInFinder(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .notFound(let path):
            Logger.terminalSnapshot.debug("terminal_link_not_found path=\(path, privacy: .public)")
            Self.presentLinkAlert(
                title: "Datei nicht gefunden",
                message: "Das verlinkte Ziel existiert nicht (mehr):\n\(path)"
            )
        case .reject(let reason):
            // Bewusste Ablehnung (leerer/relativer-ohne-Basis/kaputter Link) —
            // kein Modal, nur Telemetrie.
            Logger.terminalSnapshot.debug("terminal_link_rejected reason=\(reason, privacy: .public)")
        }
    }

    /// Klare, eigene Fehlermeldung statt des kryptischen Finder-`-50`-Dialogs.
    private static func presentLinkAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in
            self.exitCode = exitCode
            self.isRunning = false
            self.releaseEventMonitors()
            self.onTerminated(exitCode)
        }
    }
}

struct AgentTerminalView: NSViewRepresentable {
    @ObservedObject var controller: AgentTerminalController

    func makeNSView(context: Context) -> NSView {
        let container = AgentTerminalContainerView(frame: .zero)
        container.terminal = controller.terminal
        attach(controller.terminal, to: container)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let container = nsView as? AgentTerminalContainerView {
            container.terminal = controller.terminal
        }
        attach(controller.terminal, to: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        nsView.subviews.forEach { $0.removeFromSuperview() }
    }

    private func attach(_ terminal: LocalProcessTerminalView, to container: NSView) {
        container.subviews
            .filter { $0 !== terminal }
            .forEach { $0.removeFromSuperview() }

        guard terminal.superview !== container else { return }
        terminal.removeFromSuperview()
        terminal.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminal)

        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            terminal.topAnchor.constraint(equalTo: container.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }
}

/// NSView-Container, der `LocalProcessTerminalView` wrappt **und**
/// Finder-Drag-Drop akzeptiert. SwiftTerm selbst registriert keine
/// Drag-Types — beim direkten Drop auf das Terminal landet die Datei sonst
/// einfach im Nichts.
///
/// Verhalten orientiert sich an `Terminal.app`: gedroppte Datei-Pfade werden
/// als Shell-escaped String an die PTY geschrieben, sodass der User sie sofort
/// in einen Befehl einbauen kann (`@<pfad>` für Claude Code, oder einfach in
/// der nächsten Eingabe zitieren). Mehrere Dateien werden mit Leerzeichen
/// getrennt.
final class AgentTerminalContainerView: NSView {
    weak var terminal: LocalProcessTerminalView?

    /// Prevent clicks in the terminal wrapper from moving the hidden-titlebar
    /// window while the user selects/copies terminal text.
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return hasAnyFileURL(in: sender) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return hasAnyFileURL(in: sender) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let terminal else { return false }
        let urls = sender.draggingPasteboard
            .readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }

        let payload = TerminalDropPayload.build(from: urls.map(\.path))
        // PTY frisst UTF-8 Bytes — keine `txt:`-API-Annahme, das ist sicherer.
        terminal.send(txt: payload)
        // Terminal aktivieren, damit der Cursor blinkt und der nächste
        // Tastendruck dort landet.
        window?.makeFirstResponder(terminal)
        return true
    }

    private func hasAnyFileURL(in info: NSDraggingInfo) -> Bool {
        guard let types = info.draggingPasteboard.types else { return false }
        return types.contains(.fileURL)
    }
}

/// Pure Helper: bauen aus Datei-Pfaden den String, der ins Terminal injiziert
/// wird. Mehrere Pfade werden space-getrennt; jeder einzeln shell-escaped,
/// damit Spaces, Umlaute und Sonderzeichen nicht den Befehl zerschießen.
/// Bewusst keine eigene Datei — engl klein gehalten und am Container-Ort,
/// hier auch testbar via `build(from:)`.
enum TerminalDropPayload {
    static func build(from paths: [String]) -> String {
        paths.map(shellEscape).joined(separator: " ")
    }

    /// macOS Terminal.app-Konvention: kein Quoting nötig, wenn der Pfad nur
    /// aus „sicheren" ASCII-Zeichen besteht; sonst Backslash-escape jedes
    /// Sonderzeichens. Wir nehmen denselben Ansatz statt Single-Quote-Wrap,
    /// weil das Resultat optisch näher am normalen Tippverhalten ist.
    static func shellEscape(_ path: String) -> String {
        var result = ""
        result.reserveCapacity(path.count)
        for scalar in path.unicodeScalars {
            if isShellSafe(scalar) {
                result.unicodeScalars.append(scalar)
            } else {
                result.append("\\")
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    private static func isShellSafe(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9":
            return true
        case "/", "-", "_", ".", "+", "=", ":", "@", "%", ",":
            return true
        default:
            return false
        }
    }
}
