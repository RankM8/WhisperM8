import Foundation
import os

/// Doppelstart-Sperre für Codex (`CodexSessionRunningGuard`): Prozessliste
/// abseits des Main Threads lesen, Prüfung beim Bauen gegen die eigenen
/// laufenden Chats der App.
extension AgentSessionDetailView {
    /// Nur vor einem Codex-Resume, nicht auf dem Main Thread. `nil`, wenn die
    /// Prozessliste nicht lesbar ist (dann nicht sperren).
    nonisolated static func codexProcessesForLaunch(_ session: AgentChatSession) -> [CodexProcess]? {
        // Bewusst ohne `hasLaunchedInitialPrompt`: Der Stand kann veraltet sein
        // (Job-Übernahme), und die Prüfung kostet nur etwa 0,4 ms.
        guard session.provider == .codex, !session.isTerminal,
              AppPreferences.shared.isCodexStartGuardEnabled else { return [] }
        let start = DispatchTime.now().uptimeNanoseconds
        let processes = CodexSessionRunningGuard.liveCodexProcesses()
        let micros = (DispatchTime.now().uptimeNanoseconds - start) / 1000
        if let processes {
            Logger.agentStore.info("codex_running_guard_scan us=\(micros) codex=\(processes.count)")
        } else {
            Logger.agentStore.error("codex_running_guard_unreadable us=\(micros) — Start ohne Prüfung fremder Prozesse")
        }
        return processes
    }

    @MainActor
    static func codexConflict(
        sessionID: String,
        localID: UUID,
        processes: [CodexProcess]?,
        store: AgentSessionStore,
        registry: AgentTerminalRegistry
    ) -> CodexRunningConflict? {
        let sessions = Dictionary(store.loadWorkspace().sessions.map { ($0.id, $0) },
                                  uniquingKeysWith: { first, _ in first })
        // Alle laufenden Controller, auch Terminal-Tabs: Läuft dort `codex
        // resume`, nennt die Meldung den Tab statt „außerhalb“.
        let appChats = CodexSessionRunningGuard.appChats(
            controllers: registry.runningControllers.map {
                (sessionID: $0.sessionID, arguments: $0.command.arguments, processID: $0.processID)
            },
            sessions: sessions)
        return CodexSessionRunningGuard.conflict(
            sessionID: sessionID,
            localID: localID,
            appChats: appChats,
            processes: processes,
            terminatingOwner: { ProcessTerminationLedger.shared.owner(ofTerminating: $0, startTime: $1) },
            formerOwner: { ProcessTerminationLedger.shared.formerOwner(of: $0, startTime: $1) },
            titleOf: { sessions[$0]?.title ?? String($0.uuidString.prefix(8)).lowercased() })
    }
}
