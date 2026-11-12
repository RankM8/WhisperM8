import Foundation
import XCTest
@testable import WhisperM8

/// Ausgabemodus-Wechsel während der Aufnahme.
final class ControllerOutputModeCyclerTests: XCTestCase {
    private let modes = ["clean", "email", "slack"]

    func testStepsWithWrapAround() {
        XCTAssertEqual(OutputModeCycler.next(current: "clean", in: modes, step: 1), "email")
        XCTAssertEqual(OutputModeCycler.next(current: "slack", in: modes, step: 1), "clean")
        XCTAssertEqual(OutputModeCycler.next(current: "clean", in: modes, step: -1), "slack")
        XCTAssertEqual(OutputModeCycler.next(current: "email", in: modes, step: -4), "clean")
        XCTAssertEqual(OutputModeCycler.next(current: "email", in: modes, step: 0), "email")
    }

    func testEmptyAndUnknown() {
        XCTAssertNil(OutputModeCycler.next(current: "clean", in: [String](), step: 1))
        XCTAssertEqual(OutputModeCycler.next(current: "gone", in: modes, step: 1), "clean")
        XCTAssertEqual(OutputModeCycler.next(current: nil, in: modes, step: -1), "clean")
    }
}

/// Markierung in der Liste links (Plan 3.5).
final class ControllerSidebarNavigationModelTests: XCTestCase {
    private let workspace = UUID()
    private let project = UUID()
    private let chatA = UUID()
    private let chatB = UUID()
    private let chatC = UUID()

    /// Workspaces mit ihren Chats, dann Projekte mit ihren Chats.
    private var rows: [SidebarNavigationRow] {
        [
            .workspace(workspace),
            .workspaceChat(session: chatA, workspace: workspace),
            .project(project),
            .chat(chatA),
            .chat(chatB),
            .chat(chatC),
        ]
    }

    func testMoveWithoutWrapAround() {
        var model = SidebarNavigationModel(rows: rows)
        XCTAssertNil(model.marked)
        model.move(1)
        XCTAssertEqual(model.marked, .workspace(workspace), "ohne Markierung beginnt sie oben")
        model.move(-1)
        XCTAssertEqual(model.marked, .workspace(workspace), "bleibt am oberen Rand stehen")
        model.move(3)
        XCTAssertEqual(model.marked, .chat(chatA))
        model.move(10)
        XCTAssertEqual(model.marked, .chat(chatC), "bleibt am unteren Rand stehen")
    }

    /// Runde 2: Steht der Chat im Workspace und im Projekt, beginnt die
    /// Markierung im Workspace.
    func testStartPrefersWorkspaceRowOfSession() {
        var model = SidebarNavigationModel(rows: [
            .workspace(workspace), .workspaceChat(session: chatA, workspace: workspace),
            .project(project), .chat(chatA),
        ])
        model.start(at: chatA)
        XCTAssertEqual(model.marked, .workspaceChat(session: chatA, workspace: workspace))
    }

    /// Workspace zugeklappt: seine Zeile fehlt, dann gilt die Chat-Zeile.
    func testStartFallsBackToChatRowThenFirstRow() {
        var model = SidebarNavigationModel(rows: rows)
        model.start(at: chatB)
        XCTAssertEqual(model.marked, .chat(chatB), "B steht in keinem Workspace")
        model.start(at: chatA)
        XCTAssertEqual(model.marked, .workspaceChat(session: chatA, workspace: workspace))

        let other = UUID()
        model = SidebarNavigationModel(rows: [
            .workspace(workspace), .workspaceChat(session: other, workspace: workspace), .project(project),
        ])
        model.start(at: other)
        XCTAssertEqual(model.marked, .workspaceChat(session: other, workspace: workspace))
        model.start(at: UUID())
        XCTAssertEqual(model.marked, .workspace(workspace))
        model.start(at: nil)
        XCTAssertEqual(model.marked, .workspace(workspace))
        var empty = SidebarNavigationModel()
        empty.start(at: chatA)
        XCTAssertNil(empty.marked)
    }

    func testSetRowsKeepsMarkedRow() {
        var model = SidebarNavigationModel(rows: rows, marked: .chat(chatB))
        model.setRows(rows.reversed())
        XCTAssertEqual(model.marked, .chat(chatB))
    }

    func testVanishedRowTakesNeighbourAtSamePosition() {
        var model = SidebarNavigationModel(rows: rows, marked: .chat(chatB))
        model.setRows(rows.filter { $0 != .chat(chatB) })
        XCTAssertEqual(model.marked, .chat(chatC), "die Zeile, die an die Stelle rückt")

        model.setRows([.workspace(workspace), .project(project)])
        XCTAssertEqual(model.marked, .project(project), "am Ende die letzte Zeile")
    }

