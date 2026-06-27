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

private struct BoundedJSONLReader {
    static func firstLine(from fileURL: URL, maxBytes: Int) -> (line: String, bytesRead: Int)? {
        guard let data = readPrefix(from: fileURL, maxBytes: maxBytes) else { return nil }
        let bytes = data.count
        let lineData: Data
        if let newlineIndex = data.firstIndex(of: 10) {
            lineData = data[..<newlineIndex]
        } else {
            lineData = data
        }
        guard let line = String(data: lineData, encoding: .utf8), !line.isEmpty else {
            return nil
        }
        return (line, bytes)
    }

    static func lines(from fileURL: URL, maxLines: Int, maxBytes: Int) -> (lines: [String], bytesRead: Int)? {
        guard let data = readPrefix(from: fileURL, maxBytes: maxBytes),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .prefix(maxLines)
            .map(String.init)
        return (lines, data.count)
    }

    private static func readPrefix(from fileURL: URL, maxBytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: maxBytes)
    }
}

struct CodexSessionIndexer {
    var sessionsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex", isDirectory: true)
        .appendingPathComponent("sessions", isDirectory: true)

    func indexedSessions(limit: Int = 200) -> [IndexedAgentSession] {
        indexedSessionResult(limit: limit).sessions
    }

    func indexedSessionResult(
        limit: Int = 200,
        cache: inout AgentSessionIndexCache
    ) -> AgentSessionIndexResult {
        var stats = AgentSessionIndexStats(provider: .codex)
        let startedAt = Date()
        let sessions = indexSessions(limit: limit, cache: &cache, stats: &stats)
        stats.duration = Date().timeIntervalSince(startedAt)
        Logger.agentPerformance.info("agent_index provider=codex files=\(stats.scannedFiles) parsed=\(stats.parsedFiles) cacheHits=\(stats.cacheHits) cacheMisses=\(stats.cacheMisses) skipped=\(stats.skippedFiles) bytes=\(stats.bytesRead) durationMs=\(Int(stats.duration * 1000))")
        return AgentSessionIndexResult(sessions: sessions, stats: stats)
    }

    func indexedSessionResult(limit: Int = 200) -> AgentSessionIndexResult {
        var cache = AgentSessionIndexCache()
        return indexedSessionResult(limit: limit, cache: &cache)
    }

    private func indexSessions(
        limit: Int,
        cache: inout AgentSessionIndexCache,
        stats: inout AgentSessionIndexStats
    ) -> [IndexedAgentSession] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var sessions: [IndexedAgentSession] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
            stats.scannedFiles += 1
            guard let metadata = Self.metadata(for: fileURL) else {
                stats.skippedFiles += 1
                continue
            }
            switch cache.lookup(provider: .codex, fileURL: fileURL, metadata: metadata) {
            case let .hit(cached):
                stats.cacheHits += 1
                if let cached {
                    sessions.append(cached)
                } else {
                    stats.skippedFiles += 1
                }
                continue
            case .miss:
                break
            }

            stats.cacheMisses += 1
            if let parsed = parseSession(fileURL, metadata: metadata, stats: &stats) {
                stats.parsedFiles += 1
                cache[.codex, fileURL, metadata] = parsed
                sessions.append(parsed)
            } else {
                stats.skippedFiles += 1
                cache[.codex, fileURL, metadata] = nil
            }
        }

        return sessions
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
            .prefix(limit)
            .map { $0 }
    }

    private func parseSession(
        _ fileURL: URL,
        metadata: AgentSessionIndexCache.FileMetadata,
        stats: inout AgentSessionIndexStats
    ) -> IndexedAgentSession? {
        guard let read = BoundedJSONLReader.firstLine(from: fileURL, maxBytes: 256 * 1024) else {
            return nil
        }
        stats.bytesRead += Int64(read.bytesRead)

        guard let data = read.line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["type"] as? String == "session_meta",
              let payload = root["payload"] as? [String: Any],
              let sessionID = payload["id"] as? String,
              let cwd = payload["cwd"] as? String else {
            return nil
        }

        let timestamp = parseDate(payload["timestamp"] as? String)
        let createdAt = timestamp ?? metadata.createdAt ?? Date()
        let lastActivityAt = metadata.modifiedAt ?? createdAt
        let model = payload["model"] as? String
        let title = URL(fileURLWithPath: cwd).lastPathComponent

        return IndexedAgentSession(
            provider: .codex,
            externalSessionID: sessionID,
            cwd: cwd,
            title: title.isEmpty ? "Codex Chat" : title,
            model: model,
            reasoningEffort: nil,
            createdAt: createdAt,
            lastActivityAt: lastActivityAt
        )
    }

    private static func metadata(for fileURL: URL) -> AgentSessionIndexCache.FileMetadata? {
        guard let resourceValues = try? fileURL.resourceValues(
            forKeys: [.contentModificationDateKey, .creationDateKey, .fileSizeKey]
        ) else {
            return nil
        }
        return AgentSessionIndexCache.FileMetadata(
            fileSize: Int64(resourceValues.fileSize ?? 0),
            modifiedAt: resourceValues.contentModificationDate,
            createdAt: resourceValues.creationDate
        )
    }

    private func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}

struct ClaudeSessionIndexer {
    var projectsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude", isDirectory: true)
        .appendingPathComponent("projects", isDirectory: true)

    func indexedSessions(limit: Int = 100) -> [IndexedAgentSession] {
        indexedSessionResult(limit: limit).sessions
    }

