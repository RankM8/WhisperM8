import XCTest
@testable import WhisperM8

/// WM8-91, Bild vom 16.11.2026: Die Leiste unten zeigte ein anderes Team und
/// einen anderen Rückweg als der Kopf des Boards. Ursache: Der Zusammenhang
/// der Leiste (`ControllerUIModel.context`) wurde beim Wechsel des
/// Key-Fensters nicht neu bestimmt; das neue Fenster zeigte bis zur nächsten
/// Eingabe den des vorigen.
@MainActor
final class ControllerLegendWindowSwitchTests: XCTestCase {
    private var first: ControllerWindowFake!
    private var second: ControllerWindowFake!
    private var key: UUID?
    private var ui: ControllerUIModel!
    private var dispatcher: ControllerActionDispatcher!

    override func setUp() async throws {
        first = ControllerWindowFake()
        second = ControllerWindowFake()
        ui = ControllerUIModel()
        key = first.id
        let center = AgentChatsCommandCenter(keyWindowID: { [unowned self] in key })
        _ = center.register(windowID: first.id, handler: first.handler)
        _ = center.register(windowID: second.id, handler: second.handler)
        first.tickets = ControllerTicketsPlace(projectID: UUID(), team: "WM8")
        second.tickets = ControllerTicketsPlace(projectID: UUID(), team: "XYZ")
        dispatcher = ControllerActionDispatcher(
            chats: center, terminals: ControllerTerminalSpy(), dictation: ControllerDictationSpy(),
            environment: ControllerEnvironmentSpy(), ui: ui, island: ControllerIslandSpy())
    }

    private var team: String? {
        guard case .tickets(let state) = ui.context else { return nil }
        return state.place.team
    }

    func testRefreshAfterTheKeyWindowChangedShowsTheNewBoard() {
        dispatcher.refreshContext()
        XCTAssertEqual(team, "WM8")
        key = second.id
        XCTAssertEqual(team, "WM8", "ohne Neu-Lesen bleibt das Team des vorigen Fensters stehen")
        dispatcher.refreshContext()
        XCTAssertEqual(team, "XYZ")
    }

    /// Die Verdrahtung: Wird ein Fenster Key, liest die Leiste neu, und zwar
    /// nachdem der Store das neue Key-Fenster kennt (sonst läse sie wieder das alte).
    func testBecomingKeyRefreshesTheLegendAfterTheStoreKnowsTheWindow() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func source(_ name: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent("WhisperM8/Views/\(name)"), encoding: .utf8)
        }
        XCTAssertTrue(try source("AgentChatsView.swift").contains("onBecomeKey: { windowBecameKey() }"))
        let text = try source("AgentChatsView+ControllerTickets.swift")
        let start = try XCTUnwrap(text.range(of: "func windowBecameKey() {"))
        let end = try XCTUnwrap(text.range(of: "\n    }", range: start.upperBound..<text.endIndex))
        let block = String(text[start.upperBound..<end.lowerBound])
        let store = try XCTUnwrap(block.range(of: "windowStore.windowDidBecomeKey(windowID)"))
        let refresh = try XCTUnwrap(block.range(of: "controllerLegendMayHaveChanged()"))
        XCTAssertLessThan(store.lowerBound, refresh.lowerBound)
    }
}
