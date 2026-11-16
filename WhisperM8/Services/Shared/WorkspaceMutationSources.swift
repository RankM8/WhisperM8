import Foundation
import os

/// Wer hat den Chat-Bestand geändert? (WM8-101)
///
/// `workspace.apply` misst jede Änderung am Arbeitsbereich bis zum nächsten
/// Commit, nennt aber nicht, wer sie ausgelöst hat. Nach einer Änderung per
/// `chats workspace add`/`remove` kam 1 bis 3 s später eine zweite mit rund
/// 280 ms, deren Quelle offen war. Jede Mutation, die den Bestand tatsächlich
/// ändert, trägt deshalb ihren Aufrufer ein (`#function` an
/// `AgentWorkspaceStore.mutate`). Reißt `workspace.apply` das Budget, nennt
/// das Log die Aufrufer des Durchgangs (`workspace_apply_sources`).
///
/// Nur mit der Detail-Stufe aktiv; sonst kostet ein Eintrag einen
/// Bool-Vergleich. Gezählt wird je Aufrufer, die Menge ist damit durch die
/// Zahl der Mutatoren begrenzt (rund 30), nicht durch die Zahl der Änderungen.
final class WorkspaceMutationSources: @unchecked Sendable {
    static let shared = WorkspaceMutationSources()

    private let counts = OSAllocatedUnfairLock(initialState: [String: Int]())

    func record(_ caller: String) {
        guard PerfBudgets.workspaceApply.isActive else { return }
        counts.withLock { $0[caller, default: 0] += 1 }
    }

    /// Liefert die Aufrufer seit dem letzten Abholen und leert die Liste.
    func drain() -> [String: Int] {
        counts.withLock { current in
            defer { current.removeAll(keepingCapacity: true) }
            return current
        }
    }

    /// Lesbare, stabile Form für das Log: häufigste zuerst, bei Gleichstand
    /// nach Namen; mehrfache mit „×n“.
    static func describe(_ counts: [String: Int]) -> String {
        guard !counts.isEmpty else { return "-" }
        return counts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { $0.value > 1 ? "\($0.key)×\($0.value)" : $0.key }
            .joined(separator: ",")
    }
}
