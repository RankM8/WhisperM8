import Foundation

// Belegung der Paddles (Plan `controller-xbox-paddles.md`, „Wo ein Paddle
// wirkt“). Paddles wirken nur in der App, im Agent-Chats-Fenster; in einer
// Ebene, während der Aufnahme und außerhalb der App tun sie nichts, auch
// ohne Vibration. Ausnahme: „Pause“ wirkt überall, wo L1 + R1 wirkt.

extension ControllerBindingResolver {
    /// Paddle eines Drucks, auch in einer Ebene. Andere Gesten bilden
    /// Paddles nicht (keine Halte-Schwelle, kein Loslassen-Ereignis).
    static func paddleGesture(_ gesture: ControllerGesture) -> ControllerPaddle? {
        switch gesture {
        case let .press(button): return ControllerPaddle(button: button)
        case let .inLayer(_, inner): return paddleGesture(inner)
        default: return nil
        }
    }

    static func paddleAction(
        _ paddle: ControllerPaddle, gesture: ControllerGesture, in context: ControllerContext,
        bindings: ControllerPaddleBindings
    ) -> ControllerAction? {
        // In einer Ebene nichts: Die Ebene gilt als benutzt (das macht der
        // Erkenner), sonst bleibt das Ebenen-Modell unverändert.
        if case .inLayer = gesture { return nil }
        let binding = bindings[paddle]
        guard let action = binding.action else { return nil }
        let rejected: ControllerAction = .rejected
        switch context {
        case .paused:
            return binding == .pause ? action : nil
        case .outsideApp, .noWindow:
            return binding == .pause && chordAllowed(in: context) ? action : nil
        case .recording, .quickAction:
            return nil
        case .clipboardPanel:
            return binding == .clipboardHistory || binding == .pause ? action : rejected
        case .menu, .modal, .otherWindow:
            return binding == .pause ? action : rejected
        case .list:
            return binding.needsChat ? rejected : action
        case let .chat(state):
            switch binding {
            case .undo: return undoAllowed(state) ? action : rejected
            case .pasteNewest: return pasteAllowed(state) ? action : rejected
            default: return action
            }
        }
    }
}
