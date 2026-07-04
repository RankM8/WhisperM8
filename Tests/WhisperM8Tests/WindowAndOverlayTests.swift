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

        // Deep-Link in die Output-Sektion der Settings (Menüleiste/App-Menü).
        XCTAssertEqual(WindowRequest.settingsOutput.targetWindowID, "settings")
        XCTAssertEqual(WindowRequest.settingsOutput.settingsSectionID, "outputOverview")

        // Primaerfenster = eigene Single-`Window`-Scene; die WindowGroup-ID
        // ist davon getrennt und gilt nur fuer abgeloeste Sekundaerfenster.
        XCTAssertEqual(WindowRequest.agentChats.targetWindowID, "agent-chats")
        XCTAssertNil(WindowRequest.agentChats.settingsSectionID)
        XCTAssertEqual(WindowRequest.agentChatWindowGroupID, "agent-chat-window")
    }

    func testExplicitAgentChatsRequestUnlocksPrimaryWindow() {
        let center = WindowRequestCenter.shared
        let original = center.allowsAgentChatsPrimaryWindow
        defer { center.allowsAgentChatsPrimaryWindow = original }

        // Menüleisten-Profil-Zustand simulieren: Primärfenster gesperrt.
        center.allowsAgentChatsPrimaryWindow = false

        // Ein Nicht-Agent-Chats-Request lässt die Sperre unangetastet…
        center.request(.settings)
        XCTAssertFalse(center.allowsAgentChatsPrimaryWindow)

        // …ein expliziter Agent-Chats-Wunsch (Menüleiste, Profilwechsel) gibt frei.
        center.request(.agentChats)
        XCTAssertTrue(center.allowsAgentChatsPrimaryWindow)
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

    // Drag-Clamp der Pill: siehe OverlayFrameResolverTests — der Store
    // delegiert Geometrie komplett an den pure OverlayFrameResolver.
}
