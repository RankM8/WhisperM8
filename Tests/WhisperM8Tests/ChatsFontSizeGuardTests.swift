import XCTest

/// LR-AU-033: informationstragende Texte der Chat-Oberfläche (Badges, Zähler,
/// Zeitangaben, Header-Metadaten) sind mindestens 11 pt groß.
///
/// Der Guard prüft `.font(.system(size: X …)` mit X < 11 in den Chat-Dateien
/// (`LocalizationCatalogTests.chatsLocalizedFiles`). Ausgenommen sind
/// - `.font(` in der Modifier-Kette direkt an einem `Image(systemName:)` (SF-Symbole sind
///   Glyphen, kein Text),
/// - die kleine, begründete Liste `allowedSmallText` unten.
final class ChatsFontSizeGuardTests: XCTestCase {
    /// Rein dekorative Kleinst-Texte — jeweils mit Begründung.
    static let allowedSmallText: [(file: String, contains: String, reason: String)] = []

    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Läuft von `index` aufwärts über Modifier-Zeilen (`.foo(…)`) bis zur Zeile,
    /// an der die Kette hängt; ein SF-Symbol ist sie nur, wenn dort `Image(systemName:`
    /// (oder `Image(nsImage:`) beginnt.
    static func isSymbolModifierChain(lines: [String], at index: Int) -> Bool {
        var i = index
        if !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(".") {
            // `.font` steht hinter dem Ausdruck in derselben Zeile (`Image(…).font(…)`).
            let l = lines[i]
            return l.contains("Image(systemName") || l.contains("Image(nsImage")
        }
        i -= 1
        while i >= 0, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(".") { i -= 1 }
        guard i >= 0 else { return false }
        let head = lines[i]
        return head.contains("Image(systemName") || head.contains("Image(nsImage")
    }

    func testChainDetectorOnlyExemptsRealSymbols() {
        let symbol = ["Image(systemName: \"xmark\")", "    .font(.system(size: 9))"]
        XCTAssertTrue(Self.isSymbolModifierChain(lines: symbol, at: 1))
        let text = ["Image(systemName: \"xmark\")", "Text(\"N done\")", "    .font(.system(size: 9.5))"]
        XCTAssertFalse(Self.isSymbolModifierChain(lines: text, at: 2))
    }

    func testNoInformationBearingTextBelowEleven() throws {
        let regex = try NSRegularExpression(pattern: #"\.font\(\.system\(size: ([0-9.]+)"#)
        for file in LocalizationCatalogTests.chatsLocalizedFiles where file.hasPrefix("WhisperM8/Views/") {
            let source = try String(contentsOf: Self.root.appendingPathComponent(file), encoding: .utf8)
            let lines = source.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                guard let match = regex.firstMatch(in: line, range: range),
                      let sizeRange = Range(match.range(at: 1), in: line),
                      let size = Double(line[sizeRange]), size < 11 else { continue }
                if Self.isSymbolModifierChain(lines: lines, at: index) { continue }
                if Self.allowedSmallText.contains(where: { file.hasSuffix($0.file) && line.contains($0.contains) }) { continue }
                XCTFail("\(file):\(index + 1): Schrift \(size) pt < 11 pt — informationstragende Texte brauchen mind. 11 pt")
            }
        }
    }
}
