import Foundation
import Observation

/// Ephemere @Observable-Projektion der Subagent-Job-Zustände für die UI —
/// Pendant zum `AgentSessionRuntimeStatusStore`, aber mit den vollen
/// `AgentJobState`-Snapshots (Detail-View braucht Phase/Metrics/Worktree)
/// plus dem Zähler-Chip-Input für Parent-Rows. Wird ausschließlich vom
/// `AgentJobWorkspaceSync` gepflegt; Views lesen nur.
@MainActor
@Observable
final class AgentJobRuntimeModel {
    static let shared = AgentJobRuntimeModel()

    /// Aktueller Job-Snapshot pro lokaler Session-ID (`.subagentJob`-Sessions).
    private(set) var snapshotsBySessionID: [UUID: AgentJobState] = [:]
    /// Anzahl aktiver (spawning/running) Kinder pro Parent-SESSION (lokale
    /// UUID der Claude-Session, die den Job gespawnt hat).
    private(set) var runningCountByParentSessionID: [UUID: Int] = [:]
    /// Lokal markierte Übernahmen — sofort gesetzt beim Klick auf
    /// „Interaktiv übernehmen", damit die UI nicht auf den FSEvents-Roundtrip
    /// des state.json-Flips warten muss.
    private var locallyTakenOver: Set<UUID> = []

    func snapshot(for sessionID: UUID) -> AgentJobState? {
        snapshotsBySessionID[sessionID]
    }

    func runningCount(forParent sessionID: UUID) -> Int {
        runningCountByParentSessionID[sessionID] ?? 0
    }

    /// `true` sobald der Job übernommen wurde — lokal ODER laut Disk-State.
    /// Der mainWorkspace-Switch rendert dann `AgentSessionDetailView` (PTY)
    /// statt der Job-Detail-View.
    func isTakenOver(_ sessionID: UUID) -> Bool {
        locallyTakenOver.contains(sessionID)
            || snapshotsBySessionID[sessionID]?.state == .takenOver
    }

    func setTakenOverLocally(_ sessionID: UUID) {
        locallyTakenOver.insert(sessionID)
    }

    /// Session-IDs mit aktivem Job (spawning/running) — Input für den
    /// Sidebar-Scope („laufende Subagents nie ausblenden").
    var activeSubagentSessionIDs: Set<UUID> {
        Set(snapshotsBySessionID.filter { $0.value.isActive }.keys)
    }

    /// Kompletter Austausch pro Sync-Lauf, diff-gated: identische Snapshots
    /// lösen keine Observation-Invalidierung (= keine Re-Render) aus.
    func apply(
        snapshotsBySessionID snapshots: [UUID: AgentJobState],
        runningCountByParentSessionID runningCounts: [UUID: Int]
    ) {
        if snapshotsBySessionID != snapshots {
            snapshotsBySessionID = snapshots
        }
        if runningCountByParentSessionID != runningCounts {
            runningCountByParentSessionID = runningCounts
        }
        // Lokale Übernahme-Marker aufräumen, sobald der Disk-State die
        // Übernahme bestätigt (oder der Job verschwunden ist) — der Snapshot
        // trägt die Wahrheit dann selbst.
        locallyTakenOver = locallyTakenOver.filter { id in
            guard let state = snapshots[id]?.state else { return false }
            return state != .takenOver
        }
    }
}
