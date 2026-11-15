import Foundation

// Hintergrund-Befehle beim Turn-Ende (WM8-105): Während ein Chat arbeitet,
// liest die App sein Transcript gedrosselt im Hintergrund nach. Das Turn-Ende
// liest dann auf dem Main Thread nur den Rest, höchstens 2 MB
// (`ClaudeBackgroundTaskMonitor.turnEndReadLimit`).

extension AgentSessionStatusCoordinator {
    /// Ein Takt je Chat, solange er arbeitet; endet mit dem Turn.
    func keepBackgroundTasksRead(_ sessionID: UUID) {
        guard !backgroundCatchUpRunning.contains(sessionID) else { return }
        backgroundCatchUpRunning.insert(sessionID)
        let interval = backgroundCatchUpSeconds
        Task { @MainActor [weak self] in
            defer { self?.backgroundCatchUpRunning.remove(sessionID) }
            while true {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self, self.statusStore.status(for: sessionID) == .working else { return }
                self.prefetchBackgroundTasks(sessionID)
            }
        }
    }
}
