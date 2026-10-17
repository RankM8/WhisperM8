import Combine
import SwiftUI
import XCTest
@testable import WhisperM8

// MARK: - Projektion: wer eine Notiz hat

final class JarvisNotesProjectionTests: XCTestCase {
    private let jarvis = UUID()
    private let otherJarvis = UUID()
    private let chat = UUID()
    private let t0 = Date(timeIntervalSince1970: 1_792_000_000)

    private func file(active: Bool = true) -> JarvisBoardFile {
        var file = JarvisBoardFile()
        _ = JarvisBoardLogic.set(&file, owner: jarvis, sessionID: chat,
                                 patch: JarvisBoardPatch(work: "Baut L22"), now: t0)
        if !active { _ = JarvisBoardLogic.setActive(&file, owner: jarvis, active: false, now: t0) }
        return file
    }

    func testActiveBoardWithLivingJarvisGivesANote() {
        let notes = JarvisNotesProjection.notes(file: file(), aliveOwners: [jarvis], enabled: true)
        XCTAssertEqual(notes[chat]?.work, "Baut L22")
    }

    func testNoNotesWithoutLivingJarvisInactiveBoardOrKillSwitch() {
        XCTAssertTrue(JarvisNotesProjection.notes(file: file(), aliveOwners: [], enabled: true).isEmpty,
                      "ohne laufenden Jarvis keine Notizen")
        XCTAssertTrue(JarvisNotesProjection.notes(file: file(active: false), aliveOwners: [jarvis], enabled: true).isEmpty)
        XCTAssertTrue(JarvisNotesProjection.notes(file: file(), aliveOwners: [jarvis], enabled: false).isEmpty)
    }

    func testOnSeveralBoardsTheNewestEntryWins() {
        var file = file()
        _ = JarvisBoardLogic.set(&file, owner: otherJarvis, sessionID: chat,
                                 patch: JarvisBoardPatch(work: "Neuer Stand"), now: t0.addingTimeInterval(60))
        XCTAssertEqual(JarvisNotesProjection.notes(file: file, aliveOwners: [jarvis, otherJarvis], enabled: true)[chat]?.work,
                       "Neuer Stand")
        XCTAssertEqual(JarvisNotesProjection.notes(file: file, aliveOwners: [jarvis], enabled: true)[chat]?.work,
                       "Baut L22", "das Board eines gestoppten Jarvis zählt nicht")
    }

    func testOwnerIsAliveOnlyWhileItsProcessRuns() {
        XCTAssertTrue(JarvisNotesProjection.isAlive(.working))
        XCTAssertTrue(JarvisNotesProjection.isAlive(.awaitingInput))
        XCTAssertTrue(JarvisNotesProjection.isAlive(.idle))
        XCTAssertFalse(JarvisNotesProjection.isAlive(.stopped))
        XCTAssertFalse(JarvisNotesProjection.isAlive(.errored))
        XCTAssertFalse(JarvisNotesProjection.isAlive(nil))
    }
}

// MARK: - Auf- und Zuklappen

final class JarvisNoteExpansionTests: XCTestCase {
    func testWithoutNoteAlwaysClosed() {
        XCTAssertFalse(JarvisNoteExpansion.isOpen(hasNote: false, override: true, isFocused: false, defaultOpen: true))
    }

    func testDefaultAppliesToChatsTheUserIsNotIn() {
        XCTAssertTrue(JarvisNoteExpansion.isOpen(hasNote: true, override: nil, isFocused: false, defaultOpen: true))
        XCTAssertFalse(JarvisNoteExpansion.isOpen(hasNote: true, override: nil, isFocused: false, defaultOpen: false))
    }

    func testTheChatTheUserWorksInIsClosed() {
        XCTAssertFalse(JarvisNoteExpansion.isOpen(hasNote: true, override: nil, isFocused: true, defaultOpen: true))
    }

    func testAHandClickWinsEvenInTheFocusedChat() {
        XCTAssertTrue(JarvisNoteExpansion.isOpen(hasNote: true, override: true, isFocused: true, defaultOpen: false),
                      "eigene Notiz bewusst wieder aufgeklappt")
        XCTAssertFalse(JarvisNoteExpansion.isOpen(hasNote: true, override: false, isFocused: false, defaultOpen: true))
    }
}

// MARK: - Store

