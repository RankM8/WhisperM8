import Foundation

/// Ein Rückblick, den Claude Code selbst ins Transcript schreibt, während der
/// User woanders ist: `{"type":"system","subtype":"away_summary","content":"Ziel
/// ist … Zuletzt … Als Nächstes …"}`.
struct ClaudeRecap: Equatable {
    var at: Date?
    var text: String
}

/// Liest Claudes Rückblicke vom Ende eines Transcripts — Lesehilfe für Jarvis
/// (`whisperm8 chats show <ref> --recap`), damit er für seine Notizen nicht den
/// ganzen Verlauf lesen muss.
///
/// Ein festes Tail-Fenster reicht nicht: Tool-Ausgaben lassen ein Transcript in
/// Minuten um Megabytes wachsen (gemessen 17.10.2026: der jüngste Rückblick lag
/// 1,1 MB vor dem Ende einer 172-MB-Datei). Deshalb wird blockweise rückwärts
/// nach dem Merkmal `"subtype":"away_summary"` gesucht und nur die Zeile um einen
/// Treffer gelesen. In JSON-Strings stünde das Merkmal escaped (`\"subtype\"`),
/// zitierter Text löst also keinen Treffer aus; riesige Tool-Zeilen werden nie
/// ganz geladen.
///
/// Das Format ist nicht dokumentiert und lässt sich in Claudes `/config`
/// abschalten. Deshalb fail-soft: Alles, was nicht genau passt, wird
/// übersprungen; ein Fehler ergibt eine leere Liste, nie einen Abbruch.
enum ClaudeRecapReader {
    static let defaultLimit = 3
    /// Weiter zurück sucht niemand nach einem „aktuellen" Rückblick.
    static let defaultMaxScanBytes: UInt64 = 64 * 1_024 * 1_024
    static let defaultChunkBytes = 1_024 * 1_024
    /// Rückblicke sind ein paar Sätze; längere Zeilen sind etwas anderes.
    static let maxLineBytes = 64 * 1_024

    /// Diesen Hinweis hängt Claude an jeden Rückblick, er gehört nicht zum Inhalt.
    static let disableHint = "(disable recaps in /config)"

    private static let marker = Data(#""subtype":"away_summary""#.utf8)
    private static let newline: UInt8 = 0x0A

    /// Neueste zuerst, höchstens `limit`.
    static func recaps(fileURL: URL, limit: Int = defaultLimit,
                       maxScanBytes: UInt64 = defaultMaxScanBytes,
                       chunkBytes: Int = defaultChunkBytes) -> [ClaudeRecap] {
        guard limit > 0, chunkBytes > 0, let handle = try? FileHandle(forReadingFrom: fileURL) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }

        let floor = size > maxScanBytes ? size - maxScanBytes : 0
        let overlap = UInt64(marker.count - 1)
        var result: [ClaudeRecap] = []
        var end = size
        while end > floor, result.count < limit {
            let start = max(floor, end > UInt64(chunkBytes) ? end - UInt64(chunkBytes) : 0)
            // Überlappung, damit ein Merkmal über der Blockgrenze gefunden wird.
            guard let block = read(handle, from: start, to: min(size, end + overlap)) else { break }
            for hit in hits(in: block).reversed() {
                let offset = start + UInt64(hit)
                guard offset < end else { continue }   // gehört zum schon gelesenen Block
                guard let line = line(around: offset, in: handle, size: size),
                      let recap = recap(fromLine: line) else { continue }
                result.append(recap)
                if result.count == limit { break }
            }
            end = start
        }
        return result
    }

    /// Eine JSONL-Zeile → Rückblick, sonst `nil`.
    static func recap(fromLine line: String) -> ClaudeRecap? {
        guard line.contains("away_summary"),
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              object["type"] as? String == "system",
              object["subtype"] as? String == "away_summary",
              let content = object["content"] as? String else { return nil }
        let text = clean(content)
        guard !text.isEmpty else { return nil }
        return ClaudeRecap(at: parseDate(object["timestamp"] as? String), text: text)
    }

    static func clean(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix(disableHint) {
            text = String(text.dropLast(disableHint.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    // MARK: - Datei

    private static func read(_ handle: FileHandle, from start: UInt64, to end: UInt64) -> Data? {
        guard end > start, (try? handle.seek(toOffset: start)) != nil else { return nil }
        return try? handle.read(upToCount: Int(end - start))
    }

    /// Startindizes aller Merkmal-Treffer im Block, aufsteigend.
    private static func hits(in block: Data) -> [Int] {
        var result: [Int] = []
        var searchStart = block.startIndex
        while let range = block.range(of: marker, in: searchStart..<block.endIndex) {
            result.append(range.lowerBound - block.startIndex)
            searchStart = range.upperBound
        }
        return result
    }

    /// Die ganze Zeile um `offset`, wenn sie nicht länger als `maxLineBytes` ist.
    private static func line(around offset: UInt64, in handle: FileHandle, size: UInt64) -> String? {
        let window = UInt64(maxLineBytes)
        let backStart = offset > window ? offset - window : 0
        guard let before = read(handle, from: backStart, to: offset) ?? (offset == backStart ? Data() : nil) else {
            return nil
        }
        let lineStart: UInt64
        if let lastNewline = before.lastIndex(of: newline) {
            lineStart = backStart + UInt64(lastNewline - before.startIndex) + 1
        } else if backStart == 0 {
            lineStart = 0
        } else {
            return nil   // Zeilenanfang liegt weiter als das Fenster zurück: zu lang für einen Rückblick
        }
        guard let after = read(handle, from: offset, to: min(size, offset + window)) else { return nil }
        let lineEnd: UInt64
        if let firstNewline = after.firstIndex(of: newline) {
            lineEnd = offset + UInt64(firstNewline - after.startIndex)
        } else if offset + window >= size {
            lineEnd = size
        } else {
            return nil
        }
        guard let data = read(handle, from: lineStart, to: lineEnd) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}
