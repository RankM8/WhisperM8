import Foundation

/// In-Memory-Cache der ROHEN Datei-Inhalte von OutputModes.json, gekeyt nach
/// Datei-Pfad. Validierung über mtime+size-Stat statt Voll-Read pro Zugriff —
/// vorher hat jeder `.modes`-Zugriff (u. a. der 100-ms-Overlay-Tick!) die
/// Datei neu gelesen und dekodiert: 10 Disk-Reads + JSON-Decodes pro Sekunde
/// während jeder Aufnahme. `normalized(_:)` bleibt bewusst ungecacht (pure
/// In-Memory-Arbeit; liest defaultOutputModeID pro Aufruf, damit ein
/// Default-Mode-Wechsel sofort sichtbar ist).
private final class OutputModeDiskCache {
    static let shared = OutputModeDiskCache()

    private struct Entry {
        var modes: [OutputMode]
        var mtime: Date
        var size: Int
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func modes(forPath path: String, mtime: Date, size: Int) -> [OutputMode]? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[path], entry.mtime == mtime, entry.size == size else {
            return nil
        }
        return entry.modes
    }

    func store(_ modes: [OutputMode], forPath path: String, mtime: Date, size: Int) {
        lock.lock()
        defer { lock.unlock() }
        entries[path] = Entry(modes: modes, mtime: mtime, size: size)
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
    }
}

struct OutputModeStore {
    /// Wird nach jedem erfolgreichen `saveModes` gepostet. Konsumenten (z. B.
    /// das Recording-Overlay) können damit event-getrieben neu laden, statt
    /// pro Tick zu pollen.
    static let modesDidChangeNotification = Notification.Name("OutputModeStore.modesDidChange")

    private let fileURL: URL
    /// Test-Hook (Closure-DI nach Repo-Konvention): zählt/ersetzt die echten
    /// Datei-Reads. Default ist der reale Read.
    private let loader: (URL) throws -> Data

    init(fileURL: URL? = nil, loader: @escaping (URL) throws -> Data = { try Data(contentsOf: $0) }) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = Self.defaultFileURL()
        }
        self.loader = loader
    }

    var modes: [OutputMode] {
        var loadedModes = loadModes()
        if loadedModes.isEmpty {
            loadedModes = OutputMode.builtInModes
        }
        return normalized(loadedModes)
    }

    var enabledModes: [OutputMode] {
        modes.filter(\.isEnabled)
    }

    func mode(for id: String?) -> OutputMode {
        let requestedID = id?.isEmpty == false ? id : AppPreferences.shared.defaultOutputModeID
        return modes.first { $0.id == requestedID } ?? modes.first { $0.id == OutputMode.rawID } ?? OutputMode.builtInModes[0]
    }

    func saveModes(_ modes: [OutputMode]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let normalizedModes = normalized(modes)
        let data = try encoder.encode(normalizedModes)
        try data.write(to: fileURL, options: .atomic)

        // Cache direkt aktualisieren (mit dem Stat NACH dem Write) und die
        // Change-Notification posten.
        if let stat = Self.stat(atPath: fileURL.path) {
            OutputModeDiskCache.shared.store(normalizedModes, forPath: fileURL.path, mtime: stat.mtime, size: stat.size)
        }
        NotificationCenter.default.post(name: Self.modesDidChangeNotification, object: nil)
    }

    func createCustomMode() -> OutputMode {
        OutputMode(
            id: UUID().uuidString,
            name: "Custom Mode",
            shortLabel: "Custom",
            kind: .custom,
            templateID: PostProcessingTemplate.cleanID,
            isEnabled: true,
            isDefault: false
        )
    }

    /// Setzt den prozessweiten Disk-Cache zurück — ausschließlich für Tests
    /// (Cross-Test-Bleed über den statischen Cache verhindern).
    static func _resetCacheForTesting() {
        OutputModeDiskCache.shared.reset()
    }

    private func loadModes() -> [OutputMode] {
        // Billiger Stat statt Voll-Read: bei unverändertem mtime+size kommt
        // das Array aus dem Cache.
        guard let stat = Self.stat(atPath: fileURL.path) else { return [] }
        if let cached = OutputModeDiskCache.shared.modes(forPath: fileURL.path, mtime: stat.mtime, size: stat.size) {
            return cached
        }

        do {
            let data = try loader(fileURL)
            let modes = try JSONDecoder().decode([OutputMode].self, from: data)
            OutputModeDiskCache.shared.store(modes, forPath: fileURL.path, mtime: stat.mtime, size: stat.size)
            return modes
        } catch {
            Logger.debug("Failed to load output modes: \(error.localizedDescription)")
            return []
        }
    }

    private static func stat(atPath path: String) -> (mtime: Date, size: Int)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date else {
            return nil
        }
        return (mtime, (attrs[.size] as? Int) ?? 0)
    }

    private func normalized(_ modes: [OutputMode]) -> [OutputMode] {
        var byID = Dictionary(uniqueKeysWithValues: modes.map { ($0.id, $0) })

        for builtInMode in OutputMode.builtInModes where byID[builtInMode.id] == nil {
            byID[builtInMode.id] = builtInMode
        }

        let defaultID = AppPreferences.shared.defaultOutputModeID
        let builtInOrder = OutputMode.builtInModes.map(\.id)
        let builtIns = builtInOrder.compactMap { id -> OutputMode? in
            guard var mode = byID[id] else { return nil }
            mode.isDefault = mode.id == defaultID
            if mode.id == OutputMode.rawID {
                // Migration: der Modus hieß bis 2.7 „Raw" — persistierte
                // Dateien mit dem alten Default-Namen bekommen den neuen;
                // eigene Umbenennungen des Users bleiben unangetastet.
                if mode.name == "Raw" { mode.name = "Fast" }
                if mode.shortLabel == "Raw" { mode.shortLabel = "Fast" }
                mode.isEnabled = true
                mode.kind = .raw
                mode.templateID = nil
                mode.contextPolicy = .off
                mode.pasteVisualAttachments = false
                mode.codexModelRawOverride = nil
                mode.codexReasoningEffortRawOverride = nil
                mode.codexServiceTierRawOverride = nil
            }
            if mode.isDefault {
                mode.isEnabled = true
            }
            return mode
        }

        let customModes = byID.values
            .filter { !builtInOrder.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { mode -> OutputMode in
                var updatedMode = mode
                updatedMode.kind = .custom
                updatedMode.isDefault = updatedMode.id == defaultID
                if updatedMode.isDefault {
                    updatedMode.isEnabled = true
                }
                return updatedMode
            }

        return builtIns + customModes
    }

    private static func defaultFileURL() -> URL {
        let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return supportDirectory
            .appendingPathComponent("WhisperM8", isDirectory: true)
            .appendingPathComponent("OutputModes.json")
    }
}
