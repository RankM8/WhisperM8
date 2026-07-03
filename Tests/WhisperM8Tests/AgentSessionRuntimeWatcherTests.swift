import Foundation
import XCTest
@testable import WhisperM8

/// Phase-3 Test-Seam (S4): deckt die Glue-Logik von
/// AgentSessionRuntimeWatcher.pollSnapshot ab — Datei-IO per @Sendable-Closures
/// gefaket (kein echtes JSONL nötig). Die reine Decider/Parser-Logik ist
/// separat getestet; hier geht es um Stat-first-Skip und URL-Resolution.
final class AgentSessionRuntimeWatcherTests: XCTestCase {
    /// Sendable-Box für Spy-Flags in den @Sendable-Closures.
    private final class Flag: @unchecked Sendable { var value = false }

    private let url = URL(fileURLWithPath: "/tmp/whisperm8-test-transcript.jsonl")

    private func entry(
        transcriptURL: URL?,
        lastStat: AgentTranscriptFileStat? = nil,
        externalSessionID: String? = "ext-1",
        cachedLastEvent: AgentTranscriptEvent? = nil
    ) -> WatchedSession {
        WatchedSession(
            id: UUID(),
            provider: .claude,
            cwd: "/tmp",
            externalSessionID: externalSessionID,
            transcriptURL: transcriptURL,
            lastTurnFinishedAt: nil,
            lastStat: lastStat,
            cachedLastEvent: cachedLastEvent
        )
    }

    func testNoURLYieldsNilDecisionAndSkipsStat() {
        let statFlag = Flag()
        let snapshot = AgentSessionRuntimeWatcher.pollSnapshot(
            for: entry(transcriptURL: nil, externalSessionID: nil),
            now: Date(),
            statProvider: { _ in statFlag.value = true; return nil },
            tailProvider: { _, _ in nil },
            urlResolver: { _ in nil }
        )
        XCTAssertNil(snapshot.transcriptURL)
        XCTAssertNil(snapshot.decision)
        XCTAssertFalse(statFlag.value, "Ohne aufgelöste URL darf nicht gestattet werden")
    }

    func testUnchangedStatSkipsTailRead() {
        let stat = AgentTranscriptFileStat(mtime: Date(timeIntervalSince1970: 1000), size: 50)
        let tailFlag = Flag()
        let snapshot = AgentSessionRuntimeWatcher.pollSnapshot(
            for: entry(
                transcriptURL: url,
                lastStat: stat,
                cachedLastEvent: .userMessage(timestamp: Date(timeIntervalSince1970: 999))
            ),
            now: Date(),
            statProvider: { _ in stat },          // identisch zu lastStat
            tailProvider: { _, _ in tailFlag.value = true; return "" },
            urlResolver: { _ in self.url }
        )
        XCTAssertFalse(tailFlag.value, "Stat-first: unveränderter Stat -> kein 64-KB-Tail-Read")
        XCTAssertEqual(snapshot.stat, stat)
        XCTAssertEqual(snapshot.decision?.status, .working, "Decision kommt aus dem gecachten Event, ohne Read")
    }

    func testChangedStatTriggersTailRead() {
        let oldStat = AgentTranscriptFileStat(mtime: Date(timeIntervalSince1970: 1000), size: 50)
        let newStat = AgentTranscriptFileStat(mtime: Date(timeIntervalSince1970: 2000), size: 80)
        let tailFlag = Flag()
        let snapshot = AgentSessionRuntimeWatcher.pollSnapshot(
            for: entry(transcriptURL: url, lastStat: oldStat),
            now: Date(),
            statProvider: { _ in newStat },        // abweichend -> Read nötig
            tailProvider: { _, _ in tailFlag.value = true; return "" },
            urlResolver: { _ in self.url }
        )
        XCTAssertTrue(tailFlag.value, "Geänderter Stat -> Tail-Read")
        XCTAssertEqual(snapshot.stat, newStat)
    }
}