    /// Eingeklappte Gruppe: ihre Chat-Zeilen verschwinden, die Markierung bleibt in der Nähe.
    func testCollapsedGroup() {
        var model = SidebarNavigationModel(rows: rows, marked: .workspaceChat(session: chatA, workspace: workspace))
        model.setRows(rows.filter {
            if case .workspaceChat = $0 { return false }
            return true
        })
        XCTAssertEqual(model.marked, .project(project))
    }

    func testEmptyRowsClearMarking() {
        var model = SidebarNavigationModel(rows: rows, marked: .chat(chatA))
        model.setRows([])
        XCTAssertNil(model.marked)
        model.move(1)
        XCTAssertNil(model.marked)
    }

    func testInitDropsUnknownMarking() {
        XCTAssertNil(SidebarNavigationModel(rows: rows, marked: .chat(UUID())).marked)
    }
}

/// Menü hinter Options.
final class ControllerMenuModelTests: XCTestCase {
    private let session = UUID()

    private func setup(
        dialogOpen: Bool = false, acceptsInput: Bool = true, profile: ControllerChatState.Profile = .claude,
        chat: ControllerChatActionInfo? = ControllerChatActionInfo(title: "Chat")
    ) -> ControllerMenuSetup {
        ControllerMenuSetup(
            dialogOpen: dialogOpen, acceptsInput: acceptsInput, profile: profile,
            sessionID: session, target: .chat(session), chat: chat)
    }

    private func enabled(_ model: ControllerMenuModel) -> [ControllerMenuItem] {
        model.top.entries.filter(\.enabled).map(\.id)
    }

    /// Runde 2: ein Menü mit drei Gruppen in fester Reihenfolge.
    func testItemsAndGroups() {
        XCTAssertEqual(ControllerMenuItem.allCases, [
            .continueWork, .commands, .cycleMode,
            .switchAccount, .rename, .fork, .pin, .archive, .closeChat,
            .clipboardHistory, .showBindings, .pause,
        ])
        XCTAssertEqual(ControllerMenuItem.allCases.filter(\.startsGroup), [.switchAccount, .clipboardHistory])
        let model = ControllerMenuModel(setup: setup())
        XCTAssertEqual(model.selected, .continueWork)
        // Ohne Konten und ohne Fork sind diese beiden aus.
        XCTAssertEqual(enabled(model), [.continueWork, .commands, .cycleMode, .rename, .pin, .archive, .closeChat,
                                        .clipboardHistory, .showBindings, .pause])
    }

    /// Bei offener Rückfrage ist alles aus, was in den Chat schreibt (auch
    /// Shift+Tab); Aktionen am Chat bleiben.
    func testInputGroupIsOffDuringQuestion() {
        let model = ControllerMenuModel(setup: setup(dialogOpen: true))
        XCTAssertEqual(model.selected, .rename)
        XCTAssertFalse(ControllerMenuModel.isEnabled(.cycleMode, setup: setup(dialogOpen: true)))
        XCTAssertEqual(enabled(model), [.rename, .pin, .archive, .closeChat, .clipboardHistory, .showBindings, .pause])
    }

    func testDialogOpeningLaterClosesCommandsLevel() {
        var model = ControllerMenuModel(setup: setup(), selected: .commands)
        XCTAssertTrue(model.openSubmenu())
        model.update(dialogOpen: true, chatBusy: false)
        XCTAssertNil(model.submenu)
        XCTAssertEqual(model.selected, .rename, "Auswahl rückt auf einen aktiven Eintrag")
    }

    /// Review nach Runde 4: „Weiter“ und „Modus wechseln“ nur bei ruhendem
    /// Chat; Befehle bleiben (eigener Schutz gegen Entwürfe).
    func testContinueAndModeNeedARestingChat() {
        var busy = setup()
        busy.chatBusy = true
        XCTAssertFalse(ControllerMenuModel.isEnabled(.continueWork, setup: busy))
        XCTAssertFalse(ControllerMenuModel.isEnabled(.cycleMode, setup: busy))
        XCTAssertTrue(ControllerMenuModel.isEnabled(.commands, setup: busy))
        var model = ControllerMenuModel(setup: setup(), selected: .continueWork)
        XCTAssertEqual(model.selected, .continueWork)
        model.update(dialogOpen: false, chatBusy: true)
        XCTAssertNotEqual(model.selected, .continueWork)
        model.update(dialogOpen: false, chatBusy: false)
        XCTAssertTrue(model.top.isEnabled(.continueWork))
    }

