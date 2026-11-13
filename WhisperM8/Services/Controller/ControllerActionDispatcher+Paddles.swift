import Foundation

// Aktionen der Paddles am Xbox Elite (Plan `controller-xbox-paddles.md`,
// „Paddle-Aktionen im Ausführer“). Ziel ist der ausgewählte Chat beim Druck;
// ob etwas geht, wird beim Ausführen frisch am Terminal geprüft. Wo nichts
// passt: „geht nicht“ (drei Ticks).

extension ControllerActionDispatcher {
    func performPaddleAction(_ action: ControllerAction) {
        switch action {
        case .nextWaitingChat:
            if command(.nextWaitingChat, orReject: true) { refreshContext() }
        case .answerNextWaiting:
            answerNextWaiting()
        case .sendNowOrContinue:
            paddleSendNowOrContinue()
        case .cycleMode:
            paddleCycleMode()
        case let .slashCommand(text):
            paddleSlashCommand(text)
        default:
            playHaptic(.rejected)
        }
    }

    /// Antworten (offene Frage 1, Empfehlung): zuerst zum jüngsten frisch
    /// fertigen Chat (nicht der aktuelle) und dort diktieren. Gibt es keinen,
    /// zum nächsten wartenden Chat, nur springen — in eine Rückfrage läuft
    /// nie ein Diktat. Ist der aktuelle Chat der einzige Kandidat und ruht er,
    /// diktiert es hier.
    func answerNextWaiting() {
        guard dictation.phase == nil else { return playHaptic(.rejected) }
        let current = selectedSessionID
        let fresh = freshDoneChats()
        if let target = fresh.first(where: { $0 != current }) {
            // Dieselbe Prüfung wie „Wohin“ + R2: nach dem Wechsel muss das Ziel
            // wirklich ausgewählt sein, sonst kein Diktat.
            guard command(.selectSession(target), orReject: false), selectedSessionID == target,
                  let deliver = chatTarget() else {
                return playHaptic(.rejected)
            }
            refreshContext()
            // Eine Rückfrage kann inzwischen aufgegangen sein: nur springen.
            guard terminals.state(of: target)?.status == .idle else { return }
            startDictation(target: deliver)
            return
        }
        if command(.nextWaitingChat, orReject: false) {
            refreshContext()
            return
        }
        if let current, fresh.contains(current), terminals.state(of: current)?.status == .idle,
           let deliver = chatTarget() {
            startDictation(target: deliver)
            return
        }
        playHaptic(.rejected)
    }

    /// Jetzt senden / Weiter: dieselbe Entscheidung wie R1 + Kreuz. In einer
    /// Shell „geht nicht“ (dort liefe sonst „Weiter“ als Befehl).
    func paddleSendNowOrContinue() {
        guard let sessionID = selectedSessionID, let terminal = terminals.state(of: sessionID),
              terminal.isRunning, terminal.profile != .shell else {
            return playHaptic(.rejected)
        }
        let setup = menuSetup(for: .chat(sessionID))
        guard setup.acceptsInput else { return playHaptic(.rejected) }
        sendOrContinue(setup: setup) {}
    }

    /// Modus wechseln mit den Regeln von Menü und Raute: nicht in einer
    /// Rückfrage, nur wenn der Chat ruht.
    func paddleCycleMode() {
        guard let sessionID = selectedSessionID else { return playHaptic(.rejected) }
        let setup = menuSetup(for: .chat(sessionID))
        guard ControllerMenuModel.isEnabled(.cycleMode, setup: setup) else { return playHaptic(.rejected) }
        perform(.cycleMode, setup: setup)
    }

    /// `/workflows`, `/tasks`: wie aus „Befehle ›“, nur in Claude-Chats und
    /// nicht in einer Rückfrage.
    func paddleSlashCommand(_ text: String) {
        guard let sessionID = selectedSessionID else { return playHaptic(.rejected) }
        let setup = menuSetup(for: .chat(sessionID))
        guard setup.profile == .claude, ControllerMenuModel.isEnabled(.commands, setup: setup) else {
            return playHaptic(.rejected)
        }
        sendCommand(ControllerSlashCommand(text: text), setup: setup)
    }
}
