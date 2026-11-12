import AppKit
import SwiftUI

/// Was die Seite von außen braucht. Snapshots und Tests setzen eigene Werte;
/// `.live` hängt am `ControllerManager`.
struct ControllerSettingsDependencies {
    /// Verbindung, letzte Taste und Hintergrund-Zustand.
    var status: @MainActor () -> ControllerStatus
    /// Schalter wurden geändert: Lauf der Steuerung angleichen.
    var applyPreferences: @MainActor () -> Void
    /// Bedienungshilfen erlaubt? Ohne sie kann das Touchpad den Zeiger nicht bewegen.
    var accessibilityTrusted: @MainActor () -> Bool = { PermissionService.hasAccessibilityPermission }
    /// Nur den Zeiger angleichen (Geschwindigkeits-Regler, je Schritt).
    var applyPointerSettings: @MainActor () -> Void = {}
    var requestAccessibility: @MainActor () -> Void = {
        PermissionService.requestAccessibilityPermission()
        PermissionService.openAccessibilityPrivacySettings()
    }

    static let live = ControllerSettingsDependencies(
        status: { ControllerManager.shared.status },
        applyPreferences: {
            ControllerManager.shared.applyPreferences()
            ControllerConnectHint.shared.sync()
        },
        applyPointerSettings: { ControllerManager.shared.syncPointer() }
    )
}

/// Einstellungen › Controller: Ein und Aus, Verbindung, Tasten-Test, die
/// Grundschalter und die Belegung zum Nachlesen.
struct ControllerSettingsPage: View {
    @AppStorage(PreferenceKeys.controllerEnabled) private var enabled = false
    @AppStorage(PreferenceKeys.controllerLegendEnabled) private var legendEnabled = true
    @AppStorage(PreferenceKeys.controllerHapticsEnabled) private var hapticsEnabled = true
    @AppStorage(PreferenceKeys.controllerLightEnabled) private var lightEnabled = true
    @AppStorage(PreferenceKeys.controllerBackgroundEnabled) private var backgroundEnabled = false
    @AppStorage(PreferenceKeys.controllerWakeOnInputEnabled) private var wakeOnInputEnabled = true
    @AppStorage(PreferenceKeys.controllerTouchpadPointerEnabled) private var touchpadPointerEnabled = false
    @AppStorage(PreferenceKeys.controllerPointerSpeed) private var pointerSpeed = ControllerTouchpadPointer.Config.defaultSpeed
    /// Wird beim Zurückkehren in die App erhöht: Die Berechtigung kann sich in
    /// den Systemeinstellungen geändert haben.
    @State private var permissionCheck = 0

    let dependencies: ControllerSettingsDependencies

    init(dependencies: ControllerSettingsDependencies = .live) {
        self.dependencies = dependencies
    }

    var body: some View {
        SettingsPageContainer(
            title: "Controller",
            subtitle: "Use WhisperM8 with a gamepad."
        ) {
            SettingsLabsNotice("New and still evolving. Built for the PS5 DualSense; other gamepads work through the generic profile. Off by default.")

            SettingsSection("Controller") {
                SettingsToggleRow(
                    title: "Controller support",
                    subtitle: "A connected gamepad drives Agent Chats and dictation: move through the list, open chats, answer questions and dictate.",
                    isOn: $enabled
                )
                ControllerConnectionRows(status: dependencies.status(), isEnabled: enabled)
            }

            SettingsSection("Behavior") {
                SettingsToggleRow(
                    title: "Show the legend at the bottom edge",
                    subtitle: "A strip at the bottom of the Agent Chats window shows what each button does right now.",
                    isOn: $legendEnabled
                )
                SettingsToggleRow(
                    title: "Vibration",
                    subtitle: "Short pulses when a recording starts or stops and when another chat needs a decision.",
                    isOn: $hapticsEnabled
                )
                SettingsToggleRow(
                    title: "Light bar",
                    subtitle: "Red while recording, green while the chat works, amber when it asks a question.",
                    isOn: $lightEnabled
                )
                SettingsToggleRow(
                    title: "Also when another app is in front",
                    subtitle: "Dictation and clipboard history work everywhere. Turn this off for gaming, or pause the controller with L1 + R1.",
                    isOn: $backgroundEnabled
                )
                ControllerBackgroundRow(status: dependencies.status(), isEnabled: enabled && backgroundEnabled)
                SettingsToggleRow(
                    title: "Bring WhisperM8 to the front on input",
                    subtitle: "While another app is in front, moving a stick or pressing a button brings the Agent Chats window forward. That first input does nothing else. R2 and the touchpad keep working in the other app. Needs the switch above.",
                    isOn: $wakeOnInputEnabled
                )
                .disabled(!backgroundEnabled)
            }

            SettingsSection("Touchpad") {
                SettingsToggleRow(
                    title: "Touchpad as mouse",
                    subtitle: "Slide a finger to move the pointer, press the touchpad to click, press with two fingers to right-click. In other apps this needs the switch “Also when another app is in front”. The clipboard history then opens with L2 + touchpad or from the Options menu.",
                    isOn: $touchpadPointerEnabled
                )
                SettingsSliderRow(
                    title: "Pointer speed",
                    subtitle: "A quick swipe always carries the pointer farther than a slow one.",
                    value: $pointerSpeed,
                    in: ControllerTouchpadPointer.Config.speedRange
                )
                .disabled(!touchpadPointerEnabled)
                if touchpadPointerEnabled, !dependencies.accessibilityTrusted() {
                    SettingsStatusRow(
                        title: "Accessibility",
                        subtitle: "Moving the pointer and clicking need the Accessibility permission. Until you grant it, the touchpad does nothing.",
                        tone: .warn,
                        detail: "Not granted yet"
                    ) {
                        Button("Open System Settings") { dependencies.requestAccessibility() }
                            .buttonStyle(SettingsButtonStyle.standard)
                    }
                    .id(permissionCheck)
                }
            }

            ForEach(ControllerLegend.allBindings(touchpadPointer: touchpadPointerEnabled), id: \.kind) { section in
                ControllerBindingsSection(section: section)
            }

            SettingsSection("Pairing") {
                SettingsHelpText("PS5 controller: switch it off, then hold Create (left of the touchpad) and the PlayStation button together until the light bar flashes quickly. Then connect it under Bluetooth in System Settings. A USB-C cable works without pairing.")
            }
        }
        .onChange(of: enabled) { _, _ in dependencies.applyPreferences() }
        .onChange(of: backgroundEnabled) { _, _ in dependencies.applyPreferences() }
        .onChange(of: touchpadPointerEnabled) { _, _ in dependencies.applyPreferences() }
        .onChange(of: pointerSpeed) { _, _ in dependencies.applyPointerSettings() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissionCheck += 1
        }
    }
}

