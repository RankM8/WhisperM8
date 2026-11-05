import Foundation
import os

/// Einziger Halter der Statistik-Daten (`statistics/stats.json`).
///
/// Alle Zugriffe laufen über eine eigene serielle Queue mit `.utility`-Priorität.
/// Der Main-Thread schreibt nie selbst: Zähler rufen `update` (asynchron, kehrt
/// sofort zurück), gespeichert wird gebündelt höchstens alle `saveDelay`
/// Sekunden. Die Oberfläche bekommt `didChangeNotification` gedrosselt auf dem
/// Main-Thread und holt sich dann einen Schnappschuss.
final class StatisticsStore: @unchecked Sendable {
    static let shared = StatisticsStore()

    /// Wird höchstens alle `notifyInterval` Sekunden auf dem Main-Thread gepostet.
    static let didChangeNotification = Notification.Name("WhisperM8.StatisticsStore.didChange")

    private let queue = DispatchQueue(label: "com.whisperm8.statistics.store", qos: .utility)
    private let fileURL: URL
    private let saveDelay: TimeInterval
    private let notifyInterval: TimeInterval
    private let notificationCenter: NotificationCenter
    private let logger = os.Logger(subsystem: "com.whisperm8.app", category: "statistics")

    // Nur auf `queue` anfassen.
    private var database: StatsDatabase?
    private var savePending = false
    private var notifyPending = false
    private var lastNotify: Date = .distantPast

    init(
        directory: URL = StatisticsStore.defaultDirectory,
        saveDelay: TimeInterval = 60,
        notifyInterval: TimeInterval = 2,
        notificationCenter: NotificationCenter = .default
    ) {
        self.fileURL = directory.appendingPathComponent("stats.json", isDirectory: false)
        self.saveDelay = saveDelay
        self.notifyInterval = notifyInterval
        self.notificationCenter = notificationCenter
    }

    /// `~/Library/Application Support/WhisperM8/statistics/`
    static var defaultDirectory: URL {
        AppInstance.applicationSupport
            .appendingPathComponent("WhisperM8", isDirectory: true)
            .appendingPathComponent("statistics", isDirectory: true)
    }

    var directory: URL { fileURL.deletingLastPathComponent() }

    // MARK: - Zugriff

    /// Ändert die Daten asynchron auf der Store-Queue.
    func update(_ body: @escaping @Sendable (inout StatsDatabase) -> Void) {
        queue.async { [self] in
            var db = loadIfNeeded()
            let before = db
            body(&db)
            guard db != before else { return }
            database = db
            scheduleSave()
            scheduleNotify()
        }
    }

    /// Ändert einen Tag. Bequemlichkeit für die Zähler.
    func updateDay(_ date: Date, calendar: Calendar = .current, _ body: @escaping @Sendable (inout StatsDay) -> Void) {
        let key = StatisticsTime.dayKey(for: date, calendar: calendar)
        update { db in db.updateDay(key, body) }
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
    /// im selben Ordner und gehen mit.
    func reset() {
        queue.async { [self] in
            database = StatsDatabase()
            savePending = false
            try? FileManager.default.removeItem(at: directory)
            scheduleNotify(force: true)
        }
    }

    // MARK: - Intern

    private func loadIfNeeded() -> StatsDatabase {
        if let database { return database }
        let loaded = readFromDisk()
        database = loaded
        return loaded
    }

    private func readFromDisk() -> StatsDatabase {
        guard let data = try? Data(contentsOf: fileURL) else { return StatsDatabase() }
        do {
            return try JSONDecoder.statistics.decode(StatsDatabase.self, from: data)
        } catch {
            // Kaputte Datei zur Seite legen statt zu überschreiben: so bleibt sie
            // für eine Nachanalyse erhalten.
            let quarantine = fileURL.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: quarantine)
            logger.error("statistics_store_corrupt moved=\(quarantine.lastPathComponent, privacy: .public)")
            return StatsDatabase()
        }
    }

    private func scheduleSave() {
        guard !savePending else { return }
        savePending = true
        queue.asyncAfter(deadline: .now() + saveDelay) { [self] in
            guard savePending else { return }
            savePending = false
            writeToDisk()
        }
    }

    private func writeToDisk() {
        guard let database else { return }
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try JSONEncoder.statistics.encode(database)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("statistics_store_write_failed error=\(error.localizedDescription, privacy: .public)")
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
