import Foundation

/// Zentrale Codex-Session-ID→URL-Auflösung mit Cache (C16).
///
/// Vorher lief bei JEDEM Lookup (Chat öffnen, Diktat-Kontext, Runtime-Watcher-
/// Poll, Transcript-Cache-Validierung) ein rekursiver Voll-Walk über
/// `~/.codex/sessions` — 100 ms bis >1 s bei großen Beständen. Jetzt:
///
/// - Ein Walk harvestet ALLE Session-IDs aus den Dateinamen
///   (`rollout-<timestamp>-<uuid>.jsonl`) in eine Map — nachfolgende Lookups
///   beliebiger Sessions sind Hits.
/// - Hits werden per `fileExists` validiert; verschobene/gelöschte Dateien
///   invalidieren den Eintrag und stoßen einen Re-Scan an (Move-Vertrag).
/// - Misses werden kurz negativ gecacht (`negativeTTL`), damit Poll-Schleifen
///   auf noch nicht existierende Transcripts nicht pro Tick den Baum laufen.
///
/// Thread-sicher über NSLock; der Lock bleibt während des Scans gehalten
/// (Single-Flight — parallele Aufrufer warten, statt denselben Walk doppelt
/// zu machen; genau diese Aufrufer hätten vorher je einen eigenen Voll-Walk
/// bezahlt).
enum CodexTranscriptLocator {

    /// Wie lange ein Miss unterdrückt wird, bevor erneut gescannt wird.
    /// Bewusst unter dem 1,5-s-Poll-Intervall × 2 des Runtime-Watchers:
    /// frisch gestartete Sessions dürfen höchstens ~2 s später aufgelöst
    /// werden als mit dem alten Walk-pro-Aufruf. Für Tests überschreibbar.
    static var negativeTTL: TimeInterval = 2

    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    private static let lock = NSLock()
    private static var knownURLs: [String: URL] = [:]
    private static var negativeUntil: [String: Date] = [:]

    static func url(forSessionID sessionID: String, root: URL = defaultRoot) -> URL? {
        let key = sessionID.lowercased()
        lock.lock()
        defer { lock.unlock() }

        if let cached = knownURLs[key] {
            if FileManager.default.fileExists(atPath: cached.path) {
                return cached
            }
            knownURLs.removeValue(forKey: key)
        }
        if let until = negativeUntil[key], until > Date() {
            return nil
        }

        scanAndFill(root: root)

        if let found = knownURLs[key] {
            negativeUntil.removeValue(forKey: key)
            return found
        }
        // Verhaltenserhalt: der Harvest indexiert nur UUID-Dateinamen. Für
        // Nicht-UUID-IDs greift der alte gezielte Suffix-Match als Fallback.
        if UUID(uuidString: sessionID) == nil,
           let found = suffixScan(sessionID: sessionID, root: root) {
            knownURLs[key] = found
            negativeUntil.removeValue(forKey: key)
            return found
        }
        negativeUntil[key] = Date().addingTimeInterval(negativeTTL)
        return nil
    }

    /// `rollout-<timestamp>-<uuid>.jsonl` → UUID (lowercased). `nil` für
    /// Dateinamen ohne gültige Session-ID am Ende.
    static func sessionID(fromFilename filename: String) -> String? {
        guard filename.hasSuffix(".jsonl") else { return nil }
        let stem = filename.dropLast(".jsonl".count)
        guard stem.count > 36 else { return nil }
        let candidate = String(stem.suffix(36))
        guard UUID(uuidString: candidate) != nil,
              stem.dropLast(36).hasSuffix("-") else { return nil }
        return candidate.lowercased()
    }

    /// Testbarkeit: Cache vollständig leeren (die Map ist prozessweit).
    static func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        knownURLs = [:]
        negativeUntil = [:]
    }

    private static func suffixScan(sessionID: String, root: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let suffix = "-\(sessionID).jsonl"
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            if url.lastPathComponent.hasSuffix(suffix) {
                return url
            }
        }
        return nil
    }

    private static func scanAndFill(root: URL) {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let id = sessionID(fromFilename: url.lastPathComponent) else { continue }
            knownURLs[id] = url
        }
    }
}