@MainActor
final class JarvisNotesStoreTests: XCTestCase {
    private let jarvis = UUID()
    private let chat = UUID()
    private let window = UUID()
    private let t0 = Date(timeIntervalSince1970: 1_792_000_000)
    private var cancellables: Set<AnyCancellable> = []
    private var statusSubjects: [UUID: CurrentValueSubject<AgentSessionRuntimeStatus?, Never>] = [:]

    private func subject(_ owner: UUID) -> CurrentValueSubject<AgentSessionRuntimeStatus?, Never> {
        if let existing = statusSubjects[owner] { return existing }
        let created = CurrentValueSubject<AgentSessionRuntimeStatus?, Never>(nil)
        statusSubjects[owner] = created
        return created
    }

    private func makeStore(file: @escaping () -> JarvisBoardFile, enabled: Bool = true) -> JarvisNotesStore {
        let store = JarvisNotesStore()
        store.start(ownerStatus: { [unowned self] in self.subject($0).eraseToAnyPublisher() },
                    loadFile: file, isEnabled: { enabled })
        return store
    }

    private func boardFile(work: String) -> JarvisBoardFile {
        var file = JarvisBoardFile()
        _ = JarvisBoardLogic.set(&file, owner: jarvis, sessionID: chat, patch: JarvisBoardPatch(work: work), now: t0)
        return file
    }

    func testNotesFollowTheLiveStatusOfJarvis() {
        let store = makeStore(file: { self.boardFile(work: "Baut L22") })
        var received: [String?] = []
        store.notePublisher(for: chat).sink { received.append($0?.work) }.store(in: &cancellables)
        XCTAssertEqual(received, [nil], "Jarvis läuft noch nicht")

        subject(jarvis).send(.idle)
        subject(jarvis).send(.working)   // weiter lebendig: keine neue Meldung
        subject(jarvis).send(.stopped)
        XCTAssertEqual(received, [nil, "Baut L22", nil])
    }

    func testReloadPublishesOnlyRealChanges() {
        var work = "Baut L22"
        let store = makeStore(file: { self.boardFile(work: work) })
        subject(jarvis).send(.idle)
        var received: [String?] = []
        store.notePublisher(for: chat).sink { received.append($0?.work) }.store(in: &cancellables)
        store.reload()
        work = "Pusht beide Repos"
        store.reload()
        XCTAssertEqual(received, ["Baut L22", "Pusht beide Repos"])
    }

    func testRemovedOwnerLosesItsSubscription() {
        var file = boardFile(work: "x")
        let store = makeStore(file: { file })
        subject(jarvis).send(.idle)
        XCTAssertNotNil(store.notes[chat])
        file = JarvisBoardFile()
        store.reload()
        XCTAssertNil(store.notes[chat])
        subject(jarvis).send(.working)
        XCTAssertNil(store.notes[chat], "ein Owner ohne Board erzeugt keine Notizen mehr")
    }

    func testKillSwitchHidesEverything() {
        let store = makeStore(file: { self.boardFile(work: "x") }, enabled: false)
        subject(jarvis).send(.idle)
        XCTAssertTrue(store.notes.isEmpty)
    }

    func testNotedSessionsAndOverridesPerWindow() {
        let store = makeStore(file: { self.boardFile(work: "x") })
        var noted: [Set<UUID>] = []
        store.notedSessionsPublisher.sink { noted.append($0) }.store(in: &cancellables)
        subject(jarvis).send(.idle)
        XCTAssertEqual(noted, [[], [chat]])

        let otherWindow = UUID()
        var overrides: [Bool?] = []
        store.overridePublisher(windowID: window, sessionID: chat).sink { overrides.append($0) }.store(in: &cancellables)
        store.setOverride(true, windowID: window, sessionID: chat)
        store.setOverride(true, windowID: window, sessionID: chat)   // unverändert: keine Meldung
        store.setOverride(false, windowID: otherWindow, sessionID: chat)
        XCTAssertEqual(store.override(windowID: otherWindow, sessionID: chat), false, "Fenster sind unabhängig")
        store.clearOverrides(windowID: window)
        XCTAssertEqual(overrides, [nil, true, nil])
        XCTAssertEqual(store.override(windowID: otherWindow, sessionID: chat), false,
                       "Standard umschalten betrifft nur das eigene Fenster")
    }

