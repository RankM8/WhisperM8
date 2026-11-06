import Foundation

// Was der Protokoll-Leser zwischen zwei Läufen behält: je Datei einen Cursor
// (bis wohin gelesen) und die Menge schon gezählter Antworten (Dedup). Beides
// liegt neben den Statistik-Daten im Statistik-Ordner, damit „Löschen…“ im
// Store es gleich mit entfernt.
//
// Schreiblast: Beide Dateien wachsen mit der Historie (Millionen Bytes), ein
// Lauf ändert aber nur wenige Einträge. Deshalb wird angehängt statt neu
// geschrieben — Cursor als Journal-Zeilen, Dedup als rohe Hashes — und nur
// gelegentlich verdichtet.

/// Lesestand einer Protokolldatei.
struct StatisticsFileCursor: Codable, Equatable, Sendable {
    /// Größe und mtime beim letzten Lauf — sind beide gleich, wird die Datei
    /// gar nicht geöffnet.
    var size: Int64
    var mtime: Double
    /// Inode: eine ersetzte Datei (gleicher Pfad, neuer Inhalt) wird von vorn gelesen.
    var inode: UInt64
    /// Byte hinter dem letzten gelesenen Zeilenumbruch (bei `.zst`: im entpackten Strom).
    var offset: Int64
    /// Nur Subagent-Dateien: Start schon gezählt?
    var subagentCounted: Bool?
    /// Nur Codex: letzter Gesamtstand, aktuelles Modell und Projekt der Datei.
    var codexTotals: CodexTokenTotals?
    var codexModel: String?
    var codexProject: String?
    /// Nur Codex (Schlüssel = Thread-UUID): Pfad der zuletzt gelesenen Datei.
    /// Ändert er sich (verschoben, komprimiert, entpackt), wird die Datei
    /// neu gelesen, gezählt wird aber nur über den alten Gesamtstand hinaus.
    var path: String?

    init(size: Int64 = 0, mtime: Double = 0, inode: UInt64 = 0, offset: Int64 = 0) {
        self.size = size
        self.mtime = mtime
        self.inode = inode
        self.offset = offset
    }
}

struct StatisticsScanCursors: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int = StatisticsScanCursors.currentVersion
    /// Schlüssel: absoluter Pfad, bei Codex `codex:<thread-uuid>`.
    var files: [String: StatisticsFileCursor] = [:]
    /// Höchste Journal-Nummer, die schon in dieser Basisdatei steckt.
    var seq: Int?

    init(files: [String: StatisticsFileCursor] = [:], seq: Int? = nil) {
        self.files = files
        self.seq = seq
    }
}

// MARK: - Cursor auf der Platte

/// Basisdatei `log-cursors.json` plus Journal `log-cursors.journal`.
///
/// Ein Lauf hängt nur geänderte Einträge als JSON-Zeile an (`{"s":…,"k":…,"c":…}`,
/// ohne `c` = entfernt). Wird das Journal größer als die halbe Basis, schreibt
/// der nächste Lauf die Basis neu (atomar) und beginnt ein leeres Journal.
/// Die Laufnummer `s` macht das absturzsicher: Zeilen, die schon in der Basis
/// stecken (`s <= seq`), werden beim Laden übersprungen; eine halbe letzte
/// Zeile wird verworfen und erzwingt die Verdichtung.
final class StatisticsCursorPersistence {
    /// Ab dieser Journalgröße wird spätestens verdichtet.
    static let minimumCompactionBytes = 256 << 10

    let files: StatisticsScanStateFiles
    /// Stand auf der Platte (Basis + Journal).
    private(set) var saved: [String: StatisticsFileCursor]
    private var seq: Int
    private var baseBytes: Int
    private var journalBytes: Int
    private var needsCompaction: Bool
    /// Für Tests und Messungen: Bytes des letzten `save`.
    private(set) var lastWrittenBytes = 0

