import CoreGraphics
import SwiftUI
@testable import WhisperM8

/// Fixtures für das Entsperr-Panel der Tastatursperre — ohne echten Event-Tap.
extension UISnapshotGallery {
    @MainActor
    private final class SnapshotTap: KeyboardEventTapping {
        func install(handler: @escaping @MainActor (KeyboardLockPolicy.Event, CGEventFlags) -> KeyboardLockPolicy.Decision) -> Bool { true }
        func reenable() {}
        func uninstall() {}
    }

    @MainActor
    private final class SnapshotPanel: KeyboardLockPanelPresenting {
        func show(controller: KeyboardLockController) {}
        func hide() {}
    }

    @MainActor
    static func keyboardLockFixtures() -> [Fixture] {
        func lockedController(secureInput: Bool, capsLock: Bool) -> KeyboardLockController {
            let controller = KeyboardLockController(
                tap: SnapshotTap(),
                panel: SnapshotPanel(),
                secureInputProbe: { secureInput },
                capsLockProbe: { capsLock },
                keysDownProbe: { [] }
            )
            controller.lock()
            return controller
        }
        let size = CGSize(width: 420, height: 300)
        return [
            Fixture(name: "tastatursperre-panel", size: size) {
                AnyView(KeyboardLockPanelView(controller: lockedController(secureInput: false, capsLock: false)))
            },
            Fixture(name: "tastatursperre-panel-hinweise", size: size) {
                AnyView(KeyboardLockPanelView(controller: lockedController(secureInput: true, capsLock: true)))
            },
        ]
    }
}
