import XCTest
@testable import WhisperM8

/// Befund 13.11.2026 (Dex): Der Plan der Übernahme stand mit dem Anfang des
/// Geheimnisses im System-Log. Geprüft wird hier, dass weder die Logzeilen
/// noch eine versehentliche Beschreibung der Typen Geheimnis oder
/// Control-Token verraten.
final class HandoverRedactionTests: XCTestCase {
    private let secret = HandoverSecret.make()
    private let token = "TOKEN-geheim-1234567890"

    /// Alle Formen, in denen ein Wert in einer Logzeile landen kann, auch
    /// `dump` (geht an `description` vorbei über `Mirror`).
    private func renderings(_ value: Any) -> [String] {
        var dumped = ""
        dump(value, to: &dumped)
        return [String(describing: value), String(reflecting: value), "\(value)", dumped]
    }

    private func assertNothingLeaks(_ value: Any, file: StaticString = #filePath, line: UInt = #line) {
        let fragments = [secret, String(secret.prefix(12)), String(secret.suffix(12)), token]
        for text in renderings(value) {
            for fragment in fragments {
                XCTAssertFalse(text.contains(fragment), "verrät \(fragment.prefix(4))…: \(text)", file: file, line: line)
            }
        }
    }

    private var manifest: HandoverManifest {
        var manifest = HandoverManifest(chatID: "chat-1", kind: "claude", pid: 42, cols: 80, rows: 24,
                                        sendsInterruptOnStop: true)
        manifest.controlToken = token
        manifest.launchCommand = .object(["environmentOverrides": .object(["X": .string(token)])])
        return manifest
    }

    func testLaunchPlanLogsOnlyItsCase() {
        let cases: [(HandoverLaunchPlan, String)] = [
            (.nothing, "nothing"), (.take(secret: secret), "take"), (.release(secret: secret), "release"),
            (.terminateKeeper(pid: 4711), "terminateKeeper"), (.keeperGone, "keeperGone"),
        ]
        for (plan, label) in cases {
            XCTAssertEqual(plan.logLabel, label)
            XCTAssertEqual(String(describing: plan), label, "keine zugeordneten Werte, auch keine PID")
            assertNothingLeaks(plan)
        }
    }

    func testTypesCarryingSecretOrTokenDescribeThemselvesRedacted() throws {
        assertNothingLeaks(HandoverSecretLookup.found(secret))
        var hello = HandoverMessage(type: .hello)
        hello.secret = secret
        hello.manifest = manifest
        assertNothingLeaks(hello)
        assertNothingLeaks(manifest)
        assertNothingLeaks(HandoverChatSummary(manifest: manifest, exited: false, exitStatus: nil, gapBytes: 3))
        assertNothingLeaks(HandoverClient.TakenChat(manifest: manifest, descriptor: nil, image: Array(token.utf8),
                                                    exited: true, exitStatus: 0, gapBytes: 0))
        assertNothingLeaks(HandoverKeeper.Configuration(
            paths: HandoverPaths(directory: URL(fileURLWithPath: "/tmp/x")), runID: "r",
            peerPolicy: HandoverPeerPolicy(allowedExecutablePaths: []), secret: secret))
        // Auch eingebettet in Sammlungen und Optionale (Standard-Beschreibung).
        assertNothingLeaks([HandoverSecretLookup.found(secret)])
        assertNothingLeaks(Optional(manifest) as Any)
        // Nacharbeit Vic: Startkommando und JSON-Wert allein.
        let command = AgentLaunchCommand(executablePath: "/opt/claude", arguments: ["--resume", "x"],
                                         workingDirectory: "/repo",
                                         environmentOverrides: ["WHISPERM8_SESSION_TOKEN": token])
        assertNothingLeaks(HandoverLaunchCommandSnapshot(command))
        assertNothingLeaks(try XCTUnwrap(manifest.launchCommand))
        assertNothingLeaks(HandoverJSONValue.string(token))
    }

    func testErrorLabelsCarryNoFreeText() {
        let errors: [Error] = [
            HandoverClient.ClientError.refused(token),
            HandoverClient.ClientError.unexpected(token),
            HandoverWireError.unexpected(token),
        ]
        for error in errors {
            XCTAssertFalse(HandoverLog.label(error).contains(token), HandoverLog.label(error))
        }
        XCTAssertEqual(HandoverLog.label(HandoverWireError.io(ENOENT)), "wire.io(\(ENOENT))")
    }

    /// Quellprüfung über das Handover-Modul und die Handover-Dateien außerhalb:
    /// In Log-Aufrufen (auch mehrzeiligen) nie `String(describing:` und nie ein
    /// rohes `\(error)`; im ganzen Code nie `dump(` oder `Mirror(` außer in
    /// den Schwärzungen selbst.
    func testHandoverSourcesNeverLogRawDescriptions() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let directory = root.appendingPathComponent("WhisperM8/Services/AgentChats/Handover")
        var files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".swift") }
            .map { directory.appendingPathComponent($0) }
        files += [
            "WhisperM8/CLI/HandoverCommands.swift",
            "WhisperM8/Views/AgentTerminalController+Handover.swift",
            "WhisperM8/Services/AgentChats/AgentControlRequestHandler+Handover.swift",
        ].map { root.appendingPathComponent($0) }
        XCTAssertGreaterThan(files.count, 10)
        var offenders: [String] = []
        for url in files {
            let text = try String(contentsOf: url, encoding: .utf8)
            for call in Self.logCalls(in: text)
            where call.contains("String(describing:") || call.contains("\\(error)") {
                offenders.append("\(url.lastPathComponent): \(call.prefix(80))")
            }
            if url.lastPathComponent != "HandoverRedaction.swift",
               text.contains("dump(") || text.contains("Mirror(") {
                offenders.append("\(url.lastPathComponent): dump/Mirror")
            }
        }
        XCTAssertTrue(offenders.isEmpty, "rohe Beschreibung: \(offenders)")
    }

    /// Log-Aufrufe samt Fortsetzungszeilen: ab `Logger.`, `log(\"`, `fail(\"`
    /// oder `rollback(\"` bis die Klammern ausgeglichen sind.
    static func logCalls(in text: String) -> [String] {
        let starts = ["Logger.", "log(\"", "fail(\"", "rollback(\""]
        var calls: [String] = []
        let chars = Array(text)
        var index = 0
        while index < chars.count {
            let rest = String(chars[index..<min(chars.count, index + 12)])
            guard starts.contains(where: { rest.hasPrefix($0) }) else { index += 1; continue }
            var depth = 0
            var end = index
            var opened = false
            while end < chars.count {
                if chars[end] == "(" { depth += 1; opened = true }
                if chars[end] == ")" { depth -= 1 }
                end += 1
                if opened && depth == 0 { break }
            }
            calls.append(String(chars[index..<end]))
            index = end
        }
        return calls
    }

    func testLogCallScannerFindsMultilineCalls() {
        let source = """
        Logger.agentStore.error(
            "x=\\(String(describing: plan))")
        let a = 1
        """
        XCTAssertEqual(Self.logCalls(in: source).count, 1)
        XCTAssertTrue(Self.logCalls(in: source)[0].contains("String(describing:"))
    }
}
