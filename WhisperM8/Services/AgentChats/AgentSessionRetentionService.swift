import Foundation

/// Cleanup-Job fuer Claude-Hook-Files (Settings + Events). Laeuft beim
/// App-Start mit dem aktuellen Workspace-Snapshot als "alive set" — alles
/// was nicht zu einer aktuellen lokalen Session gehoert, wird entfernt.
///
/// Dazu kommen alte Event-Dateien von Chats, die noch im Workspace stehen
/// (Hook-Analyse 05.11.2026, Stufe 0): Aus der Zeit des vollen Hook-Satzes
/// lagen dort 1,7 GB, weil jeder Tool-Aufruf seine ganze Eingabe anhing.
/// Jeder Launch legt die Event-Datei ohnehin neu an; eine Datei, die seit
/// `staleEventAge` nicht mehr geschrieben wurde, gehoert zu keinem laufenden
/// Chat. Ausgenommen sind Hintergrund-Agenten (`protectedLocalSessionIDs`):
/// Sie ueberleben einen App-Neustart und schreiben weiter in ihre Datei.
///
/// Das Aufraeumen laeuft im Hintergrund, waehrend wiederhergestellte Chats
/// schon starten. Deshalb wird jede Datei erst unmittelbar vor dem Loeschen
/// geprueft: unter dem Lock von `ClaudeHookFileClaims` (Chats, die dieser
/// Prozess gestartet hat, bleiben unberuehrt) und mit frisch gelesenem
/// Aenderungsdatum statt des beim Auflisten gemerkten Werts.
///
/// Terminal-Snapshots werden NICHT mehr persistiert (siehe TranscriptReader-
/// Architektur — geschlossene Sessions werden direkt aus den nativen
/// Claude/Codex-JSONLs gerendert).
struct AgentSessionRetentionService {
    static let staleEventAge: TimeInterval = 14 * 24 * 60 * 60

    let hookPaths: ClaudeHookPaths
    let claims: ClaudeHookFileClaims
    /// Testnaht: laeuft nach dem Auflisten und vor der Pruefung einer Datei,
    /// damit Tests einen Launch genau dazwischen nachstellen koennen.
    let beforeRemoval: (URL) -> Void

    init(
        hookPaths: ClaudeHookPaths = ClaudeHookPaths(),
        claims: ClaudeHookFileClaims = .shared,
        beforeRemoval: @escaping (URL) -> Void = { _ in }
    ) {
        self.hookPaths = hookPaths
        self.claims = claims
        self.beforeRemoval = beforeRemoval
    }

    /// Aufruf beim App-Start: alle Chats im Workspace gelten als lebendig,
    /// Hintergrund-Agenten zusaetzlich als geschuetzt.
    @discardableResult
    func pruneAtLaunch(workspace: AgentWorkspace, now: Date = Date()) -> RetentionResult {
        prune(
            liveLocalSessionIDs: Set(workspace.sessions.map(\.id)),
            protectedLocalSessionIDs: Set(workspace.sessions.filter(\.isBackgroundChat).map(\.id)),
            now: now)
    }

    @discardableResult
    func prune(
        liveLocalSessionIDs: Set<UUID>,
        protectedLocalSessionIDs: Set<UUID> = [],
        now: Date = Date()
    ) -> RetentionResult {
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
        let stale = pruneStaleEvents(
            protecting: protectedLocalSessionIDs,
            olderThan: now.addingTimeInterval(-Self.staleEventAge)
        )
        result.staleHookEventsRemoved = stale.count
        result.staleHookEventBytesRemoved = stale.bytes
        if result.hasAnyRemoval {
            Logger.terminalSnapshot.info(
                "retention_pruned hookSettings=\(result.hookSettingsRemoved) hookEvents=\(result.hookEventsRemoved) staleHookEvents=\(result.staleHookEventsRemoved) staleBytes=\(result.staleHookEventBytesRemoved)"
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
            beforeRemoval(url)
            let didRemove = claims.removeUnlessClaimed(id) {
                (try? FileManager.default.removeItem(at: url)) != nil
            }
            if didRemove { removed += 1 }
        }
        return removed
    }

    /// Event-Dateien, die vor `cutoff` zuletzt geschrieben wurden. Die
    /// Settings-Dateien bleiben: Sie sind klein und gehoeren zum Chat.
    private func pruneStaleEvents(protecting protected: Set<UUID>, olderThan cutoff: Date) -> (count: Int, bytes: Int64) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: hookPaths.eventsDirectory,
            includingPropertiesForKeys: keys
        ) else {
            return (0, 0)
        }
        var removed = 0
        var bytes: Int64 = 0
        for url in entries where url.pathExtension == "jsonl" {
            let stem = url.deletingPathExtension().lastPathComponent
            // Vorauswahl mit dem beim Auflisten gelesenen Datum; entschieden
            // wird erst unten mit frischem Wert.
            guard let id = UUID(uuidString: stem), !protected.contains(id),
                  let listed = try? url.resourceValues(forKeys: Set(keys)).contentModificationDate,
                  listed < cutoff else { continue }
            beforeRemoval(url)
            var size: Int64 = 0
            let didRemove = claims.removeUnlessClaimed(id) {
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                      let modified = attributes[.modificationDate] as? Date,
                      modified < cutoff else { return false }
                size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                return (try? FileManager.default.removeItem(at: url)) != nil
            }
            if didRemove {
                removed += 1
                bytes += size
            }
        }
        return (removed, bytes)
    }
}

struct RetentionResult: Equatable {
    var hookSettingsRemoved: Int = 0
    var hookEventsRemoved: Int = 0
    var staleHookEventsRemoved: Int = 0
    var staleHookEventBytesRemoved: Int64 = 0

    var hasAnyRemoval: Bool {
        hookSettingsRemoved + hookEventsRemoved + staleHookEventsRemoved > 0
    }
}
