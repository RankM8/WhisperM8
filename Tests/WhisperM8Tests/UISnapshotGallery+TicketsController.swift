import SwiftUI
@testable import WhisperM8

/// Ticket-Board am Controller (WM8-91), Paket 1 „Öffnen und Umschalten“:
/// „Wohin“ mit dem Reiter „Tickets“ (aus einem Chat, im Board, Projekt ohne
/// Team), R1 im Board und die Leiste im Ticket-Modus. Teams außer WM8 sind
/// erfunden. `make snapshots ONLY=tickets-controller`.
extension UISnapshotGallery {
    @MainActor
    static func ticketsControllerFixtures() -> [Fixture] {
        let notch = ControllerIslandDisplay.Style.notch(width: 184, height: 32)
        let wm8 = UUID(), kun = UUID(), shop = UUID()
        let teams = [
            ControllerTicketTeam(team: "WM8", projectID: wm8, projectName: "whisperm8", colorHex: "#5E6AD2"),
            ControllerTicketTeam(team: "KUN", projectID: kun, projectName: "kundenportal", colorHex: "#3FA873"),
            ControllerTicketTeam(team: "SHOP", projectID: shop, projectName: "shop-backend", colorHex: "#C9962A"),
        ]
        let teamOf: [UUID: String] = [wm8: "WM8", kun: "KUN", shop: "SHOP"]
        func boards(here: UUID?, hereTeam: String?, inTickets: Bool, last: UUID?) -> ControllerTicketBoards {
            ControllerTicketBoards.make(
                teams: teams, hereProjectID: here, hereProjectName: "notizen", hereTeam: hereTeam,
                inTickets: inTickets, lastProjectID: last, teamOfProject: { teamOf[$0] },
                waiting: { $0 == "WM8" ? 6 : ($0 == "KUN" ? 1 : nil) })
        }
        let current = UUID()
        let chats = [
            ControllerIslandChatRow(id: current, title: "Jarvis: Supervisor WhisperM8", project: "WhisperM8",
                                    status: .working, detail: "jetzt", isCurrent: true),
            ControllerIslandChatRow(id: UUID(), title: "Board Controller", project: "WhisperM8",
                                    status: .awaiting, detail: "wartet · 2 min", isCurrent: false),
        ]
        let places = [
            ControllerWorkspaceChoice(id: UUID(), name: "WM8 Aktiv", colorHex: "#5E6AD2", chatCount: 6,
                                      hasWaitingChat: true, isCurrent: false),
        ]
        func whereTo(_ boards: ControllerTicketBoards, chatID: UUID?, title: String,
                     status: ControllerIslandStatus?, steps: Int = 0) -> ControllerIslandModel {
            var state = ControllerWhereToState(
                chats: chats, currentChatID: chatID, workspaces: places, gridActive: false, tickets: boards)
            while state.tab != .tickets, state.switchTab(1) {}
            if steps != 0 { state.move(steps) }
            return ControllerIslandModel(
                target: ControllerIslandTarget(title: title, status: status), content: .whereTo(state))
        }
        let fromChat = whereTo(boards(here: wm8, hereTeam: "WM8", inTickets: false, last: kun),
                               chatID: current, title: "Jarvis: Supervisor WhisperM8", status: .working)
        let inBoard = whereTo(boards(here: wm8, hereTeam: "WM8", inTickets: true, last: wm8),
                              chatID: nil, title: "Tickets · WM8", status: nil, steps: 1)
        let withoutTeam = whereTo(boards(here: UUID(), hereTeam: nil, inTickets: false, last: nil),
                                  chatID: current, title: "Notizen", status: .idle)
        var slots = ControllerQuickDrawSlots(setup: ControllerMenuSetup(ticketsShown: true))
        slots.app = ControllerAppToggles(alert: .all, nextAlert: .soundOff, awake: .whileWorking)
        slots.note = .noBoardChat
        let r1 = ControllerIslandModel(
            target: ControllerIslandTarget(title: "Tickets · WM8", status: nil), content: .quickDraw(slots))

        func island(_ model: ControllerIslandModel, style: ControllerIslandDisplay.Style = notch) -> AnyView {
            AnyView(ControllerIslandView(display: ControllerIslandDisplay(style: style, model: model))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(AppTheme.sidebar))
        }
        func legend(_ back: ControllerBackTarget?) -> AnyView {
            let context = ControllerContext.tickets(ControllerTicketState(
                place: ControllerTicketsPlace(projectID: wm8, team: "WM8"), backTarget: back))
            return AnyView(VStack(spacing: 0) {
                Spacer(minLength: 0)
                ControllerLegendBar(
                    target: .make(context: context, chatTitle: "Tickets · WM8"),
                    entries: ControllerLegend.entries(for: context))
            })
        }
        func chatLegend() -> AnyView {
            var state = ControllerChatState(status: .working, profile: .claude)
            state.backTarget = ControllerBackTarget(kind: .tickets, title: "WM8", id: wm8)
            return AnyView(VStack(spacing: 0) {
                Spacer(minLength: 0)
                ControllerLegendBar(
                    target: .make(context: .chat(state), chatTitle: "Jarvis: Supervisor WhisperM8"),
                    entries: ControllerLegend.entries(for: .chat(state)))
            })
        }
        let list = CGSize(width: 620, height: 400)
        let legendSize = CGSize(width: 1240, height: 60)
        return [
            Fixture(name: "tickets-controller-wohin", size: list) { island(fromChat) },
            Fixture(name: "tickets-controller-wohin-pille", size: list) { island(fromChat, style: .pill) },
            Fixture(name: "tickets-controller-wohin-im-board", size: list) { island(inBoard) },
            Fixture(name: "tickets-controller-wohin-ohne-team", size: list) { island(withoutTeam) },
            Fixture(name: "tickets-controller-r1", size: CGSize(width: 760, height: 320)) { island(r1) },
            Fixture(name: "tickets-controller-leiste", size: legendSize) {
                legend(ControllerBackTarget(kind: .chat, title: "Jarvis: Supervisor WhisperM8"))
            },
            Fixture(name: "tickets-controller-leiste-chat-zurueck", size: legendSize) { chatLegend() },
        ]
    }

