import XCTest
@testable import WhisperM8

/// Befund 13.11.2026 (Dex): Der Plan der Übernahme stand mit dem Anfang des
/// Geheimnisses im System-Log. Geprüft wird hier, dass weder die Logzeilen
/// noch eine versehentliche Beschreibung der Typen Geheimnis oder
/// Control-Token verraten.
final class HandoverRedactionTests: XCTestCase {
    private let secret = HandoverSecret.make()
    private let token = "TOKEN-geheim-1234567890"

    /// Alle Formen, in denen ein Wert in einer Logzeile landen kann.
    private func renderings(_ value: Any) -> [String] {
        [String(describing: value), String(reflecting: value), "\(value)"]
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

    func testTypesCarryingSecretOrTokenDescribeThemselvesRedacted() {
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

    /// Quellprüfung: In Logzeilen des Moduls nie `String(describing:` und nie
    /// ein `\(error)` ohne `HandoverLog.label`.
    func testHandoverSourcesNeverLogRawDescriptions() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let directory = root.appendingPathComponent("WhisperM8/Services/AgentChats/Handover")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".swift") }
        XCTAssertFalse(files.isEmpty)
        var offenders: [String] = []
        for file in files {
            let text = try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                let isLog = line.contains("Logger.") || line.contains("log(\"") || line.contains("fail(\"")
                    || line.contains("rollback(\"")
                guard isLog else { continue }
                if line.contains("String(describing:") || line.contains("\\(error)") {
                    offenders.append("\(file):\(index + 1)")
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty, "rohe Beschreibung in Logzeilen: \(offenders)")
    }
}
