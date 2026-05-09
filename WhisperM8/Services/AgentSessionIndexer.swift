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
    var tasksDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude", isDirectory: true)
        .appendingPathComponent("tasks", isDirectory: true)

    func indexedSessions(limit: Int = 100) -> [IndexedAgentSession] {
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: tasksDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return directories
            .filter { $0.hasDirectoryPath }
            .compactMap(parseTaskDirectory)
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
            .prefix(limit)
            .map { $0 }
    }

    private func parseTaskDirectory(_ directory: URL) -> IndexedAgentSession? {
        let resourceValues = try? directory.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        let date = resourceValues?.contentModificationDate ?? resourceValues?.creationDate ?? Date()
        return IndexedAgentSession(
            provider: .claude,
            externalSessionID: directory.lastPathComponent,
            cwd: FileManager.default.homeDirectoryForCurrentUser.path,
            title: "Claude \(directory.lastPathComponent.prefix(8))",
            model: nil,
            reasoningEffort: nil,
            createdAt: resourceValues?.creationDate ?? date,
            lastActivityAt: date
        )
    }
}
