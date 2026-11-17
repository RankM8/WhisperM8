import Foundation

// MARK: - Ablage der geplanten Aufgaben

/// Pfade und Datei-Zugriff für `scheduled-tasks.json` und die Lauf-Ordner.
///
/// ```
/// ~/Library/Application Support/WhisperM8/
///   scheduled-tasks.json                  Aufgaben (schreibt nur die App)
///   scheduled-tasks/scheduler.lock        hält die planende App-Instanz
///   scheduled-tasks/runs/<Aufgabe>/<Lauf>/
///     run.json      Start-Eintrag (schreibt die App)
///     result.json   Ausgabe von `claude -p --output-format json` (schreibt der Lauf)
///     stderr.log    Fehlerausgabe des Laufs
///     exit          „<Exit-Code> <Ende in Unix-Sekunden>“ (schreibt der Lauf zuletzt)
/// ```
///
/// Ordner 0700, Dateien 0600. Die CLI liest dieselben Pfade, schreibt nie.
struct ScheduledTaskStore {
    var root: URL

    init(root: URL = ScheduledTaskStore.defaultRoot()) {
        self.root = root
    }

    static func defaultRoot() -> URL {
        AppInstance.applicationSupport.appendingPathComponent("WhisperM8", isDirectory: true)
    }

    var fileURL: URL { root.appendingPathComponent("scheduled-tasks.json") }
    var dataDirectory: URL { root.appendingPathComponent("scheduled-tasks", isDirectory: true) }
    var runsDirectory: URL { dataDirectory.appendingPathComponent("runs", isDirectory: true) }
    var lockURL: URL { dataDirectory.appendingPathComponent("scheduler.lock") }

    func runsDirectory(for taskID: UUID) -> URL {
        runsDirectory.appendingPathComponent(taskID.uuidString.lowercased(), isDirectory: true)
    }

    enum StoreError: LocalizedError, Equatable {
        /// Datei da, aber nicht lesbar (kaputt oder von einer neueren App).
        /// Dann schreibt die App nicht, damit nichts verloren geht.
        case unreadable(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let detail):
                return "scheduled-tasks.json ist nicht lesbar (\(detail)). Die App ändert sie deshalb nicht."
            case .writeFailed(let detail):
                return "scheduled-tasks.json ließ sich nicht schreiben: \(detail)"
            }
        }
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Fehlt die Datei, gibt es keine Aufgaben.
    func load() throws -> ScheduledTasksFile {
        guard let data = try? Data(contentsOf: fileURL) else {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                throw StoreError.unreadable("Lesefehler")
            }
            return ScheduledTasksFile()
        }
        let file: ScheduledTasksFile
        do {
            file = try Self.makeDecoder().decode(ScheduledTasksFile.self, from: data)
        } catch {
            throw StoreError.unreadable(String(describing: error).prefix(160).description)
        }
        guard file.version <= ScheduledTasksFile.currentVersion else {
            throw StoreError.unreadable("Version \(file.version) ist neuer als diese App")
        }
        return file
    }

    func save(_ file: ScheduledTasksFile) throws {
        do {
            try Self.ensureDirectory(root)
            let data = try Self.makeEncoder().encode(file)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            throw StoreError.writeFailed(error.localizedDescription)
        }
    }

    static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    // MARK: Lauf-Ordner

    /// Lauf-Ordner einer Aufgabe, neueste zuerst (Namen sortieren nach Zeit).
    func runDirectories(for taskID: UUID, limit: Int? = nil) -> [URL] {
        let directory = runsDirectory(for: taskID)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let sorted = names.filter { !$0.hasPrefix(".") }.sorted(by: >)
        let picked = limit.map { Array(sorted.prefix($0)) } ?? sorted
        return picked.map { directory.appendingPathComponent($0, isDirectory: true) }
    }

    /// Liest Eintrag und Ergebnis eines Lauf-Ordners.
    func readRun(at directory: URL) -> ScheduledTaskRunFiles? {
        guard let record = readRecord(at: directory) else { return nil }
        let exitText = try? String(contentsOf: directory.appendingPathComponent(ScheduledTaskRunFiles.exitName), encoding: .utf8)
        return ScheduledTaskRunFiles(
            directory: directory,
            record: record,
            exit: exitText.flatMap(ScheduledTaskRunExit.init(parsing:)),
            result: try? Data(contentsOf: directory.appendingPathComponent(ScheduledTaskRunFiles.resultName)),
            stderrTail: Self.tail(of: directory.appendingPathComponent(ScheduledTaskRunFiles.stderrName))
        )
    }

    /// Die letzten Läufe einer Aufgabe, neueste zuerst.
    func recentRuns(for taskID: UUID, limit: Int) -> [ScheduledTaskRunFiles] {
        runDirectories(for: taskID, limit: limit).compactMap(readRun(at:))
    }

    /// Jüngster Lauf, der wirklich gestartet wurde (oder gerade startet).
    /// Einträge ohne Prozess („übersprungen“, „verpasst“, „nicht gestartet“)
    /// überspringt er; liest dafür nur `run.json` der Ordner davor.
    func latestStartedRun(for taskID: UUID) -> ScheduledTaskRunFiles? {
        for directory in runDirectories(for: taskID) {
            guard let record = readRecord(at: directory) else { continue }
            if record.notStarted == nil { return readRun(at: directory) }
        }
        return nil
    }

    func readRecord(at directory: URL) -> ScheduledTaskRunRecord? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(ScheduledTaskRunFiles.recordName)) else { return nil }
        return try? Self.makeDecoder().decode(ScheduledTaskRunRecord.self, from: data)
    }

    func writeRecord(_ record: ScheduledTaskRunRecord, in directory: URL) throws {
        try Self.ensureDirectory(directory)
        let url = directory.appendingPathComponent(ScheduledTaskRunFiles.recordName)
        try Self.makeEncoder().encode(record).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Höchstens die letzten 4 KB, damit ein geschwätziger Lauf nichts aufbläht.
    static func tail(of url: URL, maxBytes: Int = 4096) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
