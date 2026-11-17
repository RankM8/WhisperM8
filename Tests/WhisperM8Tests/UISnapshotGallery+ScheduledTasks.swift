import SwiftUI
@testable import WhisperM8

/// Fixtures der Labs-Seite „Geplante Aufgaben“ (WM8-110, Paket 1): aus (ab Werk) und an.
extension UISnapshotGallery {
    @MainActor
    static func scheduledTasksSettingsFixtures() -> [Fixture] {
        let size = CGSize(width: 760, height: 420)
        return [
            Fixture(name: "geplant-einstellungen-aus", size: size,
                    storage: [PreferenceKeys.scheduledTasksEnabled: false]) {
                AnyView(ScheduledTasksSettingsPage())
            },
            Fixture(name: "geplant-einstellungen-an", size: size,
                    storage: [PreferenceKeys.scheduledTasksEnabled: true]) {
                AnyView(ScheduledTasksSettingsPage())
            },
        ]
    }
}
