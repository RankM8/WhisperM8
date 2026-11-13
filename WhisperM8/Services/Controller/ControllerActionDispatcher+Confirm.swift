import Foundation

// Kreuz bei arbeitendem Claude-Chat, das nur am sichtbaren Eingabefeld hängt
// (`ControllerBindingResolver.confirmRestsOnPromptField`): Enter geht erst
// nach einer kurzen Nachprüfung raus.

extension ControllerActionDispatcher {
    /// So lange nach dem Druck wird der Bildschirm noch einmal gelesen. Claude
    /// zeichnet während eines Turns etwa alle 50 ms neu (Schimmer am Spinner);
    /// ein Dialog, auf den Claude im Moment des Drucks schon umgeschaltet hat,
    /// steht danach sicher im Bild. Eine Ruhe-Bedingung („seit 150 ms keine
    /// Ausgabe“) ginge nicht: Sie wäre während eines Turns nie erfüllt.
    static let confirmSettleDelay: TimeInterval = 0.1

    /// Enter erst, wenn das Feld nach `confirmSettleDelay` noch sichtbar ist
    /// (frisch gelesen, gedrosselte Panes vorher geleert) und derselbe Chat
    /// ausgewählt ist. Ist inzwischen ein Dialog da, geht nichts raus
    /// („geht nicht“).
    func confirmWhenSettled() {
        guard let sessionID = selectedSessionID else { return playHaptic(.rejected) }
        scheduleOnMain(Self.confirmSettleDelay) { [weak self] in
            self?.finishSettledConfirm(sessionID)
        }
    }

    private func finishSettledConfirm(_ sessionID: UUID) {
        guard selectedSessionID == sessionID,
              case let .chat(state) = ControllerContextResolver.context(for: snapshot()),
              state.acceptsKeys, ControllerBindingResolver.claudePromptVisible(state)
        else { return playHaptic(.rejected) }
        _ = terminals.sendKey(.enter, to: sessionID)
    }
}
