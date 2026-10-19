import XCTest
@testable import WhisperM8

/// LR-CLI-002: Kein Anhängen an einen getippten Entwurf.
/// LR-CLI-003: Keine Zustellung in einen noch startenden Chat.
final class PromptDeliveryGateTests: XCTestCase {
    func testQueueWaitsWhileLaunchingOrWithDraft() {
        XCTAssertEqual(PromptDeliveryGate.forQueue(runtime: .idle, lifecycle: .launching, mayHaveUnsentInput: false), .notReady)
        XCTAssertEqual(PromptDeliveryGate.forQueue(runtime: .idle, lifecycle: .ready, mayHaveUnsentInput: true), .draftPending)
        XCTAssertEqual(PromptDeliveryGate.forQueue(runtime: .working, lifecycle: .working, mayHaveUnsentInput: false), .busy("working"))
        XCTAssertEqual(PromptDeliveryGate.forQueue(runtime: .idle, lifecycle: .ready, mayHaveUnsentInput: false), .deliver)
        XCTAssertEqual(PromptDeliveryGate.forQueue(runtime: nil, lifecycle: nil, mayHaveUnsentInput: false), .deliver)
    }

    func testSendRefusesDraftUnlessForced() {
        XCTAssertTrue(PromptDeliveryGate.sendBlockedByDraft(mayHaveUnsentInput: true, force: false))
        XCTAssertFalse(PromptDeliveryGate.sendBlockedByDraft(mayHaveUnsentInput: true, force: true))
        XCTAssertFalse(PromptDeliveryGate.sendBlockedByDraft(mayHaveUnsentInput: false, force: false))
        XCTAssertTrue(PromptDeliveryGate.draftMessage.contains("enqueue"))
    }
}
