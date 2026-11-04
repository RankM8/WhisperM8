import CryptoKit
import Foundation

// MARK: - Eintrag im Zwischenablage-Verlauf

/// Ein Eintrag des Verlaufs. Kleine Texte liegen direkt im Index, alles
/// Größere (langer Text, RTF, HTML, Bild) als Datei neben dem Index
/// (`ClipboardHistoryStore`). So bleibt der Index klein und schnell zu lesen.
struct ClipboardEntry: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case text
        case image
        case files
    }

    var id: String
    var kind: Kind
    /// Wann der Inhalt zum ersten Mal kopiert wurde.
    var createdAt: Date
    /// Wann er zuletzt kopiert wurde; danach richtet sich die Reihenfolge.
    var lastCopiedAt: Date
    var copyCount: Int
    var isPinned: Bool
    var sourceBundleID: String?
    var sourceName: String?
    /// Hash des Inhalts (Text, Bilddaten oder Pfade) für die Duplikaterkennung.
    var contentHash: String
    /// Erste Zeilen des Inhalts, für Liste und Suche.
    var preview: String
    /// Voller Text, solange er klein genug für den Index ist.
    var text: String?
    var textFile: String?
    var rtfFile: String?
    var htmlFile: String?
    var imageFile: String?
    var imageWidth: Int?
    var imageHeight: Int?
    var imageBytes: Int?
    var filePaths: [String]?

    /// Dateien dieses Eintrags im Verlaufsordner.
    var blobFiles: [String] {
        [textFile, rtfFile, htmlFile, imageFile].compactMap { $0 }
    }

    static let previewLimit = 240

    static func makePreview(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = trimmed.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if collapsed.count <= previewLimit { return collapsed }
        return String(collapsed.prefix(previewLimit)) + "…"
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func hash(text: String) -> String { hash(Data(text.utf8)) }

    static func hash(paths: [String]) -> String { hash(Data(paths.joined(separator: "\n").utf8)) }
}

// MARK: - Erfasster Zwischenablage-Inhalt (Rohdaten, noch nicht gespeichert)

/// Was der Monitor beim Lesen der Zwischenablage gesehen hat. Reine Daten,
/// damit Aufbereitung und Speichern abseits des Main Threads laufen.
struct ClipboardCapture: Sendable {
    var types: [String]
    var text: String?
    var rtf: Data?
    var html: Data?
    /// PNG oder TIFF, wie die Quelle es geliefert hat.
    var imageData: Data?
    var imageIsPNG: Bool
    var filePaths: [String]
    var sourceBundleID: String?
    var sourceName: String?
    var date: Date

    init(
        types: [String] = [],
        text: String? = nil,
        rtf: Data? = nil,
        html: Data? = nil,
        imageData: Data? = nil,
        imageIsPNG: Bool = false,
        filePaths: [String] = [],
        sourceBundleID: String? = nil,
        sourceName: String? = nil,
        date: Date = Date()
    ) {
        self.types = types
        self.text = text
        self.rtf = rtf
        self.html = html
        self.imageData = imageData
        self.imageIsPNG = imageIsPNG
        self.filePaths = filePaths
        self.sourceBundleID = sourceBundleID
        self.sourceName = sourceName
        self.date = date
    }
}
