import SwiftUI

/// Einstellungen › Controller › Paddles (Plan `controller-xbox-paddles.md`,
/// Schritt 7): Zustand der Paddles, Belegung je Paddle, Standard. Der
/// Abschnitt steht immer da; die Zustandszeile erklärt, ob Paddles lesbar sind.
struct ControllerPaddleSection: View {
    let status: ControllerStatus
    let applyPreferences: @MainActor () -> Void
    let requestAccess: @MainActor () -> Void

    @AppStorage(PreferenceKeys.controllerPaddleUpperLeft) private var upperLeft = ControllerPaddleBinding.nextWaiting.rawValue
    @AppStorage(PreferenceKeys.controllerPaddleLowerLeft) private var lowerLeft = ControllerPaddleBinding.answer.rawValue
    @AppStorage(PreferenceKeys.controllerPaddleUpperRight) private var upperRight = ControllerPaddleBinding.sendNow.rawValue
    @AppStorage(PreferenceKeys.controllerPaddleLowerRight) private var lowerRight = ControllerPaddleBinding.cycleMode.rawValue

    var body: some View {
        SettingsSection("Paddles") {
            ControllerPaddleStateRow(state: status.paddles, requestAccess: requestAccess)
            SettingsPickerRow(title: "Upper left", subtitle: ControllerPaddle.upperLeft.shortName,
                              selection: binding(.upperLeft), options: ControllerPaddleBinding.allCases) { option in
                Text(verbatim: option.title)
            }
            SettingsPickerRow(title: "Lower left", subtitle: ControllerPaddle.lowerLeft.shortName,
                              selection: binding(.lowerLeft), options: ControllerPaddleBinding.allCases) { option in
                Text(verbatim: option.title)
            }
            SettingsPickerRow(title: "Upper right", subtitle: ControllerPaddle.upperRight.shortName,
                              selection: binding(.upperRight), options: ControllerPaddleBinding.allCases) { option in
                Text(verbatim: option.title)
            }
            SettingsPickerRow(title: "Lower right", subtitle: ControllerPaddle.lowerRight.shortName,
                              selection: binding(.lowerRight), options: ControllerPaddleBinding.allCases) { option in
                Text(verbatim: option.title)
            }
            SettingsButtonRow(title: "Standard assignment") {
                Button("Reset to defaults") {
                    for paddle in ControllerPaddle.allCases {
                        store(ControllerPaddleBindings.standardBinding(for: paddle), for: paddle)
                    }
                }
                .buttonStyle(SettingsButtonStyle.standard)
            }
            SettingsHelpText("Paddles act only in WhisperM8, with a single press — not inside a layer and not while recording. Leave them on A, B, X, Y in the controller profile: WhisperM8 ignores that button when it can read the paddle.")
        }
        .onChange(of: upperLeft) { _, _ in applyPreferences() }
        .onChange(of: lowerLeft) { _, _ in applyPreferences() }
        .onChange(of: upperRight) { _, _ in applyPreferences() }
        .onChange(of: lowerRight) { _, _ in applyPreferences() }
    }

    private func binding(_ paddle: ControllerPaddle) -> Binding<ControllerPaddleBinding> {
        Binding(
            get: {
                let raw: String
                switch paddle {
                case .upperLeft: raw = upperLeft
                case .lowerLeft: raw = lowerLeft
                case .upperRight: raw = upperRight
                case .lowerRight: raw = lowerRight
                }
                return ControllerPaddleBinding(rawValue: raw) ?? ControllerPaddleBindings.standardBinding(for: paddle)
            },
            set: { store($0, for: paddle) })
    }

    private func store(_ binding: ControllerPaddleBinding, for paddle: ControllerPaddle) {
        switch paddle {
        case .upperLeft: upperLeft = binding.rawValue
        case .lowerLeft: lowerLeft = binding.rawValue
        case .upperRight: upperRight = binding.rawValue
        case .lowerRight: lowerRight = binding.rawValue
        }
    }
}

/// Ob die Paddles lesbar sind; bei „nicht lesbar“ mit dem Weg zur Freigabe.
private struct ControllerPaddleStateRow: View {
    let state: ControllerPaddleSupport
    let requestAccess: @MainActor () -> Void

    var body: some View {
        switch state {
        case .readable:
            SettingsStatusRow(
                title: "Paddles",
                subtitle: "Paddles detected. Each one is its own button; the Xbox button opens the clipboard history.",
                tone: .ok, detail: "Detected")
        case .noPaddles:
            SettingsStatusRow(
                title: "Paddles",
                subtitle: "This Xbox controller has no paddles. The Xbox button opens the clipboard history.",
                tone: .off, detail: "No paddles")
        case .none:
            SettingsStatusRow(
                title: "Paddles",
                subtitle: "No controller with paddles connected.",
                tone: .off, detail: "Not connected")
        case .disabled:
            SettingsStatusRow(
                title: "Paddles",
                subtitle: "Reading paddles is switched off. They act as the buttons of the controller profile.",
                tone: .off, detail: "Off")
        case .notReadable:
            SettingsStatusRow(
                title: "Paddles",
                subtitle: "Paddles not readable — they act as the buttons of the controller profile, and the Xbox button does nothing. Allow WhisperM8 under Input Monitoring, then restart the app.",
                tone: .warn, detail: "Not readable"
            ) {
                Button("Allow in System Settings…") { requestAccess() }
                    .buttonStyle(SettingsButtonStyle.standard)
            }
        }
    }
}

extension ControllerPaddle {
    /// „P3“: Elite-Zählung.
    var shortName: String { "P\(eliteNumber)" }
}

extension ControllerPaddleBinding {
    /// Eintrag der Auswahlliste.
    var title: String {
        switch self {
        case .nextWaiting: return String(localized: "Next waiting chat")
        case .answer: return String(localized: "Answer")
        case .sendNow: return String(localized: "Send now / Continue")
        case .cycleMode: return String(localized: "Switch mode")
        case .lastChat: return String(localized: "Back to previous place")
        case .pasteNewest: return String(localized: "Paste from clipboard")
        case .undo: return String(localized: "Undo")
        case .clipboardHistory: return String(localized: "Open clipboard history")
        case .pause: return String(localized: "Pause controller")
        case .claudeWorkflows: return String(localized: "Claude: /workflows")
        case .claudeTasks: return String(localized: "Claude: /tasks")
        case .none: return String(localized: "Nothing")
        }
    }
}
