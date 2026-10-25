import SwiftUI

/// Stufe 1 des Wach-Knopfs als Schalter, dazu Stand und Entfernen der
/// einmaligen Freigabe (`SleepDisablePermission`).
struct StayAwakeSettingsSection: View {
    @AppStorage(PreferenceKeys.stayAwakeWhileWorking) private var stayAwakeWhileWorking = false
    @ObservedObject private var controller = StayAwakeController.shared

    var body: some View {
        SettingsSection("Keep Mac awake") {
            SettingsToggleRow(
                title: "Keep Mac awake while chats work",
                subtitle: "On power, the Mac stays awake while a chat works, even with the lid closed, and for two more minutes after. The sidebar button also has “Always awake” for battery, which ends at 20 % battery, when the Mac gets hot, or after 4 hours.",
                isOn: Binding(
                    get: { stayAwakeWhileWorking },
                    set: { enabled in
                        if enabled {
                            controller.setWhileWorking(true)
                        } else {
                            stayAwakeWhileWorking = false
                            controller.setWhileWorking(false)
                        }
                    }
                )
            )

            SettingsStatusRow(
                title: "Permission",
                subtitle: "Only a closed lid needs administrator rights. On first use, macOS asks for your password once, and WhisperM8 adds a rule that allows exactly “pmset -a disablesleep 0” and “… 1”. If WhisperM8 quits or crashes, sleep is turned back on.",
                tone: permissionTone,
                detail: permissionDetail
            ) {
                if controller.permission == .ready {
                    Button("Remove permission") {
                        controller.removePermission()
                    }
                    .buttonStyle(SettingsButtonStyle.standard)
                    .disabled(controller.isAwaitingPermission)
                }
            }
        }
        .onAppear { controller.start() }
    }

    private var permissionTone: SettingsStatusTone {
        switch controller.permission {
        case .ready: return .ok
        case .missing: return .off
        case .unknown: return .off
        }
    }

    private var permissionDetail: String {
        switch controller.permission {
        case .ready: return String(localized: "Granted")
        case .missing: return String(localized: "Not granted yet")
        case .unknown: return String(localized: "Checking …")
        }
    }
}
