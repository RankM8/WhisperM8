import XCTest
@testable import WhisperM8

/// Ablauf der Ticket-Ansicht: Zuordnung, Abruf nur bei sichtbarer Ansicht,
/// Leerzustände, Projektwechsel. Datei, Schlüsselbund, Netz und Chats sind ersetzt.
@MainActor
final class TicketBoardControllerTests: XCTestCase {
    private let projectA = "/Users/demo/repos/whisperm8"
    private let projectB = "/Users/demo/repos/listm8"

    /// Umgebung mit Zählern. Der Takt wartet, bis der Test ihn freigibt.
    private final class World: @unchecked Sendable {
        private let lock = NSLock()
        private var resolutions: [String: TicketBoardResolution] = [:]
        private var _resolved: [String] = []
        private var _madeStores: [String] = []
        private var ticks: [CheckedContinuation<Void, Error>] = []
        let source = TicketSourceStub()
        var chats: [TicketChat] = []
        /// Hält die Auflösung der Zuordnung an, bis `releaseResolve()` kommt.
        private var holdResolve = false
        private var heldResolves: [CheckedContinuation<Void, Never>] = []

        func set(_ path: String, _ resolution: TicketBoardResolution) {
            lock.lock(); resolutions[path] = resolution; lock.unlock()
        }

        var resolved: [String] { lock.lock(); defer { lock.unlock() }; return _resolved }
        var madeStores: [String] { lock.lock(); defer { lock.unlock() }; return _madeStores }

        func holdResolves() { lock.lock(); holdResolve = true; lock.unlock() }
        func releaseResolves() {
            lock.lock(); holdResolve = false; let held = heldResolves; heldResolves = []; lock.unlock()
            held.forEach { $0.resume() }
        }

        /// Merkt den Aufruf; `true`, wenn er warten soll.
        private func noteResolve(_ path: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            _resolved.append(path)
            return holdResolve
        }

        private func park(_ continuation: CheckedContinuation<Void, Never>) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard holdResolve else { return false }
            heldResolves.append(continuation)
            return true
        }

        private func resolution(_ path: String) -> TicketBoardResolution {
            lock.lock(); defer { lock.unlock() }
            return resolutions[path] ?? .notMapped
        }

        /// Nächster Abruf im Takt.
        func tick() {
            lock.lock(); let pending = ticks; ticks = []; lock.unlock()
            pending.forEach { $0.resume() }
        }

