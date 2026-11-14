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
    /// Betroffene Session. Nur bei Board-Ereignissen ohne Einzel-Chat
    /// (`clear`/`activate`/`deactivate`) leer.
    var sessionID: UUID?
    /// Vorheriger Laufzeitstatus (`nil` = es gab noch keine Meinung).
    var from: String?
    var to: String?
    /// Auslösendes Signal (`sessionStarted`, `toolWillRun`, `stopHook`, …) —
    /// ohne dieses Feld wäre ein Übergang nicht erklärbar, nur sichtbar.
    var signal: String
    /// `hook` = belegt durch ein Hook-Event, `transcript` = aus dem Transkript
    /// geschätzt. Der Unterschied entscheidet, wie belastbar die Zeile ist.
    var source: String
    /// Ereignisart. `nil` (alle Zeilen aus Vorversionen) = Statuswechsel einer
    /// Konversation; `board` = Änderung am Jarvis-Board. Die folgenden Felder
    /// sind optional, damit alte Zeilen unverändert lesbar bleiben.
    var kind: String? = nil
    /// Board: `set|remove|clear|activate|deactivate|milestone`.
    var op: String? = nil
    /// Board: Session-ID des Jarvis, dem das Board gehört.
    var owner: UUID? = nil
    /// Board: Ampel nach `set` bzw. vor `remove`.
    var light: String? = nil
    /// Wer die Zeile geschrieben hat: `app` in der App, sonst `nil` (Tests,
    /// Zeilen von vor WM8-87). Ältere `swift test`-Läufe schrieben mit eigener
    /// Nummernfolge in dieselbe Generation; stehen markierte Zeilen in der
    /// Datei, zählen nur sie (`ChatsStatusJournal.usable`).
    var writer: String? = nil

    static let boardKind = "board"

    var isBoardEvent: Bool { kind == Self.boardKind }
}

/// Append-only-Protokoll der Statuswechsel. Gleiche Bauart wie
/// `ChatsAuditLog`: eine Schreibstelle (die App), Rotation bei Größe, die CLI
/// liest nur.
///
/// Bewusst schlank gehalten — es ersetzt kein Ereignis-Journal mit Cursor und
/// Replay, sondern liefert genau so viel Historie, wie eine Nachanalyse
/// braucht.
final class ChatsStatusJournal: @unchecked Sendable {
    static let shared = ChatsStatusJournal(
        fileURL: sharedFileURL(), writer: AppInstance.isAppBundleProcess ? appWriter : nil)

    static let appWriter = "app"

    /// Schreibziel von `shared`: das echte Journal nur in der App (WM8-87).
    /// Unter `swift test` schrieb der Status-Koordinator sonst ins Journal
    /// des Users: 14.11.2026 stammten 6.658 von 7.556 Zeilen von
    /// Test-Sitzungen, mit eigener Nummernfolge (Sprünge) und einer Rotation
    /// alle paar Stunden. Die CLI liest weiter `defaultFileURL()`.
    static func sharedFileURL(isAppProcess: Bool = AppInstance.isAppBundleProcess) -> URL {
        guard !isAppProcess else { return defaultFileURL() }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("whisperm8-tests", isDirectory: true)
            .appendingPathComponent("chats-status-journal.jsonl")
    }

    private let lock = NSLock()
    private let fileURL: URL
    private let maxBytes: Int
    private let writer: String?

    init(fileURL: URL? = nil, maxBytes: Int = 2 * 1_048_576, writer: String? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        self.maxBytes = maxBytes
        self.writer = writer
    }

    static func defaultFileURL() -> URL {
        AppInstance.applicationSupport
            .appendingPathComponent("WhisperM8", isDirectory: true)
            .appendingPathComponent("chats-status-journal.jsonl")
    }

    /// Schreibt einen Übergang. No-op, wenn sich der Status nicht geändert hat —
    /// ein Journal voller identischer Zeilen verdeckt die echten Wechsel.
    func append(sessionID: UUID, from: String?, to: String?, signal: String, source: String, at: Date = Date()) {
        guard from != to else { return }
        lock.lock()
        defer { lock.unlock() }
        writeLocked(ChatsStatusJournalEntry(
            at: at, sessionID: sessionID, from: from, to: to, signal: signal, source: source))
    }

