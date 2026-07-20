import XCTest
@testable import WhisperM8

final class AgentCLIArgumentsTests: XCTestCase {
    // MARK: - parseRun

    func testDefaults() throws {
        let options = try AgentCLIParser.parseRun(["fix the bug"])
        XCTAssertEqual(options.prompt, "fix the bug")
        XCTAssertEqual(options.sandbox, .workspaceWrite)
        XCTAssertNil(options.cd)
        XCTAssertFalse(options.wait)
        XCTAssertFalse(options.json)
        XCTAssertFalse(options.worktree)
        XCTAssertFalse(options.allowNetwork)
        XCTAssertNil(options.playwrightStorageStatePath)
        XCTAssertNil(options.parentSessionID)
        XCTAssertTrue(options.configOverrides.isEmpty)
    }

    func testConfigOverridesAreRepeatableAndOrdered() throws {
        let options = try AgentCLIParser.parseRun([
            "--config", "tools.web_search=true",
            "--config", #"mcp_servers.foo.command="bar""#,
            "prompt",
        ])
        XCTAssertEqual(options.configOverrides, [
            "tools.web_search=true",
            #"mcp_servers.foo.command="bar""#,
        ])
    }

    func testConfigOverrideWithoutKeyValueThrows() {
        XCTAssertThrowsError(try AgentCLIParser.parseRun(["--config", "kaputt", "p"])) { error in
            guard case .invalidValue(let flag, let value, _)? = error as? AgentCLIParser.ParseError else {
                return XCTFail("Erwartet invalidValue, war \(error)")
            }
            XCTAssertEqual(flag, "--config")
            XCTAssertEqual(value, "kaputt")
        }
        // "=wert" ohne Key ist ebenso ungültig.
        XCTAssertThrowsError(try AgentCLIParser.parseRun(["--config", "=wert", "p"]))
    }

    /// Ein Override mit führendem "-" landet als eigenes argv-Element hinter
    /// `-c`; codex liest ihn dann als Flag ("unexpected argument '-f'").
    /// Deshalb muss der Parser ihn ablehnen, nicht die CLI später crashen.
    func testConfigOverrideWithLeadingDashThrows() {
        XCTAssertThrowsError(try AgentCLIParser.parseRun(["--config", "-foo=bar", "p"])) { error in
            guard case .invalidValue(let flag, let value, _)? = error as? AgentCLIParser.ParseError else {
                return XCTFail("Erwartet invalidValue, war \(error)")
            }
            XCTAssertEqual(flag, "--config")
            XCTAssertEqual(value, "-foo=bar")
        }
        XCTAssertThrowsError(try AgentCLIParser.parseRun(["--config", "--sandbox=x", "p"]))
    }

    func testConfigOverrideMissingValueThrows() {
        XCTAssertThrowsError(try AgentCLIParser.parseRun(["prompt", "--config"])) { error in
            XCTAssertEqual(error as? AgentCLIParser.ParseError, .missingValue("--config"))
        }
    }

    func testAllFlags() throws {
        let options = try AgentCLIParser.parseRun([
            "--wait", "--json", "--worktree", "--allow-network",
            "--cd", "/tmp/repo",
            "--sandbox", "read-only",
            "--model", "gpt-5.2-codex",
            "--effort", "high",
            "--playwright-storage-state", ".qa/auth/admin.json",
            "--parent", "c71d-abc",
            "do the thing",
        ])
        XCTAssertTrue(options.wait)
        XCTAssertTrue(options.json)
        XCTAssertTrue(options.worktree)
        XCTAssertTrue(options.allowNetwork)
        XCTAssertEqual(options.cd, "/tmp/repo")
        XCTAssertEqual(options.sandbox, .readOnly)
        XCTAssertEqual(options.model, "gpt-5.2-codex")
        XCTAssertEqual(options.effort, "high")
        XCTAssertEqual(options.playwrightStorageStatePath, ".qa/auth/admin.json")
        XCTAssertEqual(options.parentSessionID, "c71d-abc")
        XCTAssertEqual(options.prompt, "do the thing")
    }

    func testPromptPositionIsFlexible() throws {
        let options = try AgentCLIParser.parseRun(["do it", "--wait"])
        XCTAssertEqual(options.prompt, "do it")
        XCTAssertTrue(options.wait)
    }

    func testUnknownFlagThrows() {
        XCTAssertThrowsError(try AgentCLIParser.parseRun(["--bogus", "p"])) { error in
            XCTAssertEqual(error as? AgentCLIParser.ParseError, .unknownFlag("--bogus"))
        }
    }

    func testInvalidSandboxThrows() {
        XCTAssertThrowsError(try AgentCLIParser.parseRun(["--sandbox", "yolo", "p"])) { error in
            guard case .invalidValue(let flag, let value, _)? = error as? AgentCLIParser.ParseError else {
                return XCTFail("Erwartet invalidValue")
            }
            XCTAssertEqual(flag, "--sandbox")
            XCTAssertEqual(value, "yolo")
        }
    }

    func testMissingValueThrows() {
        XCTAssertThrowsError(try AgentCLIParser.parseRun(["--cd"])) { error in
            XCTAssertEqual(error as? AgentCLIParser.ParseError, .missingValue("--cd"))
        }
    }