    func indexedSessionResult(
        limit: Int = 100,
        cache: inout AgentSessionIndexCache
    ) -> AgentSessionIndexResult {
        var stats = AgentSessionIndexStats(provider: .claude)
        let startedAt = Date()
        let sessions = indexSessions(limit: limit, cache: &cache, stats: &stats)
        stats.duration = Date().timeIntervalSince(startedAt)
        Logger.agentPerformance.info("agent_index provider=claude files=\(stats.scannedFiles) parsed=\(stats.parsedFiles) cacheHits=\(stats.cacheHits) cacheMisses=\(stats.cacheMisses) skipped=\(stats.skippedFiles) bytes=\(stats.bytesRead) durationMs=\(Int(stats.duration * 1000))")
        return AgentSessionIndexResult(sessions: sessions, stats: stats)
    }

    func indexedSessionResult(limit: Int = 100) -> AgentSessionIndexResult {
        var cache = AgentSessionIndexCache()
        return indexedSessionResult(limit: limit, cache: &cache)
    }

    private func indexSessions(
        limit: Int,
        cache: inout AgentSessionIndexCache,
        stats: inout AgentSessionIndexStats
    ) -> [IndexedAgentSession] {
        guard let enumerator = FileManager.default.enumerator(
            at: projectsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var sessions: [IndexedAgentSession] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
            guard !fileURL.path.contains("/subagents/") else {
                stats.skippedFiles += 1
                continue
            }
            stats.scannedFiles += 1
            guard let metadata = Self.metadata(for: fileURL) else {
                stats.skippedFiles += 1
                continue
            }
            switch cache.lookup(provider: .claude, fileURL: fileURL, metadata: metadata) {
            case let .hit(cached):
                stats.cacheHits += 1
                if let cached {
                    sessions.append(cached)
                } else {
                    stats.skippedFiles += 1
                }
                continue
            case .miss:
                break
            }

            stats.cacheMisses += 1
            if let parsed = parseSessionFile(fileURL, metadata: metadata, stats: &stats) {
                stats.parsedFiles += 1
                cache[.claude, fileURL, metadata] = parsed
                sessions.append(parsed)
            } else {
                stats.skippedFiles += 1
                cache[.claude, fileURL, metadata] = nil
            }
        }

        return sessions
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
            .prefix(limit)
            .map { $0 }
    }

    private func parseSessionFile(
        _ fileURL: URL,
        metadata: AgentSessionIndexCache.FileMetadata,
        stats: inout AgentSessionIndexStats
    ) -> IndexedAgentSession? {
        guard let read = BoundedJSONLReader.lines(from: fileURL, maxLines: 200, maxBytes: 1 * 1024 * 1024) else {
            return nil
        }
        stats.bytesRead += Int64(read.bytesRead)

        let fallbackID = fileURL.deletingPathExtension().lastPathComponent
        var sessionID: String?
        var cwd: String?
        var title: String?
        var createdAt: Date?
        var lastMessageDate: Date?

        for line in read.lines {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            if sessionID == nil {
                sessionID = object["sessionId"] as? String
            }
            if cwd == nil {
                cwd = object["cwd"] as? String
            }
            if title == nil {
                title = object["customTitle"] as? String
                    ?? object["aiTitle"] as? String
                    ?? firstPromptTitle(from: object)
            }
            if let timestamp = parseDate(object["timestamp"] as? String) {
                createdAt = min(createdAt ?? timestamp, timestamp)
                lastMessageDate = max(lastMessageDate ?? timestamp, timestamp)
            }

            if sessionID != nil, cwd != nil, title != nil, createdAt != nil {
                break
            }
        }

        guard let cwd else {
            return nil
        }
        guard !AgentSessionStore.isClaudeWorktreePath(cwd) else {
            return nil
        }

        let fallbackDate = metadata.createdAt ?? metadata.modifiedAt ?? Date()
        let created = createdAt ?? fallbackDate
        let lastActivity = max(lastMessageDate ?? created, metadata.modifiedAt ?? created)

        return IndexedAgentSession(
            provider: .claude,
            externalSessionID: sessionID ?? fallbackID,
            cwd: cwd,
            title: title?.isEmpty == false ? title! : "Claude \(fallbackID.prefix(8))",
            model: nil,
            reasoningEffort: nil,
            createdAt: created,
            lastActivityAt: lastActivity
        )
    }

    private static func metadata(for fileURL: URL) -> AgentSessionIndexCache.FileMetadata? {
        guard let resourceValues = try? fileURL.resourceValues(
            forKeys: [.contentModificationDateKey, .creationDateKey, .fileSizeKey]
        ) else {
            return nil
        }
        return AgentSessionIndexCache.FileMetadata(
            fileSize: Int64(resourceValues.fileSize ?? 0),
            modifiedAt: resourceValues.contentModificationDate,
            createdAt: resourceValues.creationDate
        )
    }

    private func firstPromptTitle(from object: [String: Any]) -> String? {
        guard object["type"] as? String == "user" else {
            return nil
        }

        if let content = object["content"] as? String {
            return shortTitle(content)
        }
        if let content = (object["message"] as? [String: Any])?["content"] as? String {
            return shortTitle(content)
        }
        return nil
    }

    private func shortTitle(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > 46 else {
            return normalized
        }
        return "\(normalized.prefix(46))..."
    }

    private func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}
