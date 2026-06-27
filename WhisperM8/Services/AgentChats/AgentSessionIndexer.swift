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
    var bytesRead: Int64 = 0
    var duration: TimeInterval = 0
}

struct AgentSessionIndexCache {
    private var entries: [String: Entry] = [:]

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
            entries[cacheKey] = Entry(
                fileSize: metadata.fileSize,
                modifiedAt: metadata.modifiedAt,
                session: newValue
            )
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

    private static func cacheKey(provider: AgentProvider, fileURL: URL) -> String {
        "\(provider.rawValue):\(fileURL.standardizedFileURL.path)"
    }

    struct FileMetadata: Equatable {
        var fileSize: Int64
        var modifiedAt: Date?
        var createdAt: Date?
    }

    private struct Entry: Codable {
        var fileSize: Int64
        var modifiedAt: Date?
        var session: IndexedAgentSession?
    }
}

struct AgentSessionIndexCacheStore {
    var fileURL: URL = Self.defaultFileURL()

    func load() -> AgentSessionIndexCache {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            return AgentSessionIndexCache()
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(AgentSessionIndexCache.self, from: data)
        } catch {
            Logger.agentPerformance.warning("agent_index_cache_load_failed error=\(error.localizedDescription, privacy: .public)")
            return AgentSessionIndexCache()
        }
    }

    func save(_ cache: AgentSessionIndexCache) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(cache)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Logger.agentPerformance.warning("agent_index_cache_save_failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private static func defaultFileURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperM8", isDirectory: true)
            .appendingPathComponent("agent-session-index-cache.json")
    }
}

extension AgentSessionIndexCache: Codable {}