    private init(files: StatisticsScanStateFiles, saved: [String: StatisticsFileCursor], seq: Int, baseBytes: Int, journalBytes: Int, needsCompaction: Bool) {
        self.files = files
        self.saved = saved
        self.seq = seq
        self.baseBytes = baseBytes
        self.journalBytes = journalBytes
        self.needsCompaction = needsCompaction
    }

    private struct JournalEntry: Codable {
        var s: Int
        var k: String
        var c: StatisticsFileCursor?
    }

    static func load(_ files: StatisticsScanStateFiles) -> StatisticsCursorPersistence {
        var cursors: [String: StatisticsFileCursor] = [:]
        var seq = 0
        var baseBytes = 0
        var needsCompaction = false
        if let data = try? Data(contentsOf: files.cursorsURL),
           let decoded = try? JSONDecoder().decode(StatisticsScanCursors.self, from: data),
           decoded.version == StatisticsScanCursors.currentVersion {
            cursors = decoded.files
            seq = decoded.seq ?? 0
            baseBytes = data.count
        }
        var journalBytes = 0
        if let journal = try? Data(contentsOf: files.journalURL), !journal.isEmpty {
            journalBytes = journal.count
            if journal.last != 0x0A { needsCompaction = true }
            let decoder = JSONDecoder()
            let baseSeq = seq
            for line in journal.split(separator: 0x0A) {
                guard let entry = try? decoder.decode(JournalEntry.self, from: Data(line)) else {
                    needsCompaction = true
                    continue
                }
                // Schon in der Basis enthalten (Absturz nach dem Verdichten).
                guard entry.s > baseSeq else { continue }
                if let cursor = entry.c { cursors[entry.k] = cursor } else { cursors.removeValue(forKey: entry.k) }
                seq = max(seq, entry.s)
            }
        }
        if migrateCodexKeys(&cursors) { needsCompaction = true }
        return StatisticsCursorPersistence(
            files: files,
            saved: cursors,
            seq: seq,
            baseBytes: baseBytes,
            journalBytes: journalBytes,
            needsCompaction: needsCompaction
        )
    }

    /// Ältere Stände führten Codex-Dateien unter ihrem Pfad. Umschlüsseln auf
    /// die Thread-UUID, sonst würde jede Codex-Datei ohne Vorstand neu gezählt.
    private static func migrateCodexKeys(_ cursors: inout [String: StatisticsFileCursor]) -> Bool {
        var changed = false
        for (key, cursor) in cursors where key.hasPrefix("/") {
            let name = (key as NSString).lastPathComponent
            guard name.hasPrefix("rollout-"), let id = StatisticsLogFile.codexThreadID(fromFileName: name) else { continue }
            var moved = cursor
            moved.path = key
            cursors.removeValue(forKey: key)
            cursors[StatisticsLogFile.codexKeyPrefix + id] = moved
            changed = true
        }
        return changed
    }

    /// Sichert `current`: hängt nur Unterschiede zum letzten Stand an oder
    /// verdichtet. Ohne Unterschied wird nichts geschrieben.
    func save(_ current: [String: StatisticsFileCursor]) throws {
        lastWrittenBytes = 0
        let baseMissing = !FileManager.default.fileExists(atPath: files.cursorsURL.path)
        var entries: [JournalEntry] = []
        let nextSeq = seq + 1
        for (key, cursor) in current where saved[key] != cursor {
            entries.append(JournalEntry(s: nextSeq, k: key, c: cursor))
        }
        if current.count - entries.count != saved.count {
            for key in saved.keys where current[key] == nil {
                entries.append(JournalEntry(s: nextSeq, k: key, c: nil))
            }
        }
        guard !entries.isEmpty || needsCompaction || baseMissing else { return }

        let encoder = JSONEncoder()
        var lines = Data()
        for entry in entries {
            lines.append(try encoder.encode(entry))
            lines.append(0x0A)
        }
        let threshold = max(Self.minimumCompactionBytes, baseBytes / 2)
        if needsCompaction || baseMissing || journalBytes + lines.count > threshold {
            try compact(current, seq: nextSeq)
        } else {
            try files.ensureDirectory()
            try StatisticsAppendFile.append(lines, to: files.journalURL)
            journalBytes += lines.count
            lastWrittenBytes = lines.count
        }
        seq = nextSeq
        saved = current
    }

