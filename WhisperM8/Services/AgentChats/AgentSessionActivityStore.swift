import Combine
import Foundation

/// Ephemerer Speicher für die Stand-Zeile (`AgentSessionActivity`) und den
/// Zeitpunkt des letzten echten Statuswechsels pro Session — die Datenbasis
/// des Tab-Switchers („arbeitet · 2 min", „› Edit Store.swift").
///
/// **Bewusst ein eigener Store, nicht Teil von
/// `AgentSessionRuntimeStatusStore.statuses`:** Die Stand-Zeile ändert sich
/// bei arbeitenden Chats mit fast jedem Transcript-Write. Läge sie neben dem
/// Status, invalidierte jede neue Zeile jede Sidebar-Row (Messung „Alle"-Klick,
/// 30.09.–01.10.2026). Die Sidebar beobachtet diesen Store deshalb NIE, auch
/// nicht indirekt über einen gemeinsamen Elternwert — nur der Switcher, der
/// ausschließlich während des Umschaltens existiert.
///
/// Einziger Schreiber ist der `AgentSessionStatusCoordinator` (Transcript-
/// Stand vom Watcher, Warte-Art aus dem Hook-Pfad, `statusSince` an jedem
/// echten Statuswechsel). Nichts davon wird persistiert.
@MainActor
final class AgentSessionActivityStore: ObservableObject {
    @Published private(set) var activities: [UUID: AgentSessionActivity] = [:]
    /// Seit wann die Session in ihrem aktuellen `AgentSessionRuntimeStatus`
    /// ist. Fehlt der Eintrag, ist der Zeitpunkt unbekannt (z. B. vor dem
    /// ersten Wechsel seit App-Start).
    @Published private(set) var statusSince: [UUID: Date] = [:]

    func activity(for sessionID: UUID) -> AgentSessionActivity? {
        activities[sessionID]
    }

    func statusSince(for sessionID: UUID) -> Date? {
        statusSince[sessionID]
    }

    /// Transcript-Teil aus dem Watcher setzen; die Warte-Art bleibt erhalten.
    func setTranscriptDetail(_ detail: AgentSessionActivity.Detail?, for sessionID: UUID) {
        var activity = activities[sessionID] ?? AgentSessionActivity()
        activity.detail = detail
        store(activity, for: sessionID)
    }

    /// Hook-Teil setzen (Warte-Art + optional Tool-Name einer
    /// Berechtigungs-Anfrage); der Transcript-Teil bleibt erhalten.
    func setAwaiting(_ kind: AwaitingInputKind?, toolName: String?, for sessionID: UUID) {
        var activity = activities[sessionID] ?? AgentSessionActivity()
        activity.awaitingKind = kind
        activity.awaitingToolName = kind == nil ? nil : toolName
        store(activity, for: sessionID)
    }

    /// Echter Statuswechsel — der Aufrufer garantiert, dass sich der Status
    /// tatsächlich geändert hat.
    func noteStatusChange(for sessionID: UUID, at date: Date) {
        statusSince[sessionID] = date
    }

    func clearStatusSince(for sessionID: UUID) {
        guard statusSince[sessionID] != nil else { return }
        statusSince.removeValue(forKey: sessionID)
    }

    private func store(_ activity: AgentSessionActivity, for sessionID: UUID) {
        if activity.isEmpty {
            guard activities[sessionID] != nil else { return }
            activities.removeValue(forKey: sessionID)
            return
        }
        // Gleicher Wert → kein objectWillChange (der Watcher meldet ohnehin
        // nur Änderungen, der Hook-Pfad aber bei jedem Signal).
        guard activities[sessionID] != activity else { return }
        activities[sessionID] = activity
    }
}
