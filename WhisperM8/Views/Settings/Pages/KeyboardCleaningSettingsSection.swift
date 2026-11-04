import SwiftUI

/// „Tastatur reinigen“: sperrt die Tastatur per Mausklick, bis zum Entsperren
/// im schwebenden Panel oder nach zwei Minuten.
struct KeyboardCleaningSettingsSection: View {
    @ObservedObject private var controller = KeyboardLockController.shared
    @State private var permissionMissing = false

    var body: some View {
        SettingsSection("Keyboard Cleaning") {
            SettingsButtonRow(
                title: "Lock keyboard",
                subtitle: "Blocks every key, including media keys and shortcuts, so you can wipe the keyboard. Mouse and trackpad keep working. Unlock with the mouse in the floating panel; it unlocks by itself after 2 minutes, and when the Mac locks or sleeps."
            ) {
                if controller.isLocked {
                    Button("Unlock Keyboard") {
                        controller.unlock(reason: .user)
                    }
                    .buttonStyle(SettingsButtonStyle.primary)
                } else {
                    Button("Lock Keyboard") {
                        permissionMissing = controller.lock() == .missingPermission
                    }
                    .buttonStyle(SettingsButtonStyle.standard)
                }
            }

            if permissionMissing {
                SettingsStatusRow(
                    title: "Accessibility",
                    subtitle: "Locking the keyboard needs the Accessibility permission. Grant it, then try again.",
                    tone: .off,
                    detail: "Not granted yet"
                ) {
                    Button("Open System Settings") {
                        PermissionService.requestAccessibilityPermission()
                        PermissionService.openAccessibilityPrivacySettings()
                    }
                    .buttonStyle(SettingsButtonStyle.standard)
                }
            }
        }
    }
}
