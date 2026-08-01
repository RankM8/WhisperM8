import Foundation

/// Aufräumregel für die Workspace-Spiegel der CLI-Subagent-Jobs
/// (`whisperm8 agent`).
///
/// Hintergrund: `mergeSubagentJobs` ist bewusst additiv — verschwindet ein
/// Job-Verzeichnis (`agent rm`, manuelles Löschen), wird nur die Short-ID
/// genilt, die Session bleibt stehen, damit der Indexer die Codex-Session
/// adoptieren kann. Was fehlte, war die Gegenbewegung: die Einträge sind nie
/// wieder verschwunden. Bei intensiver CLI-Nutzung sammeln sich so Tausende
/// Karteileichen in der Sidebar an (Befund 2026-08-01: 2599 verwaiste
/// Einträge = 83 % der Workspace-Datei).
///
/// Die Regel ist bewusst eng: fällig ist nur, was auf Disk ohnehin nicht mehr
/// existiert. Solange das Job-Verzeichnis lebt, bleibt der Eintrag — der
/// nächste Sync würde ihn sonst sofort neu anlegen (Löschen wäre ein
/// Flip-Flop). Job-Verzeichnisse selbst räumt weiterhin nur `agent rm`: sie
/// können git-Worktrees enthalten, deren Entfernung über `git worktree remove`
/// laufen muss und nicht über einen blinden Verzeichnis-Löscher.
struct SubagentJobRetentionPolicy: Equatable {
    /// Abgeschlossene Jobs verschwinden 7 Tage nach ihrer letzten Aktivität.
    static let defaultMaxAge: TimeInterval = 7 * 24 * 60 * 60

    var maxAge: TimeInterval = defaultMaxAge

    /// Ein fälliger Spiegel-Eintrag samt der Angaben, die zum Aufräumen der
    /// zugehörigen Artefakte nötig sind.
    struct Candidate: Equatable, Hashable {
        var sessionID: UUID
        /// Codex-Thread-ID → Rollout-JSONL in `~/.codex/sessions`.
        var externalSessionID: String?
    }

    /// Ermittelt die fälligen Einträge. Pur und ohne I/O — der Aufrufer
    /// liefert den Disk-Zustand (`liveJobShortIDs`) und die Uhr.
    ///
    /// - Parameters:
    ///   - liveJobShortIDs: Short-IDs der Jobs, die aktuell in `agent-jobs/`
    ///     existieren. Deren Sessions sind tabu.
    ///   - protectedSessionIDs: Sessions, die der Nutzer gerade sieht
    ///     (offene Tabs, Pins, Grid-Kacheln) — nie wegräumen, auch wenn sie
    ///     formal fällig wären.
    ///   - requiresClearedShortID: Nur Einträge, deren Short-ID der Merge
    ///     bereits genilt hat. Schutz für den fristlosen Altlasten-Lauf: wäre
    ///     `agent-jobs/` in dem Moment nicht lesbar, käme eine leere
    ///     `liveJobShortIDs`-Menge herein und alle lebenden Jobs sähen
    ///     verwaist aus. Im Normalbetrieb ist die Frist dieser Schutz.
    func expiredSessions(
        in sessions: [AgentChatSession],
        liveJobShortIDs: Set<String>,
        protectedSessionIDs: Set<UUID> = [],
        requiresClearedShortID: Bool = false,
        now: Date
    ) -> [Candidate] {
        sessions.compactMap { session in
            guard session.isSubagentJob else { return nil }
            guard !protectedSessionIDs.contains(session.id) else { return nil }
            // Laufende Jobs sind unantastbar, egal wie alt der Zeitstempel ist.
            guard session.status != .running, session.status != .pending else { return nil }
            if requiresClearedShortID, session.subagentJobShortID != nil { return nil }
            // Job lebt noch auf Disk → der nächste Merge legt den Eintrag
            // ohnehin sofort wieder an.
            if let shortID = session.subagentJobShortID, liveJobShortIDs.contains(shortID) {
                return nil
            }
            guard now.timeIntervalSince(session.lastActivityAt) > maxAge else { return nil }
            return Candidate(
                sessionID: session.id,
                externalSessionID: session.externalSessionID
            )
        }
    }
}

