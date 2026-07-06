import XCTest
@testable import WhisperM8

final class AgentCLIArgumentsPreviewTests: XCTestCase {
    func testPreviewWithEmptyArgumentsReturnsOnlyBinary() {
        XCTAssertEqual(
            AgentCLIArgumentsPreview.preview(binary: "claude", extraArguments: ""),
            "claude"
        )
        XCTAssertEqual(
            AgentCLIArgumentsPreview.preview(binary: "codex", extraArguments: "   "),
            "codex"
        )
    }

    func testPreviewWithMultipleArguments() {
        XCTAssertEqual(
            AgentCLIArgumentsPreview.preview(binary: "codex", extraArguments: "--ask-for-approval untrusted"),
            "codex --ask-for-approval untrusted"
        )
    }

    func testPreviewWithQuotedArgumentContainingSpaces() {
        XCTAssertEqual(
            AgentCLIArgumentsPreview.preview(binary: "claude", extraArguments: "--mcp-config \"~/Library/Application Support/mcp.json\""),
            "claude --mcp-config \"~/Library/Application Support/mcp.json\""
        )
    }

    func testPreviewIgnoresLeadingAndRepeatedSpaces() {
        XCTAssertEqual(
            AgentCLIArgumentsPreview.preview(binary: "claude", extraArguments: "   --verbose    --model   sonnet   "),
            "claude --verbose --model sonnet"
        )
    }
}
