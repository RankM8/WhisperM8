import XCTest
@testable import WhisperM8

final class CodexAgentPreflightTests: XCTestCase {
    // MARK: - parseVersion

    func testParsesRealVersionOutput() {
        XCTAssertEqual(
            CodexAgentPreflight.parseVersion(from: "codex-cli 0.142.5"),
            SemanticVersion(major: 0, minor: 142, patch: 5)
        )
    }

    func testParsesBareVersion() {
        XCTAssertEqual(
            CodexAgentPreflight.parseVersion(from: "1.2.3"),
            SemanticVersion(major: 1, minor: 2, patch: 3)
        )
    }

    func testParsesMultilineOutputTakesLastParseableToken() {
        let output = "some banner\ncodex-cli 0.150.0\n"
        XCTAssertEqual(
            CodexAgentPreflight.parseVersion(from: output),
            SemanticVersion(major: 0, minor: 150, patch: 0)
        )
    }

    func testGarbageYieldsNil() {
        XCTAssertNil(CodexAgentPreflight.parseVersion(from: "command not found: codex"))
    }

    // MARK: - check()

    func testMissingBinaryYieldsCodexMissing() async {
        let preflight = CodexAgentPreflight(
            commandResolver: { _ in nil },
            versionRunner: { _ in XCTFail("darf nicht laufen"); return "" }
        )
        let outcome = await preflight.check()
        XCTAssertEqual(outcome, .codexMissing)
    }

    func testTooOldVersionIsRejected() async {
        let preflight = CodexAgentPreflight(
            commandResolver: { _ in "/fake/codex" },
            versionRunner: { _ in "codex-cli 0.46.0" }
        )
        let outcome = await preflight.check()
        XCTAssertEqual(outcome, .versionTooOld(
            found: SemanticVersion(major: 0, minor: 46, patch: 0),
            minimum: CodexAgentPreflight.minimumVersion
        ))
    }

    func testCurrentVersionPassesWithoutWarning() async {
        let preflight = CodexAgentPreflight(
            commandResolver: { _ in "/fake/codex" },
            versionRunner: { _ in "codex-cli 0.142.5" }
        )
        let outcome = await preflight.check()
        XCTAssertEqual(outcome, .ok(
            codexPath: "/fake/codex",
            version: SemanticVersion(major: 0, minor: 142, patch: 5),
            warning: nil
        ))
    }

    func testNewerMajorPassesWithWarning() async {
        let preflight = CodexAgentPreflight(
            commandResolver: { _ in "/fake/codex" },
            versionRunner: { _ in "codex-cli 1.0.0" }
        )
        let outcome = await preflight.check()
        guard case .ok(_, let version, let warning) = outcome else {
            return XCTFail("Erwartet .ok, war \(outcome)")
        }
        XCTAssertEqual(version, SemanticVersion(major: 1, minor: 0, patch: 0))
        XCTAssertNotNil(warning)
    }

    func testUnparseableVersionContinuesWithWarningOutcome() async {
        let preflight = CodexAgentPreflight(
            commandResolver: { _ in "/fake/codex" },
            versionRunner: { _ in "weird output" }
        )
        let outcome = await preflight.check()
        XCTAssertEqual(outcome, .versionUnparseable(codexPath: "/fake/codex", raw: "weird output"))
    }
}
