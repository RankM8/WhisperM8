import AppKit
import SwiftTerm
import SwiftUI

@MainActor
final class AgentTerminalRegistry: ObservableObject {
    @Published private var controllers: [UUID: AgentTerminalController] = [:]

    var activeSessionIDs: Set<UUID> {
        Set(controllers.values.filter(\.isRunning).map(\.sessionID))
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

@MainActor
final class AgentTerminalController: NSObject, ObservableObject, Identifiable, @preconcurrency LocalProcessTerminalViewDelegate {
    let id = UUID()
    let sessionID: UUID
    let terminal = LocalProcessTerminalView(frame: .zero)
    let command: AgentLaunchCommand

    @Published private(set) var isRunning = false
    @Published private(set) var hasStarted = false
    @Published private(set) var exitCode: Int32?

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
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        isRunning = true
        terminal.startProcess(
            executable: command.executablePath,
            args: command.arguments,
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
