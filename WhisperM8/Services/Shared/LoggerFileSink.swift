import Foundation

/// Datei-Senke des optionalen Debug-Logs (`debugFileLoggingEnabled`).
///
/// - Schreibt nur mit dem werfenden `write(contentsOf:)` — das alte
///   `FileHandle.write(_:)` löst bei ENOSPC/EPIPE eine NSException aus, die
///   Swift nicht fängt und die die App samt aller Chats beendet.
/// - Rotiert ab `maxBytes` (eine Vorversion `<name>.1`), damit ein vergessener
///   Schalter die Platte nicht füllt.
/// Jeder Fehler wird verschluckt: Logging darf nie die App beeinträchtigen.
final class LoggerFileSink: @unchecked Sendable {
    static let defaultMaxBytes = 10 * 1024 * 1024

    let url: URL
    let maxBytes: Int
    private let lock = NSLock()

    init(url: URL, maxBytes: Int = LoggerFileSink.defaultMaxBytes) {
        self.url = url
        self.maxBytes = maxBytes
    }

    var rotatedURL: URL { url.appendingPathExtension("1") }

    func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }

        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        rotateIfNeeded()

        if !fileManager.fileExists(atPath: url.path) {
            try? data.write(to: url)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // ENOSPC, Berechtigung, … — bewusst still.
        }
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: rotatedURL)
    }

    private func rotateIfNeeded() {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = (attributes?[.size] as? NSNumber)?.intValue, size >= maxBytes else { return }
        try? FileManager.default.removeItem(at: rotatedURL)
        try? FileManager.default.moveItem(at: url, to: rotatedURL)
    }
}
