import Foundation
import os

/// Einziger Halter der Statistik-Daten (Ordner `statistics/`).
///
/// Alle Zugriffe laufen über eine eigene serielle Queue mit `.utility`-Priorität.
/// Der Main-Thread schreibt nie selbst: Zähler rufen `update` (asynchron, kehrt
/// sofort zurück), gespeichert wird gebündelt höchstens alle `saveDelay`
/// Sekunden. Die Oberfläche bekommt `didChangeNotification` gedrosselt auf dem
/// Main-Thread und holt sich dann einen Schnappschuss.
///
/// Auf der Platte liegen die Daten verteilt, damit jede Minute nur wenige KB
/// geschrieben werden statt der ganzen Historie:
/// - `stats-meta.json`: alles außer den Tageswerten (Limits, Backfill, letzter Lauf);
/// - `days/<yyyy-MM-dd>.json`: je ein Tag des laufenden Monats;
/// - `months/<yyyy-MM>.json`: alle Tage eines vergangenen Monats.
/// Geschrieben werden nur geänderte Tage bzw. Monate. Die alte Gesamtdatei
/// `stats.json` wird beim ersten Laden übernommen und danach entfernt.
final class StatisticsStore: @unchecked Sendable {
    static let shared = StatisticsStore()

    /// Wird höchstens alle `notifyInterval` Sekunden auf dem Main-Thread gepostet.
    static let didChangeNotification = Notification.Name("WhisperM8.StatisticsStore.didChange")

    static let metaFileName = "stats-meta.json"
    static let legacyFileName = "stats.json"

    private let queue = DispatchQueue(label: "com.whisperm8.statistics.store", qos: .utility)
    let directory: URL
    private let saveDelay: TimeInterval
    private let notifyInterval: TimeInterval
    private let notificationCenter: NotificationCenter
    private let now: () -> Date
    private let logger = os.Logger(subsystem: "com.whisperm8.app", category: "statistics")
    /// Wird bei jedem „Löschen…“ erhöht. Hintergrund-Läufe merken sich den
    /// Wert beim Start und sichern nur, solange er noch stimmt.
    private let generationLock = OSAllocatedUnfairLock(initialState: 0)

    // Nur auf `queue` anfassen.
    private var database: StatsDatabase?
    private var dirtyDays: Set<String> = []
    private var metaDirty = false
    /// Tagesdateien, die gerade auf der Platte liegen (für das Zusammenlegen
    /// zu Monatsdateien nach einem Monatswechsel).
    private var dayFilesOnDisk: Set<String> = []
    private var savePending = false
    private var notifyPending = false
    private var lastNotify: Date = .distantPast

    init(
        directory: URL = StatisticsStore.defaultDirectory,
        saveDelay: TimeInterval = 60,
        notifyInterval: TimeInterval = 2,
        notificationCenter: NotificationCenter = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.directory = directory
        self.saveDelay = saveDelay
        self.notifyInterval = notifyInterval
        self.notificationCenter = notificationCenter
        self.now = now
    }

    /// `~/Library/Application Support/WhisperM8/statistics/`
    static var defaultDirectory: URL {
        AppInstance.applicationSupport
            .appendingPathComponent("WhisperM8", isDirectory: true)
            .appendingPathComponent("statistics", isDirectory: true)
    }

    private var metaURL: URL { directory.appendingPathComponent(Self.metaFileName, isDirectory: false) }
    private var legacyURL: URL { directory.appendingPathComponent(Self.legacyFileName, isDirectory: false) }
    private var daysDirectory: URL { directory.appendingPathComponent("days", isDirectory: true) }
    private var monthsDirectory: URL { directory.appendingPathComponent("months", isDirectory: true) }

    // MARK: - Generation

    /// Aktuelle Generation; ändert sich mit jedem `reset()`.
    var generation: Int { generationLock.withLock { $0 } }

    /// Führt `body` synchron auf der Store-Queue aus, aber nur, wenn seit dem
    /// Start des Aufrufers nicht gelöscht wurde. Läufe sichern so ihren
    /// Lesestand, ohne dass ein „Löschen…“ dazwischenfunken kann: Das Löschen
    /// des Ordners läuft auf derselben Queue. Nie von der Store-Queue aus rufen.
    @discardableResult
    func performIfCurrent(_ expected: Int, _ body: () -> Void) -> Bool {
        queue.sync {
            guard generation == expected else { return false }
            body()
            return true
        }
    }

    // MARK: - Zugriff

    /// Ändert die Daten asynchron auf der Store-Queue. Mit `ifGeneration`
    /// verfällt die Änderung, wenn inzwischen gelöscht wurde.
    func update(ifGeneration expected: Int? = nil, _ body: @escaping @Sendable (inout StatsDatabase) -> Void) {
        queue.async { [self] in
            if let expected, expected != generation { return }
            var db = loadIfNeeded()
            let before = db
            body(&db)
            let changed = Self.changedDays(from: before.days, to: db.days)
            let meta = !db.metaEquals(before)
            guard !changed.isEmpty || meta else { return }
            database = db
            dirtyDays.formUnion(changed)
            if meta { metaDirty = true }
            scheduleSave()
            scheduleNotify()
        }
    }

