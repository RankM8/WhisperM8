import XCTest

/// Verträge der `WhisperM8/Info.plist`.
final class InfoPlistContractTests: XCTestCase {
    private func loadPlist() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("WhisperM8/Info.plist"))
        return try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
    }

    /// LR-SH-013: `Logger.info` landet laut `man 5 os_log` ohne Konfiguration nur
    /// im Speicherpuffer (gemessen: `log show --info` zeigt nach Tagen nichts
    /// mehr, Default-Meldungen schon). Absturz-Diagnose braucht Persistenz auf
    /// Info-Ebene für das Subsystem.
    func testOSLogPreferencesPersistInfoForSubsystem() throws {
        let plist = try loadPlist()
        let prefs = try XCTUnwrap(plist["OSLogPreferences"] as? [String: Any], "OSLogPreferences fehlt")
        let subsystem = try XCTUnwrap(prefs["com.whisperm8.app"] as? [String: Any], "Subsystem fehlt")
        let defaults = try XCTUnwrap(subsystem["DEFAULT-OPTIONS"] as? [String: Any], "DEFAULT-OPTIONS fehlt")
        let level = try XCTUnwrap(defaults["Level"] as? [String: Any])
        XCTAssertEqual(level["Persist"] as? String, "Info")
        // Debug bleibt aus (nur Enable-Ebene unangetastet): kein Persistieren von Debug.
        XCTAssertNotEqual(level["Persist"] as? String, "Debug")
    }
}
