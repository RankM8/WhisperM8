import XCTest

/// LR-AU-033: informationstragende Texte der Chat-Oberfläche (Badges, Zähler,
/// Zeitangaben, Header-Metadaten) sind mindestens 11 pt groß.
///
/// Der Guard prüft `.font(.system(size: X …)` mit X < 11 in den Chat-Dateien
/// (`LocalizationCatalogTests.chatsLocalizedFiles`). Ausgenommen sind
/// - Zeilen direkt unter einem `Image(` (SF-Symbole sind Glyphen, kein Text),
/// - die kleine, begründete Liste `allowedSmallText` unten.
final class ChatsFontSizeGuardTests: XCTestCase {
    /// Rein dekorative Kleinst-Texte — jeweils mit Begründung.
    static let allowedSmallText: [(file: String, contains: String, reason: String)] = []

    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
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
                let context = lines[max(0, index - 3)..<index].joined(separator: "\n")
                if context.contains("Image(") || context.contains("Circle()") { continue }
                if Self.allowedSmallText.contains(where: { file.hasSuffix($0.file) && line.contains($0.contains) }) { continue }
                XCTFail("\(file):\(index + 1): Schrift \(size) pt < 11 pt — informationstragende Texte brauchen mind. 11 pt")
            }
        }
    }
}