/// Verschiebt die Rollout-Transcripts abgeräumter Subagent-Jobs aus
/// `~/.codex/sessions` in ein WhisperM8-Archiv.
///
/// Warum verschieben statt löschen: Der Indexer scannt `~/.codex/sessions` und
/// erkennt Subagent-Threads nur daran, dass eine `.subagentJob`-Session sie
/// beansprucht (`subagentThreadIDs` in `mergeIndexedSessions`). Ist der
/// Workspace-Eintrag weg, das Transcript aber noch am alten Ort, legt der
/// nächste Scan es als ganz normalen Codex-Chat neu an — das Aufräumen würde
/// sich selbst rückgängig machen. Aus dem Scan-Root heraus ist das Problem
/// gelöst, ohne ein Byte zu vernichten: `~/.codex` gilt im Projekt als extern,
/// deshalb wird dort nichts überschrieben und nichts gelöscht.
struct SubagentJobTranscriptArchiver {
    struct Result: Equatable {
        var movedCount = 0
        var missingCount = 0
        var failedCount = 0
        var movedBytes: Int64 = 0
    }

    static var defaultArchiveRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperM8/agent-jobs-archive", isDirectory: true)
    }

    var archiveRoot: URL = SubagentJobTranscriptArchiver.defaultArchiveRoot
    /// Auflösung Thread-ID → Rollout-JSONL. Default ist der gecachte Locator
    /// (ein Verzeichnis-Walk, danach beantwortet der Cache alle weiteren
    /// Abfragen) — Tests injizieren eine Map.
    var locate: (String) -> URL? = { CodexTranscriptLocator.url(forSessionID: $0) }
    var fileManager: FileManager = .default

    /// Blockierendes Datei-I/O — gehört auf einen Utility-Thread, nie auf den
    /// MainActor.
    func archive(_ candidates: [SubagentJobRetentionPolicy.Candidate]) -> Result {
        var result = Result()
        let threadIDs = candidates.compactMap(\.externalSessionID).filter { !$0.isEmpty }
        guard !threadIDs.isEmpty else { return result }

        do {
            try fileManager.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
        } catch {
            Logger.agentStore.warning(
                "subagent_retention_archive_dir_failed error=\(error.localizedDescription, privacy: .public)"
            )
            result.failedCount = threadIDs.count
            return result
        }

        for threadID in threadIDs {
            guard let source = locate(threadID),
                  fileManager.fileExists(atPath: source.path) else {
                result.missingCount += 1
                continue
            }
            let size = (try? fileManager.attributesOfItem(atPath: source.path)[.size] as? Int64) ?? nil
            let destination = uniqueDestination(for: source)
            do {
                try fileManager.moveItem(at: source, to: destination)
                result.movedCount += 1
                result.movedBytes += size ?? 0
            } catch {
                result.failedCount += 1
                Logger.agentStore.warning(
                    "subagent_retention_archive_failed file=\(source.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return result
    }

    /// Der Dateiname enthält die Thread-UUID, ist also praktisch eindeutig —
    /// eine Kollision (z. B. zweiter Lauf nach manuellem Zurückkopieren) darf
    /// trotzdem nichts überschreiben.
    private func uniqueDestination(for source: URL) -> URL {
        let candidate = archiveRoot.appendingPathComponent(source.lastPathComponent)
        guard fileManager.fileExists(atPath: candidate.path) else { return candidate }
        let stem = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        for suffix in 2...99 {
            let retry = archiveRoot
                .appendingPathComponent("\(stem)-\(suffix)")
                .appendingPathExtension(ext)
            if !fileManager.fileExists(atPath: retry.path) { return retry }
        }
        return archiveRoot.appendingPathComponent("\(stem)-\(UUID().uuidString)").appendingPathExtension(ext)
    }
}
