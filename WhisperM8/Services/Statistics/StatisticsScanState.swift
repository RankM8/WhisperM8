import Foundation

// Was der Protokoll-Leser zwischen zwei Läufen behält: je Datei einen Cursor
// (bis wohin gelesen) und die Menge schon gezählter Antworten (Dedup). Beides
// liegt neben `stats.json` im Statistik-Ordner, damit „Löschen…“ im Store
// es gleich mit entfernt.

/// Lesestand einer Protokolldatei.
struct StatisticsFileCursor: Codable, Equatable, Sendable {
    /// Größe und mtime beim letzten Lauf — sind beide gleich, wird die Datei
    /// gar nicht geöffnet.
    var size: Int64
    var mtime: Double
    /// Inode: eine ersetzte Datei (gleicher Pfad, neuer Inhalt) wird von vorn gelesen.
    var inode: UInt64
    /// Byte hinter dem letzten gelesenen Zeilenumbruch.
    var offset: Int64
    /// Nur Subagent-Dateien: Start schon gezählt?
    var subagentCounted: Bool?
    /// Nur Codex: letzter Gesamtstand, aktuelles Modell und Projekt der Datei.
    var codexTotals: CodexTokenTotals?
    var codexModel: String?
    var codexProject: String?

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
    /// Schlüssel: absoluter Pfad.
    var files: [String: StatisticsFileCursor] = [:]

    init(files: [String: StatisticsFileCursor] = [:]) {
        self.files = files
    }
}

/// Menge der schon gezählten Antworten als stabile 64-bit-Hashes.
///
/// Kompakt gehalten: auf der Platte eine sortierte Folge von UInt64 (8 Byte je
/// Antwort), im Speicher dasselbe Array plus eine kleine Menge für die Neuen
/// dieses Laufs. Eine Million Antworten kosten so 8 MB statt der ~40 MB eines
/// `Set<UInt64>`. Der Leser hält sie nur während eines Laufs im Speicher.
final class StatisticsDedupSet {
    private var sorted: [UInt64]
    private var added: Set<UInt64> = []

    init(sorted: [UInt64] = []) {
        self.sorted = sorted
    }

    var count: Int { sorted.count + added.count }
    var hasChanges: Bool { !added.isEmpty }

    /// `true`, wenn der Schlüssel neu war.
    @discardableResult
    func insert(_ key: UInt64) -> Bool {
        if containsSorted(key) { return false }
        return added.insert(key).inserted
    }

    func contains(_ key: UInt64) -> Bool {
        containsSorted(key) || added.contains(key)
    }

    /// Führt die Neuen in das sortierte Array ein (nach jedem Sichern).
    func consolidate() {
        guard !added.isEmpty else { return }
        let fresh = added.sorted()
        added.removeAll(keepingCapacity: false)
        var merged: [UInt64] = []
        merged.reserveCapacity(sorted.count + fresh.count)
        var i = 0, j = 0
        while i < sorted.count, j < fresh.count {
            if sorted[i] < fresh[j] {
                merged.append(sorted[i]); i += 1
            } else {
                merged.append(fresh[j]); j += 1
            }
        }
        merged.append(contentsOf: sorted[i...])
        merged.append(contentsOf: fresh[j...])
        sorted = merged
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

    /// Format: rohe UInt64 in Little Endian, aufsteigend sortiert.
    static func load(from url: URL) -> StatisticsDedupSet {
        guard let data = try? Data(contentsOf: url), data.count % 8 == 0 else { return StatisticsDedupSet() }
        var values = [UInt64](repeating: 0, count: data.count / 8)
        _ = values.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        for index in values.indices { values[index] = UInt64(littleEndian: values[index]) }
        // Schutz gegen eine von Hand veränderte Datei: Binärsuche braucht Ordnung.
        if zip(values, values.dropFirst()).contains(where: { $0 > $1 }) { values.sort() }
        return StatisticsDedupSet(sorted: values)
    }

    func save(to url: URL) throws {
        consolidate()
        // Alle Macs (arm64, x86_64) sind Little Endian — das Array geht 1:1 raus.
        let data = sorted.withUnsafeBufferPointer { Data(buffer: $0) }
        try data.write(to: url, options: .atomic)
    }
}

/// Pfade und Laden/Sichern des Lesestands.
struct StatisticsScanStateFiles {
    var directory: URL

    var cursorsURL: URL { directory.appendingPathComponent("log-cursors.json", isDirectory: false) }
    var dedupURL: URL { directory.appendingPathComponent("log-dedup.bin", isDirectory: false) }

    func loadCursors() -> StatisticsScanCursors {
        guard let data = try? Data(contentsOf: cursorsURL),
              let decoded = try? JSONDecoder().decode(StatisticsScanCursors.self, from: data),
              decoded.version == StatisticsScanCursors.currentVersion
        else { return StatisticsScanCursors() }
        return decoded
    }

    func saveCursors(_ cursors: StatisticsScanCursors) throws {
        try ensureDirectory()
        let data = try JSONEncoder().encode(cursors)
        try data.write(to: cursorsURL, options: .atomic)
    }

    func loadDedup() -> StatisticsDedupSet {
        StatisticsDedupSet.load(from: dedupURL)
    }

    func saveDedup(_ dedup: StatisticsDedupSet) throws {
        try ensureDirectory()
        try dedup.save(to: dedupURL)
    }

    var cursorsExist: Bool { FileManager.default.fileExists(atPath: cursorsURL.path) }

    /// „Neu einlesen“: Cursor und Dedup weg.
    func removeAll() {
        try? FileManager.default.removeItem(at: cursorsURL)
        try? FileManager.default.removeItem(at: dedupURL)
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}
