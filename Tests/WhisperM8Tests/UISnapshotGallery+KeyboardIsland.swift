import AppKit
import SwiftUI
@testable import WhisperM8

extension UISnapshotGallery {
    /// Insel per Tastatur (⌥Tab, WM8-104): Kopf und Fußzeile mit Tastenkappen,
    /// Markierung auf „vorher“ (Entwurf insel-tastatur.html, Zustände 2, 3, 5, 7).
    @MainActor
    static func keyboardIslandFixtures() -> [Fixture] {
        let notch = ControllerIslandDisplay.Style.notch(width: 184, height: 32)
        let current = UUID()
        let previousChat = UUID()
        func chat(_ title: String, _ project: String, _ status: ControllerIslandStatus?, _ detail: String,
                  id: UUID = UUID()) -> ControllerIslandChatRow {
            ControllerIslandChatRow(id: id, title: title, project: project, status: status, detail: detail,
                                    isCurrent: id == current)
        }
        let chats = [
            chat("Controller Insel", "WhisperM8", .working, "jetzt", id: current),
            chat("Jarvis: Supervisor WhisperM8", "WhisperM8", .awaiting, "wartet · 2 min", id: previousChat),
            chat("Schlüsselbund Diktat", "WhisperM8", .idle, "bereit"),
            chat("Kampagnen Import", "ListM8", .working, "arbeitet · 6 min"),
            chat("Lead Varianten", "ListM8", .idle, "vor 40 min"),
            chat("Release 2.26", "WhisperM8", .idle, "vor 2 h"),
            chat("Archiv Suche", "WhisperM8", .stopped, "gestoppt"),
        ]
        let previousPlace = UUID()
        let places = [
            ControllerWorkspaceChoice(id: UUID(), name: "Controller-Raster", colorHex: "#5E6AD2", chatCount: 4,
                                      hasWaitingChat: false, isCurrent: true),
            ControllerWorkspaceChoice(id: previousPlace, name: "ListM8 Kampagnen", colorHex: "#3FA873", chatCount: 3,
                                      hasWaitingChat: true, isCurrent: false),
            ControllerWorkspaceChoice(id: UUID(), name: "Release 2.26", colorHex: "#C9962A", chatCount: 2,
                                      hasWaitingChat: false, isCurrent: false),
            ControllerWorkspaceChoice(id: UUID(), name: "whisperm8", colorHex: "#7A7D85", chatCount: 4,
                                      hasWaitingChat: false, isCurrent: false, kind: .project),
        ]
        var chatInfo = ControllerChatActionInfo(title: "Controller Insel")
        chatInfo.accounts = [
            ControllerAccountChoice(kind: .claude, name: "main", label: "main", isCurrent: true, isLoggedIn: true),
        ]
        let session = current
        func setup(dictating: Bool = false) -> ControllerMenuSetup {
            var setup = ControllerMenuSetup(
                acceptsInput: true, profile: .claude, sessionID: session, target: .chat(session), chat: chatInfo)
            setup.quickCross = .sendNow
            setup.dictationRunning = dictating
            return setup
        }
        func commands(dictating: Bool = false, configure: (inout ControllerKeyboardCommands) -> Void = { _ in })
            -> ControllerKeyboardCommands {
            var slots = ControllerQuickDrawSlots(setup: setup(dictating: dictating))
            slots.app = ControllerAppToggles(alert: .all, nextAlert: .soundOff, awake: .whileWorking)
            var commands = ControllerKeyboardCommands(
                slots: slots, transcriptEnabled: true, chatTitle: "Controller Insel")
            configure(&commands)
            return commands
        }
        func model(previous: ControllerWhereToState.Destination, grid: Bool = false, reopen: String? = nil,
                   target: ControllerIslandTarget = ControllerIslandTarget(title: "Controller Insel", status: .working),
                   keyboard: ControllerKeyboardCommands?)
            -> ControllerIslandModel {
            var state = ControllerWhereToState(
                chats: chats, currentChatID: current, workspaces: places, gridActive: grid, previous: previous)
            state.reopenTitle = reopen
            state.markPreviousForKeyboard()
            return ControllerIslandModel(target: target, content: .whereTo(state), input: .keyboard, keyboard: keyboard)
        }
        let chatsModel = model(previous: .chat(previousChat), reopen: "Lead Varianten", keyboard: commands())
        let placesModel = model(previous: .workspace(previousPlace), grid: true, keyboard: commands())
        let dictating = model(
            previous: .chat(previousChat),
            target: ControllerIslandTarget(title: "→ Controller Insel", status: .working, dictating: true),
            keyboard: commands(dictating: true))
        let toggled = model(previous: .chat(previousChat), keyboard: commands { commands in
            commands.slots.app.alert = .soundOff
            commands.slots.app.nextAlert = .off
            commands.slots.confirmation = .alert(.soundOff, next: .off)
            commands.slots.appHit = .alerts
            commands.releaseSwitches = false
        })
        let cheat = model(previous: .chat(previousChat), keyboard: commands { commands in
            commands.cheatSheet = true
            commands.releaseSwitches = false
        })
        let now = Date()
        let card = model(previous: .chat(previousChat), keyboard: commands { commands in
            commands.slots.card = ControllerLimitsCard(rows: [
                ControllerAccountLimitRow(kind: .claude, name: "main", fiveHour: 42, week: 61,
                                          fiveHourResetsAt: now.addingTimeInterval(7_800),
                                          weekResetsAt: now.addingTimeInterval(259_200), isCurrentChat: true),
                ControllerAccountLimitRow(kind: .claude, name: "konto-2", fiveHour: 12, week: 28,
                                          fiveHourResetsAt: now.addingTimeInterval(16_000),
                                          weekResetsAt: now.addingTimeInterval(432_000)),
            ], updatedAt: now, isLoading: false)
            commands.releaseSwitches = false
        })
        let paket1 = model(previous: .chat(previousChat), reopen: "Lead Varianten", keyboard: nil)

        func island(_ model: ControllerIslandModel, style: ControllerIslandDisplay.Style = notch,
                    counts: ControllerIslandCounts? = ControllerIslandCounts(working: 2, waiting: 1)) -> AnyView {
            let display = ControllerIslandDisplay(style: style, model: model, counts: counts)
            return AnyView(ControllerIslandView(display: display)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(AppTheme.sidebar))
        }
        // B per Tastatur: Options-Menü auf „Befehle ›“, Fußzeile mit Tastenkappen.
        func keyboardMenu() -> AnyView {
            var menu = ControllerMenuModel(setup: setup(), selected: .commands)
            _ = menu.openSubmenu()
            return AnyView(ControllerMenuCard(menu: menu, fallbackTitle: nil)
                .environment(\.controllerMenuByKeyboard, true)
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(AppTheme.sidebar))
        }
        // Legende unten im Fenster per Tastatur (Paket 3), folgt Hell und Dunkel.
        func legend() -> AnyView {
            AnyView(VStack(spacing: 0) {
                Spacer()
                ControllerLegendBar(
                    target: ControllerLegendTarget(title: "Controller Insel", detail: "working", tone: .working),
                    entries: [], keyboardItems: KeyboardLegend.items(dictationKeys: ["⌥", "␣"]))
            }
            .background(AppTheme.background))
        }
        let size = CGSize(width: 620, height: 560)
        return [
            Fixture(name: "insel-tastatur-legende", size: CGSize(width: 760, height: 80)) { legend() },
            Fixture(name: "insel-tastatur-menue", size: CGSize(width: 420, height: 1000)) { keyboardMenu() },
            Fixture(name: "insel-tastatur-chats", size: size) { island(chatsModel) },
            Fixture(name: "insel-tastatur-ohne-tastenzeile", size: size) { island(paket1) },
            Fixture(name: "insel-tastatur-schalter", size: size) { island(toggled) },
            Fixture(name: "insel-tastatur-spickzettel", size: size) { island(cheat, counts: nil) },
            Fixture(name: "insel-tastatur-limits", size: CGSize(width: 780, height: 420)) { island(card) },
            Fixture(name: "insel-tastatur-workspaces", size: size) { island(placesModel) },
            Fixture(name: "insel-tastatur-diktat", size: size) { island(dictating, counts: nil) },
            Fixture(name: "insel-tastatur-pille", size: size) { island(chatsModel, style: .pill) },
        ]
    }
}
