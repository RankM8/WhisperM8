import Foundation
import XCTest
@testable import WhisperM8

/// Künstliche Controller-Eingaben des Debug-Kanals: Skript-Sprache und
/// CLI-Argumente.
final class ControllerDebugScriptTests: XCTestCase {
    // MARK: - Skript

    func testParsesEveryStepKind() throws {
        let steps = try ControllerDebugScript.parse(
            "down:cross, wait:120, up:cross,trigger:r2:0.8,stick:left:-1:0.5,trigger:r2:0,stick:left:0:0")
        XCTAssertEqual(steps, [
            .event(.button(.cross, pressed: true)),
            .wait(milliseconds: 120),
            .event(.button(.cross, pressed: false)),
            .event(.trigger(.r2, value: 0.8)),
            .event(.stick(.left, x: -1, y: 0.5)),
            .event(.trigger(.r2, value: 0)),
            .event(.stick(.left, x: 0, y: 0)),
        ])
    }

    /// Ohne Loslassen liefe ein Halten nach dem Trockenlauf weiter.
    func testScriptMustEndNeutral() {
        for script in ["down:circle", "trigger:l2:1", "stick:right:0:-1", "down:cross,up:cross,down:square"] {
            XCTAssertThrowsError(try ControllerDebugScript.parse(script), "„\(script)“ endet nicht neutral")
        }
        XCTAssertNoThrow(try ControllerDebugScript.parse("down:circle,wait:500,up:circle"))
    }

    func testRejectsUnknownAndMalformedSteps() {
        for script in ["", "down:banana", "jump:cross", "wait:abc", "wait:-5", "stick:left:2:0", "trigger:cross:1", "trigger:r2:1.5"] {
            XCTAssertThrowsError(try ControllerDebugScript.parse(script), "„\(script)“ hätte scheitern müssen")
        }
    }

    /// Trigger sind analog — `down:r2` würde die Schwelle des Kerns umgehen.
    func testTriggersMustBeAnalog() {
        XCTAssertThrowsError(try ControllerDebugScript.parse("down:r2"))
        XCTAssertThrowsError(try ControllerDebugScript.parse("up:l2"))
    }

    func testTotalWaitIsLimitedBySocketTimeout() {
        XCTAssertNoThrow(try ControllerDebugScript.parse("wait:4000,wait:4000"))
        XCTAssertThrowsError(try ControllerDebugScript.parse("wait:4000,wait:4001"))
    }

    func testPressScriptForButtonAndTrigger() throws {
        XCTAssertEqual(
            try ControllerDebugScript.parse(ControllerDebugScript.pressScript(button: .triangle, holdMilliseconds: 60)),
            [.event(.button(.triangle, pressed: true)), .wait(milliseconds: 60), .event(.button(.triangle, pressed: false))])
        XCTAssertEqual(
            try ControllerDebugScript.parse(ControllerDebugScript.pressScript(button: .l2, holdMilliseconds: 500)),
            [.event(.trigger(.l2, value: 1)), .wait(milliseconds: 500), .event(.trigger(.l2, value: 0))])
    }

    // MARK: - CLI

    private let cwd = "/Users/x/proj"

    func testCLIState() throws {
        XCTAssertEqual(try DebugCLIArguments.parse(["controller", "state"], cwd: cwd), .controllerState)
        XCTAssertThrowsError(try DebugCLIArguments.parse(["controller"], cwd: cwd))
        XCTAssertThrowsError(try DebugCLIArguments.parse(["controller", "state", "x"], cwd: cwd))
        XCTAssertThrowsError(try DebugCLIArguments.parse(["controller", "dance"], cwd: cwd))
    }

    /// Ohne `--execute` ist jeder Lauf ein Trockenlauf.
    func testCLIPressDefaultsToDryRun() throws {
        XCTAssertEqual(
            try DebugCLIArguments.parse(["controller", "press", "cross"], cwd: cwd),
            .controllerRun(script: "down:cross,wait:60,up:cross", execute: false, window: nil, frontmost: false))
    }

    func testCLIPressWithOptions() throws {
        XCTAssertEqual(
            try DebugCLIArguments.parse(
                ["controller", "press", "l2", "--hold", "500", "--execute", "--window", "ab12", "--frontmost"], cwd: cwd),
            .controllerRun(script: "trigger:l2:1,wait:500,trigger:l2:0", execute: true, window: "ab12", frontmost: true))
        XCTAssertThrowsError(try DebugCLIArguments.parse(["controller", "press", "banana"], cwd: cwd))
        XCTAssertThrowsError(try DebugCLIArguments.parse(["controller", "press", "cross", "--hold", "x"], cwd: cwd))
        XCTAssertThrowsError(try DebugCLIArguments.parse(["controller", "press"], cwd: cwd))
    }

    func testCLISequenceIsValidatedBeforeSending() throws {
        XCTAssertEqual(
            try DebugCLIArguments.parse(["controller", "sequence", "down:cross,up:cross"], cwd: cwd),
            .controllerRun(script: "down:cross,up:cross", execute: false, window: nil, frontmost: false))
        XCTAssertThrowsError(try DebugCLIArguments.parse(["controller", "sequence", "down:banana"], cwd: cwd))
        XCTAssertThrowsError(try DebugCLIArguments.parse(["controller", "sequence", "down:cross", "--hold", "5"], cwd: cwd))
    }

    // MARK: - Routing

    /// Jede Methode des Debug-Kanals braucht einen eigenen Zweig. Fehlt er,
    /// landet sie still bei `debug.job` und antwortet „Auftrag unbekannt“.
    func testEveryDebugMethodHasItsOwnBranch() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("WhisperM8/Services/AgentChats/AgentControlRequestHandler+Debug.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        for method in AgentControlRequestHandler.debugMethods where method != "debug.job" {
            XCTAssertTrue(source.contains("case \"\(method)\":"), "\(method) hat keinen Zweig in debugRequest")
        }
    }
}
