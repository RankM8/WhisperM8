import SwiftUI
@testable import WhisperM8

/// Fixtures der Labs-Seite „Neustart ohne Chatverlust“ (WM8-11): aus (ab Werk) und an.
extension UISnapshotGallery {
    @MainActor
    static func restartSettingsFixtures() -> [Fixture] {
        let size = CGSize(width: 760, height: 420)
        return [
            Fixture(name: "neustart-einstellungen-aus", size: size,
                    storage: [PreferenceKeys.restartKeepsChatsEnabled: false]) {
                AnyView(RestartSettingsPage())
            },
            Fixture(name: "neustart-einstellungen-an", size: size,
                    storage: [PreferenceKeys.restartKeepsChatsEnabled: true]) {
                AnyView(RestartSettingsPage())
            },
        ]
    }
}
