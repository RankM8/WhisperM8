import Foundation

/// Cleanup-Job fuer Claude-Hook-Files (Settings + Events). Laeuft beim
/// App-Start mit dem aktuellen Workspace-Snapshot als "alive set" — alles
/// was nicht zu einer aktuellen lokalen Session gehoert, wird entfernt.
///
/// Terminal-Snapshots werden NICHT mehr persistiert (siehe TranscriptReader-
/// Architektur — geschlossene Sessions werden direkt aus den nativen
/// Claude/Codex-JSONLs gerendert).
struct AgentSessionRetentionService {
    let hookPaths: ClaudeHookPaths

    init(hookPaths: ClaudeHookPaths = ClaudeHookPaths()) {
        self.hookPaths = hookPaths
    }

    @discardableResult
    func prune(liveLocalSessionIDs: Set<UUID>) -> RetentionResult {
        var result = RetentionResult()
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
                "retention_pruned hookSettings=\(result.hookSettingsRemoved) hookEvents=\(result.hookEventsRemoved)"
            )
        }
        return result
    }

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
    var hookSettingsRemoved: Int = 0
    var hookEventsRemoved: Int = 0

    var hasAnyRemoval: Bool {
        hookSettingsRemoved + hookEventsRemoved > 0
    }
}
