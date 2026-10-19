import XCTest

/// DoD (D2): Keine Quelldatei über 1.500 Zeilen. Bestandsdateien darüber
/// stehen in einer Ausnahmeliste mit Obergrenze — die Liste darf nur
/// schrumpfen: Wer eine Datei kürzt, senkt ihre Grenze; neue Einträge sind
/// nicht vorgesehen (dann die Datei aufteilen).
final class SourceSizeGuardTests: XCTestCase {
    static let maxLines = 1_500

    /// Endstand nach Launch-Readiness W7 (19.10.2026). Obergrenze = heutige Länge.
    static let exceptions: [String: Int] = [
        "WhisperM8/Views/AgentChatsView.swift": 3_842,
        "WhisperM8/Services/AgentChats/AgentControlRequestHandler.swift": 1_781,
        "WhisperM8/Services/AgentChats/AgentSessionStore.swift": 1_634,
    ]

    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testNoSourceFileExceedsItsLimit() throws {
        let sources = Self.root.appendingPathComponent("WhisperM8")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = String(url.path.dropFirst(Self.root.path.count + 1))
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n").count
            let limit = Self.exceptions[relative] ?? Self.maxLines
            XCTAssertLessThanOrEqual(lines, limit, "\(relative) hat \(lines) Zeilen (Grenze \(limit)) — aufteilen statt die Grenze anheben")
        }
    }

    func testExceptionsStillNeeded() throws {
        // Fällt eine Ausnahme unter 1.500 Zeilen, gehört sie aus der Liste.
        for (relative, _) in Self.exceptions {
            let url = Self.root.appendingPathComponent(relative)
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n").count
            XCTAssertGreaterThan(lines, Self.maxLines, "\(relative) ist kleiner geworden — aus der Ausnahmeliste streichen")
        }
    }
}
