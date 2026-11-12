import Foundation

// Runde 5: Einfügen aus der Zwischenablage (L1 + Kreuz) und Wiederöffnen des
// zuletzt geschlossenen Chats (L2 + Viereck).

extension ControllerActionDispatcher {
    /// L1 + Kreuz: neuesten Eintrag der Zwischenablage in den ausgewählten
    /// Chat. Text kommt wie ein Diktat als ein Block ins Feld (ohne Senden,
    /// auch in Shells); ein Bild wird in die Zwischenablage gelegt und mit
    /// Ctrl+V eingefügt (Claude, Codex). Geht der Chat bis dahin aus der
    /// Auswahl, wird nichts eingefügt.
    func pasteNewest() {
        guard let sessionID = selectedSessionID, let terminal = terminals.state(of: sessionID),
              terminal.isRunning, terminal.status != .awaitingInput,
              let clip = clipboard.newest() else {
            return playHaptic(.rejected)
        }
        let isAgentChat = terminal.profile == .claude || terminal.profile == .codex
        switch clip.kind {
        case .text:
            guard isAgentChat || terminal.profile == .shell else { return playHaptic(.rejected) }
            clipboard.loadText(clip.id) { [weak self] text in
                guard let self, let text, !text.isEmpty, self.selectedSessionID == sessionID,
                      self.terminals.sendText(text, submit: false, to: sessionID) else {
                    self?.playHaptic(.rejected)
                    return
                }
            }
        case .image:
            guard isAgentChat else { return playHaptic(.rejected) }
            clipboard.copyImage(clip.id) { [weak self] written in
                guard let self, written, self.selectedSessionID == sessionID,
                      self.terminals.sendKey(.imagePaste, to: sessionID) else {
                    self?.playHaptic(.rejected)
                    return
                }
            }
        }
    }

    /// L2 + Viereck: zuletzt geschlossenen Chat dieses App-Starts wieder öffnen
    /// (wie `chats reopen`). Wiederholt geht es weiter zurück. Schließt die
    /// Insel; ohne geschlossenen Chat „geht nicht“, die Insel bleibt.
    func reopenClosedChat() {
        guard spentLayer != .whereTo else { return }
        guard closedChats.reopen() else { return playHaptic(.rejected) }
        spendIsland(.whereTo)
        refreshContext()
    }
}
