import Foundation

struct AgentWorkspaceRepository {
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    func load(migrate: (AgentWorkspace) -> AgentWorkspace) -> AgentWorkspace {
        PerfBudgets.storeLoad.withInterval { loadBody(migrate: migrate) }
    }

    /// Eigentlicher Load — vom Signpost-Wrapper getrennt, damit die
    /// bestehende durationMs-Logzeile (log-stream-Schnittstelle laut
    /// CLAUDE.md) unverändert erhalten bleibt.
    private func loadBody(migrate: (AgentWorkspace) -> AgentWorkspace) -> AgentWorkspace {
        let startedAt = Date()
        defer {
            Logger.agentPerformance.debug("agent_store_load durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1000))")
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .empty
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let workspace = try decoder.decode(AgentWorkspace.self, from: data)
            let migrated = migrate(workspace)
            if migrated != workspace {
                do {
                    try backup(reason: "pre-migration")
                    try save(migrated)
                } catch {
                    Logger.debug("Failed to migrate agent sessions: \(error.localizedDescription)")
                }
            }
            return migrated
        } catch {
            Logger.debug("Failed to load agent sessions: \(error.localizedDescription)")
            do {
                try backup(reason: "decode-failed")
            } catch {
                Logger.debug("Failed to back up unreadable agent sessions: \(error.localizedDescription)")
            }
            return .empty
        }
    }

    func save(_ workspace: AgentWorkspace) throws {
        try PerfBudgets.storeSave.withInterval {
            let startedAt = Date()
            defer {
                Logger.agentPerformance.debug("agent_store_save durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)) projects=\(workspace.projects.count) sessions=\(workspace.sessions.count)")
            }

            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(workspace)
            try data.write(to: fileURL, options: .atomic)
        }
    }

    func backup(reason: String) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backupURL = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(fileURL.lastPathComponent).\(reason).\(timestamp).bak")
        try FileManager.default.copyItem(at: fileURL, to: backupURL)
    }

    private static func defaultFileURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperM8", isDirectory: true)
            .appendingPathComponent("AgentSessions.json")
    }
}
