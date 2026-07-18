import XCTest
@testable import WhisperM8

/// Tests des Plugin-Manager-Models: Operations-Serialisierung,
/// restartRequired-Semantik, Details-Cache-Key und Token-Summe.
@MainActor
final class ClaudePluginManagerModelTests: XCTestCase {
    private final class FakeCLIState: @unchecked Sendable {
        var calls: [[String]] = []
        var listJSON = #"{"installed": [], "available": []}"#
        var detailsText = ""
        var shouldFail = false
        var failOnList = false
        var failOnDetails = false
    }

    private func makeModel(state: FakeCLIState) -> ClaudePluginManagerModel {
        let model = ClaudePluginManagerModel()
        var cli = ClaudePluginCLI()
        cli.commandResolver = { _ in "/usr/local/bin/claude" }
        cli.environmentBuilder = { _ in [:] }
        cli.runner = { _, arguments, _ in
            state.calls.append(arguments)
            if state.shouldFail {
                throw AgentHeadlessCLIError.nonZeroExit(1, stderr: "boom")
            }
            if arguments.contains("marketplace") { return "[]" }
            if arguments.contains("details") {
                if state.failOnDetails {
                    throw AgentHeadlessCLIError.nonZeroExit(1, stderr: "details boom")
                }
                return state.detailsText
            }
            if arguments.contains("list") {
                if state.failOnList {
                    throw AgentHeadlessCLIError.nonZeroExit(1, stderr: "list boom")
                }
                return state.listJSON
            }
            return ""
        }
        model.cli = cli
        return model
    }

    private func installedFixture(enabled: Bool = true) -> String {
        """
        {"installed": [
            {"id": "leadgenjay@360-plugins", "version": "1.0.0", "scope": "user",
             "enabled": \(enabled), "installPath": "/x"}
        ], "available": []}
        """
    }

    func testReloadPopulatesListAndMutationSetsRestartRequired() async {
        let state = FakeCLIState()
        state.listJSON = installedFixture()
        let model = makeModel(state: state)

        await model.loadIfNeeded()
        XCTAssertEqual(model.pluginList.installed.map(\.id), ["leadgenjay@360-plugins"])
        XCTAssertFalse(model.restartRequired) // reines Laden ist keine Mutation

        await model.setEnabled(false, plugin: model.pluginList.installed[0])
        XCTAssertTrue(model.restartRequired)
        XCTAssertNil(model.lastError)
        // Mutation → disable + list + marketplace-Reload.
        XCTAssertTrue(state.calls.contains { $0.starts(with: ["plugin", "disable"]) })
    }

    func testFailedMutationSurfacesErrorAndDoesNotRequireRestart() async {
        let state = FakeCLIState()
        let model = makeModel(state: state)
        await model.loadIfNeeded()

        state.shouldFail = true
        await model.install("x@y", scope: .user, config: [:])
        XCTAssertNotNil(model.lastError)
        XCTAssertFalse(model.restartRequired)
        XCTAssertFalse(model.isBusy)
    }

    func testDetailsCacheKeyIncludesVersionAndTokenSum() async {
        let state = FakeCLIState()
        state.listJSON = installedFixture()
        state.detailsText = """
        leadgenjay 1.0.0
          Paket.
          Source: leadgenjay@360-plugins

        Projected token cost
          Always-on:   ~15,070 tok   added to every session
        """
        let model = makeModel(state: state)
        await model.loadIfNeeded()
        let plugin = model.pluginList.installed[0]

        XCTAssertFalse(model.isTokenSumComplete)
        await model.loadDetailsIfNeeded(for: plugin)
        XCTAssertEqual(model.cacheKey(for: plugin), "leadgenjay@360-plugins@1.0.0")
        XCTAssertEqual(model.enabledAlwaysOnTokenSum, 15070)
        XCTAssertTrue(model.isTokenSumComplete)

        // Zweiter Aufruf trifft den Cache — kein weiterer details-Call.
        let callsBefore = state.calls.count
        await model.loadDetailsIfNeeded(for: plugin)
        XCTAssertEqual(state.calls.count, callsBefore)
    }

    func testDisabledPluginsDoNotCountTowardsTokenSum() async {
        let state = FakeCLIState()
        state.listJSON = installedFixture(enabled: false)
        let model = makeModel(state: state)
        await model.loadIfNeeded()
        XCTAssertEqual(model.enabledAlwaysOnTokenSum, 0)
        XCTAssertTrue(model.isTokenSumComplete) // keine enabled Plugins offen
    }

    func testSuccessfulMutationWithFailedReloadStillRequiresRestart() async {
        // Review-Befund 2026-07-19: die Mutation IST passiert — ein
        // fehlgeschlagener Reload darf weder restartRequired unterschlagen
        // noch den Erfolg als Fehlschlag maskieren.
        let state = FakeCLIState()
        state.listJSON = installedFixture()
        let model = makeModel(state: state)
        await model.loadIfNeeded()

        state.failOnList = true
        await model.setEnabled(false, plugin: model.pluginList.installed[0])

        XCTAssertTrue(model.restartRequired)
        XCTAssertNotNil(model.lastError) // Reload-Fehler wird trotzdem gemeldet
        XCTAssertFalse(model.isBusy)
    }

    func testFailedDetailsLoadCachesPlaceholderInsteadOfSpinningForever() async {
        // Review-Befund 2026-07-19: Fehler beim Details-Fetch liess den
        // Karten-Spinner ewig drehen (Cache blieb nil).
        let state = FakeCLIState()
        state.listJSON = installedFixture()
        state.failOnDetails = true
        let model = makeModel(state: state)
        await model.loadIfNeeded()
        let plugin = model.pluginList.installed[0]

        await model.loadDetailsIfNeeded(for: plugin)

        let cached = model.detailsCache[model.cacheKey(for: plugin)]
        XCTAssertNotNil(cached)             // Platzhalter → UI zeigt "nicht verfuegbar"
        XCTAssertNil(cached?.alwaysOnTokens)
    }

    func testSwitchAccountProfileClearsCacheAndReloads() async {
        let state = FakeCLIState()
        state.listJSON = installedFixture()
        state.detailsText = "leadgenjay 1.0.0\n"
        let model = makeModel(state: state)
        await model.loadIfNeeded()
        await model.loadDetailsIfNeeded(for: model.pluginList.installed[0])
        XCTAssertFalse(model.detailsCache.isEmpty)

        await model.switchAccountProfile(to: "PowerUser")
        XCTAssertTrue(model.detailsCache.isEmpty)
        XCTAssertEqual(model.accountProfileName, "PowerUser")
    }
}
