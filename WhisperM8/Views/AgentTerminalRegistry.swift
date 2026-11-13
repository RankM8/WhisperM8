import AppKit
import Darwin

@MainActor
final class AgentTerminalRegistry: ObservableObject {
    /// Geteilte Instanz, damit View-Bäume außerhalb von `AgentChatsView`
    /// (insbesondere der MenuBarExtra) dieselben laufenden Vordergrund-PTYs
    /// erreichen — Voraussetzung für ein globales "Stop all".
    static let shared = AgentTerminalRegistry(termination: .live)

    @Published private var controllers: [UUID: AgentTerminalController] = [:]

    /// Wartezeit zwischen den Ctrl+C-Wellen (Mikrosekunden). Injizierbar, damit
    /// Tests die Anzahl der Pausen zählen können, statt sie abzusitzen.
    private let sleep: (useconds_t) -> Void
    /// Was beim Ende eines Chat-Prozesses passiert (Store, Statuskoordinator).
    /// Lebt hier statt in der Ansicht, damit es auch für Chats ohne Ansicht
    /// gilt. Tests bekommen `.inert` und schreiben nie in den echten Workspace.
    private let termination: AgentChatTermination

    init(
        sleep: @escaping (useconds_t) -> Void = { usleep($0) },
        termination: AgentChatTermination = .inert
    ) {
        self.sleep = sleep
        self.termination = termination
    }

    /// Meldet jede Änderung des Satzes laufender PTYs — Quelle des
    /// Absturz-Markers (`AgentCrashRecoveryMarker`).
    var onRunningSetChanged: ((Set<UUID>) -> Void)?

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
        onTerminated: @escaping (AgentChatTermination.Outcome) -> Void
    ) -> AgentTerminalController {
        if let controller = controllers[sessionID], controller.isRunning {
            return controller
        }

        let controller = AgentTerminalController(
            sessionID: sessionID,
            command: command,
            onLaunched: onLaunched,
            onTerminated: { [weak self] exitCode in
                guard let self else { return }
                // Erst Store und Status, dann die Ansicht (falls es eine gibt).
                // Steht der Controller noch hier, endete der Prozess von selbst.
                let outcome = self.termination.handle(
                    sessionID: sessionID, exitCode: exitCode,
                    endedController: self.controllers[sessionID])
                onTerminated(outcome)
                self.notifyRunningSetChanged()
            }
        )
        controllers[sessionID] = controller
        controller.start()
        notifyRunningSetChanged()
        return controller
    }

    func terminate(sessionID: UUID) {
        controllers[sessionID]?.terminate()
        controllers[sessionID] = nil
        notifyRunningSetChanged()
    }

    /// Mehrere Chats gemeinsam graceful anhalten (Kontowechsel „Alle Chats
    /// hierher"): 2× Ctrl+C an alle, EINE gemeinsame Wartezeit, dann
    /// terminieren — der Main Thread steht ~260 ms statt 260 ms pro Chat.
    func terminate(sessionIDs: [UUID]) {
        let targets = sessionIDs.compactMap { id in controllers[id].map { (id, $0) } }
        guard !targets.isEmpty else { return }
        if targets.count == 1 {
            terminate(sessionID: targets[0].0)
            return
        }
        for (_, controller) in targets { controller.sendInterruptForAppQuit() }
        sleep(80_000)
        for (_, controller) in targets { controller.sendInterruptForAppQuit() }
        sleep(180_000)
        for (id, controller) in targets {
            controller.terminateAfterInterrupt()
            controllers[id] = nil
        }
        notifyRunningSetChanged()
    }

    private func notifyRunningSetChanged() {
        onRunningSetChanged?(activeSessionIDs)
    }

    /// Terminiert alle laufenden Vordergrund-PTYs (je Controller graceful:
    /// 2× Ctrl+C → Kill) und gibt die betroffenen Session-IDs zurück. Iteriert
    /// über einen Snapshot der IDs, damit das Mutieren von `controllers`
    /// während des Loops sicher ist.
    @discardableResult
    func terminateAll() -> [UUID] {
        let ids = runningControllers.map(\.sessionID)
        // Gemeinsamer Mehrfach-Pfad: 2× Ctrl+C an alle, EINE Wartezeit — vorher
        // stand der Main Thread 260 ms pro Chat (LR-TRM-001).
        terminate(sessionIDs: ids)
        return ids
    }

    /// App-Quit: Terminal-Staende ALLER noch laufenden PTYs sichern, bevor
    /// AppKit die Fenster abbaut und die Kind-Prozesse mit dem App-Prozess
    /// sterben. Ohne diesen Pfad haetten genau die beim Quit (Cmd+Q,
    /// `make dev`/SIGTERM) noch offenen Chats keinen Snapshot —
    /// terminate()/processTerminated feuern hier nie. Graceful wie im
    /// Einzel-terminate() (2x Ctrl+C, damit die TUI Resume-Hinweis und
    /// JSONL-Flush schafft), aber mit einer GEMEINSAMEN Wartezeit fuer alle
    /// Chats: der Quit kostet konstant ~260 ms statt 260 ms pro Chat.
    func captureAllSnapshotsForAppQuit() {
        let running = runningControllers
        guard !running.isEmpty else { return }
        // Angedockte Hintergrund-Tabs (`claude attach`) bekommen kein Ctrl+C:
        // ihr Agent soll den Neustart ueberleben, und den Verlauf schreibt
        // der Worker selbst. Nur ihr Snapshot wird gesichert.
        if running.contains(where: \.command.sendsInterruptOnStop) {
            for controller in running { controller.sendInterruptForAppQuit() }
            sleep(80_000)
            for controller in running { controller.sendInterruptForAppQuit() }
            sleep(180_000)
        }
        for controller in running { controller.captureSnapshotForAppQuit() }
    }
}
