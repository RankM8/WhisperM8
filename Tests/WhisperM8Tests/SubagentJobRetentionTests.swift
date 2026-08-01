import XCTest
@testable import WhisperM8

/// Tests für die Aufräumregel der CLI-Subagent-Spiegel
/// (`SubagentJobRetentionPolicy` + `SubagentJobTranscriptArchiver`).
/// Beides ist pur bzw. mit injizierten Pfaden testbar; die Drosselung im
/// `AgentJobWorkspaceSync` (6-h-Fenster, FSEvent-Timing) bleibt manuelle QA.
final class SubagentJobRetentionTests: XCTestCase {
    private let projectID = UUID()
    private let now = Date(timeIntervalSince1970: 10_000_000)
    private let policy = SubagentJobRetentionPolicy()

    private func makeSession(
        id: UUID = UUID(),
        kind: AgentSessionKind? = .subagentJob,
        status: AgentChatStatus = .closed,
        shortID: String? = nil,
        externalSessionID: String? = "thread-abc",
        ageDays: Double = 30
    ) -> AgentChatSession {
        AgentChatSession(
            id: id,
            provider: .codex,
            projectID: projectID,
            externalSessionID: externalSessionID,
            title: "Subagent-Job",
            status: status,
            lastActivityAt: now.addingTimeInterval(-ageDays * 24 * 60 * 60),
            kind: kind,
            subagentJobShortID: shortID
        )
    }

    // MARK: - Policy

    /// Der Regelfall: verwaister Spiegel, älter als die Aufbewahrungsfrist.
    func testExpiresOrphanedSubagentSessionBeyondMaxAge() {
        let session = makeSession(ageDays: 30)
        let expired = policy.expiredSessions(
            in: [session],
            liveJobShortIDs: [],
            now: now
        )
        XCTAssertEqual(expired.map(\.sessionID), [session.id])
        XCTAssertEqual(expired.first?.externalSessionID, "thread-abc")
    }

    /// Innerhalb der Frist bleibt alles stehen — auch ohne Job-Verzeichnis.
    func testKeepsSubagentSessionWithinMaxAge() {
        let session = makeSession(ageDays: 3)
        XCTAssertTrue(
            policy.expiredSessions(in: [session], liveJobShortIDs: [], now: now).isEmpty
        )
    }

    /// Grenzwert: exakt auf der Frist ist noch NICHT fällig.
    func testKeepsSessionExactlyAtMaxAge() {
        let session = makeSession(ageDays: 7)
        XCTAssertTrue(
            policy.expiredSessions(in: [session], liveJobShortIDs: [], now: now).isEmpty
        )
    }

    /// Lebt das Job-Verzeichnis noch, bleibt der Spiegel — sonst würde ihn der
    /// nächste Merge sofort neu anlegen (Lösch-/Anlege-Flip-Flop).
    func testKeepsSessionWhoseJobDirectoryStillExists() {
        let session = makeSession(shortID: "a1b2c3d4", ageDays: 30)
        XCTAssertTrue(
            policy.expiredSessions(
                in: [session],
                liveJobShortIDs: ["a1b2c3d4"],
                now: now
            ).isEmpty
        )
    }

    /// Short-ID vorhanden, Verzeichnis aber verschwunden (`agent rm` ohne
    /// anschließenden Merge): fällig.
    func testExpiresSessionWhoseJobDirectoryVanished() {
        let session = makeSession(shortID: "deadbeef", ageDays: 30)
        XCTAssertEqual(
            policy.expiredSessions(in: [session], liveJobShortIDs: ["other123"], now: now)
                .map(\.sessionID),
            [session.id]
        )
    }

    /// Laufende Jobs sind unantastbar, egal wie alt der Zeitstempel ist
    /// (stale `lastActivityAt` bei langlaufenden Jobs ist real).
    func testNeverExpiresRunningOrPendingSessions() {
        let running = makeSession(status: .running, ageDays: 90)
        let pending = makeSession(status: .pending, ageDays: 90)
        XCTAssertTrue(
            policy.expiredSessions(in: [running, pending], liveJobShortIDs: [], now: now).isEmpty
        )
    }

    /// Normale Chats, Agent Views und Terminals gehen die Regel nichts an —
    /// auch nicht die Legacy-Sessions ohne `kind`-Feld.
    func testIgnoresNonSubagentSessions() {
        let sessions = [
            makeSession(kind: .chat, ageDays: 90),
            makeSession(kind: nil, ageDays: 90),
            makeSession(kind: .agentView, ageDays: 90),
            makeSession(kind: .terminal, ageDays: 90)
        ]
        XCTAssertTrue(
            policy.expiredSessions(in: sessions, liveJobShortIDs: [], now: now).isEmpty
        )
    }

    /// Was der Nutzer gerade sieht, wird nicht unter seinen Händen weggeräumt.
    func testKeepsProtectedSessions() {
        let session = makeSession(ageDays: 30)
        XCTAssertTrue(
            policy.expiredSessions(
                in: [session],
                liveJobShortIDs: [],
                protectedSessionIDs: [session.id],
                now: now
            ).isEmpty
        )
    }

    /// Archivierte Spiegel sind ebenso Karteileichen wie geschlossene.
    func testExpiresArchivedSubagentSessions() {
        let session = makeSession(status: .archived, ageDays: 30)
        XCTAssertEqual(
            policy.expiredSessions(in: [session], liveJobShortIDs: [], now: now).count,
            1
        )
    }

