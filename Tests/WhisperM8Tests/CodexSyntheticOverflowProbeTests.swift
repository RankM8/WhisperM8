import Foundation
import XCTest
@testable import WhisperM8

final class CodexSyntheticOverflowProbeTests: XCTestCase {
    private let exactErrorJSON = #"{"type":"error","error":{"type":"api_error","message":"Prompt is too long"}}"#

    override func setUp() {
        super.setUp()
        SyntheticOverflowProbeBudget.resetForTesting()
    }

    override func tearDown() {
        SyntheticOverflowProbeBudget.resetForTesting()
        super.tearDown()
    }

    func testExactOverflowSurvivesArbitraryByteSplitsLFAndCRLF() {
        for newline in ["\n", "\r\n"] {
            let stream = Data(([
                ": keepalive",
                "",
                "event: message_start",
                #"data: {"type":"message_start","message":{"role":"assistant","content":[],"stop_reason":null,"stop_sequence":null}}"#,
                "",
                "event: content_block_start",
                #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
                "",
                "event: error",
                "data: \(exactErrorJSON)",
                "",
                "",
            ].joined(separator: newline)).utf8)

            for split in 0...stream.count {
                var probe = CodexSyntheticOverflowProbe(startedAt: 10)
                let first = Data(stream.prefix(split))
                let second = Data(stream.dropFirst(split))
                if !first.isEmpty {
                    _ = probe.ingest(first, at: 10.1)
                }
                let decision = second.isEmpty
                    ? probe.finish()
                    : probe.ingest(second, at: 10.2)
                XCTAssertEqual(decision, .overflow, "newline=\(newline.debugDescription) split=\(split)")
            }

            var bytewise = CodexSyntheticOverflowProbe(startedAt: 20)
            var decision: CodexSyntheticOverflowProbe.Decision = .pending
            for byte in stream {
                decision = bytewise.ingest(Data([byte]), at: 20.1)
            }
            XCTAssertEqual(decision, .overflow)
        }
    }

    func testExactOverflowSupportsMultipleDataLines() {
        let stream = "event: error\n"
            + "data: {\"type\":\"error\",\n"
            + "data: \"error\":{\"type\":\"api_error\",\"message\":\"Prompt is too long\"}}\n\n"
        var probe = CodexSyntheticOverflowProbe(startedAt: 1)

        XCTAssertEqual(probe.ingest(Data(stream.utf8), at: 1.1), .overflow)
    }

    func testSemanticOrMalformedEventsPermanentlyFailOpen() {
        let exactError = sse(event: "error", data: exactErrorJSON)
        let candidates = [
            sse(
                event: "content_block_delta",
                data: #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hello"}}"#
            ),
            sse(
                event: "content_block_delta",
                data: #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Prompt is too long"}}"#
            ),
            sse(
                event: "error",
                data: #"{"type":"message_delta","error":{"type":"api_error","message":"Prompt is too long"}}"#
            ),
            sse(
                event: "error",
                data: #"{"type":"error","error":{"type":"invalid_request_error","message":"Prompt is too long"}}"#
            ),
            sse(
                event: "error",
                data: #"{"type":"error","error":{"type":"api_error","message":"prompt is too long"}}"#
            ),
            sse(
                event: "content_block_start",
                data: #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#
            ),
            sse(
                event: "content_block_delta",
                data: #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"abc"}}"#
            ),
            sse(
                event: "content_block_start",
                data: #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tool_1","name":"Bash","input":{}}}"#
            ),
            "event: error\ndata: {kaputt}\n\n",
            sse(
                event: "error",
                data: #"{"type":"error","error":{"type":"api_error","message":"Prompt is too long","code":"extra"}}"#
            ),
        ]

        for (index, candidate) in candidates.enumerated() {
            var probe = CodexSyntheticOverflowProbe(startedAt: 1)
            let decision = probe.ingest(Data((candidate + exactError).utf8), at: 1.1)
            XCTAssertEqual(decision, .passThrough, "candidate \(index)")
            XCTAssertEqual(probe.finish(), .passThrough, "candidate \(index) must stay fail-open")
        }
    }

    func testIncompleteExactErrorAtEOFDoesNotMatch() {
        var probe = CodexSyntheticOverflowProbe(startedAt: 1)
        let incomplete = "event: error\ndata: \(exactErrorJSON)"

        XCTAssertEqual(probe.ingest(Data(incomplete.utf8), at: 1.1), .pending)
        XCTAssertEqual(probe.finish(), .passThrough)
    }

    func testPrefixLimitFailsOpenAndReportsExactAcceptedBytes() {
        let bytes = Data(repeating: 0x78, count: CodexSyntheticOverflowProbe.maximumPrefixBytes + 17)
        var probe = CodexSyntheticOverflowProbe(startedAt: 1)

        XCTAssertEqual(probe.ingest(bytes, at: 1.1), .passThrough)
        XCTAssertEqual(probe.lastAcceptedByteCount, CodexSyntheticOverflowProbe.maximumPrefixBytes)
        XCTAssertEqual(
            probe.bufferedData,
            Data(repeating: 0x78, count: CodexSyntheticOverflowProbe.maximumPrefixBytes)
        )
    }

    func testDeadlineFailsOpenWithoutConsumingNewBytes() {
        var probe = CodexSyntheticOverflowProbe(startedAt: 100)
        XCTAssertFalse(probe.hasExpired(at: 100.999))
        XCTAssertTrue(probe.hasExpired(at: 101))

        let bytes = Data("event: error\n".utf8)
        XCTAssertEqual(probe.ingest(bytes, at: 101), .passThrough)
        XCTAssertEqual(probe.lastAcceptedByteCount, 0)
        XCTAssertTrue(probe.bufferedData.isEmpty)
    }

    func testProbeBudgetCapsAt64AndRecoversAfterRelease() {
        for index in 0..<SyntheticOverflowProbeBudget.maximumActive {
            XCTAssertTrue(SyntheticOverflowProbeBudget.acquire(), "slot \(index)")
        }
        XCTAssertFalse(SyntheticOverflowProbeBudget.acquire())

        SyntheticOverflowProbeBudget.release()
        XCTAssertTrue(SyntheticOverflowProbeBudget.acquire())
    }

    private func sse(event: String, data: String) -> String {
        "event: \(event)\ndata: \(data)\n\n"
    }
}