    func testToggleDefaultFlipsThePreferenceAndClearsOnlyThisWindow() throws {
        let suite = "jarvis-notes-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertTrue(preferences.jarvisNotesDefaultOpen, "Standard: auf")

        let store = makeStore(file: { self.boardFile(work: "x") })
        let otherWindow = UUID()
        store.setOverride(true, windowID: window, sessionID: chat)
        store.setOverride(true, windowID: otherWindow, sessionID: chat)
        JarvisNotesShortcut.toggleDefault(windowID: window, preferences: preferences, store: store)
        XCTAssertFalse(preferences.jarvisNotesDefaultOpen)
        XCTAssertNil(store.override(windowID: window, sessionID: chat))
        XCTAssertEqual(store.override(windowID: otherWindow, sessionID: chat), true)
        XCTAssertTrue(AppPreferences(defaults: defaults).isJarvisNotesEnabled, "Kill-Switch standardmäßig aus")
    }

    func testSelectionChangeDropsTheHandClickOfBothChatsInThisWindowOnly() {
        let store = makeStore(file: { self.boardFile(work: "x") })
        let other = UUID()
        let third = UUID()
        let otherWindow = UUID()
        store.setOverride(true, windowID: window, sessionID: chat)
        store.setOverride(false, windowID: window, sessionID: other)
        store.setOverride(true, windowID: window, sessionID: third)
        store.setOverride(true, windowID: otherWindow, sessionID: chat)
        // Auch in der Einzelansicht (keine Kacheln): Wechsel von chat zu other.
        store.selectionChanged(from: chat, to: other, windowID: window)
        XCTAssertNil(store.override(windowID: window, sessionID: chat), "verlassen → wieder Standard")
        XCTAssertNil(store.override(windowID: window, sessionID: other), "betreten → wieder zu")
        XCTAssertEqual(store.override(windowID: window, sessionID: third), true, "Unbeteiligte bleiben")
        XCTAssertEqual(store.override(windowID: otherWindow, sessionID: chat), true, "anderes Fenster bleibt")
        store.selectionChanged(from: third, to: third, windowID: window)
        XCTAssertEqual(store.override(windowID: window, sessionID: third), true, "kein Wechsel, nichts verworfen")
    }

    func testStartIfNeededRunsOnce() {
        let store = JarvisNotesStore()
        var loads = 0
        store.start(ownerStatus: { _ in Just(.idle).eraseToAnyPublisher() },
                    loadFile: { loads += 1; return JarvisBoardFile() }, isEnabled: { true })
        store.startIfNeeded(ownerStatus: { _ in Just(.idle).eraseToAnyPublisher() })
        XCTAssertEqual(loads, 1)
    }
}

// MARK: - Kartenhöhe

final class JarvisNoteCardHeightTests: XCTestCase {
    func testTallPaneUsesSixtyPercentOfTheSpaceBelowTheHeader() {
        XCTAssertEqual(JarvisNoteCardOverlay.maxCardHeight(paneHeight: 536, headerHeight: 28), 300, accuracy: 0.01,
                       "(536 − 28 − 8) × 0,6")
    }

    func testFlatPaneKeepsAUsableMinimumButNeverLeavesThePane() {
        XCTAssertEqual(JarvisNoteCardOverlay.maxCardHeight(paneHeight: 236, headerHeight: 28), 120, accuracy: 0.01,
                       "flach: mindestens 120 pt, solange Platz ist")
        XCTAssertEqual(JarvisNoteCardOverlay.maxCardHeight(paneHeight: 120, headerHeight: 28), 84, accuracy: 0.01,
                       "sehr flach: nie über die Kachel hinaus (120 − 28 − 8)")
        XCTAssertEqual(JarvisNoteCardOverlay.maxCardHeight(paneHeight: 20, headerHeight: 28), 0)
    }
}

// MARK: - Form

final class HangingNoteShapeTests: XCTestCase {
    private let rect = CGRect(x: 0, y: 0, width: 200, height: 100)

    func testClosedShapeCoversTheFeetAndTheCard() {
        let path = HangingNoteShape().path(in: rect)
        XCTAssertEqual(path.boundingRect.minY, 0, accuracy: 0.01, "schließt bündig an den Kopf an")
        XCTAssertEqual(path.boundingRect.maxY, 100, accuracy: 0.01)
        XCTAssertEqual(path.boundingRect.width, 200, accuracy: 0.01, "die Füße reichen bis an den Rand")
        XCTAssertTrue(path.contains(CGPoint(x: 100, y: 50)), "Kartenmitte")
        XCTAssertTrue(path.contains(CGPoint(x: 6, y: 0.5)), "Fuß links: Fläche direkt an der Oberkante, außerhalb des Fuß-Kreises")
        XCTAssertFalse(path.contains(CGPoint(x: 1, y: 6)), "unter dem konkaven Fuß ist frei")
        XCTAssertFalse(path.contains(CGPoint(x: 8, y: 99)), "untere Ecke ist rund")
    }

