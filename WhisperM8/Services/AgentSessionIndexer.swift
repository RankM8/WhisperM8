import Foundation

struct CodexSessionIndexer {
    var sessionsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex", isDirectory: true)
        .appendingPathComponent("sessions", isDirectory: true)

    func indexedSessions(limit: Int = 200) -> [IndexedAgentSession] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var sessions: [IndexedAgentSession] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
            guard let session = parseSession(fileURL) else { continue }
            sessions.append(session)
        }

        return sessions
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
            .prefix(limit)
            .map { $0 }
    }

    private func parseSession(_ fileURL: URL) -> IndexedAgentSession? {
        guard let firstLine = try? String(contentsOf: fileURL, encoding: .utf8)
            .split(separator: "\n", maxSplits: 1)
            .first,
            let data = String(firstLine).data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            root["type"] as? String == "session_meta",
            let payload = root["payload"] as? [String: Any],
            let sessionID = payload["id"] as? String,
            let cwd = payload["cwd"] as? String else {
            return nil
        }

        let resourceValues = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        let timestamp = parseDate(payload["timestamp"] as? String)
        let createdAt = timestamp ?? resourceValues?.creationDate ?? Date()
        let lastActivityAt = resourceValues?.contentModificationDate ?? createdAt
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
        guard let enumerator = FileManager.default.enumerator(
            at: projectsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var sessions: [IndexedAgentSession] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
            guard !fileURL.path.contains("/subagents/"),
                  let session = parseSessionFile(fileURL) else {
                continue
            }
            sessions.append(session)
        }

        return sessions
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
            .prefix(limit)
            .map { $0 }
    }

    private func parseSessionFile(_ fileURL: URL) -> IndexedAgentSession? {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }

        let fallbackID = fileURL.deletingPathExtension().lastPathComponent
        var sessionID: String?
        var cwd: String?
        var title: String?
        var createdAt: Date?
        var lastMessageDate: Date?

        for line in content.split(separator: "\n").prefix(200) {
            guard let data = String(line).data(using: .utf8),
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

        let resourceValues = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        let fallbackDate = resourceValues?.creationDate ?? resourceValues?.contentModificationDate ?? Date()
        let created = createdAt ?? fallbackDate
        let lastActivity = max(lastMessageDate ?? created, resourceValues?.contentModificationDate ?? created)

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