        private func sleep(_: Duration) async throws {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    lock.lock(); ticks.append(continuation); lock.unlock()
                }
            } onCancel: {
                self.lock.lock(); let pending = self.ticks; self.ticks = []; self.lock.unlock()
                pending.forEach { $0.resume(throwing: CancellationError()) }
            }
        }

        @MainActor var environment: TicketBoardEnvironment {
            TicketBoardEnvironment(
                resolve: { [self] path in
                    if noteResolve(path) {
                        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                            if !park(continuation) { continuation.resume() }
                        }
                    }
                    return resolution(path)
                },
                makeStore: { [self] workspace in
                    lock.lock(); _madeStores.append(workspace); lock.unlock()
                    return TicketBoardStore(source: source, interval: .seconds(30), sleep: { [self] in try await sleep($0) })
                },
                chats: { [self] in chats }
            )
        }
    }

    private func settle(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        // Großzügig warten: Unter der vollen Suite ist der Rechner ausgelastet.
        for _ in 0..<2_000 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "Bedingung nicht erreicht", file: file, line: line)
    }

    private func boards(_ world: World) -> Int { world.source.calls.filter { $0.hasPrefix("board") }.count }

    private func readyWorld(tickets: [Ticket] = [TicketFixtures.ticket(1), TicketFixtures.ticket(2, status: "In Progress")]) -> World {
        let world = World()
        world.set(projectA, .ready(team: "WM8", workspace: "whisperm8", projectPath: projectA))
        world.source.onBoard = { _ in TicketFixtures.snapshot(tickets, at: 100) }
        return world
    }

    // MARK: Leerzustände

    func testWithoutProjectNothingIsResolved() async {
        let world = World()
        let controller = TicketBoardController(environment: world.environment)
        await controller.show(projectPath: nil, projectName: "")
        XCTAssertEqual(controller.phase, .noProject)
        XCTAssertEqual(world.resolved, [])
        XCTAssertEqual(world.madeStores, [])
    }

    func testUnmappedProjectAsksNothingFromLinear() async {
        let world = World()
        let controller = TicketBoardController(environment: world.environment)
        await controller.show(projectPath: projectA, projectName: "whisperm8")
        XCTAssertEqual(controller.phase, .notMapped)
        XCTAssertEqual(controller.title, "whisperm8")
        XCTAssertEqual(world.madeStores, [])
        XCTAssertEqual(boards(world), 0)
    }

    func testMissingKeyAsksNothingFromLinear() async {
        let world = World()
        world.set(projectA, .noKey(workspace: "whisperm8"))
        let controller = TicketBoardController(environment: world.environment)
        await controller.show(projectPath: projectA, projectName: "whisperm8")
        XCTAssertEqual(controller.phase, .noKey(workspace: "whisperm8"))
        XCTAssertEqual(world.madeStores, [])
        XCTAssertEqual(boards(world), 0)
    }

    func testFirstFetchFailingShowsUnreachableAndTryAgainRecovers() async {
        let world = readyWorld()
        var fail = true
        world.source.onBoard = { _ in
            if fail { throw TicketSourceError.network("-1009") }
            return TicketFixtures.snapshot([TicketFixtures.ticket(1)], at: 100)
        }
        let controller = TicketBoardController(environment: world.environment)
        await controller.show(projectPath: projectA, projectName: "whisperm8")
        await settle { controller.phase == .unreachable(TicketSourceError.network("-1009").userText) }
        XCTAssertEqual(controller.viewModel.presentation.visibleCount, 0)

        fail = false
        controller.refresh()
        await settle { controller.phase == .ready }
        XCTAssertEqual(controller.viewModel.presentation.visibleCount, 1)
        XCTAssertNil(controller.load.problem)
    }

    // MARK: Abruf und Takt

    func testShowLoadsOnceThenInIntervals() async {
        let world = readyWorld()
        let controller = TicketBoardController(environment: world.environment)
        XCTAssertEqual(controller.phase, .noProject)
        await controller.show(projectPath: projectA, projectName: "whisperm8")
        await settle { controller.phase == .ready }
        XCTAssertEqual(boards(world), 1)
        XCTAssertEqual(controller.viewModel.presentation.visibleCount, 2)
        XCTAssertEqual(controller.load.fetchedAt, Date(timeIntervalSince1970: 100))
        XCTAssertFalse(controller.load.isLoading)

        world.tick()
        await settle { self.boards(world) == 2 }
        await settle { !controller.load.isLoading }
        XCTAssertEqual(controller.phase, .ready)
    }

    func testHiddenViewFetchesNothing() async {
        let world = readyWorld()
        let controller = TicketBoardController(environment: world.environment)
        await controller.show(projectPath: projectA, projectName: "whisperm8")
        await settle { controller.phase == .ready }

        controller.hide()
        world.tick()
        controller.refresh()
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(boards(world), 1, "verdeckt: weder Takt noch Knopf rufen ab")
        XCTAssertEqual(controller.phase, .ready, "der letzte Stand bleibt stehen")
        XCTAssertEqual(controller.viewModel.presentation.visibleCount, 2)

        // Wieder sichtbar: sofort ein frischer Abruf, derselbe Speicher.
        await controller.show(projectPath: projectA, projectName: "whisperm8")
        await settle { self.boards(world) == 2 }
        XCTAssertEqual(world.madeStores, ["whisperm8"])
    }

    func testSameSnapshotIsNotMatchedAgain() async {
        let world = readyWorld()
        let controller = TicketBoardController(environment: world.environment)
        await controller.show(projectPath: projectA, projectName: "whisperm8")
        await settle { controller.phase == .ready }
        let rebuilds = controller.viewModel.rebuilds

        // Der Abzug trägt denselben Zeitpunkt: kein neuer Abgleich, kein neues Rechnen.
        world.tick()
        await settle { self.boards(world) == 2 }
        await settle { !controller.load.isLoading }
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(controller.viewModel.rebuilds, rebuilds)
    }

    func testFailingLaterFetchKeepsBoardAndNamesTheProblem() async {
        let world = readyWorld()
        var fail = false
        world.source.onBoard = { _ in
            if fail { throw TicketSourceError.network("-1009") }
            return TicketFixtures.snapshot([TicketFixtures.ticket(1)], at: 100)
        }
        let controller = TicketBoardController(environment: world.environment)
        await controller.show(projectPath: projectA, projectName: "whisperm8")
        await settle { controller.phase == .ready }

        fail = true
        world.tick()
        await settle { controller.load.problem != nil }
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertEqual(controller.load.problem, TicketSourceError.network("-1009").userText)
        XCTAssertEqual(controller.load.fetchedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(controller.viewModel.presentation.visibleCount, 1)

        fail = false
        world.tick()
        await settle { controller.load.problem == nil }
    }

    // MARK: Chats

    func testLinkedChatAppearsOnItsTicket() async {
        let chatID = UUID()
        let world = readyWorld(tickets: [TicketFixtures.ticket(7, status: "In Progress", links: [TicketFixtures.link(chatID)])])
        world.chats = [TicketChat(id: chatID, title: "WM8-7 Jon · Board", projectName: "whisperm8", projectPath: projectA, state: nil, isRunning: true)]
        let controller = TicketBoardController(environment: world.environment)
        await controller.show(projectPath: projectA, projectName: "whisperm8")
        await settle { controller.phase == .ready }
        controller.viewModel.selectedKey = "WM8-7"
        XCTAssertEqual(controller.viewModel.detail?.localChatID, chatID)
    }

    // MARK: Projektwechsel

    func testProjectChangeDropsFilterSelectionAndOldBoard() async {
        let world = readyWorld()
        world.set(projectB, .ready(team: "DS", workspace: "dealsupply", projectPath: projectB))
        world.source.onBoard = { team in
            team == "WM8"
                ? TicketFixtures.snapshot([TicketFixtures.ticket(1), TicketFixtures.ticket(2)], at: 100)
                : TicketFixtures.snapshot([TicketFixtures.ticket(3, project: "Import")], at: 200)
        }
        let controller = TicketBoardController(environment: world.environment)
        await controller.show(projectPath: projectA, projectName: "whisperm8")
        await settle { controller.phase == .ready }
        controller.viewModel.selectedKey = "WM8-1"
        controller.viewModel.mode = .backlog
        controller.viewModel.filter.project = "Neustart"

        world.holdResolves()
        let change = Task { await controller.show(projectPath: projectB, projectName: "ListM8") }
        await settle { world.resolved.count == 2 }
        // Schon vor der Antwort: nichts vom alten Projekt bleibt stehen.
        XCTAssertEqual(controller.phase, .loading)
        XCTAssertNil(controller.viewModel.selectedKey)
        XCTAssertEqual(controller.viewModel.mode, .board)
        XCTAssertNil(controller.viewModel.filter.project)
        XCTAssertEqual(controller.viewModel.presentation.visibleCount, 0)
        XCTAssertNil(controller.load.fetchedAt)

        world.releaseResolves()
        await change.value
        await settle { controller.phase == .ready }
        XCTAssertEqual(controller.title, "ListM8")
        XCTAssertEqual(controller.viewModel.presentation.visibleCount, 1)
        XCTAssertEqual(world.madeStores, ["whisperm8", "dealsupply"])

        // Der Takt des alten Projekts ruft nicht mehr ab.
        let before = world.source.calls.filter { $0 == "board WM8" }.count
        world.tick()
        await settle { world.source.calls.filter { $0 == "board DS" }.count == 2 }
        XCTAssertEqual(world.source.calls.filter { $0 == "board WM8" }.count, before)
    }

    func testOvertakenResolutionChangesNothing() async {
        let world = readyWorld()
        world.set(projectB, .noKey(workspace: "dealsupply"))
        let controller = TicketBoardController(environment: world.environment)

        world.holdResolves()
        let first = Task { await controller.show(projectPath: projectA, projectName: "whisperm8") }
        await settle { world.resolved.count == 1 }
        let second = Task { await controller.show(projectPath: projectB, projectName: "ListM8") }
        await settle { world.resolved.count == 2 }
        world.releaseResolves()
        await first.value
        await second.value

        XCTAssertEqual(controller.phase, .noKey(workspace: "dealsupply"))
        XCTAssertEqual(controller.title, "ListM8")
        XCTAssertEqual(world.madeStores, [], "die überholte Antwort für das erste Projekt legt keinen Abruf an")
        XCTAssertEqual(boards(world), 0)
    }

    func testHideWhileResolvingStartsNoFetch() async {
        let world = readyWorld()
        let controller = TicketBoardController(environment: world.environment)
        world.holdResolves()
        let show = Task { await controller.show(projectPath: projectA, projectName: "whisperm8") }
        await settle { world.resolved.count == 1 }
        controller.hide()
        world.releaseResolves()
        await show.value
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(boards(world), 0)
    }

    func testSetupDoneWhileOpenIsPickedUpOnNextShow() async {
        let world = World()
        world.source.onBoard = { _ in TicketFixtures.snapshot([TicketFixtures.ticket(1)], at: 100) }
        let controller = TicketBoardController(environment: world.environment)
        await controller.show(projectPath: projectA, projectName: "whisperm8")
        XCTAssertEqual(controller.phase, .notMapped)

        // In den Einstellungen eingerichtet; das Fenster wird wieder aktiv.
        world.set(projectA, .ready(team: "WM8", workspace: "whisperm8", projectPath: projectA))
        await controller.show(projectPath: projectA, projectName: "whisperm8")
        await settle { controller.phase == .ready }
        XCTAssertEqual(controller.viewModel.presentation.visibleCount, 1)
    }

    func testAccessLostWhileOpenLeavesNoOldBoard() async {
        let world = readyWorld()
        let controller = TicketBoardController(environment: world.environment)
        await controller.show(projectPath: projectA, projectName: "whisperm8")
        await settle { controller.phase == .ready }

        world.set(projectA, .noKey(workspace: "whisperm8"))
        await controller.show(projectPath: projectA, projectName: "whisperm8")
        XCTAssertEqual(controller.phase, .noKey(workspace: "whisperm8"))
        XCTAssertEqual(controller.viewModel.presentation.visibleCount, 0)
        world.tick()
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(boards(world), 1, "ohne Schlüssel kein Abruf mehr")
    }
}
