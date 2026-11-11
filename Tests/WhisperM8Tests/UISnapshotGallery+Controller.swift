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
        // Liste links mit Controller-Markierung (Etappe 6). Die Markierung liest
        // das geteilte `ControllerUIModel` — für den Snapshot gesetzt.
        func listWithMarker() -> AnyView {
            let windowID = UUID()
            let workspace = UUID(), chat1 = UUID(), chat2 = UUID(), chat3 = UUID(), project = UUID()
            let model = ControllerUIModel.shared
            model.area = .list
            model.listWindowID = windowID
            model.markedRow = .workspaceChat(session: chat2, workspace: workspace)
            func row(_ title: String, indent: Bool, bold: Bool = false, dot: Color? = nil) -> some View {
                HStack(spacing: 8) {
                    if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
                    Text(verbatim: title)
                        .font(.system(size: 12.5, weight: bold ? .semibold : .regular))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, indent ? 26 : 10)
                .padding(.trailing, 10)
                .frame(height: 26)
            }
            return AnyView(VStack(alignment: .leading, spacing: 2) {
                row("DealSupply: Expertenfunktionen", indent: false, bold: true)
                    .controllerListRow(.workspace(workspace))
                row("1 Moe · Doku: auf den neuesten Stand", indent: true, dot: AppTheme.statusWorking)
                    .controllerListRow(.workspaceChat(session: chat1, workspace: workspace))
                row("2 Lux · Integrationen: Einrichtung", indent: true, dot: AppTheme.statusAwaiting)
                    .controllerListRow(.workspaceChat(session: chat2, workspace: workspace))
                row("whisperm8", indent: false, bold: true)
                    .controllerListRow(.project(project))
                row("WhisperM8 PS5-Controller-Steuerung", indent: true, dot: AppTheme.textTertiary)
                    .controllerListRow(.chat(chat3))
            }
            .padding(.vertical, 8)
            .frame(width: 300, alignment: .leading)
            .background(AppTheme.sidebar)
            .environment(\.agentChatsWindowID, windowID))
        }
        // Aufnahme-Pill bei einer Aufnahme per Controller: Ziel und Modus ohne Hover.
        func pillWithTarget() -> AnyView {
            let controller = OverlayController(presentsWindow: false)
            controller.overlayStyle = .mini
            controller.levelModel.level = 0.5
            controller.controllerTargetLabel = "WhisperM8 PS5-Controller-Steuerung"
            return AnyView(RecordingPillView(controller: controller).padding(20))
        }
        let extraFixtures: [Fixture] = [
            Fixture(name: "controller-liste-markierung", size: CGSize(width: 340, height: 180)) { listWithMarker() },
            Fixture(name: "controller-pill-ziel", size: CGSize(width: 520, height: 80)) { pillWithTarget() },
        ]
        return legendFixtures + extraFixtures + [
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
