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
    /// Alle Typen der Originalkopie (Text, RTF, HTML, Bild, App-eigene
    /// Formate), damit Einfügen den Inhalt so vollständig wie möglich
    /// zurückbringt, etwa Tabellen aus Excel oder Numbers mit Bild.
    var archiveFile: String?
    /// Zeichenzahl des vollen Texts (auch wenn er in einer Datei liegt).
    var charCount: Int?
    var imageWidth: Int?
    var imageHeight: Int?
    var imageBytes: Int?
    var filePaths: [String]?
    /// Modus des Diktats (etwa "Slack"), wenn der Eintrag ein Diktat-Ergebnis
    /// ist. Fehlt bei normalen Kopien und in älteren Indexdateien.
    var dictationMode: String? = nil

    /// Dateien dieses Eintrags im Verlaufsordner.
    var blobFiles: [String] {
        [textFile, rtfFile, htmlFile, imageFile, archiveFile].compactMap { $0 }
    }

    /// Zeichen des vollen Texts; ältere Einträge ohne Zähler nehmen den Index-Text.
    var textLength: Int { charCount ?? text?.count ?? preview.count }

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

// MARK: - Originaltypen einer Kopie

/// Eine Darstellung eines Pasteboard-Eintrags (Typ plus Daten).
struct ClipboardRepresentation: Codable, Equatable, Sendable {
    var type: String
    var data: Data
}

/// Alle Pasteboard-Einträge einer Kopie mit allen Typen, in Originalreihenfolge.
struct ClipboardArchive: Codable, Equatable, Sendable {
    var items: [[ClipboardRepresentation]]

    var byteCount: Int { items.reduce(0) { $0 + $1.reduce(0) { $0 + $1.data.count } } }

    func encoded() -> Data? {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try? encoder.encode(self)
    }

    static func decode(_ data: Data) -> ClipboardArchive? {
        try? PropertyListDecoder().decode(ClipboardArchive.self, from: data)
    }
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
    /// Alle Typen der Kopie; `nil`, wenn sie das Größenlimit sprengt.
    var archive: ClipboardArchive?
    var sourceBundleID: String?
    var sourceName: String?
    var date: Date
    /// Siehe `ClipboardEntry.dictationMode`.
    var dictationMode: String?

    init(
        types: [String] = [],
        text: String? = nil,
        rtf: Data? = nil,
        html: Data? = nil,
        imageData: Data? = nil,
        imageIsPNG: Bool = false,
        filePaths: [String] = [],
        archive: ClipboardArchive? = nil,
        sourceBundleID: String? = nil,
        sourceName: String? = nil,
        date: Date = Date(),
        dictationMode: String? = nil
    ) {
        self.types = types
        self.text = text
        self.rtf = rtf
        self.html = html
        self.imageData = imageData
        self.imageIsPNG = imageIsPNG
        self.filePaths = filePaths
        self.archive = archive
        self.sourceBundleID = sourceBundleID
        self.sourceName = sourceName
        self.date = date
        self.dictationMode = dictationMode
    }
}
