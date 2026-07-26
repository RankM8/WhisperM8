import Foundation

/// Ein protokollierter Statuswechsel einer Session.
///
/// Hintergrund (Forensik 2026-07-26): Bei der Untersuchung eines gemeldeten
/// Queue-Staus ließ sich die Ereigniskette aus Transcript, Hook-Events und
/// Audit-Log rekonstruieren — der entscheidende Wert, der Laufzeitstatus zum
/// Zeitpunkt des `enqueue`, aber NICHT. Er lebt ausschließlich im Speicher und
/// war nach dem nächsten Übergang verloren. Genau diese Lücke schließt das
/// Journal: Es beantwortet später „was meldete die Session, als X passierte?".
struct ChatsStatusJournalEntry: Codable, Equatable {
    var at: Date
    var sessionID: UUID
    /// Vorheriger Laufzeitstatus (`nil` = es gab noch keine Meinung).
    var from: String?
    var to: String?
    /// Auslösendes Signal (`sessionStarted`, `toolWillRun`, `stopHook`, …) —
    /// ohne dieses Feld wäre ein Übergang nicht erklärbar, nur sichtbar.
    var signal: String
    /// `hook` = belegt durch ein Hook-Event, `transcript` = aus dem Transkript
    /// geschätzt. Der Unterschied entscheidet, wie belastbar die Zeile ist.
    var source: String
}

/// Append-only-Protokoll der Statuswechsel. Gleiche Bauart wie
/// `ChatsAuditLog`: eine Schreibstelle (die App), Rotation bei Größe, die CLI
/// liest nur.
///
/// Bewusst schlank gehalten — es ersetzt kein Ereignis-Journal mit Cursor und
/// Replay, sondern liefert genau so viel Historie, wie eine Nachanalyse
/// braucht.
final class ChatsStatusJournal: @unchecked Sendable {
    static let shared = ChatsStatusJournal()

    private let lock = NSLock()
    private let fileURL: URL
    private let maxBytes: Int

    init(fileURL: URL? = nil, maxBytes: Int = 2 * 1_048_576) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        self.maxBytes = maxBytes
    }

    static func defaultFileURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperM8", isDirectory: true)
            .appendingPathComponent("chats-status-journal.jsonl")
    }

    /// Schreibt einen Übergang. No-op, wenn sich der Status nicht geändert hat —
    /// ein Journal voller identischer Zeilen verdeckt die echten Wechsel.
    func append(sessionID: UUID, from: String?, to: String?, signal: String, source: String, at: Date = Date()) {
        guard from != to else { return }
        let entry = ChatsStatusJournalEntry(
            at: at, sessionID: sessionID, from: from, to: to, signal: signal, source: source)
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Self.encoder.encode(entry) else { return }
        var line = data
        line.append(0x0A)
        rotateIfNeeded(incomingBytes: line.count)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? line.write(to: fileURL)
        }
    }

    /// Die letzten Einträge einer Session, älteste zuerst. Reine Disk-Funktion —
    /// auch von der CLI genutzt, ohne Schreib-Nebenwirkung.
    static func recent(sessionID: UUID, limit: Int = 8, fileURL: URL? = nil) -> [ChatsStatusJournalEntry] {
        let url = fileURL ?? defaultFileURL()
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var found: [ChatsStatusJournalEntry] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let data = line.data(using: .utf8),
                  let entry = try? decoder.decode(ChatsStatusJournalEntry.self, from: data) else { continue }
            guard entry.sessionID == sessionID else { continue }
            found.append(entry)
            if found.count >= limit { break }
        }
        return found.reversed()
    }

    private func rotateIfNeeded(incomingBytes: Int) {
        let size = ((try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? Int) ?? 0
        guard size + incomingBytes > maxBytes else { return }
        let backup = fileURL.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: fileURL, to: backup)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
