import SwiftUI
@testable import WhisperM8

/// Xbox-Fassungen der Controller-Ansichten (Plan `controller-xbox-paddles.md`,
/// „Snapshots“): Einstellungen, Legende, Menü und Insel mit A B X Y.
extension UISnapshotGallery {
    @MainActor
    static func controllerXboxFixtures() -> [Fixture] {
        func xboxStatus(
            lastButton: ControllerButton? = nil, paddles: ControllerPaddleSupport = .readable
        ) -> ControllerStatus {
            let status = ControllerStatus()
            status.isRunning = true
            status.paddles = paddles
            status.lastButton = lastButton
            status.device = ControllerDeviceInfo(
                name: "Xbox Wireless Controller", category: "Xbox One",
                batteryLevel: nil, hasLight: false, hasHaptics: true, family: .xbox)
            return status
        }
        func page(_ status: ControllerStatus) -> AnyView {
            AnyView(ControllerSettingsPage(
                dependencies: ControllerSettingsDependencies(status: { status }, applyPreferences: {})))
        }
        func legend(_ context: ControllerContext, title: String = "WhisperM8 Xbox-Steuerung") -> AnyView {
            let traits = ControllerInputTraits(family: .xbox)
            return AnyView(VStack(spacing: 0) {
                Spacer(minLength: 0)
                ControllerLegendBar(
                    target: .make(context: context, chatTitle: title),
                    entries: ControllerLegend.entries(for: context, traits: traits))
            }
            .environment(\.controllerFamily, .xbox))
        }
        var chat = ControllerChatState(status: .idle, profile: .claude)
        chat.backTarget = ControllerBackTarget(kind: .chat, title: "Login-Fix")
        // Dieselben Insel- und Menü-Fixtures wie für den DualSense, mit Xbox-Zeichen.
        let reused = (islandFixtures() + islandPackageFixtures() + controllerFixtures().filter { $0.name == "controller-menue" })
            .filter { ["controller-insel-schnellbefehle-arbeitet", "controller-insel-paket-rauten",
                       "controller-insel-paket-wohin-aktuell", "controller-insel-schreiben", "controller-menue"]
                .contains($0.name) }
            .map { fixture in
                Fixture(name: fixture.name.replacingOccurrences(of: "controller-", with: "controller-xbox-"),
                        size: fixture.size, storage: fixture.storage) {
                    AnyView(fixture.view().environment(\.controllerFamily, .xbox))
                }
            }
        return reused + [
            Fixture(name: "controller-xbox-legende-chat", size: CGSize(width: 1340, height: 60)) { legend(.chat(chat)) },
            Fixture(name: "controller-xbox-legende-liste", size: CGSize(width: 1100, height: 60)) { legend(.list) },
            Fixture(name: "controller-xbox-legende-aussen", size: CGSize(width: 1100, height: 60)) {
                legend(.outsideApp(backgroundEnabled: true))
            },
            Fixture(
                name: "controller-xbox-einstellungen", size: CGSize(width: 760, height: 1950),
                storage: [PreferenceKeys.controllerEnabled: true, PreferenceKeys.controllerBackgroundEnabled: true]
            ) {
                page(xboxStatus(lastButton: .paddleUpperLeft))
            },
            Fixture(
                name: "controller-xbox-einstellungen-nicht-lesbar", size: CGSize(width: 760, height: 1950),
                storage: [PreferenceKeys.controllerEnabled: true, PreferenceKeys.controllerPaddleLowerRight: "claudeTasks"]
            ) {
                page(xboxStatus(lastButton: .cross, paddles: .notReadable(reason: "not permitted")))
            },
            Fixture(
                name: "controller-xbox-einstellungen-ohne-paddles", size: CGSize(width: 760, height: 1950),
                storage: [PreferenceKeys.controllerEnabled: true]
            ) {
                page(xboxStatus(lastButton: .touchpad, paddles: .noPaddles))
            },
        ]
    }
}
