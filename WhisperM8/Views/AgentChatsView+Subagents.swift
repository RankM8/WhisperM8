import SwiftUI

/// Subagent-Jobs der AgentChatsView: Übernahme-Flow („Interaktiv
/// übernehmen") — der Rest der Job-UI lebt in `SubagentJobDetailView`.
/// Eigene Extension-Datei nach dem Phase-2-Muster (+BackgroundAgents etc.).
extension AgentChatsView {
    /// Übernimmt einen Subagent-Job dauerhaft + exklusiv als interaktiven
    /// Codex-Chat. Ablauf (Plan 3.6):
    /// 1. Guard: Phase ∈ {done, failed, stopped} — laufende Jobs erst stoppen.
    /// 2. `transition(.takenOver)` in state.json (geteilter Writer, verweigert
    ///    z. B. wenn `agent send` parallel resumed hat).
    /// 3. Session-Felder defensiv reparieren (externalSessionID = ThreadID,
    ///    hasLaunchedInitialPrompt, subagentCwd).
    /// 4. Lokal als übernommen markieren (nicht auf den FSEvents-Roundtrip
    ///    warten) + Status-Koordinator auf clear (ab jetzt PTY-Pfad).
    /// 5. Start über den bestehenden Mechanismus — exakt wie der
    ///    BG-Agent-Attach (`sessionActionRequest`, +BackgroundAgents).
    @MainActor
    func takeOverSubagentJob(_ session: AgentChatSession) {
        guard let shortId = session.subagentJobShortID else {
            errorMessage = "Job-Verzeichnis unbekannt — Übernahme nicht möglich."
            return
        }
        Task { @MainActor in
            let outcome: Result<AgentJobState, Error> = await Task.detached(priority: .userInitiated) {
                let jobStore = AgentJobStore()
                guard let state = jobStore.readCorrected(shortId: shortId) else {
                    return .failure(AgentJobStore.StoreError.jobNotFound(shortId))
                }
                guard !state.isActive else {
                    return .failure(AgentJobStore.StoreError.invalidTransition(from: state.state, to: .takenOver))
                }
                do {
                    return .success(try jobStore.transition(shortId: shortId, to: .takenOver))
                } catch {
                    return .failure(error)
                }
            }.value

            switch outcome {
            case .failure(let error):
                errorMessage = "Übernahme fehlgeschlagen: \(error.localizedDescription)"
            case .success(let jobState):
                // Session-Felder defensiv prüfen — der Resume-Branch von
                // `codexCommand()` braucht externalSessionID + subagentCwd.
                do {
                    try store.updateSession(id: session.id) { updated in
                        if updated.externalSessionID == nil {
                            updated.externalSessionID = jobState.codexThreadID
                        }
                        if !updated.hasLaunchedInitialPrompt {
                            updated.hasLaunchedInitialPrompt = true
                        }
                        if updated.subagentCwd == nil {
                            updated.subagentCwd = jobState.worktree?.path ?? jobState.cwd
                        }
                    }
                } catch {
                    errorMessage = error.localizedDescription
                    return
                }

                // Sofort lokal markieren — mainWorkspace rendert dadurch
                // umgehend die AgentSessionDetailView (PTY).
                jobRuntimeModel.setTakenOverLocally(session.id)
                AgentSessionStatusCoordinator.shared.updateSubagentJobStatus(
                    sessionID: session.id,
                    state: .takenOver
                )
                openTab(session.id)
                selectedSessionID = session.id
                sessionActionRequest = AgentSessionActionRequest(sessionID: session.id, kind: .start)
                AgentJobWorkspaceSync.shared.requestSync(reason: "takeover")
            }
        }
    }
}
