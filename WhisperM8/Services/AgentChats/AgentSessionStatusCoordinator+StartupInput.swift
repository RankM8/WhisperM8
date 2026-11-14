import Foundation

// Startbereitschaft eines Claude-Chats (WM8-100).
//
// Gemessen am 14.11.2026 nach `chats resume` (Claude Code 2.1.325): Der
// Prozess läuft nach 3,5 s, die Startfrist gab nach 9,1 s frei, das
// Eingabefeld stand erst nach 13,3 s, Claudes Registry meldete „idle“ rund
// eine Sekunde später. Was in dieser Lücke eingefügt wird, steht danach im
// Eingabefeld, das Enter ist verloren. Deshalb gilt ein frisch gestarteter
// Claude-Chat erst als bereit, wenn sein Eingabefeld am Bildschirm zu sehen
// ist (oder Registry, Hook, Verlauf ihn vorher als bereit melden). Wer
// danach sendet, prüft im Startfenster dasselbe noch einmal am Bildschirm.
//
// Übernommene Chats (Neustart mit Übergabe) sind ausgenommen: Ihr Bildschirm
// ist nach der Übernahme leer, bis Claude neu zeichnet (WM8-97 regelt sie).

extension AgentSessionStatusCoordinator {
    /// Abstand der Nachschau, solange das Eingabefeld fehlt.
    nonisolated static let startupInputPollSeconds: TimeInterval = 1
    /// Längstens so lange nach dem Start wird auf das Eingabefeld gewartet;
    /// danach gilt der Chat wie früher als bereit (Notfrist).
    nonisolated static let startupInputMaxWaitSeconds: TimeInterval = 120

    /// Die Startfrist ist abgelaufen. Bei einem Claude-Chat, dessen
    /// Eingabefeld noch fehlt, wird weiter nachgesehen statt freizugeben.
    func launchGraceFired(sessionID: UUID) {
        guard case .launching = states[sessionID] else { return }
        if Self.keepWaitingForInput(
            visible: startupInputVisible(sessionID),
            since: startupInputSince[sessionID],
            now: now()) {
            scheduleLaunchGrace(sessionID: sessionID, seconds: Self.startupInputPollSeconds)
            return
        }
        apply(.launchGraceExpired, to: sessionID)
    }

    /// Pur: weiter warten, solange das Feld sicher fehlt und die Notfrist
    /// nicht um ist. Nicht ablesbar (`nil`) heißt freigeben wie bisher.
    nonisolated static func keepWaitingForInput(visible: Bool?, since: Date?, now: Date) -> Bool {
        guard visible == false, let since else { return false }
        return now.timeIntervalSince(since) < startupInputMaxWaitSeconds
    }

    /// Im Startfenster und das Eingabefeld ist noch nicht zu sehen: `send`
    /// und Warteschlange halten an, auch wenn Registry oder Hook schon
    /// „bereit“ gemeldet haben. Nur bei ruhendem Chat; eine offene Rückfrage
    /// (`awaitingInput`) hat kein Eingabefeld und darf beantwortet werden.
    func startupInputPending(_ sessionID: UUID) -> Bool {
        guard statusStore.status(for: sessionID) == .idle else { return false }
        return Self.keepWaitingForInput(
            visible: startupInputVisible(sessionID),
            since: startupInputSince[sessionID],
            now: now())
    }

    /// Ablesung an der laufenden App: nur Claude-Chats, nur wenn die Ansicht
    /// unten steht. Höchstens einmal je Sekunde im Startfenster und je
    /// Zustellversuch, nie pro Ausgabe.
    @MainActor
    static func liveStartupInputVisible(_ sessionID: UUID) -> Bool? {
        guard let controller = AgentTerminalRegistry.shared.controller(for: sessionID),
              controller.isRunning,
              controller.command.keyboardProfile == .claudeCodeChat,
              let screen = controller.controllerScreenSnapshot() else { return nil }
        return screen.promptField != nil
    }
}
