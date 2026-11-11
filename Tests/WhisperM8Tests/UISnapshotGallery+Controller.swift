import SwiftUI
@testable import WhisperM8

/// Fixtures der Controller-Steuerung: Einstellungsseite in ihren Zuständen.
extension UISnapshotGallery {
    @MainActor
    static func controllerFixtures() -> [Fixture] {
        func status(
            connected: Bool, lastButton: ControllerButton? = nil,
            background: ControllerBackgroundState = .off
        ) -> ControllerStatus {
            let status = ControllerStatus()
            status.isRunning = connected
            status.background = background
            status.lastButton = lastButton
            if connected {
                status.device = ControllerDeviceInfo(
                    name: "DualSense Wireless Controller", category: "DualSense",
                    batteryLevel: nil, hasLight: true, hasHaptics: true)
            }
            return status
        }
        func page(_ status: ControllerStatus) -> AnyView {
            AnyView(ControllerSettingsPage(
                dependencies: ControllerSettingsDependencies(status: { status }, applyPreferences: {})
            ))
        }
        let size = CGSize(width: 760, height: 1500)
        let chat = ControllerChatState(status: .idle, profile: .claude)
        func legend(_ context: ControllerContext, title: String = "WhisperM8 PS5-Controller-Steuerung",
                    hold: ControllerButton? = nil) -> AnyView {
            AnyView(VStack(spacing: 0) {
                Spacer(minLength: 0)
                ControllerLegendBar(
                    target: .make(context: context, chatTitle: title),
                    entries: ControllerLegend.entries(for: context),
                    holdProgress: hold.map { ControllerHoldProgress(button: $0, startedAt: .distantPast, duration: 0) }
                )
            })
        }
        let legendSize = CGSize(width: 1100, height: 60)
        let legendFixtures: [Fixture] = [
            Fixture(name: "controller-legende-chat", size: legendSize) { legend(.chat(chat)) },
            Fixture(name: "controller-legende-rueckfrage", size: legendSize) {
                var state = chat
                state.status = .awaitingInput
                state.secondsSinceAwaitingBegan = 3
                return legend(.chat(state), title: "2 Lux · Integrationen")
            },
            Fixture(name: "controller-legende-arbeitet", size: legendSize) {
                var state = chat
                state.status = .working
                return legend(.chat(state), title: "1 Moe · Doku: auf den neuesten Stand", hold: .circle)
            },
            Fixture(name: "controller-legende-liste", size: legendSize) { legend(.list) },
            Fixture(name: "controller-legende-aufnahme", size: legendSize) {
                legend(.recording(phase: .recording, targetIsChat: true))
            },
            Fixture(name: "controller-legende-pause", size: legendSize) { legend(.paused) },
            Fixture(name: "controller-menue", size: CGSize(width: 680, height: 340)) {
                AnyView(HStack(alignment: .top, spacing: 24) {
                    ControllerMenuPanel(heading: "2 Lux · Integrationen", menu: ControllerMenuModel(), dialogOpen: false)
                    ControllerMenuPanel(
                        heading: "2 Lux · Integrationen",
                        menu: ControllerMenuModel(selected: .cycleMode), dialogOpen: true)
                }.padding(20))
            },
        ]
        return legendFixtures + [
            Fixture(name: "controller-einstellungen-aus", size: size) {
                page(status(connected: false))
            },
            Fixture(
                name: "controller-einstellungen-verbunden", size: size,
                storage: [PreferenceKeys.controllerEnabled: true]
            ) {
                page(status(connected: true, lastButton: .cross))
            },
            Fixture(
                name: "controller-einstellungen-hintergrund", size: size,
                storage: [PreferenceKeys.controllerEnabled: true, PreferenceKeys.controllerBackgroundEnabled: true]
            ) {
                page(status(connected: true, lastButton: .r2, background: .received))
            },
        ]
    }
}
