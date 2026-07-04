import Foundation

/// Routet Text (z.B. einen Subagent-Report) in eine bestehende Session:
/// Fenster/Tab fokussieren + Text in die laufende TUI injizieren. Läuft die
/// Session noch nicht, wird sie über den bestehenden Start-Pfad hochgefahren
/// und der Text nachgereicht, sobald das PTY steht.
///
/// Der Chat-Erzeugungs-Pfad der Diktier-Pipeline (`AgentChatLaunchService`)
/// greift hier bewusst NICHT: die Ziel-Session existiert bereits und der
/// Resume-Pfad ignoriert `initialPrompt` — deshalb Terminal-Injektion.
/// Minimales Terminal-Interface fürs Routing — Tests injizieren einen Fake,
/// Produktion nutzt `AgentTerminalController`.
@MainActor
protocol PromptRoutableTerminal: AnyObject {
    var isRunning: Bool { get }
    var hasStarted: Bool { get }
    func sendUserText(_ text: String)
}

@MainActor
struct AgentPromptRoutingService {
    /// Test-Seams (Konvention: Closure-DI).
    var controllerResolver: (UUID) -> PromptRoutableTerminal?
    var focusRequester: (UUID) -> Void
    var sessionStarter: (UUID) -> Void
    var textSender: (PromptRoutableTerminal, String) -> Void
    var schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void

    init(
        controllerResolver: ((UUID) -> PromptRoutableTerminal?)? = nil,
        focusRequester: ((UUID) -> Void)? = nil,
        sessionStarter: ((UUID) -> Void)? = nil,
        textSender: ((PromptRoutableTerminal, String) -> Void)? = nil,
        schedule: ((TimeInterval, @escaping @MainActor () -> Void) -> Void)? = nil
    ) {
        self.controllerResolver = controllerResolver ?? { AgentTerminalRegistry.shared.controller(for: $0) }
        self.focusRequester = focusRequester ?? { WindowRequestCenter.shared.requestSessionFocus(sessionID: $0) }
        self.sessionStarter = sessionStarter ?? { sessionID in
            // Fokus-Request öffnet den Tab; der Start läuft über den
            // bestehenden Auto-Start beim Tab-Öffnen bzw. den Resume-Pfad
            // der Detail-View. Ein separater Start-Kanal ist nicht nötig —
            // wir warten einfach, bis das PTY steht (Retry unten).
            WindowRequestCenter.shared.requestSessionFocus(sessionID: sessionID)
        }
        self.textSender = textSender ?? { controller, text in controller.sendUserText(text) }
        self.schedule = schedule ?? { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                Task { @MainActor in work() }
            }
        }
    }

    /// Fokussiert die Ziel-Session und injiziert den Text. Läuft das PTY
    /// noch nicht, wird die Injektion gestaged: bis zu `maxAttempts`
    /// Versuche im `retryInterval`-Abstand (Grace für den TUI-Start).
    func route(
        text: String,
        toLocalSessionID sessionID: UUID,
        maxAttempts: Int = 8,
        retryInterval: TimeInterval = 0.7
    ) {
        focusRequester(sessionID)

        if let controller = controllerResolver(sessionID), controller.isRunning {
            textSender(controller, text)
            return
        }

        sessionStarter(sessionID)
        attemptStagedSend(
            text: text,
            sessionID: sessionID,
            remainingAttempts: maxAttempts,
            retryInterval: retryInterval
        )
    }

    private func attemptStagedSend(
        text: String,
        sessionID: UUID,
        remainingAttempts: Int,
        retryInterval: TimeInterval
    ) {
        guard remainingAttempts > 0 else {
            Logger.agentStore.warning("prompt_routing_gave_up sessionID=\(sessionID.uuidString, privacy: .public)")
            return
        }
        let service = self
        schedule(retryInterval) {
            if let controller = service.controllerResolver(sessionID),
               controller.isRunning, controller.hasStarted {
                // Kleine Extra-Grace nach hasStarted: die TUI braucht einen
                // Moment, bis der Composer Eingaben annimmt.
                service.schedule(1.0) {
                    if let live = service.controllerResolver(sessionID), live.isRunning {
                        service.textSender(live, text)
                    }
                }
                return
            }
            service.attemptStagedSend(
                text: text,
                sessionID: sessionID,
                remainingAttempts: remainingAttempts - 1,
                retryInterval: retryInterval
            )
        }
    }
}

extension AgentTerminalController: PromptRoutableTerminal {}

// MARK: - Report → Prompt-Text

extension AgentReport {
    /// Kompaktes Markdown für die Übergabe an die Parent-Session — der
    /// Claude-Chat bekommt den Report als normalen User-Prompt-Baustein.
    func promptText(shortId: String) -> String {
        var lines = [
            "Subagent-Report \(shortId) — Status: \(status.rawValue)",
            summary,
        ]
        if !filesChanged.isEmpty {
            lines.append("Geänderte Dateien: \(filesChanged.joined(separator: ", "))")
        }
        for commit in commits {
            lines.append("Commit \(commit.sha): \(commit.message)")
        }
        if let tests = testsRun {
            lines.append("Tests: \(tests.command) → \(tests.passed ? "passed" : "FAILED")")
        }
        if !openQuestions.isEmpty {
            lines.append("Offene Fragen: " + openQuestions.joined(separator: " · "))
        }
        return lines.joined(separator: "\n")
    }
}