/// Verbindung und Tasten-Test. Eigene View, damit nur sie den Status beobachtet.
private struct ControllerConnectionRows: View {
    let status: ControllerStatus
    let isEnabled: Bool

    var body: some View {
        if let device = status.device, isEnabled {
            SettingsStatusRow(
                title: device.name,
                subtitle: batteryText(device.batteryLevel),
                tone: .ok,
                detail: "Connected"
            )
            SettingsRow(title: "Button test", subtitle: "Press a button on the controller.") {
                if let button = status.lastButton {
                    HStack(spacing: 8) {
                        ControllerGlyphView(text: button.glyph, round: button.isRoundGlyph)
                        Text(verbatim: button.displayName)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    // Derselbe Druck noch einmal: kurz aufblitzen lassen.
                    .id(status.lastButtonCount)
                    .transition(.opacity)
                } else {
                    Text(verbatim: "–")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(AppTheme.textTertiary)
                }
            }
        } else if isEnabled {
            SettingsStatusRow(
                title: "No controller connected",
                subtitle: "Connect a gamepad over Bluetooth or USB. See “Pairing” below.",
                tone: .off,
                detail: "Not connected"
            )
        } else {
            SettingsStatusRow(
                title: "No controller connected",
                subtitle: "Turn on controller support to use a connected gamepad.",
                tone: .off,
                detail: "Not connected"
            )
        }
    }

    private func batteryText(_ level: Float?) -> String {
        guard let level else { return String(localized: "Battery: not reported") }
        return String(localized: "Battery: \(Int((level * 100).rounded())) %")
    }
}

/// Ob Tasten ankommen, während ein anderes Programm vorne ist.
private struct ControllerBackgroundRow: View {
    let status: ControllerStatus
    let isEnabled: Bool

    var body: some View {
        if isEnabled {
            switch status.background {
            case .received:
                SettingsStatusRow(
                    title: "Buttons in the background",
                    subtitle: "A button press has arrived while another app was in front.",
                    tone: .ok, detail: "Works")
            case .unavailable:
                SettingsStatusRow(
                    title: "Buttons in the background",
                    subtitle: "This macOS version does not deliver controller input to apps in the background.",
                    tone: .error, detail: "Not available")
            case .waiting, .off:
                SettingsStatusRow(
                    title: "Buttons in the background",
                    subtitle: "Switch to another app and press a button to check.",
                    tone: .warn, detail: "Nothing received yet")
            }
        }
    }
}

/// Belegung zum Nachlesen, aus derselben Tabelle wie die Legende.
private struct ControllerBindingsSection: View {
    let section: ControllerLegendSection

    var body: some View {
        switch section.kind {
        case .core: SettingsSection("Core buttons") { rows }
        case .extra: SettingsSection("More buttons") { rows }
        case .layers: SettingsSection("Hold L1, R1 or L2: layers") { rows }
        }
    }

    @ViewBuilder
    private var rows: some View {
        Group {
            ForEach(Array(section.entries.enumerated()), id: \.offset) { _, entry in
                HStack(alignment: .center, spacing: 14) {
                    ControllerInputGlyphs(inputs: entry.inputs, isCombination: entry.isCombination)
                        .frame(width: 116, alignment: .leading)
                    Text(verbatim: entry.label.explanation)
                        .font(.system(size: 13))
                        .foregroundStyle(AppTheme.textPrimary)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 5)
            }
        }
    }
}
