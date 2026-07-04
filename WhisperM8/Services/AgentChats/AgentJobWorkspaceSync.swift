import AppKit
import Foundation

/// Spiegelt die Subagent-Jobs aus `agent-jobs/` in den Workspace und die
/// UI-Laufzeitmodelle. Event-getrieben (FSEvents via
/// `AgentJobDirectoryMonitor`) plus Launch-/Foreground-Trigger — kein Polling.
///
/// Ablauf pro Sync:
/// 1. Job-Snapshots OFF-MAIN lesen (`readAllCorrected` macht stat + Liveness-
///    Probe pro Job — nichts für den MainActor).
/// 2. Phasen-Diff gegen den letzten Lauf (running→done/failed ⇒ Unread).
/// 3. `AgentSessionStore.mergeSubagentJobs` auf dem MainActor (idempotent,
///    Parent-Projekt-Auflösung passiert lock-konform im Store).
/// 4. `AgentJobRuntimeModel` + Status-Koordinator + Unread-Marker füttern.
@MainActor
final class AgentJobWorkspaceSync {
    static let shared = AgentJobWorkspaceSync()

    private let monitor: AgentJobDirectoryMonitor
    private let store: AgentSessionStore
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var started = false
    private var isSyncing = false
    private var pendingSync = false
    /// Letzte bekannte Phase pro Short-ID — Basis des Übergangs-Diffs.
    private var lastPhaseByShortId: [String: AgentJobState.State] = [:]

    init(
        monitor: AgentJobDirectoryMonitor? = nil,
        store: AgentSessionStore = AgentSessionStore()
    ) {
        // Kein Default-Argument: die Auswertung von Defaults ist nonisolated,
        // der Monitor-Init aber @MainActor.
        self.monitor = monitor ?? AgentJobDirectoryMonitor()
        self.store = store
    }

    /// Startet Monitor + Lifecycle-Hooks (Muster
    /// `AgentScanCoordinator.installLifecycleHooks`) und macht einen
    /// initialen Sync. Idempotent.
    func start() {
        guard !started else { return }
        started = true

        monitor.onJobsChanged = { [weak self] in
            self?.requestSync(reason: "fsevent")
        }
        monitor.start()

        let didBecomeActive = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                AgentJobWorkspaceSync.shared.requestSync(reason: "foreground")
            }
        }
        lifecycleObservers.append(didBecomeActive)

        requestSync(reason: "launch")
    }

    /// Coalescing: läuft bereits ein Sync, wird genau EIN Folge-Lauf gemerkt
    /// (der liest ohnehin den frischesten Disk-Stand).
    func requestSync(reason: String) {
        if isSyncing {
            pendingSync = true
            return
        }
        isSyncing = true
        Task { @MainActor in
            await self.performSync(reason: reason)
            self.isSyncing = false
            if self.pendingSync {
                self.pendingSync = false
                self.requestSync(reason: "coalesced")
            }
        }
    }

    private func performSync(reason: String) async {
        let startedAt = Date()

        // 1. Disk-Reads off-main — Store-Lock verbietet I/O in der Mutation,
        //    und die Liveness-Probes (kill(pid,0)) gehören nicht auf Main.
        let jobs = await Task.detached(priority: .utility) {
            AgentJobStore().readAllCorrected()
        }.value

        // 2. Phasen-Diff: nur ECHTE Übergänge bumpen Aktivität/Unread.
        //    Jobs, die dieser Prozess noch nie gesehen hat (erster Lauf nach
        //    App-Start), zählen nicht als Übergang.
        var bumpShortIds: Set<String> = []
        var completedShortIds: Set<String> = []
        for job in jobs {
            guard let previous = lastPhaseByShortId[job.shortId], previous != job.state else { continue }
            bumpShortIds.insert(job.shortId)
            if previous == .running || previous == .spawning,
               job.state == .done || job.state == .failed {
                completedShortIds.insert(job.shortId)
            }
        }
        lastPhaseByShortId = Dictionary(uniqueKeysWithValues: jobs.map { ($0.shortId, $0.state) })

        // 3. Workspace-Merge (idempotent, diff-gated persistiert).
        do {
            try store.mergeSubagentJobs(jobs, activityBumpShortIds: bumpShortIds)
        } catch {
            Logger.agentStore.warning("subagent_sync_merge_failed error=\(error.localizedDescription, privacy: .public)")
        }

        // 4. Projektionen füttern: Runtime-Modell, Status-Dots, Unread.
        let workspace = store.loadWorkspace()
        var sessionByShortId: [String: AgentChatSession] = [:]
        var parentIDByExternalID: [String: UUID] = [:]
        for session in workspace.sessions {
            if session.isSubagentJob, let shortId = session.subagentJobShortID {
                sessionByShortId[shortId] = session
            } else if let externalID = session.externalSessionID, !session.isSubagentJob {
                parentIDByExternalID[externalID] = session.id
            }
        }

        var snapshots: [UUID: AgentJobState] = [:]
        var runningByParent: [UUID: Int] = [:]
        for job in jobs {
            guard let session = sessionByShortId[job.shortId] else { continue }
            snapshots[session.id] = job
            AgentSessionStatusCoordinator.shared.updateSubagentJobStatus(
                sessionID: session.id,
                state: job.state
            )
            if job.isActive,
               let parentExtID = session.subagentParentSessionID,
               let parentID = parentIDByExternalID[parentExtID] {
                runningByParent[parentID, default: 0] += 1
            }
            if completedShortIds.contains(job.shortId) {
                AgentWindowStore.shared.markSubagentUnread(session.id)
                AgentSessionStatusCoordinator.shared.postSubagentNotification(
                    sessionID: session.id,
                    failed: job.state == .failed
                )
            }
        }
        AgentJobRuntimeModel.shared.apply(
            snapshotsBySessionID: snapshots,
            runningCountByParentSessionID: runningByParent
        )

        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        Logger.agentPerformance.debug("subagent_sync reason=\(reason, privacy: .public) jobs=\(jobs.count) durationMs=\(durationMs)")
    }

    deinit {
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }
}
