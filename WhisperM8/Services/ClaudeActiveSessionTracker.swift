import Foundation

/// Tracking-Eintrag pro lokalem WhisperM8-Tab. Wird vom Resolver und vom
/// Lazy-Check (`repairResumeStateBeforeLaunch`) genutzt — kein
/// Background-Polling mehr.
struct ClaudeActiveSessionTrackerEntry: Equatable {
    let localSessionID: UUID
    let projectCwd: String
    var currentExternalID: String?
    let launchedAt: Date
}

/// Ergebnis einer Resolver-Anfrage. Pure Daten — der Aufrufer entscheidet,
/// was mit der neuen ID passieren soll.
enum ClaudeActiveSessionDecision: Equatable {
    case unchanged
    case rebind(newExternalID: String, title: String?)
    case ambiguous(candidates: [IndexedAgentSession])
}

/// Pure, testbare Entscheidungs-Logik. Keine FS-Zugriffe, keine Zeit.
///
/// Wird **nicht** mehr von einem Background-Timer aufgerufen — Real-Time-
/// Detection laeuft event-driven via `ClaudeHookBridge` (Hook-Events via
/// `DispatchSource`). Der Resolver bleibt fuer Lazy-Checks vor einem
/// Resume-Launch und fuer Tests.
enum ClaudeActiveSessionResolver {
    static func decide(
        entry: ClaudeActiveSessionTrackerEntry,
        indexedSessions: [IndexedAgentSession],
        now: Date = Date()
    ) -> ClaudeActiveSessionDecision {
        let canonical = AgentSessionStore.canonicalProjectPath(entry.projectCwd)
        let projectSessions = indexedSessions.filter { indexed in
            indexed.provider == .claude
                && AgentSessionStore.canonicalProjectPath(indexed.cwd) == canonical
        }

        let launchedThreshold = entry.launchedAt.addingTimeInterval(-5)
        let candidates = projectSessions.filter { indexed in
            indexed.externalSessionID != entry.currentExternalID
                && indexed.lastActivityAt >= launchedThreshold
        }

        guard !candidates.isEmpty else {
            return .unchanged
        }

        let sorted = candidates.sorted { $0.lastActivityAt > $1.lastActivityAt }
        if sorted.count == 1 {
            let pick = sorted[0]
            return .rebind(newExternalID: pick.externalSessionID, title: pick.title)
        }
        let leader = sorted[0]
        let runner = sorted[1]
        let gap = leader.lastActivityAt.timeIntervalSince(runner.lastActivityAt)
        if gap >= 2.0 {
            return .rebind(newExternalID: leader.externalSessionID, title: leader.title)
        }
        return .ambiguous(candidates: sorted)
    }
}
