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
        cachedLastEvent: AgentTranscriptEvent? = nil,
        cachedActivity: AgentSessionActivity? = nil
    ) -> WatchedSession {
        WatchedSession(
            id: UUID(),
            provider: .claude,
            cwd: "/tmp",
            externalSessionID: externalSessionID,
            transcriptURL: transcriptURL,
            lastTurnFinishedAt: nil,
            lastStat: lastStat,
            cachedLastEvent: cachedLastEvent,
            cachedActivity: cachedActivity
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
        // Frische mtime, damit hier wirklich der Stat-Skip getestet wird —
        // eine alte mtime würde (korrekt) im Stall-Sicherheitsnetz des
        // Deciders landen und idle liefern.
        let now = Date()
        let stat = AgentTranscriptFileStat(mtime: now.addingTimeInterval(-1), size: 50)
        let tailFlag = Flag()
        let snapshot = AgentSessionRuntimeWatcher.pollSnapshot(
            for: entry(
                transcriptURL: url,
                lastStat: stat,
                cachedLastEvent: .userMessage(timestamp: now.addingTimeInterval(-2))
            ),
            now: now,
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

    // MARK: - Stand-Zeile (Tab-Switcher)

    func testTailReadLiefertActivityAusDemselbenTail() {
        let stat = AgentTranscriptFileStat(mtime: Date(), size: 120)
        let line = #"{"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"t","name":"Bash","input":{"command":"swift test"}}]}}"#
        let snapshot = AgentSessionRuntimeWatcher.pollSnapshot(
            for: entry(transcriptURL: url),
            now: Date(),
            statProvider: { _ in stat },
            tailProvider: { _, _ in line + "\n" },
            urlResolver: { _ in self.url }
        )
        XCTAssertEqual(snapshot.activity?.detail, .tool(name: "Bash", argument: "swift test"))
    }

    func testStatFirstBehaeltGecachteActivityOhneRead() {
        let now = Date()
        let stat = AgentTranscriptFileStat(mtime: now.addingTimeInterval(-1), size: 50)
        let cached = AgentSessionActivity(detail: .reply("Fertig."))
        let tailFlag = Flag()
        let snapshot = AgentSessionRuntimeWatcher.pollSnapshot(
            for: entry(transcriptURL: url, lastStat: stat,
                       cachedLastEvent: .userMessage(timestamp: now), cachedActivity: cached),
            now: now,
            statProvider: { _ in stat },
            tailProvider: { _, _ in tailFlag.value = true; return "" },
            urlResolver: { _ in self.url }
        )
        XCTAssertFalse(tailFlag.value)
        XCTAssertEqual(snapshot.activity, cached)
    }
}
