import AppKit
import Foundation
@testable import WhisperM8
import XCTest

/// Seitenspalte „Board-Chat“ (WM8-113): welcher Chat, wo er steht, wie breit.
final class BoardChatRulesTests: XCTestCase {
    private let project = UUID()
    private let otherProject = UUID()
    private let now = Date(timeIntervalSince1970: 1_794_700_000)

    private func chat(_ title: String, project: UUID? = nil, running: Bool = true, minutesAgo: Double = 0,
                      archived: Bool = false, id: UUID = UUID(), kind: AgentSessionKind = .chat) -> BoardChatCandidate {
        BoardChatCandidate(id: id, title: title, projectID: project ?? self.project, isRunning: running,
                           lastActivityAt: now.addingTimeInterval(-minutesAgo * 60), isArchived: archived, kind: kind)
    }

    // MARK: Jarvis erkennen

    func testJarvisIsRecognisedByTheTitleLikeTheCLI() {
        XCTAssertTrue(BoardChatRules.isJarvis(title: "Jarvis: Supervisor WhisperM8"))
        XCTAssertTrue(BoardChatRules.isJarvis(title: "jarvis"))
        XCTAssertFalse(BoardChatRules.isJarvis(title: "  Jarvis · WM8"), "wie die CLI: kein Trimmen")
        XCTAssertFalse(BoardChatRules.isJarvis(title: "Pia · Produkt"))
        XCTAssertFalse(BoardChatRules.isJarvis(title: "Frag Jarvis später"))
        // Dieselbe Regel wie `tickets board` und `tickets status`.
        for title in ["Jarvis: Supervisor", "Vic · Prüfer", "JARVIS", "  Jarvis"] {
            let ticketChat = TicketChat(id: UUID(), title: title, projectName: "p", projectPath: "/p", state: nil, isRunning: true)
            XCTAssertEqual(BoardChatRules.isJarvis(title: title), TicketBoardBuilder.isSupervisor(ticketChat), title)
        }
    }

    // MARK: Automatische Wahl

    func testPicksTheJarvisOfThisProjectOnly() {
        let mine = chat("Jarvis: Supervisor WhisperM8")
        let foreign = chat("Jarvis: Supervisor Beispiel", project: otherProject, minutesAgo: -5)
        let worker = chat("Vic · Prüfer", minutesAgo: -10)
        XCTAssertEqual(BoardChatRules.automaticJarvis(in: [foreign, worker, mine], projectID: project), mine.id)
    }

    func testRunningBeatsRecentlyActive() {
        let stopped = chat("Jarvis alt", running: false, minutesAgo: 0)
        let running = chat("Jarvis neu", running: true, minutesAgo: 90)
        XCTAssertEqual(BoardChatRules.automaticJarvis(in: [stopped, running], projectID: project), running.id)
    }

    func testMostRecentlyActiveWinsAmongEquals() {
        let older = chat("Jarvis A", minutesAgo: 30)
        let newer = chat("Jarvis B", minutesAgo: 2)
        XCTAssertEqual(BoardChatRules.automaticJarvis(in: [older, newer], projectID: project), newer.id)
        XCTAssertEqual(BoardChatRules.automaticJarvis(in: [newer, older], projectID: project), newer.id)
    }

    func testTieIsStableRegardlessOfOrder() {
        let first = chat("Jarvis", id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!)
        let second = chat("Jarvis", id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!)
        XCTAssertEqual(BoardChatRules.automaticJarvis(in: [first, second], projectID: project), first.id)
        XCTAssertEqual(BoardChatRules.automaticJarvis(in: [second, first], projectID: project), first.id)
    }

    func testArchivedJarvisIsNeverPicked() {
        let archived = chat("Jarvis", archived: true)
        XCTAssertNil(BoardChatRules.automaticJarvis(in: [archived], projectID: project))
        XCTAssertNil(BoardChatRules.automaticJarvis(in: [], projectID: project))
    }

    // MARK: Produkt-Chat und Wahl (Teil c)

    func testProductChatIsRecognisedButNeverAJarvis() {
        XCTAssertTrue(BoardChatRules.isProduct(title: "Pia · Produkt WM8"))
        XCTAssertTrue(BoardChatRules.isProduct(title: "Product chat"))
        XCTAssertTrue(BoardChatRules.isProduct(title: "Produkt-Chat WM8"))
        XCTAssertFalse(BoardChatRules.isProduct(title: "Produktion: Release vorbereiten"), "ganzes Wort")
        XCTAssertFalse(BoardChatRules.isProduct(title: "Production-Fix für den Export"), "ganzes Wort")
        XCTAssertFalse(BoardChatRules.isProduct(title: "Jarvis: Produkt und Supervisor"))
        XCTAssertFalse(BoardChatRules.isProduct(title: "Vic · Prüfer"))
    }

