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
        var saveFails = false

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

    private func model(_ world: World, projects: [TicketProjectChoice] = []) -> TicketsSettingsModel {
        TicketsSettingsModel(dependencies: TicketsSettingsDependencies(
            loadConfig: { world.note("loadConfig"); return world.config },
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
            deleteKey: { world.note("deleteKey \($0)"); world.keys[$0] = nil },
            account: { _ in world.note("account"); return world.account },
            teams: { world.note("teams \($0)"); return world.teams[$0] ?? .failure(.unauthorized) },
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
        XCTAssertFalse(model.isLoading)
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
        await model.removeKey(workspace: "whisperm8")
        XCTAssertEqual(world.keys, ["dealsupply": "lin_api_b"])
        XCTAssertEqual(world.config.workspacesByTeam, ["WM8": "whisperm8"], "die Zuordnung der Teams bleibt")
        XCTAssertEqual(world.config.teamsByProjectPath, ["/Users/g/repos/whisperm8": "WM8"])
        let whisperm8 = model.workspaces.first { $0.name == "whisperm8" }
        XCTAssertEqual(whisperm8?.hasKey, false, "bleibt sichtbar, als „ohne Key“")
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
        XCTAssertEqual(TicketsSettingsText.folderName("/Users/g/repos/ListM8"), "ListM8")
    }

    func testErrorTextsNeverContainAKeyAndAreNotCLIText() {
        let all: [TicketSourceError] = [.notConfigured, .unauthorized, .rateLimited, .network("x"), .notFound("Team XX"),
                                        .rejected("y"), .invalidResponse("z")]
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