    func testOutlineIsOpenAtTheTop() {
        let outline = HangingNoteShape(closed: false).path(in: rect)
        XCTAssertEqual(outline.currentPoint?.x ?? -1, 200, accuracy: 0.01, "endet am rechten Fuß, nicht wieder links")
        XCTAssertEqual(outline.currentPoint?.y ?? -1, 0, accuracy: 0.01)
    }

    func testTooSmallRectFallsBackToARectangle() {
        let tiny = CGRect(x: 0, y: 0, width: 10, height: 10)
        XCTAssertEqual(HangingNoteShape().path(in: tiny).boundingRect, tiny)
    }
}

// MARK: - Ende zu Ende: Socket → Datei → CLI-Lesevertrag → Notiz

/// Die ganze Kette ohne laufende App: Jarvis schreibt über den Socket-Handler,
/// die Datei hält es, die CLI liest es im JSON-Vertrag, die App projiziert die
/// Notiz für die Karte.
@MainActor
final class JarvisNotesEndToEndTests: XCTestCase {
    private let jarvis = UUID()
    private let chat = UUID()
    private var directory: URL!
    private var store: JarvisBoardStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("notes-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = JarvisBoardStore(fileURL: directory.appendingPathComponent("jarvis-board.json"),
                                 journal: ChatsStatusJournal(fileURL: directory.appendingPathComponent("journal.jsonl")))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func perform(_ method: String, _ params: [String: Any]) -> ChatsControlResponse {
        AgentControlRequestHandler.performBoardMutation(
            ChatsControlRequest(requestID: UUID().uuidString,
                                actor: ChatsControlActor(sessionID: jarvis.uuidString, token: "t"),
                                method: method, params: .object(params)),
            store: store, enabled: true, verifiedOwner: jarvis, targetState: { _ in .available })
    }

    func testJarvisWritesAndTheCardShowsWorkNeedsAndMilestones() throws {
        XCTAssertTrue(perform("board.set", [
            "targetSessionID": chat.uuidString, "light": "needsYou", "mission": "Prüfdienst wählen",
            "work": "Wartet auf dich: Ticket erstellen", "needs": "Entscheidung: Ticket mit Eli erstellen",
        ]).ok)
        XCTAssertTrue(perform("board.milestone", ["targetSessionID": chat.uuidString, "text": "Dienste verglichen"]).ok)
        XCTAssertTrue(perform("board.milestone", ["targetSessionID": chat.uuidString, "text": "Empfehlung steht"]).ok)

        // CLI-Lesevertrag (`chats board --json`)
        let file = JarvisBoardStore.load(fileURL: store.fileURL)
        let board = try XCTUnwrap(file.board(owner: jarvis))
        let rows = ChatsBoardReadModel.rows(board: board, file: file, sessions: [:], runtime: [:], lastTransitions: [:])
        let json = ChatsBoardReadModel.entryJSON(try XCTUnwrap(rows.first))
        XCTAssertEqual(json["work"] as? String, "Wartet auf dich: Ticket erstellen")
        XCTAssertEqual(json["next"] as? String, "Wartet auf dich: Ticket erstellen", "Mod liest weiter `next`")
        XCTAssertEqual((json["milestones"] as? [[String: Any]])?.compactMap { $0["text"] as? String },
                       ["Empfehlung steht", "Dienste verglichen"])

        // App: Notiz erscheint erst mit laufendem Jarvis.
        let notes = JarvisNotesStore()
        let jarvisStatus = CurrentValueSubject<AgentSessionRuntimeStatus?, Never>(nil)
        notes.start(ownerStatus: { _ in jarvisStatus.eraseToAnyPublisher() },
                    loadFile: { JarvisBoardStore.load(fileURL: self.store.fileURL) }, isEnabled: { true })
        XCTAssertNil(notes.notes[chat])
        jarvisStatus.send(.idle)
        let note = try XCTUnwrap(notes.notes[chat])
        XCTAssertEqual(note.needs, "Entscheidung: Ticket mit Eli erstellen")
        XCTAssertEqual(note.milestones.first?.text, "Empfehlung steht")

        // Jarvis nimmt den Chat vom Board → Notiz verschwindet nach dem Reload.
        XCTAssertTrue(perform("board.remove", ["targetSessionID": chat.uuidString]).ok)
        notes.reload()
        XCTAssertNil(notes.notes[chat])
    }
}
