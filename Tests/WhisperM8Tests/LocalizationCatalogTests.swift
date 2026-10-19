import XCTest

/// Lokalisierungs-Guard (E1: Englisch Basis, Deutsch vollständig; W3.0).
///
/// Der Katalog `WhisperM8/Localization/Localizable.xcstrings` wird vom
/// Makefile in das App-Bundle kompiliert. Geprüft wird:
/// 1. jeder Schlüssel hat eine fertige deutsche Übersetzung mit denselben
///    Platzhaltern;
/// 2. in den bereits lokalisierten Dateien (`localizedFiles`, wächst mit jeder
///    Welle) steht jeder UI-Text als Schlüssel im Katalog — ein neuer Text ohne
///    Katalogeintrag fällt sofort auf.
final class LocalizationCatalogTests: XCTestCase {
    /// Dateien, deren sichtbare Texte vollständig über den Katalog laufen.
    /// Neue oder umgestellte Ansichten hier eintragen.
    static let localizedFiles: [String] = [
        "WhisperM8/Views/Transcript/TranscriptEmptyStateView.swift",
    ]

    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func loadCatalog() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("WhisperM8/Localization/Localizable.xcstrings"))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func strings() throws -> [String: [String: Any]] {
        try XCTUnwrap(try loadCatalog()["strings"] as? [String: [String: Any]])
    }

    func testCatalogIsEnglishBased() throws {
        XCTAssertEqual(try loadCatalog()["sourceLanguage"] as? String, "en")
    }

    func testEveryKeyHasFinishedGermanTranslationWithSamePlaceholders() throws {
        for (key, entry) in try strings() {
            if entry["shouldTranslate"] as? Bool == false { continue }
            let de = (entry["localizations"] as? [String: Any])?["de"] as? [String: Any]
            let unit = de?["stringUnit"] as? [String: Any]
            let variations = de?["variations"]
            XCTAssertTrue(unit != nil || variations != nil, "„\(key)“: deutsche Übersetzung fehlt")
            guard let unit else { continue }
            XCTAssertEqual(unit["state"] as? String, "translated", "„\(key)“: Übersetzung nicht fertig")
            let value = unit["value"] as? String ?? ""
            XCTAssertFalse(value.isEmpty, "„\(key)“: deutscher Text leer")
            XCTAssertEqual(Self.placeholders(in: key), Self.placeholders(in: value),
                           "„\(key)“: Platzhalter weichen ab (\(value))")
        }
    }

    func testLocalizedFilesUseOnlyCatalogKeys() throws {
        let keys = Set(try strings().keys)
        for file in Self.localizedFiles {
            let source = try String(contentsOf: Self.root.appendingPathComponent(file), encoding: .utf8)
            for literal in Self.uiLiterals(in: source) where !keys.contains(literal) {
                XCTFail("\(file): „\(literal)“ fehlt im String-Katalog")
            }
        }
    }

    func testCatalogCompilesWithXcstringstool() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("l10n-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: out) }
        process.arguments = ["xcstringstool", "compile",
                             Self.root.appendingPathComponent("WhisperM8/Localization/Localizable.xcstrings").path,
                             "--output-directory", out.path]
        var environment = ProcessInfo.processInfo.environment
        environment["DEVELOPER_DIR"] = environment["DEVELOPER_DIR"] ?? "/Applications/Xcode.app/Contents/Developer"
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("de.lproj/Localizable.strings").path))
    }

    // MARK: - Helfer

    /// `%@`, `%lld`, `%1$@` … in Reihenfolge, Positionsangaben ignoriert.
    static func placeholders(in text: String) -> [String] {
        let pattern = #"%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j)?[@dDuUxXoOfeEgGcCsSpaA]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]).replacingOccurrences(of: #"\d+\$"#, with: "", options: .regularExpression) }
        }.sorted()
    }

    /// Einfache Literale in typischen UI-Aufrufen. Interpolationen (`\(`)
    /// prüft der Guard nicht — dafür `String(localized:)` mit Platzhalter nutzen.
    static func uiLiterals(in source: String) -> [String] {
        let calls = #"(?:Text|Button|Label|Toggle|Section|Picker|Menu|ContentUnavailableView|String\(localized:|\.help|\.navigationTitle|LocalizedStringKey)\(\s*"((?:[^"\\]|\\.)*)""#
        guard let regex = try? NSRegularExpression(pattern: calls) else { return [] }
        let range = NSRange(source.startIndex..., in: source)
        return regex.matches(in: source, range: range).compactMap { match in
            Range(match.range(at: 1), in: source).map { String(source[$0]) }
        }.filter { !$0.contains("\\(") && !$0.isEmpty }
    }
}