    func testAutomaticProductOfThisProject() {
        let product = chat("Pia · Produkt WM8")
        let foreign = chat("Ada · Produkt", project: otherProject)
        let jarvis = chat("Jarvis")
        XCTAssertEqual(BoardChatRules.automaticProduct(in: [foreign, jarvis, product], projectID: project), product.id)
        XCTAssertNil(BoardChatRules.automaticProduct(in: [jarvis], projectID: project))
    }

    func testTwoProductChatsPickTheRunningOneStably() {
        let stopped = chat("Ada · Produkt", running: false, minutesAgo: 0)
        let running = chat("Pia · Produkt", running: true, minutesAgo: 60)
        XCTAssertEqual(BoardChatRules.automaticProduct(in: [stopped, running], projectID: project), running.id)
        XCTAssertEqual(BoardChatRules.automaticProduct(in: [running, stopped], projectID: project), running.id)
    }

    // MARK: Nur echte Agent-Chats dieses Projekts

    func testOnlyAgentChatsAndBackgroundAgentsQualify() {
        XCTAssertTrue(BoardChatRules.acceptsKind(.chat))
        XCTAssertTrue(BoardChatRules.acceptsKind(.backgroundChat))
        for kind in [AgentSessionKind.terminal, .agentView, .subagentJob] {
            XCTAssertFalse(BoardChatRules.acceptsKind(kind), "\(kind)")
        }
    }

    func testRejectionReasons() {
        func reject(_ kind: AgentSessionKind = .chat, archived: Bool = false, project: UUID? = nil, group: Int = 1) -> BoardChatRejection? {
            BoardChatRules.rejection(kind: kind, isArchived: archived, projectID: project ?? self.project,
                                     boardProjectID: self.project, groupSize: group)
        }
        XCTAssertNil(reject())
        XCTAssertEqual(reject(.terminal), .notAgentChat, "Shell-Tab: Umbrüche würden Befehle")
        XCTAssertEqual(reject(.subagentJob), .notAgentChat)
        XCTAssertEqual(reject(archived: true), .archived)
        XCTAssertEqual(reject(project: otherProject), .otherProject)
        XCTAssertEqual(reject(group: 3), .group)
    }

    func testAShellTabNamedJarvisIsNeverPickedAutomatically() {
        let shell = chat("Jarvis Shell", running: true, kind: .terminal)
        let product = chat("Produkt Shell", kind: .terminal)
        XCTAssertNil(BoardChatRules.automaticJarvis(in: [shell], projectID: project))
        XCTAssertNil(BoardChatRules.automaticProduct(in: [product], projectID: project))
    }

    func testChoicesListJarvisProductAndAChosenChatOnce() {
        let jarvis = BoardChatChoice.Chat(id: UUID(), name: "Jarvis", title: "Jarvis: Supervisor WhisperM8")
        let product = BoardChatChoice.Chat(id: UUID(), name: "Pia", title: "Pia · Produkt WM8")
        let other = BoardChatChoice.Chat(id: UUID(), name: "Vic", title: "Vic · Prüfer")
        let all = BoardChatRules.choices(jarvis: jarvis, product: product, chosen: other, current: other.id)
        XCTAssertEqual(all.map(\.name), ["Jarvis", "Pia", "Vic"])
        XCTAssertEqual(all.map(\.kind), [.jarvis, .product, .other])
        XCTAssertEqual(all.filter(\.isSelected).map(\.id), [other.id])
        // Gewählt ist der Produkt-Chat: kein dritter Knopf.
        let two = BoardChatRules.choices(jarvis: jarvis, product: product, chosen: product, current: product.id)
        XCTAssertEqual(two.map(\.name), ["Jarvis", "Pia"])
        XCTAssertEqual(BoardChatRules.choices(jarvis: nil, product: nil, chosen: nil, current: nil), [])
    }

    func testChoosingTheAutomaticJarvisStoresNoChoice() {
        let jarvis = UUID(), product = UUID()
        XCTAssertNil(BoardChatRules.storedChoice(after: jarvis, automaticJarvis: jarvis))
        XCTAssertEqual(BoardChatRules.storedChoice(after: product, automaticJarvis: jarvis), product)
        XCTAssertEqual(BoardChatRules.storedChoice(after: product, automaticJarvis: nil), product)
    }

    // MARK: Ort

    func testPlacementFollowsTheTabOwner() {
        let primary = UUID(), second = UUID(), third = UUID()
        let order = [primary, second, third]
        XCTAssertEqual(BoardChatRules.placement(windowID: primary, hostWindowID: primary, windowOrder: order), .here)
        XCTAssertEqual(BoardChatRules.placement(windowID: primary, hostWindowID: third, windowOrder: order),
                       .otherWindow(number: 3, windowID: third))
        XCTAssertEqual(BoardChatRules.placement(windowID: second, hostWindowID: primary, windowOrder: order),
                       .otherWindow(number: 1, windowID: primary))
        XCTAssertEqual(BoardChatRules.placement(windowID: primary, hostWindowID: nil, windowOrder: order), .notOpen)
    }

