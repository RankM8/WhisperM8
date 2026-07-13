import Foundation

struct CodexSessionIndexer {
    var sessionsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex", isDirectory: true)
        .appendingPathComponent("sessions", isDirectory: true)

    func indexedSessions(limit: Int = 1000) -> [IndexedAgentSession] {
        indexedSessionResult(limit: limit).sessions
    }

    func indexedSessionResult(
        limit: Int = 1000,
        cache: inout AgentSessionIndexCache
    ) -> AgentSessionIndexResult {
        var stats = AgentSessionIndexStats(provider: .codex)
        let startedAt = Date()
        let sessions = indexSessions(limit: limit, cache: &cache, stats: &stats)
        stats.duration = Date().timeIntervalSince(startedAt)
        Logger.agentPerformance.info("agent_index provider=codex files=\(stats.scannedFiles) parsed=\(stats.parsedFiles) cacheHits=\(stats.cacheHits) cacheMisses=\(stats.cacheMisses) skipped=\(stats.skippedFiles) bytes=\(stats.bytesRead) durationMs=\(Int(stats.duration * 1000))")
        return AgentSessionIndexResult(sessions: sessions, stats: stats)
    }

    func indexedSessionResult(limit: Int = 1000) -> AgentSessionIndexResult {
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
