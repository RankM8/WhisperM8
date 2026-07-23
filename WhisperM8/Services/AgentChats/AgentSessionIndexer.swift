import Foundation

struct AgentSessionIndexResult {
    var sessions: [IndexedAgentSession]
    var stats: AgentSessionIndexStats
}

struct AgentSessionIndexStats: Equatable {
    var provider: AgentProvider
    var scannedFiles = 0
    var parsedFiles = 0
    var cacheHits = 0
    var cacheMisses = 0
    var skippedFiles = 0
    var prunedCacheEntries = 0
    var bytesRead: Int64 = 0
    var duration: TimeInterval = 0
}

struct AgentSessionIndexCache {
    static let currentSchemaVersion = 2

    private var entries: [String: Entry] = [:]
    private(set) var isDirty = false
    private(set) var invalidatedLegacyFormat = false

    init(invalidateForRewrite: Bool = false) {
        isDirty = invalidateForRewrite
    }

    enum Lookup {
        case hit(IndexedAgentSession?)
        case miss
    }

    subscript(provider: AgentProvider, fileURL: URL, metadata: FileMetadata) -> IndexedAgentSession? {
        get {
            guard case let .hit(session) = lookup(provider: provider, fileURL: fileURL, metadata: metadata) else {
                return nil
            }
            return session
        }
        set {
            let cacheKey = Self.cacheKey(provider: provider, fileURL: fileURL)
            let entry = Entry(
                fileSize: metadata.fileSize,
                modifiedAt: metadata.modifiedAt,
                session: newValue
            )
            guard entries[cacheKey] != entry else { return }
            entries[cacheKey] = entry
            isDirty = true
        }
    }

    func lookup(provider: AgentProvider, fileURL: URL, metadata: FileMetadata) -> Lookup {
        let cacheKey = Self.cacheKey(provider: provider, fileURL: fileURL)
        guard let entry = entries[cacheKey],
              entry.fileSize == metadata.fileSize,
              entry.modifiedAt == metadata.modifiedAt else {
            return .miss
        }
        return .hit(entry.session)
    }

    /// Entfernt ausschließlich Cacheeinträge eines vollständig gelesenen Roots,
    /// deren Datei in diesem Scan nicht mehr vorkam. Externe Transcripts bleiben
    /// selbstverständlich unangetastet.
    mutating func prune(
        provider: AgentProvider,
        rootURL: URL,
        keeping seenKeys: Set<String>
    ) -> Int {
        let rootPath = rootURL.standardizedFileURL.path
        let keyPrefix = "\(provider.rawValue):\(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")"
        let staleKeys = entries.keys.filter { key in
            key.hasPrefix(keyPrefix) && !seenKeys.contains(key)
        }
        guard !staleKeys.isEmpty else { return 0 }
        for key in staleKeys {
            entries.removeValue(forKey: key)
        }
        isDirty = true
        return staleKeys.count
    }

    var entryCount: Int { entries.count }

    mutating func markPersisted() {
        isDirty = false
        invalidatedLegacyFormat = false
    }

    static func cacheKey(provider: AgentProvider, fileURL: URL) -> String {
        "\(provider.rawValue):\(fileURL.standardizedFileURL.path)"
    }

    struct FileMetadata: Equatable {
        var fileSize: Int64
        var modifiedAt: Date?
        var createdAt: Date?
    }

    private struct Entry: Codable, Equatable {
        var fileSize: Int64
        var modifiedAt: Date?
        var session: IndexedAgentSession?
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case entries
    }
}

extension AgentSessionIndexCache: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decodeIfPresent(Int.self, forKey: .schemaVersion) == Self.currentSchemaVersion else {
            // Der Legacy-Cache besitzt keinen Versionsschlüssel und hat seine
            // mtime-Subsekunden bereits verloren. Nicht scheinpräzise migrieren,
            // sondern einmal kontrolliert neu aufbauen.
            entries = [:]
            isDirty = true
            invalidatedLegacyFormat = true
            return
        }
        entries = try container.decode([String: Entry].self, forKey: .entries)
        isDirty = false
        invalidatedLegacyFormat = false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(entries, forKey: .entries)
    }
}

struct AgentSessionIndexCacheStore {
    var fileURL: URL = Self.defaultFileURL()

    func load() -> AgentSessionIndexCache {
        PerfBudgets.indexCacheLoad.withInterval {
            guard FileManager.default.fileExists(atPath: fileURL.path),
                  let data = try? Data(contentsOf: fileURL) else {
                return AgentSessionIndexCache()
            }

            do {
                let decoder = JSONDecoder()
                // Numerische Sekunden erhalten Date-Subsekunden im JSON-
                // Roundtrip; ISO8601 hatte sie zuvor abgeschnitten.
                decoder.dateDecodingStrategy = .secondsSince1970
                let cache = try decoder.decode(AgentSessionIndexCache.self, from: data)
                if cache.invalidatedLegacyFormat {
                    Logger.agentPerformance.notice("agent_index_cache_invalidated reason=legacy-format")
                }
                Logger.agentPerformance.debug("agent_index_cache_loaded entries=\(cache.entryCount)")
                return cache
            } catch {
                Logger.agentPerformance.warning("agent_index_cache_load_failed error=\(error.localizedDescription, privacy: .public)")
                return AgentSessionIndexCache(invalidateForRewrite: true)
            }
        }
    }

    /// Schreibt nur einen tatsächlich veränderten Cache. Rückgabe `true`, wenn
    /// neue Bytes atomar persistiert wurden.
    @discardableResult
    func save(_ cache: inout AgentSessionIndexCache) -> Bool {
        guard cache.isDirty else {
            let entryCount = cache.entryCount
            Logger.agentPerformance.debug("agent_index_cache_save_skipped entries=\(entryCount)")
            return false
        }
        do {
            try PerfBudgets.indexCacheSave.withInterval {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .secondsSince1970
                let data = try encoder.encode(cache)
                try data.write(to: fileURL, options: .atomic)
            }
            cache.markPersisted()
            let entryCount = cache.entryCount
            Logger.agentPerformance.debug("agent_index_cache_saved entries=\(entryCount)")
            return true
        } catch {
            Logger.agentPerformance.warning("agent_index_cache_save_failed error=\(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private static func defaultFileURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperM8", isDirectory: true)
            .appendingPathComponent("agent-session-index-cache.json")
    }
}
