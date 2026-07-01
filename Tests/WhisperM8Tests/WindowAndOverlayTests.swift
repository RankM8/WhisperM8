import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import WhisperM8

@MainActor
final class WindowAndOverlayTests: XCTestCase {
    override func tearDown() {
        WindowRequestCenter.shared.resetForTesting()
        super.tearDown()
    }

    func testWindowRequestCenterStoresLatestRequest() {
        let center = WindowRequestCenter.shared

        center.request(.settings)
        XCTAssertEqual(center.latestRequest, .settings)

        center.request(.onboarding)
        XCTAssertEqual(center.latestRequest, .onboarding)
    }

    func testWindowRequestsExposeExplicitRoutingTargets() {
        XCTAssertEqual(WindowRequest.settings.targetWindowID, "settings")
        XCTAssertEqual(WindowRequest.settings.settingsSectionID, "api")

        // Primaerfenster = eigene Single-`Window`-Scene; die WindowGroup-ID
        // ist davon getrennt und gilt nur fuer abgeloeste Sekundaerfenster.
        XCTAssertEqual(WindowRequest.agentChats.targetWindowID, "agent-chats")
        XCTAssertNil(WindowRequest.agentChats.settingsSectionID)
        XCTAssertEqual(WindowRequest.agentChatWindowGroupID, "agent-chat-window")
    }

    func testAgentDragDropUTIsMatchInfoPlistDeclarations() throws {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("WhisperM8/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )
        let declarations = try XCTUnwrap(plist["UTExportedTypeDeclarations"] as? [[String: Any]])
        let identifiers = Set(declarations.compactMap { $0["UTTypeIdentifier"] as? String })

        XCTAssertTrue(identifiers.contains(UTType.agentChatSession.identifier))
        XCTAssertTrue(identifiers.contains(UTType.agentProject.identifier))
    }

    func testOverlayClampKeepsPanelInsideVisibleFrame() {
        let visibleFrame = NSRect(x: 100, y: 100, width: 800, height: 600)
        let panelSize = NSSize(width: 300, height: 100)

        let clamped = OverlayPositionStore.clamp(
            origin: NSPoint(x: 950, y: 50),
            size: panelSize,
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(clamped.x, 600)
        XCTAssertEqual(clamped.y, 100)
    }
}
