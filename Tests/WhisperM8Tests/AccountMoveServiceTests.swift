import Foundation
import XCTest
@testable import WhisperM8

/// Der komplette Umzugspfad ohne UI: Store-Stempel, Transcript-Bewegung,
/// Journal und Rueckgaengig greifen ineinander. Genau diese Verdrahtung waere
/// sonst nur manuell pruefbar.
@MainActor
final class AccountMoveServiceTests: XCTestCase {
    private var home: URL!
    private var storeURL: URL!
    private var journalURL: URL!
    private var profiles: ClaudeAccountProfiles!
    private var store: AgentSessionStore!
    private var service: AccountMoveService!
    private let cwd = "/tmp/whisperm8-service-test"
    /// Spion auf die Scan-Pause (siehe setUp).
    private var scanDepth = 0
    private var maxScanDepth = 0

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8ServiceHome-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        storeURL = home.appendingPathComponent("AgentSessions.json")
        journalURL = home.appendingPathComponent("account-moves.jsonl")

        profiles = ClaudeAccountProfiles()
        profiles.homeDirectory = home
        try FileManager.default.createDirectory(
            at: profiles.configDir(forProfile: "ai3"), withIntermediateDirectories: true
        )
        store = AgentSessionStore(fileURL: storeURL)

        service = AccountMoveService()
        service.store = store
        service.profiles = profiles
        service.journal = AccountMoveJournal(fileURL: journalURL)
        // Scans NICHT an den echten Coordinator geben: dessen `resumeScans`
        // startet einen Scan gegen die Produktions-Workspace-Datei.
        scanDepth = 0
        maxScanDepth = 0
        service.suspendScans = { [self] in
            scanDepth += 1
            maxScanDepth = max(maxScanDepth, scanDepth)
        }
        service.resumeScans = { [self] in scanDepth -= 1 }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func projectsDir(_ profile: String) -> URL {
        profiles.configDir(forProfile: profile)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(AgentTranscriptLocator.encodeClaudeCwd(cwd), isDirectory: true)
    }

    private func makeSession(externalID: String, profile: String?) throws -> AgentChatSession {
        var session = try store.createSession(
            provider: .claude,
            projectPath: cwd,
            title: "Chat \(externalID)",
            claudeProfile: .explicit(profile)
        )
        session.externalSessionID = externalID
        return try store.upsertSession(session)
    }

    private func writeTranscript(_ id: String, in profile: String) throws {
        let dir = projectsDir(profile)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "verlauf-\(id)".write(
            to: dir.appendingPathComponent("\(id).jsonl"), atomically: true, encoding: .utf8
        )
    }

    private func move(_ session: AgentChatSession, to target: String?) -> AccountMoveService.Move {
        AccountMoveService.Move(
            sessionID: session.id,
            title: session.title,
            externalSessionID: session.externalSessionID,
            cwd: cwd,
            fromProfile: session.claudeProfileName,
            toProfile: target
        )
    }