    private func compact(_ current: [String: StatisticsFileCursor], seq: Int) throws {
        try files.ensureDirectory()
        let data = try JSONEncoder().encode(StatisticsScanCursors(files: current, seq: seq))
        try data.write(to: files.cursorsURL, options: .atomic)
        // Nach der atomaren Basis: alte Journal-Zeilen haben `s <= seq` und
        // würden beim Laden ohnehin übersprungen.
        try? FileManager.default.removeItem(at: files.journalURL)
        baseBytes = data.count
        journalBytes = 0
        needsCompaction = false
        lastWrittenBytes = data.count
    }
}

/// Anhängen an eine Datei mit `O_APPEND` (eigener, close-on-exec Deskriptor).
enum StatisticsAppendFile {
    static func append(_ data: Data, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        try data.withUnsafeBytes { raw in
            guard var base = raw.baseAddress else { return }
            var left = raw.count
            while left > 0 {
                let written = write(fd, base, left)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                left -= written
                base += written
            }
        }
    }
}

// MARK: - Dedup

/// Menge der schon gezählten Antworten als stabile 64-bit-Hashes.
///
/// Kompakt gehalten: im Speicher ein sortiertes Array von UInt64 (8 Byte je
/// Antwort) plus eine kleine Menge für die Neuen dieses Laufs. Eine Million
/// Antworten kosten so 8 MB statt der ~40 MB eines `Set<UInt64>`. Der Leser
/// hält sie nur während eines Laufs im Speicher.
///
/// Auf der Platte: rohe UInt64 in Little Endian. Vorne ein sortierter Block,
/// dahinter unsortiert angehängte Neue. Gesichert werden nur die Neuen; erst
/// wenn der angehängte Teil ein Viertel des Blocks übersteigt, wird die Datei
/// sortiert neu geschrieben.
final class StatisticsDedupSet {
    /// Unter dieser Größe des angehängten Teils wird nie verdichtet.
    static let minimumCompactionCount = 32_768

    private var sorted: [UInt64]
    private var added: Set<UInt64> = []
    /// Anzahl angehängter (unsortierter) Werte in der Datei.
    private var persistedTail = 0
    /// Datei hatte einen kaputten Rest oder Doppelte: beim nächsten Sichern neu schreiben.
    private var needsRewrite = false
    /// Für Tests und Messungen: Bytes des letzten `save`.
    private(set) var lastWrittenBytes = 0

    init(sorted: [UInt64] = []) {
        self.sorted = sorted
    }

    var count: Int { sorted.count + added.count }
    var hasChanges: Bool { !added.isEmpty || needsRewrite }

    /// `true`, wenn der Schlüssel neu war.
    @discardableResult
    func insert(_ key: UInt64) -> Bool {
        if containsSorted(key) { return false }
        return added.insert(key).inserted
    }

    func contains(_ key: UInt64) -> Bool {
        containsSorted(key) || added.contains(key)
    }

    /// Führt die Neuen in das sortierte Array ein.
    func consolidate() {
        guard !added.isEmpty else { return }
        let fresh = added.sorted()
        added.removeAll(keepingCapacity: false)
        sorted = Self.merge(sorted, fresh)
    }

