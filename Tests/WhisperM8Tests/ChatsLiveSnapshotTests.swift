import XCTest
@testable import WhisperM8

/// Knappe `sessions.live`-Antwort: fehlende Sessions müssen genauso gelesen
/// werden wie ihr früherer Eintrag in der vollen Liste.
final class ChatsLiveSnapshotTests: XCTestCase {
    private let running = UUID()
    private let resting = UUID()

    private func snapshot(omittedAreDetached: Bool) -> ChatsLiveSnapshot {
        ChatsLiveSnapshot(
            entries: [running: ChatsLiveStatus(runtimeStatus: .working, isAttachedPTY: true,
                                               canSend: true, canInterrupt: true)],
            omittedAreDetached: omittedAreDetached)
    }

    func testSparseAnswerTreatsMissingSessionsAsDetached() {
        let live = snapshot(omittedAreDetached: true)
        let missing = live[resting]
        XCTAssertEqual(missing?.isAttachedPTY, false)
        XCTAssertNil(missing?.runtimeStatus)
        XCTAssertEqual(live[running]?.runtimeStatus, .working)
        XCTAssertEqual(live.attachedIDs, [running])
    }

    func testFullAnswerFromOlderAppKeepsMissingUnknown() {
        XCTAssertNil(snapshot(omittedAreDetached: false)[resting])
    }

    func testMergeKeepsEstimateForDetachedSession() {
        let estimate = ChatsRuntimeInfo(status: .idle, source: "transcriptEstimate", since: nil, revision: 7,
                                        transcriptPath: nil, transcriptSizeBytes: nil, availability: .available)
        let merged = ChatsLiveMerge.merge(estimate: estimate, live: snapshot(omittedAreDetached: true)[resting])
        XCTAssertEqual(merged, estimate)
    }
}