    /// Eine abweichende Frist (Defaults-Override) wird respektiert.
    func testHonorsCustomMaxAge() {
        let thirtyDays = SubagentJobRetentionPolicy(maxAge: 30 * 24 * 60 * 60)
        let session = makeSession(ageDays: 20)
        XCTAssertTrue(
            thirtyDays.expiredSessions(in: [session], liveJobShortIDs: [], now: now).isEmpty
        )
        XCTAssertEqual(
            thirtyDays.expiredSessions(
                in: [makeSession(ageDays: 40)],
                liveJobShortIDs: [],
                now: now
            ).count,
            1
        )
    }

    // MARK: - Altlasten-Lauf (Frist ausgesetzt)

    /// Der einmalige Purge-Lauf räumt auch taufrische verwaiste Spiegel ab.
    func testZeroMaxAgeExpiresRecentOrphans() {
        let purge = SubagentJobRetentionPolicy(maxAge: 0)
        let session = makeSession(ageDays: 0.01)
        XCTAssertEqual(
            purge.expiredSessions(in: [session], liveJobShortIDs: [], now: now).count,
            1
        )
    }

    /// Sicherheitsnetz des Purge-Laufs: wäre `agent-jobs/` in dem Moment
    /// nicht lesbar, käme eine leere Live-Menge herein — Sessions mit noch
    /// gesetzter Short-ID dürfen dann trotzdem nicht sterben.
    func testInitialPurgeSpareSessionsWithShortIDEvenIfJobListLooksEmpty() {
        let purge = SubagentJobRetentionPolicy(maxAge: 0)
        let stillLinked = makeSession(shortID: "a1b2c3d4", ageDays: 30)
        let orphaned = makeSession(shortID: nil, ageDays: 30)

        let expired = purge.expiredSessions(
            in: [stillLinked, orphaned],
            liveJobShortIDs: [],
            requiresClearedShortID: true,
            now: now
        )
        XCTAssertEqual(expired.map(\.sessionID), [orphaned.id])
    }

    /// Im Normalbetrieb ist die Frist der Schutz — dort greift die
    /// Short-ID-Bedingung bewusst nicht.
    func testRegularRunStillExpiresSessionsWithStaleShortID() {
        let session = makeSession(shortID: "deadbeef", ageDays: 30)
        XCTAssertEqual(
            policy.expiredSessions(
                in: [session],
                liveJobShortIDs: [],
                requiresClearedShortID: false,
                now: now
            ).count,
            1
        )
    }

    // MARK: - Archiver

    /// Das Transcript verlässt den Scan-Root und liegt vollständig im Archiv —
    /// nur so kann der Indexer es nicht als neuen Chat wieder aufsammeln.
    func testArchiverMovesTranscriptOutOfScanRoot() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("retention-\(UUID().uuidString)", isDirectory: true)
        let sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
        let archiveDir = root.appendingPathComponent("archive", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let transcript = sessionsDir.appendingPathComponent("rollout-2026-07-01-thread-abc.jsonl")
        try "{\"line\":1}\n".write(to: transcript, atomically: true, encoding: .utf8)

        let archiver = SubagentJobTranscriptArchiver(
            archiveRoot: archiveDir,
            locate: { $0 == "thread-abc" ? transcript : nil }
        )
        let result = archiver.archive([
            .init(sessionID: UUID(), externalSessionID: "thread-abc")
        ])

        XCTAssertEqual(result.movedCount, 1)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertGreaterThan(result.movedBytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: transcript.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: archiveDir.appendingPathComponent(transcript.lastPathComponent).path
        ))
    }

    /// Fehlendes Transcript (extern gelöscht) ist kein Fehler — die Session
    /// wird trotzdem abgeräumt.
    func testArchiverCountsMissingTranscriptsSeparately() throws {
        let archiveDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("retention-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: archiveDir) }

        let archiver = SubagentJobTranscriptArchiver(archiveRoot: archiveDir, locate: { _ in nil })
        let result = archiver.archive([
            .init(sessionID: UUID(), externalSessionID: "thread-gone")
        ])

        XCTAssertEqual(result.movedCount, 0)
        XCTAssertEqual(result.missingCount, 1)
        XCTAssertEqual(result.failedCount, 0)
    }

    /// Ein zweiter Lauf mit gleichnamiger Datei darf das Archiv nicht
    /// überschreiben.
    func testArchiverDoesNotOverwriteExistingArchiveEntry() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("retention-\(UUID().uuidString)", isDirectory: true)
        let sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
        let archiveDir = root.appendingPathComponent("archive", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let name = "rollout-2026-07-01-thread-abc.jsonl"
        let existing = archiveDir.appendingPathComponent(name)
        try "alt".write(to: existing, atomically: true, encoding: .utf8)
        let transcript = sessionsDir.appendingPathComponent(name)
        try "neu".write(to: transcript, atomically: true, encoding: .utf8)

        let archiver = SubagentJobTranscriptArchiver(
            archiveRoot: archiveDir,
            locate: { _ in transcript }
        )
        XCTAssertEqual(archiver.archive([
            .init(sessionID: UUID(), externalSessionID: "thread-abc")
        ]).movedCount, 1)

        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "alt")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: archiveDir.appendingPathComponent("rollout-2026-07-01-thread-abc-2.jsonl").path
        ))
    }

    /// Ohne Thread-ID gibt es nichts zu verschieben — und keinen leeren
    /// Archiv-Ordner als Nebenwirkung.
    func testArchiverIgnoresCandidatesWithoutThreadID() {
        let archiveDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("retention-\(UUID().uuidString)", isDirectory: true)
        let archiver = SubagentJobTranscriptArchiver(archiveRoot: archiveDir, locate: { _ in nil })
        let result = archiver.archive([
            .init(sessionID: UUID(), externalSessionID: nil),
            .init(sessionID: UUID(), externalSessionID: "")
        ])
        XCTAssertEqual(result, SubagentJobTranscriptArchiver.Result())
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveDir.path))
    }
}
