import Foundation

// Aktionen der Paddles am Xbox Elite (Plan `controller-xbox-paddles.md`,
// „Paddle-Aktionen im Ausführer“).

extension ControllerActionDispatcher {
    func performPaddleAction(_ action: ControllerAction) {
        playHaptic(.rejected)
    }
}
