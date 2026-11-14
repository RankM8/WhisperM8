import XCTest
@testable import WhisperM8

@MainActor
final class TicketsSettingsModelTests: XCTestCase {
    /// Zustand hinter den Abhängigkeiten. Jede Closure prüft, dass sie nicht auf
    /// dem Main Thread läuft: Der Schlüsselbund ist ein blockierender Kindprozess.
    private final class World: @unchecked Sendable {
        private let lock = NSLock()
        private var _config = TicketConfig()
        private var _keys: [String: String] = [:]
        private var _calls: [String] = []
        private var _onMain: [String] = []
        var account: Result<TicketAccount, TicketSourceError> = .success(
            TicketAccount(userName: "Giuliano Costa", workspace: "WhisperM8 (linear.app/whisperm8)", workspaceKey: "whisperm8", isAdmin: true))
        var teams: [String: Result<[String], TicketSourceError>] = ["whisperm8": .success(["WM8"]), "dealsupply": .success(["PRB", "DS"])]
        var storeSucceeds = true
        var deleteSucceeds = true
        var saveFails = false
        /// Die Datei ist da, lässt sich aber nicht lesen.
        var unreadable = false
        /// Hält den ersten Aufruf von `teams` an, bis der Test ihn freigibt.
        var firstTeamsCallGate: DispatchSemaphore?
        private var gateUsed = false

        func waitAtGateOnce() {
            lock.lock()
            let gate = gateUsed ? nil : firstTeamsCallGate
            if gate != nil { gateUsed = true }
            lock.unlock()
            gate?.wait()
        }

        var config: TicketConfig {
            get { lock.lock(); defer { lock.unlock() }; return _config }
            set { lock.lock(); _config = newValue; lock.unlock() }
        }
        var keys: [String: String] {
            get { lock.lock(); defer { lock.unlock() }; return _keys }
            set { lock.lock(); _keys = newValue; lock.unlock() }
        }
        var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }
        var ranOnMain: [String] { lock.lock(); defer { lock.unlock() }; return _onMain }