    func testWithoutLiveChatOrChatInfo() {
        XCTAssertEqual(enabled(ControllerMenuModel(setup: setup(acceptsInput: false))),
                       [.rename, .pin, .archive, .closeChat, .clipboardHistory, .showBindings, .pause])
        XCTAssertEqual(enabled(ControllerMenuModel(setup: setup(acceptsInput: false, chat: nil))),
                       [.clipboardHistory, .showBindings, .pause])
        XCTAssertFalse(ControllerMenuModel.isEnabled(.commands, setup: setup(profile: .shell)), "Shell: keine Befehle")
    }

    func testMoveWrapsAndSkipsDisabled() {
        var model = ControllerMenuModel(setup: setup(), selected: .pause)
        model.move(1)
        XCTAssertEqual(model.selected, .continueWork)
        model.move(-1)
        XCTAssertEqual(model.selected, .pause)
        model = ControllerMenuModel(setup: setup(), selected: .cycleMode)
        model.move(1)
        XCTAssertEqual(model.selected, .rename, "Konto wechseln und Forken sind aus")
    }

    func testCommandsLevel() {
        var model = ControllerMenuModel(setup: setup(), selected: .commands)
        XCTAssertTrue(model.openSubmenu())
        guard case let .commands(list) = model.submenu else { return XCTFail("Befehle erwartet") }
        XCTAssertEqual(list.entries.map(\.id), ControllerSlashCommands.claude)
        XCTAssertEqual(list.selected, "/")
        model.move(1)
        guard case let .commands(moved) = model.submenu else { return XCTFail("Befehle erwartet") }
        XCTAssertEqual(moved.selected, "/model")
        XCTAssertTrue(model.back())
        XCTAssertNil(model.submenu)
        XCTAssertFalse(model.back(), "auf der ersten Ebene schließt der Aufrufer")
    }

    func testAccountsLevelSkipsCurrentAndSignedOut() {
        var chat = ControllerChatActionInfo(title: "Chat")
        chat.accounts = [
            ControllerAccountChoice(kind: .claude, name: "main", label: "main", isCurrent: true, isLoggedIn: true),
            ControllerAccountChoice(kind: .claude, name: "work", label: "work", isCurrent: false, isLoggedIn: true),
            ControllerAccountChoice(kind: .claude, name: "old", label: "old", isCurrent: false, isLoggedIn: false),
            ControllerAccountChoice(kind: .gpt, name: "main", label: "main", isCurrent: true, isLoggedIn: true),
        ]
        var model = ControllerMenuModel(setup: setup(chat: chat), selected: .switchAccount)
        XCTAssertEqual(model.selected, .switchAccount)
        XCTAssertTrue(model.openSubmenu())
        guard case let .accounts(list) = model.submenu else { return XCTFail("Konten erwartet") }
        XCTAssertEqual(list.entries.filter(\.enabled).map(\.id), ["claude:work"])
        XCTAssertEqual(list.selected, "claude:work")
    }

    func testForkOnlyWhenForkable() {
        var chat = ControllerChatActionInfo(title: "Chat")
        XCTAssertFalse(ControllerMenuModel.isEnabled(.fork, setup: setup(chat: chat)))
        chat.canFork = true
        XCTAssertTrue(ControllerMenuModel.isEnabled(.fork, setup: setup(chat: chat)))
        chat.isArchived = true
        XCTAssertFalse(ControllerMenuModel.isEnabled(.archive, setup: setup(chat: chat)))
        XCTAssertFalse(ControllerMenuModel.isEnabled(.closeChat, setup: setup(chat: chat)))
    }
}

/// Runde 2: feste Befehlsliste je CLI.
final class ControllerSlashCommandsTests: XCTestCase {
    func testListsPerProfile() {
        XCTAssertEqual(ControllerSlashCommands.list(for: .claude).map(\.text).prefix(3), ["/", "/model", "/config"])
        XCTAssertEqual(ControllerSlashCommands.list(for: .claude).last?.text, "/help")
        XCTAssertEqual(ControllerSlashCommands.list(for: .codex).map(\.text), ["/", "/model", "/approvals", "/new", "/compact"])
        XCTAssertTrue(ControllerSlashCommands.list(for: .shell).isEmpty)
        XCTAssertTrue(ControllerSlashCommands.list(for: nil).isEmpty)
    }

    func testOnlySlashStaysUnsent() {
        XCTAssertFalse(ControllerSlashCommand(text: "/").submits)
        XCTAssertTrue(ControllerSlashCommand(text: "/model").submits)
        XCTAssertEqual(Set(ControllerSlashCommands.claude).count, ControllerSlashCommands.claude.count, "keine Doppelten")
    }
}