    func testMoveStampsSessionAndMovesTranscript() throws {
        let session = try makeSession(externalID: "svc-1", profile: nil)
        try writeTranscript("svc-1", in: "main")

        let outcome = service.perform([move(session, to: "ai3")])

        XCTAssertEqual(outcome.moved.count, 1)
        XCTAssertTrue(outcome.failed.isEmpty)
        XCTAssertEqual(
            store.loadWorkspace().sessions.first { $0.id == session.id }?.claudeProfileName,
            "ai3"
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: projectsDir("ai3").appendingPathComponent("svc-1.jsonl").path
        ))
    }

    func testSessionWithoutTranscriptIsStampedOnly() throws {
        let session = try makeSession(externalID: "svc-2", profile: nil)
        // Kein Transcript geschrieben — die Session wurde nie gestartet.

        let outcome = service.perform([move(session, to: "ai3")])

        XCTAssertEqual(outcome.moved.first?.movedTranscript, false)
        XCTAssertEqual(
            store.loadWorkspace().sessions.first { $0.id == session.id }?.claudeProfileName,
            "ai3"
        )
    }

    func testFailureLeavesOtherMovesIntact() throws {
        let ok = try makeSession(externalID: "svc-3", profile: nil)
        try writeTranscript("svc-3", in: "main")
        let clashing = try makeSession(externalID: "svc-4", profile: nil)
        try writeTranscript("svc-4", in: "main")
        try writeTranscript("svc-4", in: "ai3") // Kollision im Ziel

        let outcome = service.perform([move(ok, to: "ai3"), move(clashing, to: "ai3")])

        // Teilerfolge bleiben stehen — kein Auto-Rollback.
        XCTAssertEqual(outcome.moved.map(\.sessionID), [ok.id])
        XCTAssertEqual(outcome.failed.count, 1)
        let workspace = store.loadWorkspace()
        XCTAssertEqual(workspace.sessions.first { $0.id == ok.id }?.claudeProfileName, "ai3")
        XCTAssertNil(workspace.sessions.first { $0.id == clashing.id }?.claudeProfileName,
                     "gescheiterte Session behaelt ihr Herkunftskonto")
    }

    func testCancelStopsAfterCurrentSession() throws {
        let first = try makeSession(externalID: "svc-5", profile: nil)
        let second = try makeSession(externalID: "svc-6", profile: nil)
        try writeTranscript("svc-5", in: "main")
        try writeTranscript("svc-6", in: "main")

        var seen = 0
        let outcome = service.perform(
            [move(first, to: "ai3"), move(second, to: "ai3")],
            shouldCancel: {
                defer { seen += 1 }
                return seen >= 1 // vor der zweiten Session abbrechen
            }
        )

        XCTAssertTrue(outcome.wasCancelled)
        XCTAssertEqual(outcome.moved.map(\.sessionID), [first.id])
        // Die abgebrochene Session ist unberuehrt — nichts halb bewegt.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: projectsDir("main").appendingPathComponent("svc-6.jsonl").path
        ))
    }

    func testUndoRestoresProfileAndTranscript() throws {
        let session = try makeSession(externalID: "svc-7", profile: nil)
        try writeTranscript("svc-7", in: "main")
        _ = service.perform([move(session, to: "ai3")])

        let undo = service.undoLastBatch(
            cwdResolver: { _ in self.cwd },
            externalIDResolver: { _ in "svc-7" }
        )

        XCTAssertEqual(undo.moved.count, 1)
        XCTAssertNil(
            store.loadWorkspace().sessions.first { $0.id == session.id }?.claudeProfileName,
            "Rueckgaengig stellt den Haupt-Account wieder her"
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: projectsDir("main").appendingPathComponent("svc-7.jsonl").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: projectsDir("ai3").appendingPathComponent("svc-7.jsonl").path
        ))
    }

    func testUndoIsNotItselfUndoable() throws {
        let session = try makeSession(externalID: "svc-8", profile: nil)
        try writeTranscript("svc-8", in: "main")
        _ = service.perform([move(session, to: "ai3")])
        _ = service.undoLastBatch(cwdResolver: { _ in self.cwd }, externalIDResolver: { _ in "svc-8" })

        // Der Rueckweg darf nicht selbst der neueste Batch werden — sonst
        // pendelte ein zweites „Rueckgaengig" die Session wieder ins Ziel.
        XCTAssertTrue(AccountMoveJournal(fileURL: journalURL).lastBatch().isEmpty)
        let second = service.undoLastBatch(cwdResolver: { _ in self.cwd }, externalIDResolver: { _ in "svc-8" })
        XCTAssertTrue(second.moved.isEmpty)
        XCTAssertNil(store.loadWorkspace().sessions.first { $0.id == session.id }?.claudeProfileName)
    }

    func testScanStaysSuspendedForTheWholeBatch() throws {
        let session = try makeSession(externalID: "svc-9", profile: nil)
        try writeTranscript("svc-9", in: "main")

        var suspendedDuringMove = false
        _ = service.perform(
            [move(session, to: "ai3")],
            progress: { _, _ in suspendedDuringMove = self.scanDepth > 0 }
        )

        XCTAssertTrue(suspendedDuringMove, "waehrend der Bewegung darf kein Scan starten")
        XCTAssertEqual(scanDepth, 0, "die Pause muss danach wieder aufgehoben sein")
        XCTAssertEqual(maxScanDepth, 1, "genau eine Pause pro Batch, nicht eine pro Session")
    }

    func testEmptyMoveListIsNoOp() {
        let outcome = service.perform([])
        XCTAssertTrue(outcome.moved.isEmpty)
        XCTAssertEqual(maxScanDepth, 0, "ohne Bewegung wird der Scan gar nicht erst angehalten")
    }
}
