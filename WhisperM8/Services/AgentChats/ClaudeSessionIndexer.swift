import Foundation

struct ClaudeSessionIndexer {
    /// Alle Transcript-Roots: `~/.claude/projects` (main) plus die
    /// `projects/`-Dirs der Account-Profile (`~/.claude-profiles/<name>/`).
    var projectsDirectories: [URL]

    init(projectsDirectories: [URL]? = nil) {
        self.projectsDirectories = projectsDirectories ?? ClaudeAccountProfiles().claudeProjectsRoots()
    }

    /// Bequemer Einzel-Root-Init (Tests, gezielte Scans).
    init(projectsDirectory: URL) {
        self.projectsDirectories = [projectsDirectory]
    }

    func indexedSessions(limit: Int = 1000) -> [IndexedAgentSession] {
        indexedSessionResult(limit: limit).sessions
    }

    func indexedSessionResult(
        limit: Int = 1000,
        cache: inout AgentSessionIndexCache
    ) -> AgentSessionIndexResult {
        var stats = AgentSessionIndexStats(provider: .claude)
        let startedAt = Date()
        let sessions = indexSessions(limit: limit, cache: &cache, stats: &stats)
        stats.duration = Date().timeIntervalSince(startedAt)
        Logger.agentPerformance.info("agent_index provider=claude files=\(stats.scannedFiles) parsed=\(stats.parsedFiles) cacheHits=\(stats.cacheHits) cacheMisses=\(stats.cacheMisses) skipped=\(stats.skippedFiles) pruned=\(stats.prunedCacheEntries) bytes=\(stats.bytesRead) durationMs=\(Int(stats.duration * 1000))")
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
        var sessions: [IndexedAgentSession] = []
        for directory in projectsDirectories {
            indexSessions(in: directory, into: &sessions, cache: &cache, stats: &stats)
        }
        return sessions
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
            .prefix(limit)
            .map { $0 }
    }

    private func indexSessions(
        in projectsDirectory: URL,
        into sessions: inout [IndexedAgentSession],
        cache: inout AgentSessionIndexCache,
        stats: inout AgentSessionIndexStats
    ) {
        var enumerationSucceeded = true
        guard let enumerator = FileManager.default.enumerator(
            at: projectsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles],
            errorHandler: { url, error in
                enumerationSucceeded = false
                Logger.agentPerformance.warning("agent_index_enumeration_failed provider=claude root=\(url.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                return true
            }
        ) else {
            return
        }

        var seenKeys: Set<String> = []
        while let object = enumerator.nextObject() {
            guard let fileURL = object as? URL else { continue }

            // Subagent-Verzeichnisse gar nicht erst betreten. Sie enthalten die
            // MEHRHEIT aller Dateien — gemessen 2.257 von 3.017 —, und keine
            // davon wird indiziert. Sie einzeln aufzuzaehlen und danach
            // wegzuwerfen kostet einen `stat` je Datei fuer nichts.
            if fileURL.hasDirectoryPath, fileURL.lastPathComponent == "subagents" {
                enumerator.skipDescendants()
                continue
            }
            // Limit-Ping-Arbeitsordner (ClaudeAccountLimitPinger): dessen
            // Sessions sind reine Token-Refresh-Artefakte und dürfen nie als
            // Chats importiert werden — auch nicht im Zeitfenster zwischen
            // CLI-Lauf und Aufräumen (FSEvents triggert Scans in Sekunden).
            if fileURL.hasDirectoryPath,
               ClaudeAccountLimitPinger.isPingProjectsDirectory(fileURL.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            guard fileURL.pathExtension == "jsonl" else { continue }
            guard !fileURL.path.contains("/subagents/") else {
                stats.skippedFiles += 1
                continue
            }
            guard !ClaudeAccountLimitPinger.isPingProjectsDirectory(
                fileURL.deletingLastPathComponent().lastPathComponent
            ) else {
                stats.skippedFiles += 1
                continue
            }
            seenKeys.insert(AgentSessionIndexCache.cacheKey(provider: .claude, fileURL: fileURL))
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

        if enumerationSucceeded {
            stats.prunedCacheEntries += cache.prune(
                provider: .claude,
                rootURL: projectsDirectory,
                keeping: seenKeys
            )
        }
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
            lastActivityAt: lastActivity,
            // Account-Profil aus dem Ablageort: Sessions unter einem
            // Profil-Root muessen spaeter unter demselben Config-Dir resumen.
            claudeProfileName: ClaudeAccountProfiles.profileName(forTranscriptPath: fileURL.path)
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
