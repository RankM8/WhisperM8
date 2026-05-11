import Foundation

/// Cleanup-Job fuer Terminal-Snapshots und Claude-Hook-Files. Laeuft beim
/// App-Start mit dem aktuellen Workspace-Snapshot als "alive set" — alles
/// was nicht zu einer aktuellen lokalen Session gehoert, wird entfernt.
struct AgentSessionRetentionService {
    let snapshotStore: AgentTerminalSnapshotStore
    let hookPaths: ClaudeHookPaths

    init(
        snapshotStore: AgentTerminalSnapshotStore = AgentTerminalSnapshotStore(),
        hookPaths: ClaudeHookPaths = ClaudeHookPaths()
    ) {
        self.snapshotStore = snapshotStore
        self.hookPaths = hookPaths
    }

    /// Raeumt verwaiste Snapshot- und Hook-Dateien. `liveLocalSessionIDs`
    /// kommt typischerweise aus `AgentWorkspace.sessions.map(\.id)`.
    @discardableResult
    func prune(liveLocalSessionIDs: Set<UUID>) -> RetentionResult {
        var result = RetentionResult()
        result.snapshotsRemoved = snapshotStore.pruneOrphans(keeping: liveLocalSessionIDs)
        result.hookSettingsRemoved = pruneDirectory(
            hookPaths.settingsDirectory,
            extension: "json",
            keeping: liveLocalSessionIDs
        )
        result.hookEventsRemoved = pruneDirectory(
            hookPaths.eventsDirectory,
            extension: "jsonl",
            keeping: liveLocalSessionIDs
        )
        if result.hasAnyRemoval {
            Logger.terminalSnapshot.info(
                "snapshot_pruned snapshots=\(result.snapshotsRemoved) hookSettings=\(result.hookSettingsRemoved) hookEvents=\(result.hookEventsRemoved)"
            )
        }
        return result
    }

    /// Entfernt Files in `directory` mit `extension`, deren Dateiname (ohne
    /// Suffix) eine UUID ist, die nicht in `keeping` vorkommt. Idempotent.
    private func pruneDirectory(_ directory: URL, extension ext: String, keeping: Set<UUID>) -> Int {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return 0
        }
        var removed = 0
        for url in entries where url.pathExtension == ext {
            let stem = url.deletingPathExtension().lastPathComponent
            guard let id = UUID(uuidString: stem) else { continue }
            if keeping.contains(id) { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil {
                removed += 1
            }
        }
        return removed
    }
}

struct RetentionResult: Equatable {
    var snapshotsRemoved: Int = 0
    var hookSettingsRemoved: Int = 0
    var hookEventsRemoved: Int = 0

    var hasAnyRemoval: Bool {
        snapshotsRemoved + hookSettingsRemoved + hookEventsRemoved > 0
    }
}
