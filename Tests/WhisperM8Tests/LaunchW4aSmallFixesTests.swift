import XCTest
@testable import WhisperM8

/// Kleine Fixes der Welle W4a.
final class LaunchW4aSmallFixesTests: XCTestCase {
    /// LR-CLI-004: Maschinell ausgelöste Befehle holen die App nicht nach vorn.
    func testOnlyExplicitOpenActivatesApp() {
        XCTAssertFalse(ControlActivationPolicy.shouldActivate(method: "session.resume", wantsOpen: false))
        XCTAssertFalse(ControlActivationPolicy.shouldActivate(method: "session.new", wantsOpen: false))
        XCTAssertFalse(ControlActivationPolicy.shouldActivate(method: "workspace.unarchive", wantsOpen: false))
        XCTAssertTrue(ControlActivationPolicy.shouldActivate(method: "workspace.unarchive", wantsOpen: true))
        XCTAssertTrue(ControlActivationPolicy.shouldActivate(method: "session.open", wantsOpen: true))
    }
}

/// LR-AU-007: Ein defekter UI-State wird gesichert, bevor die Erst-Migration ihn ersetzt.
final class UIStateBackupTests: XCTestCase {
    func testBrokenUIStateIsBackedUpBeforeMigration() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uistate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ui = dir.appendingPathComponent("agent-ui-state.json")
        let broken = Data(#"{"schemaVersion": "kaputt", "pinned": [1,2"#.utf8)
        try broken.write(to: ui)
        let store = AgentSessionStore(fileURL: dir.appendingPathComponent("ws.json"), uiStateFileURL: ui)
        _ = store.loadUIState()
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".decode-failed-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(backups[0])), broken)
    }
}

/// LR-AU-010: Tab-Kürzel nicht in Textfeldern.
@MainActor
final class TabNavFirstResponderTests: XCTestCase {
    func testTextEditorsKeepShortcuts() {
        XCTAssertFalse(TabNavShortcut.shouldHandle(firstResponder: NSTextView()))
        XCTAssertTrue(TabNavShortcut.shouldHandle(firstResponder: NSView()))
        XCTAssertTrue(TabNavShortcut.shouldHandle(firstResponder: nil))
    }
}

/// LR-AU-012: Bulk-Aktionen in sichtbarer Reihenfolge.
@MainActor
final class BulkOrderTests: XCTestCase {
    func testSelectionFollowsVisualTabOrder() {
        let ids = (0..<5).map { _ in UUID() }
        let order = [ids[3], ids[0], ids[4], ids[1]]
        let selection: Set<UUID> = [ids[4], ids[0], ids[3], ids[2]]
        let result = AgentChatsView.orderedSelection(selection, visualOrder: order)
        XCTAssertEqual(Array(result.prefix(3)), [ids[3], ids[0], ids[4]])
        XCTAssertEqual(result.last, ids[2], "ohne Tab hinten")
    }
}

/// LR-KO-005: Profil mit laufendem Chat lässt sich nicht entfernen.
final class ClaudeProfileRunningGuardTests: XCTestCase {
    func testRunningSessionOfProfileBlocks() {
        var session = AgentChatSession(provider: .claude, projectID: UUID(), title: "x")
        session.claudeProfileName = "a"
        XCTAssertTrue(ClaudeProfileRunningGuard.hasRunningSession(profile: "a", sessions: [session], runningIDs: [session.id]))
        XCTAssertFalse(ClaudeProfileRunningGuard.hasRunningSession(profile: "a", sessions: [session], runningIDs: []))
        XCTAssertFalse(ClaudeProfileRunningGuard.hasRunningSession(profile: "b", sessions: [session], runningIDs: [session.id]))
    }
}

/// LR-AU-006 (D4): Cmd+Q fragt nur bei arbeitenden oder wartenden Chats.
final class QuitConfirmationTests: XCTestCase {
    func testOnlyWorkingOrWaitingChatsNeedConfirmation() {
        let working = UUID(), waiting = UUID(), idle = UUID()
        let statuses: [UUID: AgentSessionRuntimeStatus] = [working: .working, waiting: .awaitingInput, idle: .idle]
        let busy = QuitConfirmation.busySessionIDs(running: [working, waiting, idle], status: { statuses[$0] })
        XCTAssertEqual(busy, [working, waiting])
        XCTAssertTrue(QuitConfirmation.busySessionIDs(running: [idle], status: { statuses[$0] }).isEmpty)
    }

    func testSystemQuitSkipsDialog() {
        XCTAssertTrue(QuitConfirmation.isSystemQuit(kAEShutDown))
        XCTAssertTrue(QuitConfirmation.isSystemQuit(kAEReallyLogOut))
        XCTAssertFalse(QuitConfirmation.isSystemQuit(nil))
    }

    func testKeepForResumeLeavesMarkerWithRunningChats() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("marker-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let marker = AgentCrashRecoveryMarker(fileURL: url, ownPID: 4242, isProcessAlive: { _ in false })
        _ = marker.beginRun()
        let ids: Set<UUID> = [UUID(), UUID()]
        marker.record(runningSessionIDs: ids)
        marker.keepForResume(runningSessionIDs: ids)
        marker.record(runningSessionIDs: [])   // PTYs sterben beim Quit
        let next = AgentCrashRecoveryMarker(fileURL: url, ownPID: 4343, isProcessAlive: { _ in false })
        XCTAssertEqual(Set(next.beginRun()), ids)
    }
}
