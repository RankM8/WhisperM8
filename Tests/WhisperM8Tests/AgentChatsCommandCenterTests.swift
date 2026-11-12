import Foundation
import XCTest
@testable import WhisperM8

/// Befehls-Katalog der Agent-Chats-Fenster: Anmeldung mit Token und Routing
/// ausschließlich zum aktiven Fenster.
@MainActor
final class AgentChatsCommandCenterTests: XCTestCase {
    /// Handler-Attrappe: merkt sich die Befehle und meldet sich wahlweise als
    /// Key-Fenster.
    private final class WindowSpy {
        let id = UUID()
        var isKey = true
        var isNewChatPickerOpen = false
        var screenDisplayID: UInt32?
        var result = true
        private(set) var received: [AgentChatsCommand] = []

        var handler: AgentChatsCommandCenter.Handler {
            AgentChatsCommandCenter.Handler(
                perform: { [unowned self] command in
                    received.append(command)
                    return result
                },
                snapshot: { [unowned self] in
                    AgentChatsWindowSnapshot(
                        windowID: id,
                        isKeyWindow: isKey,
                        selectedSessionID: nil,
                        isGridActive: false,
                        canReturnToWorkspace: false,
                        isSwitcherOpen: false,
                        hasSheet: false,
                        isSidebarVisible: true,
                        hasMultiSelection: false,
                        isArchiveMode: false,
                        isNewChatPickerOpen: isNewChatPickerOpen,
                        screenDisplayID: screenDisplayID
                    )
                }
            )
        }
    }

    private var keyWindowID: UUID?

    private func makeCenter() -> AgentChatsCommandCenter {
        AgentChatsCommandCenter(keyWindowID: { [unowned self] in keyWindowID })
    }

    // MARK: - Routing

    func testCommandGoesToKeyWindow() {
        let center = makeCenter()
        let first = WindowSpy()
        let second = WindowSpy()
        _ = center.register(windowID: first.id, handler: first.handler)
        _ = center.register(windowID: second.id, handler: second.handler)
        keyWindowID = second.id

        XCTAssertTrue(center.perform(.nextTab))

        XCTAssertEqual(first.received, [])
        XCTAssertEqual(second.received, [.nextTab])
    }

    func testNoKeyWindowMeansNoCommand() {
        let center = makeCenter()
        let window = WindowSpy()
        _ = center.register(windowID: window.id, handler: window.handler)
        keyWindowID = nil

        XCTAssertFalse(center.perform(.lastChat))
        XCTAssertEqual(window.received, [])
        XCTAssertNil(center.activeWindowID)
        XCTAssertNil(center.snapshot())
    }

    /// Der Store nennt ein Fenster als Key, das Fenster selbst sieht sich aber
    /// nicht (mehr) so — etwa kurz nach einem App-Wechsel. Dann nichts tun.
    func testWindowThatIsNotKeyItselfIsSkipped() {
        let center = makeCenter()
        let window = WindowSpy()
        window.isKey = false
        _ = center.register(windowID: window.id, handler: window.handler)
        keyWindowID = window.id

        XCTAssertFalse(center.perform(.previousTab))
        XCTAssertEqual(window.received, [])
    }

    /// Runde 2: Die Projekt-Auswahl „Neuer Chat“ ist ein Popover, das selbst
    /// Key wird. Das Fenster mit offener Auswahl bleibt Ziel des Controllers.
    func testWindowWithOpenNewChatPickerStaysActive() {
        let center = makeCenter()
        let other = WindowSpy()
        let window = WindowSpy()
        window.isNewChatPickerOpen = true
        window.isKey = false
        _ = center.register(windowID: other.id, handler: other.handler)
        _ = center.register(windowID: window.id, handler: window.handler)
        keyWindowID = nil

        XCTAssertEqual(center.activeWindowID, window.id)
        XCTAssertEqual(center.snapshot()?.isNewChatPickerOpen, true)
        // Befehle ohne Ziel gehen trotzdem nur an ein Fenster, das Key ist.
        XCTAssertFalse(center.perform(.nextTab))

        window.isNewChatPickerOpen = false
        XCTAssertNil(center.activeWindowID)
    }

    func testKeyWindowWithoutHandlerIsNotActive() {
        let center = makeCenter()
        keyWindowID = UUID()

        XCTAssertNil(center.activeWindowID)
        XCTAssertFalse(center.perform(.nextTab))
    }

    /// Gezieltes Ziel (Debug-Kanal der Test-Instanz, Tests): geht auch an ein
    /// Fenster, das nicht Key ist.
    func testExplicitWindowBypassesKeyCheck() {
        let center = makeCenter()
        let window = WindowSpy()
        window.isKey = false
        _ = center.register(windowID: window.id, handler: window.handler)

        XCTAssertTrue(center.perform(.lastChat, in: window.id))
        XCTAssertEqual(window.received, [.lastChat])
        XCTAssertEqual(center.snapshot(of: window.id)?.windowID, window.id)
    }

    func testResultOfHandlerIsPassedThrough() {
        let center = makeCenter()
        let window = WindowSpy()
        window.result = false
        _ = center.register(windowID: window.id, handler: window.handler)
        keyWindowID = window.id

        XCTAssertFalse(center.perform(.lastChat))
        XCTAssertEqual(window.received, [.lastChat])
    }

    // MARK: - Anmeldung

    func testUnregisterRemovesHandler() {
        let center = makeCenter()
        let window = WindowSpy()
        let token = center.register(windowID: window.id, handler: window.handler)
        keyWindowID = window.id

        center.unregister(token)

        XCTAssertFalse(center.perform(.nextTab))
        XCTAssertEqual(window.received, [])
    }

    /// Bildschirm für die Pille der Notch-Anzeige: bevorzugt das zuletzt
    /// aktive Fenster; nach dem Schließen (Abmelden beim `willClose`) zählt
    /// es nicht mehr, ohne Fenster gibt es keinen Bildschirm.
    func testWindowDisplayIDFollowsThePreferredWindowAndForgetsClosedOnes() {
        let center = makeCenter()
        let first = WindowSpy()
        first.screenDisplayID = 2
        let second = WindowSpy()
        second.screenDisplayID = 5
        let firstToken = center.register(windowID: first.id, handler: first.handler)
        let secondToken = center.register(windowID: second.id, handler: second.handler)

        XCTAssertEqual(center.windowDisplayID(preferring: second.id), 5)
        XCTAssertEqual(center.windowDisplayID(preferring: first.id), 2)
        center.unregister(secondToken)
        XCTAssertEqual(center.windowDisplayID(preferring: second.id), 2, "geschlossenes Fenster zählt nicht")
        center.unregister(firstToken)
        XCTAssertNil(center.windowDisplayID(preferring: first.id))
    }

    /// Neuaufbau der View: Die neue Instanz meldet sich an, danach läuft das
    /// `onDisappear` der alten mit ihrem veralteten Token. Der neue Handler
    /// muss bleiben.
    func testStaleTokenDoesNotRemoveNewerHandler() {
        let center = makeCenter()
        let old = WindowSpy()
        let windowID = old.id
        let staleToken = center.register(windowID: windowID, handler: old.handler)

        let replacement = WindowSpy()
        _ = center.register(windowID: windowID, handler: replacement.handler)
        center.unregister(staleToken)
        keyWindowID = windowID

        XCTAssertTrue(center.perform(.nextTab))
        XCTAssertEqual(old.received, [])
        XCTAssertEqual(replacement.received, [.nextTab])
    }
}
