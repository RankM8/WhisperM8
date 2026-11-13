import Foundation

// MARK: - Ende eines Chat-Prozesses, ohne Ansicht

/// Was passiert, wenn der Prozess eines Chats endet: Status im Store von
/// `running` auf `closed`, Meldung an den Statuskoordinator, Erkennung eines
/// schnell gescheiterten `claude attach`.
///
/// Das lag bis 13.11.2026 in `AgentSessionDetailView.markTerminated` und lief
/// deshalb nur, solange die Ansicht des Chats lebte. Jetzt meldet die Registry
/// das Ende selbst; die Ansicht bekommt das Ergebnis und kümmert sich nur noch
/// um ihren Teil (Rückweg nach gescheitertem Andocken, Fehlermeldung,
/// Auffrischen). Voraussetzung für Chats ohne Ansicht, etwa nach einem
/// Neustart ohne Chatverlust (docs/plans/neustart-ohne-chatverlust.md).
@MainActor
struct AgentChatTermination {
    struct Outcome: Equatable {
        var exitCode: Int32?
        /// Schnell gescheitertes `claude attach`: die Ansicht stößt den
        /// Rückweg an (`AgentAttachRecovery`).
        var quickFailedAttach: Bool
        /// Status ließ sich nicht schreiben; der Koordinator wurde dann nicht
        /// benachrichtigt (wie bisher). Die Ansicht zeigt den Text.
        var errorDescription: String?
    }

    /// Setzt `running` → `closed`; wirft, wenn der Store nicht schreibt.
    var markClosed: (UUID) throws -> Void
    var notifyStatus: (UUID, Int32?) -> Void
    var now: () -> Date = Date.init

    static let live = storeBacked(
        AgentSessionStore(),
        notifyStatus: { id, exitCode in
            AgentSessionStatusCoordinator.shared.sessionTerminated(sessionID: id, exitCode: exitCode)
        }
    )

    /// Schreibt in den angegebenen Store (Tests: eigener Workspace).
    static func storeBacked(
        _ store: AgentSessionStore,
        notifyStatus: @escaping (UUID, Int32?) -> Void
    ) -> AgentChatTermination {
        AgentChatTermination(
            markClosed: { id in
                try store.updateSession(id: id) { updated in
                    if updated.status == .running {
                        updated.status = .closed
                    }
                }
            },
            notifyStatus: notifyStatus
        )
    }

    /// Für Registries in Tests: schreibt nichts und meldet nichts.
    static let inert = AgentChatTermination(markClosed: { _ in }, notifyStatus: { _, _ in })

    /// - Parameter endedController: Der Controller, der beim Ende noch in der
    ///   Registry steht. Fehlt er, hat die App den Prozess selbst beendet
    ///   (`terminate()` entfernt ihn vorher) — dann ist es kein gescheitertes
    ///   Andocken.
    func handle(sessionID: UUID, exitCode: Int32?, endedController: AgentTerminalController?) -> Outcome {
        let quickFailedAttach = AgentAttachRecovery.isQuickFailedAttach(
            isBackgroundAttachFallback: endedController?.command.isBackgroundAttachFallback ?? false,
            end: AgentAttachRecovery.decode(waitStatus: exitCode),
            runDuration: endedController?.startedAt.map { now().timeIntervalSince($0) }
        )
        do {
            try markClosed(sessionID)
            notifyStatus(sessionID, exitCode)
            return Outcome(exitCode: exitCode, quickFailedAttach: quickFailedAttach, errorDescription: nil)
        } catch {
            return Outcome(exitCode: exitCode, quickFailedAttach: quickFailedAttach,
                           errorDescription: error.localizedDescription)
        }
    }
}