    /// Ändert einen Tag. Vergleicht nur diesen einen Tag statt der ganzen Historie.
    func updateDay(_ date: Date, calendar: Calendar = .current, _ body: @escaping @Sendable (inout StatsDay) -> Void) {
        let key = StatisticsTime.dayKey(for: date, calendar: calendar)
        queue.async { [self] in
            var db = loadIfNeeded()
            let old = db.days[key]
            var day = old ?? StatsDay()
            body(&day)
            guard day != old else { return }
            db.days[key] = day
            database = db
            dirtyDays.insert(key)
            scheduleSave()
            scheduleNotify()
        }
    }

    /// Schnappschuss für die Oberfläche (nie auf dem Main-Thread blockierend).
    func snapshot() async -> StatsDatabase {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: loadIfNeeded())
            }
        }
    }

    /// Synchroner Schnappschuss — nur für Tests und Hintergrund-Queues.
    func snapshotSync() -> StatsDatabase {
        queue.sync { loadIfNeeded() }
    }

    /// Schreibt ausstehende Änderungen sofort (App-Ende, Tests).
    func flush() {
        queue.sync { [self] in
            guard savePending else { return }
            savePending = false
            writeToDisk()
        }
    }

    /// Löscht alle Statistik-Daten (Knopf „Löschen…“). Protokoll-Cursor liegen
    /// im selben Ordner und gehen mit. Die Generation steigt sofort, damit
    /// laufende Sammler ab jetzt nichts mehr sichern.
    func reset() {
        generationLock.withLock { $0 += 1 }
        queue.async { [self] in
            database = StatsDatabase()
            dirtyDays = []
            metaDirty = false
            dayFilesOnDisk = []
            savePending = false
            try? FileManager.default.removeItem(at: directory)
            scheduleNotify(force: true)
        }
    }

    // MARK: - Laden

    private func loadIfNeeded() -> StatsDatabase {
        if let database { return database }
        let loaded = readFromDisk()
        database = loaded
        return loaded
    }

    private func readFromDisk() -> StatsDatabase {
        let fm = FileManager.default
        // `stats-meta.json` ist das Fertig-Zeichen der Übernahme.
        if !fm.fileExists(atPath: metaURL.path), fm.fileExists(atPath: legacyURL.path) { return migrateLegacyFile() }

        var db = decodeOrQuarantine(StatsDatabase.self, at: metaURL) ?? StatsDatabase()
        db.days = [:]
        for url in jsonFiles(in: monthsDirectory) {
            guard let segment = decodeOrQuarantine(StatsDaySegment.self, at: url) else { continue }
            db.days.merge(segment.days) { _, new in new }
        }
        let currentMonth = Self.monthKey(of: StatisticsTime.dayKey(for: now()))
        for url in jsonFiles(in: daysDirectory) {
            guard let segment = decodeOrQuarantine(StatsDaySegment.self, at: url) else { continue }
            // Tagesdateien sind neuer als eine Monatsdatei desselben Monats.
            db.days.merge(segment.days) { _, new in new }
            let key = url.deletingPathExtension().lastPathComponent
            dayFilesOnDisk.insert(key)
            // Ein vergangener Monat liegt noch tageweise da: beim nächsten
            // Sichern zu einer Monatsdatei zusammenlegen.
            if Self.monthKey(of: key) != currentMonth { dirtyDays.insert(key) }
        }
        // Reste einer abgebrochenen Übernahme der alten Gesamtdatei.
        if fm.fileExists(atPath: legacyURL.path) { try? fm.removeItem(at: legacyURL) }
        if !dirtyDays.isEmpty { scheduleSave() }
        return db
    }

    /// Übernimmt die alte Gesamtdatei `stats.json`: alles einmal in die neue
    /// Aufteilung schreiben, erst danach die alte Datei entfernen. Bricht das
    /// ab, fehlt `stats-meta.json` noch und der nächste Start übernimmt erneut.
    private func migrateLegacyFile() -> StatsDatabase {
        guard FileManager.default.fileExists(atPath: legacyURL.path),
              let legacy = decodeOrQuarantine(StatsDatabase.self, at: legacyURL)
        else { return StatsDatabase() }
        database = legacy
        dirtyDays = Set(legacy.days.keys)
        metaDirty = true
        if writeToDisk(metaRequiresDays: true) {
            try? FileManager.default.removeItem(at: legacyURL)
            logger.info("statistics_store_migrated days=\(legacy.days.count, privacy: .public)")
        } else {
            scheduleSave()
        }
        return legacy
    }

    private func decodeOrQuarantine<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder.statistics.decode(type, from: data)
        } catch {
            // Kaputte Datei zur Seite legen statt zu überschreiben: so bleibt sie
            // für eine Nachanalyse erhalten.
            let quarantine = url.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: quarantine)
            logger.error("statistics_store_corrupt moved=\(quarantine.lastPathComponent, privacy: .public)")
            return nil
        }
    }

    private func jsonFiles(in directory: URL) -> [URL] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") && !$0.contains("corrupt") }
            .sorted()
            .map { directory.appendingPathComponent($0, isDirectory: false) }
    }

    // MARK: - Sichern

    private func scheduleSave() {
        guard !savePending else { return }
        savePending = true
        queue.asyncAfter(deadline: .now() + saveDelay) { [self] in
            guard savePending else { return }
            savePending = false
            writeToDisk()
        }
    }

    /// Schreibt geänderte Tage (laufender Monat: je Tag, sonst je Monat) und
    /// bei Bedarf die Metadaten. Fehlgeschlagene Teile bleiben vorgemerkt.
    /// `metaRequiresDays`: Metadaten nur schreiben, wenn alle Tage sicher
    /// liegen — bei der Übernahme ist `stats-meta.json` das Fertig-Zeichen.
    @discardableResult
    private func writeToDisk(metaRequiresDays: Bool = false) -> Bool {
        guard let database, !dirtyDays.isEmpty || metaDirty else { return true }
        let fm = FileManager.default
        do {
            for dir in [directory, daysDirectory, monthsDirectory] {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
        } catch {
            logger.error("statistics_store_write_failed error=\(error.localizedDescription, privacy: .public)")
            return false
        }

        let currentMonth = Self.monthKey(of: StatisticsTime.dayKey(for: now()))
        // Nach einem Monatswechsel liegen noch Tagesdateien des Vormonats da.
        for key in dayFilesOnDisk where Self.monthKey(of: key) != currentMonth { dirtyDays.insert(key) }

        var failed: Set<String> = []
        var months: Set<String> = []
        for key in dirtyDays {
            let month = Self.monthKey(of: key)
            if month != currentMonth {
                months.insert(month)
                continue
            }
            let url = daysDirectory.appendingPathComponent("\(key).json", isDirectory: false)
            if let day = database.days[key] {
                if write(StatsDaySegment(days: [key: day]), to: url) { dayFilesOnDisk.insert(key) } else { failed.insert(key) }
            } else {
                try? fm.removeItem(at: url)
                dayFilesOnDisk.remove(key)
            }
        }
        for month in months {
            let days = database.days.filter { Self.monthKey(of: $0.key) == month }
            let url = monthsDirectory.appendingPathComponent("\(month).json", isDirectory: false)
            guard write(StatsDaySegment(days: days), to: url) else {
                failed.formUnion(dirtyDays.filter { Self.monthKey(of: $0) == month })
                continue
            }
            // Erst die Monatsdatei, dann die Tagesdateien weg: ein Absturz
            // dazwischen lässt nur doppelte, gleiche Werte zurück.
            for key in dayFilesOnDisk where Self.monthKey(of: key) == month {
                try? fm.removeItem(at: daysDirectory.appendingPathComponent("\(key).json", isDirectory: false))
                dayFilesOnDisk.remove(key)
            }
        }
        dirtyDays = failed

        if metaDirty, failed.isEmpty || !metaRequiresDays {
            var meta = database
            meta.days = [:]
            if write(meta, to: metaURL) { metaDirty = false }
        }
        return failed.isEmpty && !metaDirty
    }

    private func write<T: Encodable>(_ value: T, to url: URL) -> Bool {
        do {
            let data = try JSONEncoder.statistics.encode(value)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            logger.error("statistics_store_write_failed file=\(url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func scheduleNotify(force: Bool = false) {
        guard !notifyPending else { return }
        let wait = force ? 0 : max(0, notifyInterval - Date().timeIntervalSince(lastNotify))
        notifyPending = true
        queue.asyncAfter(deadline: .now() + wait) { [self] in
            notifyPending = false
            lastNotify = Date()
            let center = notificationCenter
            DispatchQueue.main.async {
                center.post(name: StatisticsStore.didChangeNotification, object: nil)
            }
        }
    }

    // MARK: - Hilfen

    /// `2026-11-05` → `2026-11`.
    static func monthKey(of dayKey: String) -> String { String(dayKey.prefix(7)) }

    /// Tage, die neu sind, sich geändert haben oder weggefallen sind.
    static func changedDays(from before: [String: StatsDay], to after: [String: StatsDay]) -> Set<String> {
        var changed: Set<String> = []
        for (key, day) in after where before[key] != day { changed.insert(key) }
        if after.count - changed.count != before.count {
            for key in before.keys where after[key] == nil { changed.insert(key) }
        }
        return changed
    }
}

/// Inhalt einer Tages- oder Monatsdatei.
struct StatsDaySegment: Codable, Equatable {
    var days: [String: StatsDay]
}

extension StatsDatabase {
    /// Gleich bis auf die Tageswerte?
    func metaEquals(_ other: StatsDatabase) -> Bool {
        version == other.version
            && limits == other.limits
            && backfill == other.backfill
            && lastScan == other.lastScan
            && chatsBackfilled == other.chatsBackfilled
    }
}

extension JSONEncoder {
    static var statistics: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var statistics: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