    private static func merge(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        var merged: [UInt64] = []
        merged.reserveCapacity(a.count + b.count)
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] < b[j] {
                merged.append(a[i]); i += 1
            } else {
                merged.append(b[j]); j += 1
            }
        }
        merged.append(contentsOf: a[i...])
        merged.append(contentsOf: b[j...])
        return merged
    }

    private func containsSorted(_ key: UInt64) -> Bool {
        var low = 0
        var high = sorted.count - 1
        while low <= high {
            let mid = (low + high) >> 1
            let value = sorted[mid]
            if value == key { return true }
            if value < key { low = mid + 1 } else { high = mid - 1 }
        }
        return false
    }

    // MARK: - Platte

    static func load(from url: URL) -> StatisticsDedupSet {
        guard let data = try? Data(contentsOf: url), data.count >= 8 else { return StatisticsDedupSet() }
        let usable = data.count - data.count % 8
        var values = [UInt64](repeating: 0, count: usable / 8)
        _ = values.withUnsafeMutableBytes { data.copyBytes(to: $0, from: 0..<usable) }
        for index in values.indices { values[index] = UInt64(littleEndian: values[index]) }

        // Länge des sortierten Blocks vorne; der Rest ist angehängt.
        var prefix = values.isEmpty ? 0 : 1
        while prefix < values.count, values[prefix - 1] < values[prefix] { prefix += 1 }
        let tail = values.count - prefix
        var hadDuplicates = false
        if tail > 0 {
            values.sort()
            var write = 1
            for read in 1..<values.count where values[read] != values[write - 1] {
                values[write] = values[read]
                write += 1
            }
            hadDuplicates = write != values.count
            values.removeLast(values.count - write)
        }
        let set = StatisticsDedupSet(sorted: values)
        set.persistedTail = tail
        // Halbe letzte Zahl (Absturz beim Anhängen) oder Doppelte: neu schreiben,
        // damit spätere Anhänge wieder auf 8-Byte-Grenzen liegen.
        set.needsRewrite = usable != data.count || hadDuplicates
        return set
    }

    /// Sichert die Neuen dieses Laufs: anhängen oder, wenn der angehängte Teil
    /// zu groß wird, alles sortiert neu schreiben.
    func save(to url: URL) throws {
        lastWrittenBytes = 0
        guard hasChanges || !FileManager.default.fileExists(atPath: url.path) else { return }
        let fresh = Array(added)
        let threshold = max(Self.minimumCompactionCount, sorted.count / 4)
        let fileMissing = !FileManager.default.fileExists(atPath: url.path)
        if needsRewrite || fileMissing || persistedTail + fresh.count > threshold {
            consolidate()
            // Alle Macs (arm64, x86_64) sind Little Endian — das Array geht 1:1 raus.
            let data = sorted.withUnsafeBufferPointer { Data(buffer: $0) }
            try data.write(to: url, options: .atomic)
            persistedTail = 0
            needsRewrite = false
            lastWrittenBytes = data.count
            return
        }
        let data = fresh.withUnsafeBufferPointer { Data(buffer: $0) }
        try StatisticsAppendFile.append(data, to: url)
        persistedTail += fresh.count
        lastWrittenBytes = data.count
        consolidate()
    }
}

/// Pfade und Laden/Sichern des Lesestands.
struct StatisticsScanStateFiles {
    var directory: URL

    var cursorsURL: URL { directory.appendingPathComponent("log-cursors.json", isDirectory: false) }
    var journalURL: URL { directory.appendingPathComponent("log-cursors.journal", isDirectory: false) }
    var dedupURL: URL { directory.appendingPathComponent("log-dedup.bin", isDirectory: false) }

    func loadCursors() -> StatisticsCursorPersistence {
        StatisticsCursorPersistence.load(self)
    }

    func loadDedup() -> StatisticsDedupSet {
        StatisticsDedupSet.load(from: dedupURL)
    }

    func saveDedup(_ dedup: StatisticsDedupSet) throws {
        try ensureDirectory()
        try dedup.save(to: dedupURL)
    }

    /// „Neu einlesen“: Cursor und Dedup weg.
    func removeAll() {
        try? FileManager.default.removeItem(at: cursorsURL)
        try? FileManager.default.removeItem(at: journalURL)
        try? FileManager.default.removeItem(at: dedupURL)
    }

    func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}