    func testContentShowsTheTerminalOnlyForATabOfThisWindow() {
        let other = UUID()
        XCTAssertEqual(AgentChatsView.boardChatContent(hasChat: true, placement: .here), .terminal)
        XCTAssertEqual(AgentChatsView.boardChatContent(hasChat: true, placement: .otherWindow(number: 2, windowID: other)),
                       .otherWindow(number: 2))
        XCTAssertEqual(AgentChatsView.boardChatContent(hasChat: true, placement: .notOpen), .notOpen)
        XCTAssertEqual(AgentChatsView.boardChatContent(hasChat: false, placement: .here), .noChat)
    }

    // MARK: Breite

    func testWidthDefaultsAndClamps() {
        XCTAssertEqual(BoardChatRules.width(stored: nil, isTriage: false, available: 1400), 380)
        XCTAssertEqual(BoardChatRules.width(stored: 100, isTriage: false, available: 1400), 280)
        XCTAssertEqual(BoardChatRules.width(stored: 2000, isTriage: false, available: 2400), 720)
        XCTAssertEqual(BoardChatRules.width(stored: 512.4, isTriage: false, available: 1400), 512)
    }

    func testTriageMakesTheColumnNarrowerButNeverWider() {
        XCTAssertEqual(BoardChatRules.width(stored: nil, isTriage: true, available: 1400), 330)
        XCTAssertEqual(BoardChatRules.width(stored: 300, isTriage: true, available: 1400), 300)
        XCTAssertEqual(BoardChatRules.width(stored: 600, isTriage: true, available: 1400), 330)
    }

    func testBoardKeepsItsRoomInANarrowWindow() {
        XCTAssertEqual(BoardChatRules.width(stored: 600, isTriage: false, available: 900), 480)
        // Sehr schmal: die Spalte bleibt bei ihrer Mindestbreite.
        XCTAssertEqual(BoardChatRules.width(stored: 600, isTriage: false, available: 500), 280)
    }

    func testDraggingLeftWidens() {
        XCTAssertEqual(BoardChatRules.draggedWidth(from: 380, translation: -100, available: 1400), 480)
        XCTAssertEqual(BoardChatRules.draggedWidth(from: 380, translation: 300, available: 1400), 280)
        XCTAssertEqual(BoardChatRules.draggedWidth(from: 380, translation: -900, available: 1400), 720)
        XCTAssertEqual(BoardChatRules.draggedWidth(from: 380, translation: -300, available: 1000), 580)
    }
}

/// Speicher der Spalte: je Projekt, optional, abseits des Main Threads.
@MainActor
final class BoardChatPreferencesStoreTests: XCTestCase {
    private final class Disk: @unchecked Sendable {
        private let lock = NSLock()
        private var _file: BoardChatPreferencesFile?
        private var _writes = 0
        init(_ file: BoardChatPreferencesFile?) { _file = file }
        var file: BoardChatPreferencesFile? { lock.withLock { _file } }
        var writes: Int { lock.withLock { _writes } }
        func store(_ file: BoardChatPreferencesFile) { lock.withLock { _file = file; _writes += 1 } }
    }

    private func makeStore(_ disk: Disk) -> BoardChatPreferencesStore {
        BoardChatPreferencesStore(read: { disk.file }, write: { disk.store($0) }, saveDelay: .milliseconds(1))
    }

    private func settle(_ store: BoardChatPreferencesStore) async throws {
        try await Task.sleep(for: .milliseconds(40))
        BoardChatPreferencesStore.waitForWrites()
    }

    func testDefaultsWithoutFile() async {
        let store = makeStore(Disk(nil))
        await store.waitUntilLoaded()
        XCTAssertTrue(store.isLoaded)
        XCTAssertEqual(store.preferences(for: UUID()), BoardChatProjectPreferences())
    }

    func testChangesArePerProjectAndPersisted() async throws {
        let disk = Disk(nil)
        let store = makeStore(disk)
        await store.waitUntilLoaded()
        let a = UUID(), b = UUID(), chat = UUID()
        store.setWidth(450, for: a)
        store.setCollapsed(true, for: b)
        store.setChosenSession(chat, for: b)
        try await settle(store)
        XCTAssertEqual(store.preferences(for: a).width, 450)
        XCTAssertNil(store.preferences(for: a).isCollapsed)
        XCTAssertEqual(store.preferences(for: b), BoardChatProjectPreferences(width: nil, isCollapsed: true, chosenSessionID: chat))

        let reloaded = makeStore(disk)
        await reloaded.waitUntilLoaded()
        XCTAssertEqual(reloaded.preferences(for: a).width, 450)
        XCTAssertEqual(reloaded.preferences(for: b).chosenSessionID, chat)
    }

