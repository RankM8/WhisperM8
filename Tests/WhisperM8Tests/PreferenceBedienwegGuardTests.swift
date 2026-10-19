import XCTest
@testable import WhisperM8

/// DoD „Kein `defaults write` als Bedienweg": Jeder Schalter aus `PreferenceKeys`
/// hat einen UI-Weg in den Einstellungen (oder einer anderen Bedienfläche) — oder
/// steht mit Begründung in `PreferenceBedienweg`.
final class PreferenceBedienwegGuardTests: XCTestCase {
    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func read(_ relative: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(relative), encoding: .utf8)
    }

    private func swiftFiles(under relative: String) -> [String] {
        let base = Self.root.appendingPathComponent(relative)
        guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { return [] }
        return enumerator.compactMap { ($0 as? URL)?.path }.filter { $0.hasSuffix(".swift") }
    }

    private struct Key {
        let constant: String
        let value: String
        let properties: [String]
    }

    /// Alle `static let name = "name"` aus `PreferenceKeys` samt den Eigenschaften,
    /// die den Key in `AppPreferences` kapseln.
    private func preferenceKeys() throws -> [Key] {
        let source = try read("WhisperM8/Support/AppPreferences.swift")
        let range = NSRange(source.startIndex..., in: source)
        let keyRegex = try NSRegularExpression(pattern: #"static let (\w+) = "(\w+)""#)
        let constants: [(String, String)] = keyRegex.matches(in: source, range: range).compactMap { m in
            guard let a = Range(m.range(at: 1), in: source), let b = Range(m.range(at: 2), in: source) else { return nil }
            return (String(source[a]), String(source[b]))
        }
        let varRegex = try NSRegularExpression(
            pattern: #"\n    (?:static )?var (\w+): [^{\n]*\{(.*?)\n    \}"#,
            options: [.dotMatchesLineSeparators]
        )
        var propertiesByKey: [String: [String]] = [:]
        for m in varRegex.matches(in: source, range: range) {
            guard let nameRange = Range(m.range(at: 1), in: source),
                  let bodyRange = Range(m.range(at: 2), in: source) else { continue }
            let body = String(source[bodyRange])
            for (constant, _) in constants where body.contains("Keys.\(constant)") {
                propertiesByKey[constant, default: []].append(String(source[nameRange]))
            }
        }
        return constants.map { Key(constant: $0.0, value: $0.1, properties: propertiesByKey[$0.0] ?? []) }
    }

    /// Bedienflächen: Einstellungen plus die wenigen Oberflächen, die Schalter direkt anbieten.
    /// Je Datei getrennt, damit ein Binding nur in der Datei seiner Deklaration zählt.
    private func surfaceSource() throws -> [String] {
        var files = swiftFiles(under: "WhisperM8/Views/Settings")
        files.append(Self.root.appendingPathComponent("WhisperM8/Views/SettingsView.swift").path)
        for extra in PreferenceBedienweg.additionalSurfaces {
            files.append(Self.root.appendingPathComponent(extra).path)
        }
        return try files.map { try String(contentsOfFile: $0, encoding: .utf8) }
    }

    /// Ein UI-Weg ist ein Binding (`$name`) oder eine Zuweisung — bloßes Lesen
    /// (z. B. um eine Seite auszublenden) zählt nicht.
    private func hasUIPath(_ key: Key, in surface: [String]) -> Bool {
        // `@AppStorage(PreferenceKeys.x) private var name` → wird `name` IN DERSELBEN
        // Datei gebunden/gesetzt? Sonst machte ein gleichnamiges Property einer
        // fremden Datei (`port`, `enabled` …) einen Schlüssel ohne UI grün.
        let declaration = "@AppStorage\\(\\s*(?:PreferenceKeys\\.\(key.constant)\\b|\"\(key.value)\")[^\\n]*?\\bvar (\\w+)"
        if let regex = try? NSRegularExpression(pattern: declaration) {
            for file in surface {
                let range = NSRange(file.startIndex..., in: file)
                for match in regex.matches(in: file, range: range) {
                    guard let nameRange = Range(match.range(at: 1), in: file) else { continue }
                    if isWritten(String(file[nameRange]), in: file) { return true }
                }
            }
        }
        // Properties von `AppPreferences` nur qualifiziert (`prefs.name = …`,
        // `$prefs.name`) — ein nacktes `name =` gehört fast immer zu etwas anderem.
        return key.properties.contains { name in surface.contains { isWrittenQualified(name, in: $0) } }
    }

    private func isWritten(_ name: String, in surface: String) -> Bool {
        surface.range(of: "\\$\(name)\\b", options: .regularExpression) != nil
            || surface.range(of: "(?<!var )\\b\(name)\\s*=[^=]", options: .regularExpression) != nil
            || surface.range(of: "\\b\(name)\\.toggle\\(", options: .regularExpression) != nil
    }

    private func isWrittenQualified(_ name: String, in surface: String) -> Bool {
        surface.range(of: "\\$\\w+(?:\\.\\w+)*\\.\(name)\\b", options: .regularExpression) != nil
            || surface.range(of: "\\w\\.\(name)\\s*=[^=]", options: .regularExpression) != nil
            || surface.range(of: "\\w\\.\(name)\\.toggle\\(", options: .regularExpression) != nil
    }

    private var allExceptions: [PreferenceBedienweg.Entry] {
        PreferenceBedienweg.killSwitches + PreferenceBedienweg.internalState
            + PreferenceBedienweg.indirectUI + PreferenceBedienweg.measurementTools
    }

    func testEveryPreferenceHasUIPathOrDocumentedException() throws {
        let surface = try surfaceSource()
        let excepted = Set(allExceptions.map(\.key))
        var missing: [String] = []
        for key in try preferenceKeys() where !excepted.contains(key.value) {
            if !hasUIPath(key, in: surface) { missing.append(key.value) }
        }
        XCTAssertTrue(missing.isEmpty, "Ohne UI-Weg und ohne Eintrag in PreferenceBedienweg: \(missing.sorted())")
    }

    func testExceptionListHasNoStaleOrDuplicateKeys() throws {
        let known = Set(try preferenceKeys().map(\.value))
        let all = allExceptions.map(\.key)
        XCTAssertEqual(all.count, Set(all).count, "Schlüssel doppelt in den Ausnahmelisten")
        for key in all {
            XCTAssertTrue(known.contains(key), "„\(key)“ steht in der Ausnahmeliste, existiert aber nicht in PreferenceKeys")
        }
    }

    func testExceptionsHaveReasons() {
        for entry in allExceptions {
            XCTAssertGreaterThan(entry.reason.count, 10, "„\(entry.key)“ braucht eine Begründung")
        }
    }

    func testKillSwitchesAreNotPlainSettings() throws {
        // Ein Kill-Switch mit eigenem UI-Weg gehört nicht mehr in die Notbremsen-Liste.
        let surface = try surfaceSource()
        let keys = try preferenceKeys()
        for entry in PreferenceBedienweg.killSwitches {
            guard let key = keys.first(where: { $0.value == entry.key }) else { continue }
            XCTAssertFalse(hasUIPath(key, in: surface), "„\(entry.key)“ hat inzwischen einen UI-Weg — aus killSwitches streichen")
        }
    }

    func testBindingInForeignFileDoesNotCount() {
        let key = Key(constant: "demoPort", value: "demoPort", properties: ["port"])
        let declaring = "@AppStorage(PreferenceKeys.demoPort) private var port = 1\nText(\"\\(port)\")"
        let foreign = "TextField(\"Port\", value: $port)\nport = 2"
        XCTAssertFalse(hasUIPath(key, in: [declaring, foreign]))
        XCTAssertTrue(hasUIPath(key, in: [declaring + "\nTextField(\"Port\", value: $port)"]))
        XCTAssertTrue(hasUIPath(key, in: ["Toggle(isOn: $preferences.port)"]))
    }
}
