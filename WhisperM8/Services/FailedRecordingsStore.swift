import Foundation

/// Metadaten-Sidecar zu einer aufbewahrten Aufnahme. Liegt als
/// `<audio-basename>.json` neben der M4A-Datei im FailedRecordings-Ordner,
/// damit ein Retry später weiß, wie die Aufnahme entstanden ist.
struct FailedRecordingMetadata: Codable, Equatable {
    var recordedAt: Date
    var audioDuration: TimeInterval
    var language: String?
    var errorMessage: String
    var originalFilename: String
}

/// Eine aufbewahrte Aufnahme: Audio-Datei + Sidecar + dekodierte Metadaten.
struct FailedRecording: Equatable {
    var audioURL: URL
    var sidecarURL: URL
    var metadata: FailedRecordingMetadata
}

/// Bewahrt Aufnahmen auf, deren Transkription fehlgeschlagen ist, statt sie
/// zu löschen — ein langes Diktat darf nie an einem Netz-Timeout sterben.
/// Zusätzlich wichtig: Der AudioRecorder schreibt nach `temporaryDirectory`,
/// das macOS periodisch leert. Erst der Umzug hierher (Application Support)
/// macht die Aufnahme wirklich haltbar.
///
/// Aufräum-Policy bei jedem `preserve()`/`prune()`:
/// - maximal `maxCount` Aufnahmen (älteste fliegen zuerst)
/// - nichts älter als `maxAge`
/// - verwaiste Sidecars (Audio weg) werden entsorgt; verwaiste Audios
///   (Sidecar weg, z. B. Crash zwischen Move und Sidecar-Write) bleiben
///   bewusst liegen, bis `maxAge` sie einholt — lieber eine Datei zu viel
///   behalten als Datenverlust riskieren.
final class FailedRecordingsStore {
    private let directoryURL: URL
    private let fileManager: FileManager
    private let now: () -> Date
    private let maxCount: Int
    private let maxAge: TimeInterval

    static func defaultDirectoryURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("WhisperM8/FailedRecordings", isDirectory: true)
    }

    init(
        directoryURL: URL = FailedRecordingsStore.defaultDirectoryURL(),
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        maxCount: Int = 10,
        maxAge: TimeInterval = 7 * 24 * 60 * 60
    ) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        self.now = now
        self.maxCount = maxCount
        self.maxAge = maxAge
    }

    /// Verschiebt die Aufnahme in den Store und legt den Sidecar an. Liegt die
    /// Datei bereits im Store (Retry, der erneut fehlschlug), bleibt sie an
    /// Ort und Stelle — nur der Sidecar wird mit dem neuen Fehler überschrieben.
    @discardableResult
    func preserve(
        audioURL: URL,
        audioDuration: TimeInterval,
        language: String?,
        errorMessage: String
    ) throws -> FailedRecording {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let destinationURL: URL
        // `resolvingSymlinksInPath` normalisiert /private/var vs. /var —
        // sonst würde ein Retry-Pfad aus `list()` hier als "außerhalb des
        // Stores" gelten und die Datei unnötig erneut verschoben.
        let audioParent = audioURL.deletingLastPathComponent().resolvingSymlinksInPath().path
        let storePath = directoryURL.resolvingSymlinksInPath().path
        if audioParent == storePath {
            destinationURL = audioURL
        } else {
            // Zeitstempel + UUID-Suffix: kollisionsfrei auch bei zwei
            // Fehlschlägen in derselben Sekunde.
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let stamp = formatter.string(from: now())
            let suffix = UUID().uuidString.prefix(8)
            let ext = audioURL.pathExtension.isEmpty ? "m4a" : audioURL.pathExtension
            destinationURL = directoryURL.appendingPathComponent("recording-\(stamp)-\(suffix).\(ext)")
            try fileManager.moveItem(at: audioURL, to: destinationURL)
        }

        let metadata = FailedRecordingMetadata(
            recordedAt: now(),
            audioDuration: audioDuration,
            language: language,
            errorMessage: errorMessage,
            originalFilename: audioURL.lastPathComponent
        )
        let sidecarURL = Self.sidecarURL(for: destinationURL)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metadata).write(to: sidecarURL, options: .atomic)

        prune()
        return FailedRecording(audioURL: destinationURL, sidecarURL: sidecarURL, metadata: metadata)
    }

    /// Entfernt eine Aufnahme komplett (Audio + Sidecar). Wird nach einem
    /// erfolgreichen Retry aufgerufen — fehlende Dateien sind dann kein Fehler.
    func remove(_ recording: FailedRecording) {
        try? fileManager.removeItem(at: recording.audioURL)
        try? fileManager.removeItem(at: recording.sidecarURL)
    }

    /// Alle aufbewahrten Aufnahmen, neueste zuerst. Sidecars ohne Audio werden
    /// ignoriert (und beim nächsten `prune()` entsorgt).
    func list() -> [FailedRecording] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return contents
            .filter { $0.pathExtension == "json" }
            .compactMap { sidecarURL -> FailedRecording? in
                guard let data = try? Data(contentsOf: sidecarURL),
                      let metadata = try? decoder.decode(FailedRecordingMetadata.self, from: data) else {
                    return nil
                }
                let audioURL = sidecarURL.deletingPathExtension()
                guard fileManager.fileExists(atPath: audioURL.path) else { return nil }
                return FailedRecording(audioURL: audioURL, sidecarURL: sidecarURL, metadata: metadata)
            }
            .sorted { $0.metadata.recordedAt > $1.metadata.recordedAt }
    }

    /// Wendet die Aufräum-Policy an (siehe Klassen-Doku).
    func prune() {
        let recordings = list()
        let cutoff = now().addingTimeInterval(-maxAge)

        for (index, recording) in recordings.enumerated() {
            if index >= maxCount || recording.metadata.recordedAt < cutoff {
                remove(recording)
            }
        }

        guard let contents = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for url in contents where url.pathExtension == "json" {
            // Verwaiste Sidecars: zugehöriges Audio existiert nicht mehr.
            if !fileManager.fileExists(atPath: url.deletingPathExtension().path) {
                try? fileManager.removeItem(at: url)
            }
        }
        for url in contents where url.pathExtension != "json" {
            // Verwaiste Audios nur über die Alters-Schiene entsorgen (Doku oben).
            let hasSidecar = fileManager.fileExists(atPath: Self.sidecarURL(for: url).path)
            if !hasSidecar {
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now()
                if mtime < cutoff {
                    try? fileManager.removeItem(at: url)
                }
            }
        }
    }

    /// Sidecar liegt als `<audio-dateiname>.json` neben der Audio-Datei
    /// (Extension wird angehängt, nicht ersetzt — `list()` rekonstruiert die
    /// Audio-URL via `deletingPathExtension`).
    private static func sidecarURL(for audioURL: URL) -> URL {
        audioURL.appendingPathExtension("json")
    }
}