    /// Schreibt eine Board-Änderung. Läuft bewusst NICHT durch den
    /// `from != to`-Guard von `append` — ein Board-Ereignis hat keinen
    /// Statuswechsel und wäre dort immer verworfen worden. Selbe Sequenz und
    /// Generation wie die Statuswechsel, damit ein einziger Cursor beides trägt.
    func appendBoard(op: String, owner: UUID, sessionID: UUID?, light: String?, at: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        writeLocked(ChatsStatusJournalEntry(
            at: at, sessionID: sessionID, from: nil, to: nil, signal: "board.\(op)", source: Self.boardSource,
            kind: ChatsStatusJournalEntry.boardKind, op: op, owner: owner, light: light))
    }

    static let boardSource = "board"

    /// Aufrufer hält `lock`. Nummer und Generation stempelt erst diese
    /// Funktion, NACH der Rotation (WM8-87): Vorher bekam der Eintrag, der
    /// die Rotation auslöste, noch Nummer und Generation der alten Datei und
    /// stand dann als erste Zeile in der neuen. `changes()` hielt ihn für den
    /// ältesten Eintrag, jeder Cursor galt als Lücke, `chats watch` endete
    /// sofort, und die Board-Mod startete im 2-s-Takt neu.
    private func writeLocked(_ unstamped: ChatsStatusJournalEntry) {
        // Größe vorab mit einer großzügigen Nummer schätzen; die echte steht
        // erst nach der Rotation fest.
        var probe = unstamped
        probe.seq = Int(Int32.max)
        probe.journalId = "00000000"
        guard let estimate = try? Self.encoder.encode(probe) else { return }
        rotateIfNeeded(incomingBytes: estimate.count + 1)
        var entry = unstamped
        entry.seq = nextSequence()
        entry.journalId = resolvedJournalId()
        entry.writer = writer
        guard let data = try? Self.encoder.encode(entry) else { return }
        var line = data
        line.append(0x0A)
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
        // Leistung (Vic, 13.11.2026): Dekodiert wird nur, was die UUID der
        // Sitzung enthält; JSONEncoder schreibt sie groß. Ohne diese Prüfung
        // dekodierte `chats show` bei einer ruhigen Sitzung jede Zeile.
        let needle = sessionID.uuidString
        var found: [ChatsStatusJournalEntry] = []
        // Nach einer Rotation liegen ältere Zeilen in `<datei>.1` (im echten
        // Workspace schon geschehen). Neueste zuerst: erst die aktuelle Datei,
        // die rotierte nur, wenn die aktuelle nicht reicht.
        for candidate in [url, url.appendingPathExtension("1")] {
            guard let data = try? Data(contentsOf: candidate, options: .mappedIfSafe) else { continue }
            for range in lineRanges(containing: Array(needle.utf8), in: data).reversed() {
                guard let entry = try? decoder.decode(ChatsStatusJournalEntry.self, from: data.subdata(in: range))
                else { continue }
                // Board-Ereignisse sind keine Statuswechsel — die Historie einer
                // Session (`chats show`) bliebe sonst nicht mehr erklärbar.
                guard entry.sessionID == sessionID, !entry.isBoardEvent else { continue }
                found.append(entry)
                if found.count >= limit { return found.reversed() }
            }
        }
        return found.reversed()
    }