    func testMissingPromptThrows() {
        XCTAssertThrowsError(try AgentCLIParser.parseRun(["--wait"])) { error in
            XCTAssertEqual(error as? AgentCLIParser.ParseError, .missingPrompt)
        }
    }

    func testMultiplePromptsThrow() {
        XCTAssertThrowsError(try AgentCLIParser.parseRun(["fix", "the", "bug"])) { error in
            XCTAssertEqual(error as? AgentCLIParser.ParseError, .multiplePrompts)
        }
    }

    /// Defekt 1: Ein wertnehmendes Flag darf das folgende Flag nicht als Wert
    /// schlucken. Früher wurde `--model` still auf "--json" gesetzt und --json
    /// blieb aus — jetzt ein klares missingValue.
    func testFlagValueDoesNotConsumeFollowingFlag() {
        XCTAssertThrowsError(try AgentCLIParser.parseRun(["--model", "--json", "p"])) { error in
            XCTAssertEqual(error as? AgentCLIParser.ParseError, .missingValue("--model"))
        }
        XCTAssertThrowsError(try AgentCLIParser.parseRun(["--cd", "--wait", "p"])) { error in
            XCTAssertEqual(error as? AgentCLIParser.ParseError, .missingValue("--cd"))
        }
    }

    /// Defekt 2: Nach `--` ist der Prompt frei — auch mit führendem "-".
    func testDashDashTerminatorAllowsDashPrompt() throws {
        let options = try AgentCLIParser.parseRun(["--wait", "--", "- fix the bug"])
        XCTAssertTrue(options.wait)
        XCTAssertEqual(options.prompt, "- fix the bug")
    }

    /// `--` beendet die Flag-Erkennung: ein danach stehendes "--json" ist Text,
    /// kein Flag mehr.
    func testDashDashTerminatorStopsFlagParsing() throws {
        let options = try AgentCLIParser.parseRun(["--", "--json ist hier nur Text"])
        XCTAssertFalse(options.json)
        XCTAssertEqual(options.prompt, "--json ist hier nur Text")
    }

    // MARK: - parseSend

    func testSendBasic() throws {
        let options = try AgentCLIParser.parseSend(["a3f81c2e", "--wait", "mach weiter"])
        XCTAssertEqual(options.shortId, "a3f81c2e")
        XCTAssertEqual(options.prompt, "mach weiter")
        XCTAssertTrue(options.wait)
    }

    /// Defekt 2 (Live-Beweis): `send <id> "- prompt"` schlug fehl. Mit `--`
    /// davor geht es.
    func testSendDashDashTerminatorAllowsDashPrompt() throws {
        let options = try AgentCLIParser.parseSend(["a3f81c2e", "--wait", "--", "- bitte zusammenfassen"])
        XCTAssertEqual(options.shortId, "a3f81c2e")
        XCTAssertTrue(options.wait)
        XCTAssertEqual(options.prompt, "- bitte zusammenfassen")
    }

    func testSendUnknownFlagBeforeTerminatorThrows() {
        XCTAssertThrowsError(try AgentCLIParser.parseSend(["a3f81c2e", "--bogus", "p"])) { error in
            XCTAssertEqual(error as? AgentCLIParser.ParseError, .unknownFlag("--bogus"))
        }
    }

    func testIDCommandRejectsPathTraversal() {
        XCTAssertThrowsError(try AgentCLIParser.parseIDCommand(["../evil"]))
    }

    func testIDCommandAcceptsGeneratedShortIDFormat() throws {
        let result = try AgentCLIParser.parseIDCommand(["a3f81c2e", "--json"])
        XCTAssertEqual(result.shortId, "a3f81c2e")
        XCTAssertTrue(result.json)
    }

    // MARK: - parseLogs

    func testLogsTail() throws {
        let result = try AgentCLIParser.parseLogs(["a3f81c2e", "--tail", "10"])
        XCTAssertEqual(result.shortId, "a3f81c2e")
        XCTAssertEqual(result.tail, 10)
    }

    /// Defekt 1 (Live-Beweis): `logs <id> --tail --json` meldete "Ungültiger
    /// Wert '--json'". Jetzt: --tail hat keinen Wert bekommen.
    func testLogsTailDoesNotConsumeFollowingFlag() {
        XCTAssertThrowsError(try AgentCLIParser.parseLogs(["a3f81c2e", "--tail", "--json"])) { error in
            XCTAssertEqual(error as? AgentCLIParser.ParseError, .missingValue("--tail"))
        }
    }

    // MARK: - CLIModeDetector

    func testAgentSubcommandRunsCLI() {
        let base = "/Applications/WhisperM8.app/Contents/MacOS/WhisperM8"
        XCTAssertTrue(CLIModeDetector.shouldRunCLI([base, "agent", "run", "--wait", "p"]))
        // Detach-Modus: argv0 ist das App-Binary, nicht der Symlink.
        XCTAssertTrue(CLIModeDetector.shouldRunCLI([base, "agent-supervise", "a3f81c2e"]))
    }
}
