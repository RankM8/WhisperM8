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
    /// Monoton wachsende Sequenznummer innerhalb einer `journalId`. Basis des
    /// Cursors — ein Agent kann damit „was ist seit meinem letzten Blick
    /// passiert?" beantworten, ohne den Bestand erneut zu lesen.
    var seq: Int = 0
    /// Identität dieses Journals. Ändert sich bei Rotation; ein Cursor aus
    /// einer alten Generation ist damit erkennbar ungültig (statt still
    /// falsche Ergebnisse zu liefern).
    var journalId: String = ""
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
        lock.lock()
        defer { lock.unlock() }
        let entry = ChatsStatusJournalEntry(
            at: at, seq: nextSequence(), journalId: resolvedJournalId(),
            sessionID: sessionID, from: from, to: to, signal: signal, source: source)
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

    // MARK: - Cursor

    /// Cursorform `<journalId>:<seq>`. Für Agenten OPAK — die Zerlegung ist
    /// Sache dieser Klasse, damit die Form später änderbar bleibt.
    static func cursor(journalId: String, seq: Int) -> String { "\(journalId):\(seq)" }

    static func parseCursor(_ raw: String) -> (journalId: String, seq: Int)? {
        guard let separator = raw.lastIndex(of: ":"),
              let seq = Int(raw[raw.index(after: separator)...]) else { return nil }
        return (String(raw[raw.startIndex..<separator]), seq)
    }

    /// Aktueller Stand — der Cursor, den ein Agent sich merkt.
    ///
    /// `nil`, solange das Journal noch keine Einträge mit Generation trägt
    /// (Dateien aus einer Vorversion). Ein Cursor `":0"` auszugeben wäre
    /// schlimmer als keiner: Er sähe gültig aus und würde bei jedem `since`
    /// dieselben Alt-Einträge nachliefern.
    static func currentCursor(fileURL: URL? = nil) -> String? {
        let entries = readAll(fileURL: fileURL ?? defaultFileURL())
        guard let last = entries.last, !last.journalId.isEmpty else { return nil }
        return cursor(journalId: last.journalId, seq: last.seq)
    }

    /// Alle Einträge nach einem Cursor. `gap == true` heißt: Der Cursor ist
    /// nicht mehr bedienbar (Rotation oder abgeschnittener Bereich) — der
    /// Aufrufer MUSS dann einen frischen Snapshot ziehen. Ein stilles
    /// Fortfahren „ab jetzt" wäre der gefährlichste Fehler, weil eine Lücke
    /// dann wie „nichts passiert" aussieht.
    static func changes(
        since rawCursor: String?,
        limit: Int = 64,
        fileURL: URL? = nil
    ) -> (entries: [ChatsStatusJournalEntry], gap: Bool, hasMore: Bool, cursor: String?) {
        // Einträge ohne Generation stammen aus einer Vorversion und sind für
        // Cursor-Abfragen unbrauchbar — sie tragen keine Ordnung.
        let all = readAll(fileURL: fileURL ?? defaultFileURL()).filter { !$0.journalId.isEmpty }
        let currentId = all.last?.journalId
        let latest = all.last.map { cursor(journalId: $0.journalId, seq: $0.seq) }

        guard let rawCursor, let parsed = parseCursor(rawCursor) else {
            // Ohne Cursor: nur den aktuellen Stand melden, nichts nachliefern.
            return ([], false, false, latest)
        }
        guard let currentId, parsed.journalId == currentId else {
            return ([], true, false, latest)
        }
        // Liegt der Cursor VOR dem ältesten vorhandenen Eintrag, wurde
        // dazwischen rotiert oder beschnitten.
        if let oldest = all.first, parsed.seq < oldest.seq - 1 {
            return ([], true, false, latest)
        }
        let newer = all.filter { $0.seq > parsed.seq }
        let page = Array(newer.prefix(limit))
        let nextCursor = page.last.map { cursor(journalId: $0.journalId, seq: $0.seq) } ?? rawCursor
        return (page, false, newer.count > page.count, nextCursor)
    }

    static func readAll(fileURL: URL) -> [ChatsStatusJournalEntry] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(ChatsStatusJournalEntry.self, from: data)
        }
    }

    // MARK: - Sequenz und Generation

    private var cachedSeq: Int?
    private var cachedJournalId: String?

    private func nextSequence() -> Int {
        if let cachedSeq {
            self.cachedSeq = cachedSeq + 1
            return cachedSeq + 1
        }
        let last = Self.readAll(fileURL: fileURL).last?.seq ?? 0
        cachedSeq = last + 1
        return last + 1
    }

    private func resolvedJournalId() -> String {
        if let cachedJournalId { return cachedJournalId }
        let existing = Self.readAll(fileURL: fileURL).last?.journalId
        let id = (existing?.isEmpty == false) ? existing! : UUID().uuidString.prefix(8).lowercased()
        let resolved = String(id)
        cachedJournalId = resolved
        return resolved
    }

    private func rotateIfNeeded(incomingBytes: Int) {
        let size = ((try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? Int) ?? 0
        guard size + incomingBytes > maxBytes else { return }
        let backup = fileURL.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: fileURL, to: backup)
        // Neue Generation: Cursor der alten Generation sind damit erkennbar
        // ungültig und liefern `gap: true` statt still ab „jetzt" fortzufahren.
        cachedJournalId = UUID().uuidString.prefix(8).lowercased()
        cachedSeq = 0
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
