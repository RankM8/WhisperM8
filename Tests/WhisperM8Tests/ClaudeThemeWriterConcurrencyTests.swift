import XCTest
@testable import WhisperM8

/// LR-AK-017: Schrieb die CLI zwischen Lesen und Ersetzen eine Einstellung,
/// ersetzte der Theme-Writer die Datei mit seinem älteren Stand.
@MainActor
final class ClaudeThemeWriterConcurrencyTests: XCTestCase {
    func testConcurrentSettingsChangeSurvivesThemeWrite() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("theme-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = dir.appendingPathComponent("settings.json")
        try #"{"model":"opus","theme":"light"}"#.write(to: settings, atomically: true, encoding: .utf8)

        let writer = ClaudeThemeWriter(claudeStateURL: settings, backupURL: dir.appendingPathComponent("backup.json"))
        var injected = false
        writer.beforeReplace = {
            guard !injected else { return }
            injected = true
            try? #"{"model":"opus","permissions":{"allow":["Bash(ls)"]},"theme":"light"}"#
                .write(to: settings, atomically: true, encoding: .utf8)
        }
        writer.performWrite(target: "dark")

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        XCTAssertEqual(json["theme"] as? String, "dark")
        XCTAssertNotNil(json["permissions"], "gleichzeitig gespeicherte Einstellung bleibt erhalten")
    }
}
