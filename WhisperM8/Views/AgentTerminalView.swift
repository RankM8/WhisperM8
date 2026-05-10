import AppKit
import SwiftTerm
import SwiftUI

@MainActor
final class AgentTerminalRegistry: ObservableObject {
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
/// - `Command+←` / `→` → `Ctrl+A` / `Ctrl+E` — Zeilenanfang / -ende
enum TerminalShortcut {
    /// Virtual-Key-Codes (NSEvent.keyCode) der relevanten Tasten.
    enum KeyCode {
        public static let z: UInt16 = 6
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
        characters: String?
    ) -> [UInt8]? {
        let hasOption = modifiers.contains(.option)
        let hasCommand = modifiers.contains(.command)
        let hasControl = modifiers.contains(.control)
        let hasShift = modifiers.contains(.shift)

        // Cmd-Combos kollidieren mit Ctrl-Combos auf TUI-Ebene → wenn Control gehalten
        // wird, immer durchreichen (User will die Standard-Control-Sequence).
        guard !hasControl else { return nil }

        switch keyCode {
        case KeyCode.delete:
            if hasOption && !hasCommand { return [0x17] }   // Ctrl+W
            if hasCommand { return [0x15] }                  // Ctrl+U
        case KeyCode.leftArrow:
            if hasOption && !hasCommand { return [0x1b, 0x62] }  // Esc+B
            if hasCommand { return [0x01] }                       // Ctrl+A
        case KeyCode.rightArrow:
            if hasOption && !hasCommand { return [0x1b, 0x66] }  // Esc+F
            if hasCommand { return [0x05] }                       // Ctrl+E
        case KeyCode.z:
            // Cmd+Shift+Z (Redo) bewusst durchreichen — Readline kennt kein Redo.
            if hasCommand && !hasShift,
               characters?.lowercased() == "z" {
                return [0x1f]   // Ctrl+_ (Readline-undo)
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
    private var monitor: Any?

    init(attachedTo terminalView: LocalProcessTerminalView) {
        self.terminalView = terminalView
        self.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
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

        guard let bytes = TerminalShortcut.bytes(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags,
            characters: event.charactersIgnoringModifiers
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
    let terminal = LocalProcessTerminalView(frame: .zero)
    let command: AgentLaunchCommand
    private var keyboardShortcutHandler: TerminalKeyboardShortcutHandler?

    @Published private(set) var isRunning = false
    @Published private(set) var hasStarted = false
    @Published private(set) var exitCode: Int32?

    var processID: Int32? {
        let pid = terminal.process.shellPid
        return pid > 0 ? pid : nil
    }

    private var onLaunched: () -> Void
    private var onTerminated: (Int32?) -> Void

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

        // Terminal-Hintergrund an das App-Theme angleichen — kein hartes Schwarz mehr,
        // damit sich der Terminal-Bereich visuell ins dunkle UI integriert statt als
        // Fremdkörper zu wirken.
        let themedBackground = NSColor(calibratedRed: 0.058, green: 0.060, blue: 0.064, alpha: 1)
        terminal.nativeBackgroundColor = themedBackground
        terminal.layer?.backgroundColor = themedBackground.cgColor

        // macOS-Edit-Shortcuts (Option/Command+Backspace, Word-Move, Undo) in
        // Claude-Code-/Codex-/Readline-kompatible Control-Sequences übersetzen.
        keyboardShortcutHandler = TerminalKeyboardShortcutHandler(attachedTo: terminal)
    }

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
        terminal.terminate()
        isRunning = false
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in
            self.exitCode = exitCode
            self.isRunning = false
            self.onTerminated(exitCode)
        }
    }
}

struct AgentTerminalView: NSViewRepresentable {
    @ObservedObject var controller: AgentTerminalController

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: .zero)
        attach(controller.terminal, to: container)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
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