    /// Paket 2 (WM8-91): Board mit ausgewählter Karte und Leiste, „N weitere“
    /// gewählt, Triage, Chat-Zeile und die Menü-Karte am Ticket. Das Board ist
    /// dasselbe wie in `ticketBoardFixtures` (Team WM8, Personen erfunden).
    @MainActor
    static func ticketsControllerBoardFixtures(
        view: @escaping ((TicketBoardViewModel) -> Void) -> AnyView, comments: TicketComments
    ) -> [Fixture] {
        let ui = ControllerUIModel.shared
        func place(_ view: ControllerTicketView, chatLine: String? = nil, chats: Bool = false) -> ControllerContext {
            var place = ControllerTicketsPlace(projectID: nil, team: "WM8")
            place.view = view
            place.hasTicket = true
            place.ticketHasChats = chats
            place.chatLineTitle = chatLine
            return .tickets(ControllerTicketState(
                place: place, backTarget: ControllerBackTarget(kind: .chat, title: "Jarvis: Supervisor")))
        }
        func screen(_ context: ControllerContext, menu: ControllerMenuModel? = nil,
                    _ configure: @escaping (TicketBoardViewModel) -> Void) -> AnyView {
            ui.menu = menu
            return AnyView(VStack(spacing: 0) {
                view(configure)
                    .overlayPreferenceValue(ControllerMenuAnchorKey.self) { anchors in
                        if let menu {
                            ControllerMenuCardResolver(menu: menu, fallbackTitle: "Tickets · WM8", anchors: anchors, bottomInset: 0)
                        }
                    }
                ControllerLegendBar(
                    target: .make(context: context, chatTitle: "Tickets · WM8"),
                    entries: ControllerLegend.entries(for: context))
            })
        }
        var setup = ControllerMenuSetup()
        setup.ticketsShown = true
        setup.ticket = ControllerTicketMenuInfo(
            key: "WM8-81", chats: [.init(id: UUID(), title: "Jon")], hasURL: true, waitingFilterOn: false)
        let menu = ControllerMenuModel(setup: setup)
        let size = CGSize(width: 1340, height: 900)
        return [
            Fixture(name: "tickets-controller-board", size: size) {
                screen(place(.board)) { $0.setBoardSpot(.card("WM8-69")) }
            },
            // Hoch genug, dass „N weitere“ unter den acht Karten zu sehen ist.
            Fixture(name: "tickets-controller-board-weitere", size: CGSize(width: 1340, height: 1760)) {
                screen(place(.board)) { $0.setBoardSpot(.more(column: "s0")) }
            },
            Fixture(name: "tickets-controller-triage", size: size) {
                screen(place(.triage, chats: true)) {
                    $0.openFromLane("WM8-81")
                    $0.setComments(.loaded(comments), ticketID: "id-81")
                }
            },
            Fixture(name: "tickets-controller-chat-zeile", size: size) {
                screen(place(.chatLine, chatLine: "Jon", chats: true)) {
                    $0.openFromLane("WM8-81")
                    $0.setComments(.loaded(comments), ticketID: "id-81")
                    $0.triageFocus = .chat(0)
                }
            },
            Fixture(name: "tickets-controller-menue", size: size) {
                screen(place(.board), menu: menu) { $0.setBoardSpot(.card("WM8-81")) }
            },
        ]
    }
}
