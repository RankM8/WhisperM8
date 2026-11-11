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
            Fixture(name: "controller-legende-gestoppt", size: legendSize) {
                var state = chat
                state.status = .ended
                state.hasTerminal = false
                return legend(.chat(state), title: "3 Kit · Release-Notizen")
            },
            Fixture(name: "controller-legende-liste", size: legendSize) { legend(.list) },
            Fixture(name: "controller-legende-aufnahme", size: legendSize) {
                legend(.recording(phase: .recording, targetIsChat: true))
            },
            Fixture(name: "controller-legende-pause", size: legendSize) { legend(.paused) },
            Fixture(name: "controller-menue", size: CGSize(width: 1340, height: 600)) {
                let session = UUID()
                var chat = ControllerChatActionInfo(title: "2 Lux · Integrationen", isPinned: true, canFork: true)
                chat.accounts = [
                    ControllerAccountChoice(kind: .claude, name: "main", label: "main (giuliano@example.com)",
                                            isCurrent: true, isLoggedIn: true),
                    ControllerAccountChoice(kind: .claude, name: "work", label: "work (team@example.com)",
                                            isCurrent: false, isLoggedIn: true),
                    ControllerAccountChoice(kind: .claude, name: "old", label: "old (not signed in)",
                                            isCurrent: false, isLoggedIn: false),
                    ControllerAccountChoice(kind: .gpt, name: "main", label: "main · gpt@example.com",
                                            isCurrent: true, isLoggedIn: true),
                ]
                let setup = ControllerMenuSetup(
                    acceptsInput: true, profile: .claude, sessionID: session, target: .chat(session), chat: chat)
                var question = setup
                question.dialogOpen = true
                var commands = ControllerMenuModel(setup: setup, selected: .commands)
                _ = commands.openSubmenu()
                commands.move(1)
                var accounts = ControllerMenuModel(setup: setup, selected: .switchAccount)
                _ = accounts.openSubmenu()
                return AnyView(HStack(alignment: .top, spacing: 20) {
                    ControllerMenuPanel(menu: ControllerMenuModel(setup: setup))
                    ControllerMenuPanel(menu: ControllerMenuModel(setup: question))
                    ControllerMenuPanel(menu: commands)
                    ControllerMenuPanel(menu: accounts)
                }.padding(20).frame(maxHeight: .infinity, alignment: .top))
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
        // Liste der Ausgabemodi über der Pill (Moduswechsel per Steuerkreuz).
        func pillWithModeList() -> AnyView {
            let controller = OverlayController(presentsWindow: false)
            controller.overlayStyle = .mini
            controller.levelModel.level = 0.5
            controller.controllerTargetLabel = "WhisperM8 PS5-Controller-Steuerung"
            let modes = Array(OutputMode.builtInModes.prefix(6))
            controller.selectedOutputMode = modes[2]
            return AnyView(VStack(spacing: 8) {
                OutputModeListView(modes: modes, selectedID: modes[2].id)
                RecordingPillView(controller: controller)
            }
            .padding(20)
            .environment(\.colorScheme, .dark))
        }
        let extraFixtures: [Fixture] = [
            Fixture(name: "controller-pill-modusliste", size: CGSize(width: 520, height: 330)) { pillWithModeList() },
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
