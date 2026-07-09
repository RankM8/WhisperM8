import Foundation

/// Top-Level-Defaults aus ~/.codex/config.toml — das, was `codex exec` OHNE
/// `-m`/`-c model_reasoning_effort=` tatsächlich nutzt. Die TUI schreibt
/// diese Keys bei jeder `/model`-Auswahl.
struct CodexGlobalConfigDefaults: Equatable, Sendable {
    var model: String?
    var effort: String?

    static let empty = CodexGlobalConfigDefaults(model: nil, effort: nil)
}

/// Liest die globalen Codex-Defaults (strikt read-only gegenüber ~/.codex/).
/// Bewusst KEIN vollwertiger TOML-Parser: gebraucht werden nur die zwei
/// Top-Level-Keys `model` und `model_reasoning_effort` vor der ersten
/// `[section]`. Stat-gecacht wie `CodexModelCatalogStore`.
final class CodexGlobalConfigReader: @unchecked Sendable {
    static let shared = CodexGlobalConfigReader()

    private let fileURL: URL
    private let dataLoader: (URL) throws -> Data
    private let statLoader: (URL) -> (mtime: Date, size: Int)?

    private let lock = NSLock()
    private var cached: (stat: (mtime: Date, size: Int), defaults: CodexGlobalConfigDefaults)?

    /// DI-Closures für Tests — Konvention wie überall.
    init(
        fileURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/config.toml"),
        dataLoader: @escaping (URL) throws -> Data = { try Data(contentsOf: $0) },
        statLoader: @escaping (URL) -> (mtime: Date, size: Int)? = { url in
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let mtime = attrs[.modificationDate] as? Date,
                  let size = attrs[.size] as? Int else { return nil }
            return (mtime, size)
        }
    ) {
        self.fileURL = fileURL
        self.dataLoader = dataLoader
        self.statLoader = statLoader
    }

    /// Aktuelle Defaults; Datei fehlt/unlesbar → `.empty`.
    func defaults() -> CodexGlobalConfigDefaults {
        lock.lock()
        defer { lock.unlock() }

        guard let stat = statLoader(fileURL) else {
            return cached?.defaults ?? .empty
        }
        if let cached, cached.stat == stat {
            return cached.defaults
        }
        guard let data = try? dataLoader(fileURL),
              let text = String(data: data, encoding: .utf8) else {
            return cached?.defaults ?? .empty
        }
        let parsed = Self.parse(text)
        cached = (stat, parsed)
        return parsed
    }

    /// Purer Parser: nur Top-Level-Zeilen bis zur ersten `[section]`;
    /// `key = "value"` oder `key = value`, `#`-Kommentare toleriert.
    static func parse(_ text: String) -> CodexGlobalConfigDefaults {
        var defaults = CodexGlobalConfigDefaults.empty
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Erste Sektion beendet den Top-Level-Bereich — ein `model` in
            // z.B. [profiles.foo] ist NICHT der globale Default.
            if line.hasPrefix("[") { break }
            guard let equalsIndex = line.firstIndex(of: "=") else { continue }
            let key = line[..<equalsIndex].trimmingCharacters(in: .whitespaces)
            guard key == "model" || key == "model_reasoning_effort" else { continue }

            var value = line[line.index(after: equalsIndex)...].trimmingCharacters(in: .whitespaces)
            // Inline-Kommentar nur außerhalb von Quotes relevant — für die
            // zwei simplen String-Keys reicht: erst Quotes, sonst bis '#'.
            if value.hasPrefix("\"") {
                let inner = value.dropFirst()
                value = String(inner[..<(inner.firstIndex(of: "\"") ?? inner.endIndex)])
            } else if let hashIndex = value.firstIndex(of: "#") {
                value = value[..<hashIndex].trimmingCharacters(in: .whitespaces)
            }
            guard !value.isEmpty else { continue }

            if key == "model" {
                defaults.model = String(value)
            } else {
                defaults.effort = String(value)
            }
        }
        return defaults
    }
}
