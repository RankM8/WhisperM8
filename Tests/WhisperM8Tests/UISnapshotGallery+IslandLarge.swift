import AppKit
import SwiftUI
import XCTest
@testable import WhisperM8

/// Snapshot-Fixtures der Controller-Insel als große Form an einer
/// Kamera-Insel: alle Ebenen (Wohin mit Kacheln je Reiter, Schreiben,
/// Schnellbefehle, Limits, Tastatur) und die Kapsel, aus der sie wächst.
/// Attrappe und Maße wie in `UISnapshotGallery+NotchIsland.swift`; alle Namen
/// sind Platzhalter.
extension UISnapshotGallery {
    @MainActor
    static func islandLargeFixtures() -> [Fixture] {
        let current = UUID(), previousChat = UUID()
        func chat(_ title: String, _ status: ControllerIslandStatus?, _ detail: String, id: UUID = UUID()) -> ControllerIslandChatRow {
            ControllerIslandChatRow(
                id: id, title: title, project: "Project A", status: status, detail: detail, isCurrent: id == current)
        }
        let chats = [
            chat("Chat A", .working, "now", id: current),
            chat("Chat B", .awaiting, "waiting · 2 min", id: previousChat),
            chat("Chat C", .idle, "ready"),
            chat("Chat D with a rather long title", .working, "working · 6 min"),
            chat("Chat E", .errored, "error"),
            chat("Chat F", .idle, "ready"),
            chat("Chat G", .idle, "ready"),
            chat("Chat H", .working, "working · 1 min"),
        ]
        let projectView = UUID()
        let places = [
            ControllerWorkspaceChoice(id: UUID(), name: "Workspace A", colorHex: "#5E6AD2", chatCount: 6,
                                      hasWaitingChat: false, isCurrent: true),
            ControllerWorkspaceChoice(id: UUID(), name: "Workspace B", colorHex: "#3FA873", chatCount: 4,
                                      hasWaitingChat: true, isCurrent: false),
            ControllerWorkspaceChoice(id: UUID(), name: "Project A", colorHex: "#5E6AD2", chatCount: 5,
                                      hasWaitingChat: true, isCurrent: false, kind: .project, viewWorkspaceID: projectView),
            ControllerWorkspaceChoice(id: UUID(), name: "Project B", colorHex: "#C9962A", chatCount: 2,
                                      hasWaitingChat: false, isCurrent: false, kind: .project),
        ]
        let boards = ControllerTicketBoards(rows: [
            ControllerTicketBoardChoice(id: UUID(), team: "AAA", projectName: "Project A", colorHex: "#5E6AD2",
                                        waitingCount: 3, isHere: true, isCurrent: false),
            ControllerTicketBoardChoice(id: UUID(), team: "BBB", projectName: "Project B", colorHex: "#3FA873",
                                        waitingCount: 0, isHere: false, isCurrent: false, isPrevious: true),
            ControllerTicketBoardChoice(id: UUID(), team: "CCC", projectName: "Project C", colorHex: "#C9962A",
                                        waitingCount: nil, isHere: false, isCurrent: false),
        ])
        let target = ControllerIslandTarget(title: "Chat A", status: .working)

        func whereTo(grid: Bool = false, tickets: ControllerTicketBoards? = nil,
                     _ change: (inout ControllerWhereToState) -> Void = { _ in }) -> ControllerWhereToState {
            var state = ControllerWhereToState(
                chats: chats, currentChatID: current, workspaces: places, gridActive: grid,
                previous: grid ? .workspace(projectView) : .chat(previousChat), tickets: tickets)
            state.reopenTitle = "Chat Z"
            state.setColumns(2)
            change(&state)
            return state
        }
        func model(_ content: ControllerIslandModel.Content, input: ControllerIslandInput = .controller) -> ControllerIslandModel {
            ControllerIslandModel(target: target, content: content, input: input)
        }

        // Steuerkreuz: ▶ zur Nachbar-Kachel, ▼ eine Reihe tiefer.
        let chatsStart = model(.whereTo(whereTo()))
        let chatsMoved = model(.whereTo(whereTo { $0.moveSideways(1); $0.moveRow(1) }))
        let chatsScrolled = model(.whereTo(whereTo { state in (0..<3).forEach { _ in state.moveRow(1) } }))
        let placesModel = model(.whereTo(whereTo(grid: true) { $0.moveSideways(1) }))
        let ticketsModel = model(.whereTo(whereTo(tickets: boards) { state in
            // ▶ bis in den Reiter „Tickets“ (je Reiter erst die rechte Kachel).
            (0..<4).forEach { _ in state.moveSideways(1) }
        }))
        let keyboardModel = model(.whereTo(whereTo { $0.markPreviousForKeyboard() }), input: .keyboard)

        let chatState = ControllerChatState(status: .idle, profile: .claude)
        let writing = model(.writing(ControllerWritingSlots(
            state: chatState,
            clip: ControllerClipPreview(id: "1", kind: .text, preview: "Example text from the clipboard"))))
        var busyState = chatState
        busyState.status = .working
        let writingBusy = model(.writing(ControllerWritingSlots(state: busyState)))

        let session = UUID()
        var chatInfo = ControllerChatActionInfo(title: "Chat A")
        chatInfo.accounts = [
            ControllerAccountChoice(kind: .claude, name: "main", label: "main", isCurrent: true, isLoggedIn: true),
            ControllerAccountChoice(kind: .claude, name: "second", label: "second", isCurrent: false, isLoggedIn: true),
        ]
        chatInfo.usageAccount = ControllerUsageAccount(kind: .claude, name: "main")
        let setup = ControllerMenuSetup(
            acceptsInput: true, profile: .claude, sessionID: session, target: .chat(session), chat: chatInfo)
        var slots = ControllerQuickDrawSlots(setup: setup)
        slots.app = ControllerAppToggles(alert: .all, nextAlert: .soundOff, awake: .whileWorking)
        slots.account = ControllerIslandAccountBadge(name: "main", fiveHourUsed: 42)
        let quickDraw = model(.quickDraw(slots))
        let now = Date()
        func limitRow(_ kind: ControllerAccountChoice.Kind, _ name: String, _ five: Double, _ week: Double,
                      current: Bool = false) -> ControllerAccountLimitRow {
            ControllerAccountLimitRow(
                kind: kind, name: name, fiveHour: five, week: week,
                fiveHourResetsAt: now.addingTimeInterval(7_800), weekResetsAt: now.addingTimeInterval(259_200),
                problem: nil, problemReplacesNumbers: false, isCurrentChat: current)
        }
        var cardSlots = slots
        cardSlots.card = ControllerLimitsCard(
            rows: [limitRow(.claude, "main", 42, 61, current: true), limitRow(.claude, "second", 12, 28),
                   limitRow(.gpt, "gpt-main", 88, 47)],
            updatedAt: now.addingTimeInterval(-70), isLoading: false)
        let limits = model(.quickDraw(cardSlots))

        func island(
            _ name: String, _ model: ControllerIslandModel, size: CGSize, music: Bool = false, revealed: Bool = true,
            counts: ControllerIslandCounts? = nil
        ) -> Fixture {
            Fixture(name: "kamera-insel-controller-\(name)", size: size) {
                let screen = islandScreen(size)
                let occupancy = islandOccupancy(size, music: music)
                let display = ControllerIslandDisplay(
                    style: ControllerIslandGeometry.style(for: screen, occupancy: occupancy), model: model, counts: counts)
                // Wie das Fenster: ab der Oberkante der großen Form, auf die Kamera zentriert.
                return AnyView(IslandDesk(size: size, music: music) {
                    ControllerIslandView(display: display, revealed: revealed)
                        .frame(maxWidth: .infinity, alignment: .top)
                        .padding(.top, NotchIslandLargeGeometry.topInset(screen))
                })
            }
        }
        let list = CGSize(width: 720, height: 420)
        let wide = CGSize(width: 860, height: 330)
        return [
            island("wohin", chatsStart, size: list),
            island("wohin-bewegt", chatsMoved, size: list),
            island("wohin-musik", chatsMoved, size: list, music: true),
            island("wohin-zaehler", chatsStart, size: list, counts: ControllerIslandCounts(working: 3, waiting: 1)),
            island("wohin-weiter-unten", chatsScrolled, size: list),
            island("wohin-projekte", placesModel, size: list),
            island("wohin-tickets", ticketsModel, size: list),
            island("wohin-tastatur", keyboardModel, size: CGSize(width: 720, height: 440)),
            island("schreiben", writing, size: CGSize(width: 720, height: 330)),
            island("schreiben-arbeitet", writingBusy, size: CGSize(width: 720, height: 360)),
            island("schnellbefehle", quickDraw, size: wide),
            island("schnellbefehle-musik", quickDraw, size: wide, music: true),
            island("limits", limits, size: CGSize(width: 860, height: 380)),
            // Zu: nur die Kapsel um die Kamera, aus der die Form wächst.
            island("zu", chatsStart, size: CGSize(width: 720, height: 130), revealed: false),
        ]
    }
}
