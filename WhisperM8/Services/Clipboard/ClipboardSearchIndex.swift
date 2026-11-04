import Foundation

// MARK: - Suchindex des Verlaufs (im Speicher, ohne Datei-Zugriff beim Tippen)

/// Durchsuchbarer Text je Eintrag, schon gefaltet (Groß/Klein und Akzente
/// egal) und als UTF-8-Bytes, damit die Suche beim Tippen nur noch `memmem`
/// über den Speicher laufen lässt. Gebaut wird abseits des Main Threads im
/// Store, beim Aufnehmen eines Eintrags und einmal beim Laden.
///
/// Lange Texte (Logs, Fehlerausgaben) gehen komplett hinein bis zur Grenze
/// `headBytes + tailBytes`; darüber zählen Anfang und Ende, weil dort bei
/// Logs das Wichtige steht. Ein Gesamtbudget hält den Speicher auch bei 200
/// riesigen Einträgen in Grenzen: dann werden die ältesten langen Einträge
/// auf einen kleineren Anfang und ein kleineres Ende gekürzt.
struct ClipboardSearchIndex: Sendable, Equatable {
    struct Limits: Sendable, Equatable {
        var headBytes = 256 * 1024
        var tailBytes = 256 * 1024
        var totalBytes = 64 * 1024 * 1024
        var reducedBytes = 32 * 1024
    }

    private(set) var haystacks: [String: [UInt8]] = [:]
    var limits = Limits()

    init(limits: Limits = Limits()) {
        self.limits = limits
    }

    var totalBytes: Int { haystacks.values.reduce(0) { $0 + $1.count } }

    func haystack(for id: String) -> [UInt8]? { haystacks[id] }

    mutating func set(_ entry: ClipboardEntry, fullText: String?) {
        haystacks[entry.id] = Self.haystack(for: entry, fullText: fullText, limits: limits)
    }

    mutating func remove(id: String) {
        haystacks[id] = nil
    }

    /// Wirft alles raus, was nicht mehr im Verlauf steht.
    mutating func retain(_ entries: [ClipboardEntry]) {
        let ids = Set(entries.map(\.id))
        haystacks = haystacks.filter { ids.contains($0.key) }
    }

    /// Hält das Gesamtbudget ein: die ältesten langen Einträge werden zuerst gekürzt.
    mutating func enforceBudget(_ entries: [ClipboardEntry]) {
        var total = totalBytes
        guard total > limits.totalBytes else { return }
        let reduced = limits.reducedBytes
        for entry in ClipboardHistoryCore.chronological(entries).reversed() {
            guard total > limits.totalBytes else { break }
            guard let bytes = haystacks[entry.id], bytes.count > reduced * 2 else { continue }
            let shortened = Array(bytes.prefix(reduced)) + [0x0A] + Array(bytes.suffix(reduced))
            total -= bytes.count - shortened.count
            haystacks[entry.id] = shortened
        }
    }

    // MARK: Aufbau (rein)

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Anfang und Ende eines langen Texts (in UTF-8-Bytes gemessen).
    static func excerpt(_ text: String, head: Int, tail: Int) -> String {
        let utf8 = text.utf8
        guard utf8.count > head + tail else { return text }
        let headEnd = utf8.index(utf8.startIndex, offsetBy: head)
        let tailStart = utf8.index(utf8.endIndex, offsetBy: -tail)
        return String(decoding: utf8[..<headEnd], as: UTF8.self) + "\n" + String(decoding: utf8[tailStart...], as: UTF8.self)
    }

    /// Gefalteter Suchtext eines Eintrags: Inhalt plus Name der Herkunfts-App.
    static func haystack(for entry: ClipboardEntry, fullText: String?, limits: Limits = Limits()) -> [UInt8] {
        var parts: [String] = []
        switch entry.kind {
        case .text:
            parts.append(excerpt(fullText ?? entry.text ?? entry.preview, head: limits.headBytes, tail: limits.tailBytes))
        case .image:
            parts.append(entry.preview)
        case .files:
            parts.append(contentsOf: entry.filePaths ?? [])
            parts.append(entry.preview)
        }
        if let name = entry.sourceName { parts.append(name) }
        return Array(fold(parts.joined(separator: "\n")).utf8)
    }

    /// Erstes Vorkommen von `needle` in `haystack` (Byte-Position).
    static func firstIndex(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        return haystack.withUnsafeBytes { hay -> Int? in
            needle.withUnsafeBytes { pin -> Int? in
                guard let hayBase = hay.baseAddress, let pinBase = pin.baseAddress,
                      let found = memmem(hayBase, hay.count, pinBase, pin.count) else { return nil }
                return hayBase.distance(to: UnsafeRawPointer(found))
            }
        }
    }
}