    /// Zeilen (ohne Zeilenende), die `needle` enthalten, in Dateireihenfolge.
    /// Sucht mit `memmem` in den Bytes; Zerlegen und Suchen in Swift-Strings
    /// kostete bei 16.000 Zeilen rund 300 ms je `chats show` (Debug-Build).
    static func lineRanges(containing needle: [UInt8], in data: Data) -> [Range<Int>] {
        guard !needle.isEmpty, !data.isEmpty else { return [] }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Range<Int>] in
            guard let base = raw.baseAddress else { return [] }
            let count = raw.count
            var ranges: [Range<Int>] = []
            var offset = 0
            while offset < count {
                guard let hit = needle.withUnsafeBytes({ memmem(base + offset, count - offset, $0.baseAddress, needle.count) })
                else { break }
                let position = UnsafeRawPointer(hit) - base
                var start = position
                while start > 0, raw[start - 1] != UInt8(ascii: "\n") { start -= 1 }
                var end = position
                while end < count, raw[end] != UInt8(ascii: "\n") { end += 1 }
                ranges.append(start..<end)
                offset = end + 1
            }
            return ranges
        }
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
        let url = fileURL ?? defaultFileURL()
        // Für den Cursor genügt die letzte Zeile: nur das Ende lesen statt
        // bis zu 2 MB (läuft bei jedem `chats board --json`, WM8-87).
        let tail = readTail(fileURL: url)
        // Nur verlässlich, wenn das Ende eine Zeile der App enthält; sonst
        // könnten markierte Zeilen weiter oben stehen (ein Testlauf schrieb
        // zuletzt viel).
        if tail.contains(where: { $0.writer != nil }) { return currentCursor(entries: tail) }
        let all = readAll(fileURL: url)
        if all.isEmpty { return currentCursor(entries: tail) }
        return currentCursor(entries: all)
    }

    /// Die vollständigen Zeilen in den letzten `bytes` Bytes der Datei, in
    /// Dateireihenfolge. Leer, wenn die Datei fehlt oder dort keine Zeile
    /// lesbar ist (der Aufrufer liest dann alles).
    static func readTail(fileURL: URL, bytes: Int = 16_384) -> [ChatsStatusJournalEntry] {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              var data = try? handle.readToEnd() else { return [] }
        // Mitten in einer Zeile begonnen: bis zum ersten Zeilenende verwerfen.
        if start > 0 {
            guard let newline = data.firstIndex(of: 0x0A) else { return [] }
            data = data[data.index(after: newline)...]
        }
        return data.split(separator: 0x0A).compactMap { line in
            try? decoder.decode(ChatsStatusJournalEntry.self, from: Data(line))
        }
    }

    /// Wie `currentCursor(fileURL:)`, auf bereits gelesenen Einträgen (wer das
    /// Journal ohnehin liest, liest es so nur einmal).
    static func currentCursor(entries: [ChatsStatusJournalEntry]) -> String? {
        guard let last = usable(entries).last, !last.journalId.isEmpty else { return nil }
        return cursor(journalId: last.journalId, seq: last.seq)
    }

    /// Die Zeilen, die für Cursor zählen: Stehen Zeilen der App in der Datei,
    /// nur diese (fremde Schreiber vergeben eigene Nummern in derselben
    /// Generation). Ohne markierte Zeilen (Journale von vor WM8-87, Tests)
    /// alle.
    static func usable(_ entries: [ChatsStatusJournalEntry]) -> [ChatsStatusJournalEntry] {
        guard entries.contains(where: { $0.writer != nil }) else { return entries }
        return entries.filter { $0.writer != nil }
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
        changes(since: rawCursor, limit: limit, entries: readAll(fileURL: fileURL ?? defaultFileURL()))
    }

    /// Wie `changes(since:limit:fileURL:)`, auf bereits gelesenen Einträgen.
    static func changes(
        since rawCursor: String?,
        limit: Int = 64,
        entries: [ChatsStatusJournalEntry]
    ) -> (entries: [ChatsStatusJournalEntry], gap: Bool, hasMore: Bool, cursor: String?) {
        // Einträge ohne Generation stammen aus einer Vorversion und sind für
        // Cursor-Abfragen unbrauchbar — sie tragen keine Ordnung. Zählen darf
        // nur die aktuelle Generation (die der letzten Zeile): Ein Rest der
        // alten am Dateianfang (Journale vor WM8-87) machte sonst jeden
        // Cursor zur Lücke.
        let usable = usable(entries)
        let currentId = usable.last(where: { !$0.journalId.isEmpty })?.journalId
        let all = usable.filter { $0.journalId == currentId && currentId != nil }
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
        if let oldest = all.map(\.seq).min(), parsed.seq < oldest - 1 {
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
        adoptOrStartGeneration()
        if let cachedSeq {
            self.cachedSeq = cachedSeq + 1
            return cachedSeq + 1
        }
        let last = Self.readAll(fileURL: fileURL).last?.seq ?? 0
        cachedSeq = last + 1
        return last + 1
    }

    /// Erster Schreibvorgang eines markierten Schreibers (der App): Stammt die
    /// letzte Zeile nicht von ihm, beginnt eine neue Generation. Sonst hinge
    /// die App an Nummern, die ein Testlauf vergeben hat, und Cursor sprängen
    /// (WM8-87). Kostet Lesern genau eine saubere Lücke.
    private func adoptOrStartGeneration() {
        guard cachedSeq == nil, cachedJournalId == nil, let writer else { return }
        let last = Self.readAll(fileURL: fileURL).last
        guard let last, last.writer != writer || last.journalId.isEmpty else { return }
        cachedJournalId = UUID().uuidString.prefix(8).lowercased()
        cachedSeq = 0
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
