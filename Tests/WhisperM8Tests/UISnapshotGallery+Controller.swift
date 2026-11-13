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
        let size = CGSize(width: 760, height: 1950)
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
            Fixture(name: "controller-legende-chat", size: CGSize(width: 1340, height: 60)) {
                var state = chat
                state.backTarget = ControllerBackTarget(kind: .chat, title: "Login-Fix")
                return legend(.chat(state))
            },
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
            // Review nach Runde 3: Liste aus dem Menü offen (Pfeiltasten, Kreuz
            // bestätigt) und Shell (ohne Leerzeichen und Leeren).
            Fixture(name: "controller-legende-auswahl", size: CGSize(width: 1340, height: 60)) {
                var state = chat
                state.choiceListOpen = true
                return legend(.chat(state), title: "2 Lux · Integrationen")
            },
            Fixture(name: "controller-legende-shell", size: legendSize) {
                legend(.chat(ControllerChatState(status: .idle, profile: .shell)), title: "zsh")
            },
            Fixture(name: "controller-legende-liste", size: legendSize) { legend(.list) },
            Fixture(name: "controller-legende-aufnahme", size: legendSize) {
                legend(.recording(phase: .recording, targetIsChat: true))
            },
            Fixture(name: "controller-legende-pause", size: legendSize) { legend(.paused) },
            // Raster: L2 getippt führt zurück in den vorigen Workspace.
            Fixture(name: "controller-legende-raster", size: CGSize(width: 1340, height: 60)) {
                var state = chat
                state.gridActive = true
                state.backTarget = ControllerBackTarget(kind: .workspace, title: "Marketing")
                return legend(.chat(state), title: "2 Lux · Integrationen")
            },
            Fixture(name: "controller-menue", size: CGSize(width: 1340, height: 900)) {
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
                chat.accounts[1].fiveHourUsed = 12
                chat.accounts[1].weekUsed = 28
                chat.accounts[0].fiveHourUsed = 42
                chat.accounts[0].weekUsed = 61
                chat.accounts = ControllerAccountHeadroom.marked(chat.accounts)
                // Runde 5: Kopf-Aktionen einer Kachel mit Notiz.
                chat.hasProject = true
                chat.projectOpenTargetName = "PhpStorm"
                chat.canRefreshTitle = true
                chat.canRestart = true
                chat.hasTab = true
                chat.notesAvailable = true
                chat.notesDefaultOpen = true
                chat.tileNoteOpen = false
                chat.removableWorkspaceName = "Marketing"
                chat.shownInWorkspace = ControllerWorkspaceContext(
                    id: UUID(), name: "Marketing", gridVisible: true, chatIsMember: true, isCurated: true)
                chat.pendingAccountSwitchTarget = "work"
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
                    ControllerMenuCard(menu: ControllerMenuModel(setup: setup), fallbackTitle: nil).pillGlassShadow()
                    ControllerMenuCard(menu: ControllerMenuModel(setup: question), fallbackTitle: nil).pillGlassShadow()
                    ControllerMenuCard(menu: commands, fallbackTitle: nil).pillGlassShadow()
                    ControllerMenuCard(menu: accounts, fallbackTitle: nil).pillGlassShadow()
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
        let extraFixtures: [Fixture] = islandFixtures() + islandPackageFixtures() + [
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

    /// Controller-Insel (Runde 4) in den Zuständen des Entwurfs
    /// (`docs/design/controller-insel.html`), an der Notch und als Pille.
    @MainActor
    static func islandFixtures() -> [Fixture] {
        let notch = ControllerIslandDisplay.Style.notch(width: 184, height: 32)
        let current = UUID()
        func row(_ title: String, _ project: String, _ status: ControllerIslandStatus?, _ detail: String,
                 id: UUID = UUID()) -> ControllerIslandChatRow {
            ControllerIslandChatRow(id: id, title: title, project: project, status: status, detail: detail,
                                    isCurrent: id == current)
        }
        let chats = [
            row("Controller Insel", "WhisperM8", .working, "jetzt", id: current),
            row("Jarvis: Supervisor WhisperM8", "WhisperM8", .awaiting, "wartet · 2 min"),
            row("E2E Befunde Raster", "WhisperM8", .idle, "bereit"),
            row("Kampagnen Import", "ListM8", .working, "arbeitet · 6 min"),
            row("Lead Varianten", "ListM8", .errored, "Fehler"),
            row("Release Notizen 2.26", "WhisperM8", .idle, "bereit"),
        ] + (0..<9).map { row("Älterer Chat \($0 + 1)", "WhisperM8", .idle, "bereit") }
        let workspaces = [
            ControllerWorkspaceChoice(id: UUID(), name: "WhisperM8", colorHex: "#5E6AD2", chatCount: 6,
                                      hasWaitingChat: false, isCurrent: true),
            ControllerWorkspaceChoice(id: UUID(), name: "ListM8", colorHex: "#3FA873", chatCount: 4,
                                      hasWaitingChat: true, isCurrent: false),
            ControllerWorkspaceChoice(id: UUID(), name: "DealSupply", colorHex: "#C9962A", chatCount: 3,
                                      hasWaitingChat: false, isCurrent: false),
            ControllerWorkspaceChoice(id: UUID(), name: "Aktiv", colorHex: "#D6473D", chatCount: 5,
                                      hasWaitingChat: false, isCurrent: false),
        ]
        let target = ControllerIslandTarget(title: "Controller Insel", status: .working)
        /// Die Liste steht sofort da, die Markierung auf dem aktuellen Ort;
        /// der vorige (hier „Jarvis“ bzw. „ListM8“) trägt „vorher“ und steht
        /// gleich darunter.
        func whereTo(grid: Bool, previous: Bool = true, open: [Int] = []) -> ControllerIslandModel {
            let back: ControllerWhereToState.Destination = previous
                ? (grid ? .workspace(workspaces[1].id) : .chat(chats[1].id)) : .stay
            var state = ControllerWhereToState(
                chats: chats, currentChatID: current, workspaces: workspaces, gridActive: grid, previous: back)
            for step in open { state.move(step) }
            return ControllerIslandModel(target: target, content: .whereTo(state))
        }
        let session = UUID()
        var chatInfo = ControllerChatActionInfo(title: "Controller Insel")
        chatInfo.accounts = [
            ControllerAccountChoice(kind: .claude, name: "main", label: "main", isCurrent: true, isLoggedIn: true),
            ControllerAccountChoice(kind: .claude, name: "work", label: "work", isCurrent: false, isLoggedIn: true),
        ]
        var setup = ControllerMenuSetup(
            acceptsInput: true, profile: .claude, sessionID: session, target: .chat(session), chat: chatInfo)
        let quickDraw = ControllerIslandModel(
            target: ControllerIslandTarget(title: "Controller Insel", status: .idle),
            content: .quickDraw(ControllerQuickDrawSlots(setup: setup)))
        var busySetup = setup
        busySetup.chatBusy = true
        let quickDrawBusy = ControllerIslandModel(
            target: ControllerIslandTarget(title: "Controller Insel", status: .working),
            content: .quickDraw(ControllerQuickDrawSlots(setup: busySetup)))
        setup.dialogOpen = true
        let quickDrawQuestion = ControllerIslandModel(
            target: ControllerIslandTarget(title: "Jarvis: Supervisor", status: .awaiting),
            content: .quickDraw(ControllerQuickDrawSlots(setup: setup, hit: .switchAccount)))
        let writing = ControllerIslandModel(
            target: ControllerIslandTarget(title: "Controller Insel", status: .idle),
            content: .writing(ControllerWritingSlots(state: ControllerChatState(status: .idle, profile: .claude))))
        // Runde 5: L1 mit Text bzw. Bild zum Einfügen, R1 mit „Jetzt senden“
        // und mit laufendem Diktat.
        let writingPaste = ControllerIslandModel(
            target: ControllerIslandTarget(title: "Controller Insel", status: .working),
            content: .writing(ControllerWritingSlots(
                state: ControllerChatState(status: .working, profile: .claude),
                clip: ControllerClipPreview(id: "t", kind: .text, preview: "Bitte die Tests für den Konto-Wechsel ergänzen"))))
        let writingImage = ControllerIslandModel(
            target: ControllerIslandTarget(title: "Controller Insel", status: .idle),
            content: .writing(ControllerWritingSlots(
                state: ControllerChatState(status: .idle, profile: .claude),
                clip: ControllerClipPreview(id: "i", kind: .image, preview: "", imageWidth: 1280, imageHeight: 800))))
        var sendNowSetup = busySetup
        sendNowSetup.quickCross = .sendNow
        let quickDrawSendNow = ControllerIslandModel(
            target: ControllerIslandTarget(title: "Controller Insel", status: .working),
            content: .quickDraw(ControllerQuickDrawSlots(setup: sendNowSetup)))
        var dictatingSetup = busySetup
        dictatingSetup.dictationRunning = true
        let quickDrawDictating = ControllerIslandModel(
            target: ControllerIslandTarget(title: "→ Controller Insel", status: .working),
            content: .quickDraw(ControllerQuickDrawSlots(setup: dictatingSetup)))
        let writingShell = ControllerIslandModel(
            target: ControllerIslandTarget(title: "zsh · whisperm8", status: .idle),
            content: .writing(ControllerWritingSlots(state: ControllerChatState(status: .idle, profile: .shell))))

        func island(_ model: ControllerIslandModel, style: ControllerIslandDisplay.Style = notch,
                    counts: ControllerIslandCounts? = nil) -> AnyView {
            let display = ControllerIslandDisplay(style: style, model: model, counts: counts)
            return AnyView(ControllerIslandView(display: display)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(AppTheme.sidebar))
        }

        /// Bildschirm ohne Notch mit der Pille an `pill` (Anteil am
        /// Bildschirm) und der Insel, die aus ihr wächst — oben nach unten,
        /// unten nach oben.
        func pillScene(_ model: ControllerIslandModel, pill: NotchPillPosition?, size: CGSize) -> AnyView {
            let screen = NotchScreenInfo(
                displayID: 9, frame: CGRect(origin: .zero, size: size),
                visibleFrame: CGRect(x: 0, y: 0, width: size.width, height: size.height - 25),
                safeAreaTop: 0, auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil, isBuiltIn: false)
            let display = ControllerIslandDisplay(
                style: .pill, model: model, counts: ControllerIslandCounts(working: 2, waiting: 1),
                opensUpward: ControllerIslandGeometry.opensUpward(screen: screen, stored: pill))
            let host = NSHostingView(rootView: ControllerIslandView(display: display))
            let body = CGSize(width: display.bodyWidth, height: host.fittingSize.height)
            let frame = ControllerIslandGeometry.frame(screen: screen, bodySize: body, stored: pill)
            return AnyView(
                ZStack(alignment: .topLeading) {
                    LinearGradient(colors: [Color(red: 0.80, green: 0.84, blue: 0.93), Color(red: 0.93, green: 0.86, blue: 0.82)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Rectangle().fill(Color.white.opacity(0.55)).frame(height: 25)
                    ControllerIslandView(display: display)
                        .shadow(color: .black.opacity(0.3), radius: 12, x: 0, y: 3)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: size.height - frame.maxY)
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .clipped())
        }
        let size = CGSize(width: 620, height: 470)
        let small = CGSize(width: 620, height: 230)
        // Raute mit Hinweiszeile darunter braucht etwas mehr Höhe.
        let smallNote = CGSize(width: 620, height: 260)
        return [
            // L2 gehalten: Liste sofort, Markierung auf dem vorigen Chat.
            Fixture(name: "controller-insel-wohin-chats", size: size) { island(whereTo(grid: false)) },
            Fixture(name: "controller-insel-wohin-chats-bewegt", size: size) { island(whereTo(grid: false, open: [1, 1])) },
            // Ohne vorigen Ort: Markierung auf dem aktuellen Chat, Loslassen tut nichts.
            Fixture(name: "controller-insel-wohin-ohne-vorher", size: size) { island(whereTo(grid: false, previous: false)) },
            Fixture(name: "controller-insel-wohin-workspaces", size: size) { island(whereTo(grid: true)) },
            Fixture(name: "controller-insel-wohin-notch-zaehler", size: size) {
                island(whereTo(grid: false), counts: ControllerIslandCounts(working: 2, waiting: 1))
            },
            Fixture(name: "controller-insel-schreiben", size: small) { island(writing) },
            Fixture(name: "controller-insel-schreiben-shell", size: small) { island(writingShell) },
            Fixture(name: "controller-insel-schreiben-einfuegen", size: smallNote) { island(writingPaste) },
            Fixture(name: "controller-insel-schreiben-bild", size: small) { island(writingImage, style: .pill) },
            Fixture(name: "controller-insel-schnellbefehle-jetzt-senden", size: small) { island(quickDrawSendNow) },
            Fixture(name: "controller-insel-schnellbefehle-diktat", size: smallNote) { island(quickDrawDictating) },
            Fixture(name: "controller-insel-schnellbefehle", size: small) { island(quickDraw) },
            Fixture(name: "controller-insel-schnellbefehle-rueckfrage", size: smallNote) { island(quickDrawQuestion) },
            // Review nach Runde 4: Chat arbeitet — Weiter und Modus aus.
            Fixture(name: "controller-insel-schnellbefehle-arbeitet", size: smallNote) { island(quickDrawBusy) },
            // Mit Notch-Zählern bleibt bei L1 und R1 der Ziel-Chat im Kopf.
            Fixture(name: "controller-insel-schnellbefehle-notch-zaehler", size: small) {
                island(quickDraw, counts: ControllerIslandCounts(working: 2, waiting: 1))
            },
            Fixture(name: "controller-insel-schreiben-notch-zaehler", size: small) {
                island(writing, counts: ControllerIslandCounts(working: 2, waiting: 1))
            },
            Fixture(name: "controller-insel-pille-chats", size: size) {
                island(whereTo(grid: false, open: [1]), style: .pill)
            },
            // Pille oben mittig: Insel wächst nach unten; Pille unten links: nach oben.
            Fixture(name: "controller-insel-pille-oben-nach-unten", size: CGSize(width: 900, height: 560)) {
                pillScene(whereTo(grid: false), pill: nil, size: CGSize(width: 900, height: 560))
            },
            Fixture(name: "controller-insel-pille-unten-nach-oben", size: CGSize(width: 900, height: 560)) {
                pillScene(whereTo(grid: true), pill: NotchPillPosition(x: 0.2, y: 0.1), size: CGSize(width: 900, height: 560))
            },
            Fixture(name: "controller-insel-pille-schnellbefehle", size: small) { island(quickDraw, style: .pill) },
            Fixture(name: "controller-insel-pille-schreiben-shell", size: small) { island(writingShell, style: .pill) },
        ]
    }
}