        func note(_ call: String) {
            lock.lock()
            _calls.append(call)
            if Thread.isMainThread { _onMain.append(call) }
            lock.unlock()
        }
    }

    private struct SaveFailed: Error {}

    private func waitUntil(_ condition: @escaping () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "Bedingung nicht eingetreten")
    }

    private func model(_ world: World, projects: [TicketProjectChoice] = []) -> TicketsSettingsModel {
        TicketsSettingsModel(dependencies: TicketsSettingsDependencies(
            loadConfig: { world.note("loadConfig"); return world.config },
            loadConfigForChange: {
                world.note("loadConfigForChange")
                if world.unreadable { throw SaveFailed() }
                return world.config
            },
            saveConfig: { config in
                world.note("saveConfig")
                if world.saveFails { throw SaveFailed() }
                world.config = config
            },
            hasKey: { world.note("hasKey \($0)"); return world.keys[$0] != nil },
            storeKey: { workspace, key in
                world.note("storeKey \(workspace)")
                if world.storeSucceeds { world.keys[workspace] = key }
                return world.storeSucceeds
            },
            deleteKey: { workspace in
                world.note("deleteKey \(workspace)")
                if world.deleteSucceeds { world.keys[workspace] = nil }
                return world.deleteSucceeds
            },
            account: { _ in world.note("account"); return world.account },
            teams: { workspace in
                world.note("teams \(workspace)")
                world.waitAtGateOnce()
                return world.teams[workspace] ?? .failure(.unauthorized)
            },
            projects: { projects },
            chooseFolder: { nil }
        ))
    }

    private func twoWorkspaces() -> World {
        let world = World()
        var config = TicketConfig()
        config.set(workspace: "whisperm8", forTeam: "WM8")
        config.set(team: "WM8", forProject: "/Users/g/repos/whisperm8")
        config.add(workspace: "dealsupply")
        world.config = config
        world.keys = ["whisperm8": "lin_api_a", "dealsupply": "lin_api_b"]
        return world
    }

    // MARK: Laden

    func testLoadShowsWorkspacesTeamsAndMappings() async {
        let world = twoWorkspaces()
        let projects = [TicketProjectChoice(name: "whisperm8", path: "/Users/g/repos/whisperm8"),
                        TicketProjectChoice(name: "ListM8", path: "/Users/g/repos/ListM8")]
        let model = model(world, projects: projects)
        await model.load()
        XCTAssertEqual(model.workspaces.map(\.name), ["dealsupply", "whisperm8"])
        XCTAssertEqual(model.workspaces[0].teams, ["DS", "PRB"], "Teams sortiert")
        XCTAssertEqual(model.teamChoices.map(\.id), ["dealsupply/DS", "dealsupply/PRB", "whisperm8/WM8"])
        XCTAssertEqual(model.mappings, [.init(path: "/Users/g/repos/whisperm8", team: "WM8", workspace: "whisperm8")])
        XCTAssertEqual(model.unmappedProjects.map(\.name), ["ListM8"], "schon zugeordnete Projekte stehen nicht zur Wahl")
    }

    func testAnOverdueLoadDoesNotOverwriteANewerOne() async {
        let world = twoWorkspaces()
        let gate = DispatchSemaphore(value: 0)
        world.firstTeamsCallGate = gate
        let model = model(world)
        let slow = Task { await model.load() }
        await waitUntil { world.calls.contains { $0.hasPrefix("teams") } }

        // Inzwischen kommt ein dritter Workspace dazu, und ein zweites Laden läuft durch.
        var config = world.config
        config.add(workspace: "neu")
        world.config = config
        world.keys["neu"] = "lin_api_c"
        world.teams["neu"] = .success(["NEU"])
        await model.load()
        XCTAssertEqual(model.workspaces.map(\.name), ["dealsupply", "neu", "whisperm8"])

        let callsBefore = world.calls.count
        gate.signal()
        await slow.value
        XCTAssertEqual(model.workspaces.map(\.name), ["dealsupply", "neu", "whisperm8"], "das überholte Laden trägt nichts mehr ein")
        XCTAssertEqual(world.calls.count, callsBefore, "und fragt auch nicht weiter")
    }

    func testStopKeepsARunningLoadFromAskingFurther() async {
        let world = twoWorkspaces()
        let gate = DispatchSemaphore(value: 0)
        world.firstTeamsCallGate = gate
        let model = model(world)
        let running = Task { await model.load() }
        await waitUntil { world.calls.contains { $0.hasPrefix("teams") } }

        model.stop()   // der Schalter geht aus
        let callsBefore = world.calls
        gate.signal()
        await running.value
        XCTAssertEqual(world.calls, callsBefore, "kein weiterer Griff in Schlüsselbund oder Linear")
        XCTAssertTrue(model.workspaces.isEmpty, "nichts eingetragen")
    }

    func testCancelledLoadStops() async {
        let world = twoWorkspaces()
        let gate = DispatchSemaphore(value: 0)
        world.firstTeamsCallGate = gate
        let model = model(world)
        let running = Task { await model.load() }
        await waitUntil { world.calls.contains { $0.hasPrefix("teams") } }
        running.cancel()   // so beendet `.task(id:)` das Laden, wenn der Schalter wechselt
        let callsBefore = world.calls
        gate.signal()
        await running.value
        XCTAssertEqual(world.calls, callsBefore)
        XCTAssertTrue(model.workspaces.isEmpty)
    }

    func testWorkspaceWithoutKeyOrWithRejectedKeyIsShownAsSuch() async {
        let world = twoWorkspaces()
        world.keys["dealsupply"] = nil
        world.teams["whisperm8"] = .failure(.unauthorized)
        let model = model(world)
        await model.load()
        let dealsupply = model.workspaces[0], whisperm8 = model.workspaces[1]
        XCTAssertFalse(dealsupply.hasKey)
        XCTAssertNil(dealsupply.problem)
        XCTAssertFalse(world.calls.contains("teams dealsupply"), "ohne Key wird Linear nicht gefragt")
        XCTAssertTrue(whisperm8.hasKey)
        XCTAssertEqual(whisperm8.problem, TicketSourceError.unauthorized.userText)
        XCTAssertTrue(model.teamChoices.isEmpty)
    }

    func testNothingRunsOnTheMainThread() async {
        let world = twoWorkspaces()
        let model = model(world)
        await model.load()
        await model.saveKey("lin_api_neu")
        await model.assign(projectPath: "/Users/g/repos/ListM8", to: .init(team: "DS", workspace: "dealsupply"))
        await model.removeMapping(path: "/Users/g/repos/ListM8")
        await model.removeKey(workspace: "dealsupply")
        XCTAssertFalse(world.calls.isEmpty)
        XCTAssertEqual(world.ranOnMain, [], "Schlüsselbund, Datei und Netz laufen abseits des Main Threads")
    }

    // MARK: Key

    func testSaveKeyStoresUnderTheWorkspaceLinearNames() async {
        let world = World()
        world.account = .success(TicketAccount(userName: "Giuliano Costa", workspace: "DealSupply (linear.app/dealsupply)",
                                               workspaceKey: "dealsupply", isAdmin: true))
        let model = model(world)
        let saved = await model.saveKey("  lin_api_ds\n")
        XCTAssertTrue(saved)
        XCTAssertEqual(world.keys, ["dealsupply": "lin_api_ds"])
        XCTAssertEqual(world.config.knownWorkspaces, ["dealsupply"])
        XCTAssertEqual(model.workspaces.map(\.name), ["dealsupply"], "danach neu geladen")
        guard case .saved(let text) = model.keyNotice else { return XCTFail("\(String(describing: model.keyNotice))") }
        XCTAssertTrue(text.contains("DealSupply") && text.contains("Giuliano Costa"))
        XCTAssertFalse(text.contains("lin_api"), "der Key steht in keiner Meldung")
    }

    func testRejectedOrMalformedKeyIsNotStored() async {
        let world = World()
        let model = model(world)
        let malformed = await model.saveKey("kein key \"mit\" zeichen")
        XCTAssertFalse(malformed)
        XCTAssertFalse(world.calls.contains("account"), "ein unförmiger Key geht gar nicht erst an Linear")

        world.account = .failure(.unauthorized)
        let rejected = await model.saveKey("lin_api_falsch")
        XCTAssertFalse(rejected)
        XCTAssertEqual(model.keyNotice, .failed(TicketSourceError.unauthorized.userText))

        world.account = .success(TicketAccount(userName: "x", workspace: "Kaputt", workspaceKey: "Kein Kürzel", isAdmin: false))
        let unnamed = await model.saveKey("lin_api_x")
        XCTAssertFalse(unnamed)

        XCTAssertTrue(world.keys.isEmpty)
        XCTAssertFalse(world.calls.contains { $0.hasPrefix("storeKey") })
        XCTAssertFalse(world.calls.contains("saveConfig"))
        if case .failed(let text) = model.keyNotice { XCTAssertFalse(text.contains("lin_api")) } else { XCTFail("Meldung fehlt") }
    }

    func testKeychainOrFileFailureIsReported() async {
        let world = World()
        world.storeSucceeds = false
        let model = model(world)
        let noKeychain = await model.saveKey("lin_api_a")
        XCTAssertFalse(noKeychain)
        XCTAssertFalse(world.calls.contains("saveConfig"), "ohne Schlüsselbund-Eintrag kein Workspace in der Einrichtung")

        world.storeSucceeds = true
        world.saveFails = true
        let noFile = await model.saveKey("lin_api_a")
        XCTAssertFalse(noFile)
        if case .failed = model.keyNotice {} else { XCTFail("Meldung fehlt") }
    }

    func testRemoveKeyKeepsTheMappings() async {
        let world = twoWorkspaces()
        let model = model(world)
        let before = world.config
        await model.removeKey(workspace: "whisperm8")
        XCTAssertEqual(world.keys, ["dealsupply": "lin_api_b"])
        XCTAssertEqual(world.config, before, "die Einrichtung bleibt, wie sie ist")
        let whisperm8 = model.workspaces.first { $0.name == "whisperm8" }
        XCTAssertEqual(whisperm8?.hasKey, false, "bleibt sichtbar, als „ohne Key“")
        XCTAssertNil(model.keyNotice)

        // Auch ein Workspace, auf den kein Team zeigt, bleibt stehen.
        await model.removeKey(workspace: "dealsupply")
        XCTAssertEqual(model.workspaces.map(\.name), ["dealsupply", "whisperm8"])
    }

    /// Ein Team ohne festen Workspace liegt im einzigen eingerichteten. Fiele
    /// beim Entfernen eines Keys ein Workspace weg, wechselte es still die Firma.
    func testRemoveKeyNeverMovesATeamWithoutFixedWorkspace() async {
        let world = World()
        var config = TicketConfig()
        config.add(workspace: "a")
        config.add(workspace: "b")
        config.set(team: "T", forProject: "/Users/g/repos/t")   // Datei aus der Zeit vor den Workspaces
        world.config = config
        world.keys = ["a": "lin_api_a", "b": "lin_api_b"]
        XCTAssertNil(world.config.workspace(forTeam: "T"), "bei zwei Workspaces wird nicht geraten")
        let model = model(world)
        await model.removeKey(workspace: "b")
        XCTAssertNil(world.config.workspace(forTeam: "T"), "auch danach nicht")
    }

    func testFailedKeyRemovalIsReported() async {
        let world = twoWorkspaces()
        world.deleteSucceeds = false
        let model = model(world)
        await model.removeKey(workspace: "whisperm8")
        XCTAssertEqual(world.keys.count, 2)
        if case .failed = model.keyNotice {} else { XCTFail("Meldung fehlt") }
        XCTAssertEqual(model.workspaces.first { $0.name == "whisperm8" }?.hasKey, true)
    }

    func testNothingIsWrittenOnTopOfAnUnreadableFile() async {
        let world = twoWorkspaces()
        world.unreadable = true
        let model = model(world)
        let assigned = await model.assign(projectPath: "/Users/g/repos/ListM8", to: .init(team: "DS", workspace: "dealsupply"))
        XCTAssertFalse(assigned)
        XCTAssertNotNil(model.mappingProblem)
        await model.removeMapping(path: "/Users/g/repos/whisperm8")
        let saved = await model.saveKey("lin_api_neu")
        XCTAssertFalse(saved)
        XCTAssertFalse(world.calls.contains("saveConfig"), "sonst wäre der Inhalt der Datei verloren")
    }

    func testSecondSaveWhileOneIsRunningIsIgnored() async {
        let world = World()
        let model = model(world)
        async let first = model.saveKey("lin_api_a")
        async let second = model.saveKey("lin_api_a")
        let results = await [first, second]
        XCTAssertEqual(results.filter { $0 }.count, 1, "Return und Knopf zugleich speichern nur einmal")
        XCTAssertEqual(world.calls.filter { $0 == "account" }.count, 1)
    }

    // MARK: Zuordnung

    func testAssignWritesProjectAndTeam() async {
        let world = twoWorkspaces()
        let model = model(world)
        let assigned = await model.assign(projectPath: "/Users/g/repos/ListM8/", to: .init(team: "DS", workspace: "dealsupply"))
        XCTAssertTrue(assigned)
        XCTAssertEqual(world.config.teamsByProjectPath["/Users/g/repos/ListM8"], "DS")
        XCTAssertEqual(world.config.workspacesByTeam["DS"], "dealsupply")
        XCTAssertNil(model.mappingProblem)
        XCTAssertEqual(model.mappings.map(\.team), ["DS", "WM8"])
    }

    func testAssignDoesNotMoveATeamToAnotherWorkspace() async {
        let world = twoWorkspaces()
        world.teams["dealsupply"] = .success(["DS", "WM8"])   // dasselbe Kürzel gibt es drüben auch
        let model = model(world)
        let before = world.config
        let assigned = await model.assign(projectPath: "/Users/g/repos/ListM8", to: .init(team: "WM8", workspace: "dealsupply"))
        XCTAssertFalse(assigned)
        XCTAssertEqual(world.config, before, "nichts geändert: sonst schriebe das WhisperM8-Projekt nach drüben")
        XCTAssertNotNil(model.mappingProblem)
        XCTAssertTrue(model.mappingProblem?.contains("--reassign") ?? false)
    }

    func testRemoveMappingKeepsTheTeam() async {
        let world = twoWorkspaces()
        let model = model(world)
        await model.removeMapping(path: "/Users/g/repos/whisperm8")
        XCTAssertTrue(world.config.teamsByProjectPath.isEmpty)
        XCTAssertEqual(world.config.workspacesByTeam, ["WM8": "whisperm8"])
        XCTAssertTrue(model.mappings.isEmpty)
    }

    // MARK: Kleinkram

    func testShortPathAndFolderName() {
        XCTAssertEqual(TicketsSettingsText.shortPath("/Users/g/repos/whisperm8", home: "/Users/g"), "~/repos/whisperm8")
        XCTAssertEqual(TicketsSettingsText.shortPath("/Users/g", home: "/Users/g"), "~")
        XCTAssertEqual(TicketsSettingsText.shortPath("/Users/gast/x", home: "/Users/g"), "/Users/gast/x", "kein Treffer auf bloßen Namensanfang")
    }

    func testErrorTextsNeverContainAKeyAndAreNotCLIText() {
        // `.rejected` und `.ambiguous` reichen fremden Text durch; geprüft wird der eigene.
        let all: [TicketSourceError] = [.notConfigured, .unauthorized, .rateLimited, .network("x"), .notFound("Team XX"),
                                        .invalidResponse("z")]
        for error in all {
            XCTAssertFalse(error.userText.isEmpty)
            XCTAssertFalse(error.userText.contains("lin_api"))
            XCTAssertFalse(error.userText.contains("whisperm8 tickets"), "in der App kein Verweis auf Befehle: \(error)")
        }
    }

    func testSwitchIsOffByDefaultAndPageLivesInLabs() {
        let suite = "tickets-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(AppPreferences(defaults: defaults).isTicketBoardEnabled)
        XCTAssertEqual(SettingsNavigation.launchClass(of: .tickets), .labs)
        XCTAssertTrue(SettingsNavigation.agentPages.contains(.tickets), "im reinen Diktat-Profil nicht in der Hauptliste")
        XCTAssertEqual(SettingsPage.page(routeID: "tickets"), .tickets)
    }
}