    func testWidthIsClampedAndExpandingRemovesTheEntry() async throws {
        let disk = Disk(nil)
        let store = makeStore(disk)
        await store.waitUntilLoaded()
        let project = UUID()
        store.setWidth(5000, for: project)
        XCTAssertEqual(store.preferences(for: project).width, BoardChatRules.maximumWidth)
        store.setWidth(nil, for: project)
        store.setCollapsed(true, for: project)
        store.setCollapsed(false, for: project)
        XCTAssertNil(store.projects[project], "Nur Vorgaben: kein Eintrag")
        try await settle(store)
        XCTAssertEqual(disk.file?.projects.isEmpty, true)
    }

    func testRemembersTheLastJarvisPerProject() async throws {
        let disk = Disk(nil)
        let store = makeStore(disk)
        await store.waitUntilLoaded()
        let project = UUID(), jarvis = UUID()
        store.setLastJarvis(jarvis, for: project)
        try await settle(store)
        let reloaded = makeStore(disk)
        await reloaded.waitUntilLoaded()
        XCTAssertEqual(reloaded.preferences(for: project).lastJarvisSessionID, jarvis)
    }

    func testUnchangedValueWritesNothing() async throws {
        let disk = Disk(nil)
        let store = makeStore(disk)
        await store.waitUntilLoaded()
        store.setCollapsed(false, for: UUID())
        try await settle(store)
        XCTAssertEqual(disk.writes, 0)
    }

    func testOlderFileWithoutFieldsAndUnknownKeysLoads() async throws {
        let json = #"{"projects":{"not-a-uuid":{"width":400},"8A4F1C2E-2B7D-4C1A-9E3F-5D6B7A8C9D0E":{"width":420,"future":1}}}"#
        let file = try JSONDecoder().decode(BoardChatPreferencesFile.self, from: Data(json.utf8))
        let store = makeStore(Disk(file))
        await store.waitUntilLoaded()
        XCTAssertEqual(store.projects.count, 1)
        XCTAssertEqual(store.preferences(for: UUID(uuidString: "8A4F1C2E-2B7D-4C1A-9E3F-5D6B7A8C9D0E")!).width, 420)
    }

    func testAChangeBeforeLoadingWinsAndKeepsTheRestOfTheFile() async throws {
        let kept = UUID(), changed = UUID()
        let disk = Disk(BoardChatPreferencesFile(projects: [
            kept.uuidString: BoardChatProjectPreferences(width: 500),
            changed.uuidString: BoardChatProjectPreferences(width: 300),
        ]))
        let store = makeStore(disk)
        store.setWidth(600, for: changed)       // vor dem Laden
        await store.waitUntilLoaded()
        try await settle(store)
        XCTAssertEqual(store.preferences(for: kept).width, 500)
        XCTAssertEqual(store.preferences(for: changed).width, 600)
        XCTAssertEqual(disk.file?.projects[kept.uuidString]?.width, 500, "Der frühe Klick ersetzt nicht die ganze Datei")
    }
}

/// Fokus im Ticket-Modus: ins Terminal nur per Klick ins Terminal.
@MainActor
final class BoardChatFocusRuleTests: XCTestCase {
    func testClickOutsideTheTerminalReleasesItsFocus() {
        XCTAssertTrue(BoardChatFocusRule.releasesFocus(responderIsTerminal: true, clickInsideResponder: false))
        XCTAssertFalse(BoardChatFocusRule.releasesFocus(responderIsTerminal: true, clickInsideResponder: true),
                       "Klick ins Terminal: Fokus bleibt")
        XCTAssertFalse(BoardChatFocusRule.releasesFocus(responderIsTerminal: false, clickInsideResponder: false),
                       "Textfeld oder Fenster hat den Fokus: nichts tun")
    }

    func testTerminalIsRecognisedLikeTheBoardKeys() {
        XCTAssertTrue(BoardChatFocusRule.isTerminal(QuietableTerminalView(frame: .zero)))
        XCTAssertFalse(BoardChatFocusRule.isTerminal(NSTextView(frame: .zero)))
        XCTAssertFalse(BoardChatFocusRule.isTerminal(nil))
    }

    func testReleaseHandsTheFocusBackToTheWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: true)
        let terminal = QuietableTerminalView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        window.contentView?.addSubview(terminal)
        window.makeFirstResponder(terminal)
        XCTAssertTrue(window.firstResponder === terminal)
        BoardChatFocusRule.releaseTerminalFocus(in: window)
        XCTAssertTrue(window.firstResponder === window)
    }
}