/// Runde 2: Reihenfolge der Chats der Liste links (Stick hoch/runter, L1/R1).
final class ControllerSidebarChatOrderTests: XCTestCase {
    private let workspace = UUID()
    private let project = UUID()
    private let chatA = UUID()
    private let chatB = UUID()
    private let chatC = UUID()

    /// Workspace mit A und B, darunter das Projekt mit A, B und C.
    private var rows: [SidebarNavigationRow] {
        [
            .workspace(workspace),
            .workspaceChat(session: chatA, workspace: workspace),
            .workspaceChat(session: chatB, workspace: workspace),
            .project(project),
            .chat(chatA), .chat(chatB), .chat(chatC),
        ]
    }

    func testEachChatOnceAtItsFirstRow() {
        XCTAssertEqual(SidebarChatOrder.sessions(in: rows), [chatA, chatB, chatC])
    }

    func testNeighborWithoutWrap() {
        XCTAssertEqual(SidebarChatOrder.neighbor(of: chatA, step: 1, in: rows), chatB)
        XCTAssertEqual(SidebarChatOrder.neighbor(of: chatB, step: 1, in: rows), chatC)
        XCTAssertEqual(SidebarChatOrder.neighbor(of: chatC, step: -1, in: rows), chatB)
        XCTAssertNil(SidebarChatOrder.neighbor(of: chatC, step: 1, in: rows))
        XCTAssertNil(SidebarChatOrder.neighbor(of: chatA, step: -1, in: rows))
        XCTAssertNil(SidebarChatOrder.neighbor(of: chatA, step: 1, in: []))
    }

    /// Aktueller Chat verschwunden (oder keiner): vorn bzw. hinten beginnen.
    func testMissingCurrentStartsAtTheEdge() {
        XCTAssertEqual(SidebarChatOrder.neighbor(of: UUID(), step: 1, in: rows), chatA)
        XCTAssertEqual(SidebarChatOrder.neighbor(of: nil, step: -1, in: rows), chatC)
    }

    func testPreferredRowIsWorkspaceBeforeProject() {
        XCTAssertEqual(SidebarNavigationModel.preferredRow(of: chatA, in: rows),
                       .workspaceChat(session: chatA, workspace: workspace))
        XCTAssertEqual(SidebarNavigationModel.preferredRow(of: chatC, in: rows), .chat(chatC))
        XCTAssertNil(SidebarNavigationModel.preferredRow(of: UUID(), in: rows))
    }
}

/// Runde 2: Liste der Ausgabemodi an der Pill — wann sie zu sehen ist und wo.
final class OutputModeListTests: XCTestCase {
    func testVisibleUntilDelayAfterLastChange() {
        var visibility = OutputModeListVisibility()
        XCTAssertFalse(visibility.isVisible(at: 0))
        visibility.noteChange(at: 10)
        XCTAssertTrue(visibility.isVisible(at: 10))
        XCTAssertTrue(visibility.isVisible(at: 11.4))
        XCTAssertFalse(visibility.isVisible(at: 11.5))
        // Jeder weitere Wechsel verlängert.
        visibility.noteChange(at: 11)
        XCTAssertTrue(visibility.isVisible(at: 12.4))
        XCTAssertEqual(visibility.hideAt, 12.5)
    }

    func testRecordingEndHidesImmediately() {
        var visibility = OutputModeListVisibility()
        visibility.noteChange(at: 5)
        visibility.recordingEnded()
        XCTAssertFalse(visibility.isVisible(at: 5.1))
        XCTAssertNil(visibility.hideAt)
    }

    func testPlacementAbovePillAndInsideScreen() {
        let screen = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let size = NSSize(width: 240, height: 200)
        let pill = NSRect(x: 400, y: 40, width: 200, height: 40)
        let frame = OutputModeListPlacement.frame(listSize: size, pillFrame: pill, visibleFrame: screen)
        XCTAssertEqual(frame.minY, pill.maxY + OutputModeListPlacement.gap)
        XCTAssertEqual(frame.midX, pill.midX)

        // Am rechten Rand: in den Bildschirm geschoben.
        let edge = OutputModeListPlacement.frame(
            listSize: size, pillFrame: NSRect(x: 900, y: 40, width: 100, height: 40), visibleFrame: screen)
        XCTAssertEqual(edge.maxX, screen.maxX)

        // Pill ganz oben: Liste darunter.
        let top = OutputModeListPlacement.frame(
            listSize: size, pillFrame: NSRect(x: 400, y: 740, width: 200, height: 40), visibleFrame: screen)
        XCTAssertEqual(top.maxY, 740 - OutputModeListPlacement.gap)
    }
}
