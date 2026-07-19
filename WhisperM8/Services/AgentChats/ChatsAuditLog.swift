import Foundation

// MARK: - Audit-Log für Control-Aktionen

/// Append-only-Protokoll aller mutierenden `whisperm8 chats`-Aktionen. Wird
/// ausschließlich von der App geschrieben (eine Schreibstelle, kein
/// Locking-Problem); die CLI liest es über `chats audit`.
///
/// Privacy-Default: kein Prompt-Volltext — nur Länge + die ersten 80 Zeichen.
/// Das Transcript der Ziel-Session hat den Volltext ohnehin.
struct ChatsAuditEntry: Codable, Equatable {
    var at: Date
    var actor: String           // "projekt/titel", "unverified" oder "external"
    var verified: Bool
    var method: String
    var target: String?         // "projekt/titel" der Ziel-Session
    var outcome: String         // "ok" | Fehlercode
    var promptChars: Int?
    var promptHead: String?
}

final class ChatsAuditLog: @unchecked Sendable {
    static let shared = ChatsAuditLog()

    private let lock = NSLock()
    private let fileURL: URL
    private let maxBytes: Int

    /// Rotation bei 5 MB → `.1`-Sidecar.
    init(fileURL: URL? = nil, maxBytes: Int = 5 * 1_048_576) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        self.maxBytes = maxBytes
    }

    static func defaultFileURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperM8", isDirectory: true)
            .appendingPathComponent("chats-audit.jsonl")
    }

    func append(_ entry: ChatsAuditEntry) {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Self.encoder.encode(entry) else { return }
        var line = data
        line.append(0x0A)
        // Rotation MIT der neuen Zeile prüfen — sonst überschreitet der letzte
        // Eintrag maxBytes um seine volle Länge (GPT-Review).
        rotateIfNeeded(incomingBytes: line.count)
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

    /// Liest die letzten `limit` Einträge (neueste zuletzt), optional gefiltert
    /// auf eine Ziel-Session.
    func recent(limit: Int, targetFilter: String? = nil) -> [ChatsAuditEntry] {
        lock.lock()
        defer { lock.unlock() }
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        var entries: [ChatsAuditEntry] = []
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let entry = try? Self.decoder.decode(ChatsAuditEntry.self, from: data) else { continue }
            if let targetFilter, entry.target != targetFilter { continue }
            entries.append(entry)
        }
        return Array(entries.suffix(limit))
    }

    private func rotateIfNeeded(incomingBytes: Int) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? Int,
              size + incomingBytes > maxBytes else { return }
        let rotated = fileURL.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: fileURL, to: rotated)
    }

    /// Kürzt einen Prompt auf die ersten 80 Zeichen (eine Zeile) für die
    /// Audit-Vorschau.
    static func promptHead(_ prompt: String) -> String {
        let oneLine = prompt
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if oneLine.count <= 80 { return oneLine }
        return String(oneLine.prefix(79)) + "…"
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
