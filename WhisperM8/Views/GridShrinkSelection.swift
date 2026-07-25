import Foundation

/// Laufende Verkleinerung, bei der der User im Grid entscheidet, welche Chats
/// bleiben — der Ersatz für den früheren Text-Dialog „Workspace verkleinern?".
///
/// Der Modus startet nur bei echtem Überhang: passt die Belegung nach dem
/// Kompaktieren (`WorkspaceSlotOps.planCapacityChange`) in die Zielstufe, wird
/// direkt angewendet, ohne zu fragen.
///
/// Referenztyp mit `@Observable`, gehalten als optionaler `@State` der
/// `AgentChatsView`. Der teure View-Body liest ausschließlich
/// `gridShrinkSelection != nil` und die `let`-Properties — `let`s werden von
/// Observation nicht getrackt, ein Markierungswechsel invalidiert ihn also
/// nicht. `retainedIDs` lesen nur die beiden Miniatur-Views
/// (`GridShrinkActionBar`, `GridSlotSelectionOverlay`).
@Observable
final class GridShrinkSelection {
    let workspaceID: UUID
    /// Stufe, auf die verkleinert werden soll (immer < aktueller Kapazität).
    let targetCapacity: Int

    /// Alle belegten Sessions in SLOT-Reihenfolge — sie bestimmt auch die
    /// spätere Anordnung, nie die Klick-Reihenfolge des Users.
    private(set) var candidateIDs: [UUID]
    private(set) var retainedIDs: Set<UUID>

    /// Vorbelegung = die Auto-Politik aus `planCapacityChange` (die vorderen
    /// `targetCapacity` Belegten bleiben). Ein einziger Klick auf
    /// „Verkleinern" entspricht damit dem alten Verhalten — der Modus ist eine
    /// Korrekturmöglichkeit, kein Zwang.
    init(workspaceID: UUID, targetCapacity: Int, candidates: [UUID]) {
        self.workspaceID = workspaceID
        self.targetCapacity = targetCapacity
        self.candidateIDs = candidates
        self.retainedIDs = Set(candidates.prefix(max(0, targetCapacity)))
    }

    // MARK: - Ableitungen

    var orderedRetained: [UUID] { candidateIDs.filter { retainedIDs.contains($0) } }
    var orderedEvicted: [UUID] { candidateIDs.filter { !retainedIDs.contains($0) } }

    func isRetained(_ sessionID: UUID) -> Bool { retainedIDs.contains(sessionID) }

    /// Künftige Slot-Position (1-basiert) für das Badge an der Pane —
    /// `nil`, wenn dieser Chat den Workspace verlässt.
    func retentionSlotNumber(of sessionID: UUID) -> Int? {
        orderedRetained.firstIndex(of: sessionID).map { $0 + 1 }
    }

    /// Weniger behalten als Slots ist erlaubt (der Workspace bleibt, nur
    /// leerer) — nur MEHR als die Zielstufe fasst geht nicht.
    var isCommitEnabled: Bool { retainedIDs.count <= targetCapacity }

    /// Wie viele muss der User noch abwählen, damit es passt (0 = passt).
    var overflowCount: Int { max(0, retainedIDs.count - targetCapacity) }

    // MARK: - Mutation

    func toggle(_ sessionID: UUID) {
        guard candidateIDs.contains(sessionID) else { return }
        if retainedIDs.contains(sessionID) {
            retainedIDs.remove(sessionID)
        } else {
            retainedIDs.insert(sessionID)
        }
    }

    // MARK: - Rekonziliation

    enum Reconciliation: Equatable {
        /// Weiter im Modus (Kandidaten/Markierungen wurden angeglichen).
        case continues
        /// Es passt jetzt ohne Auswahl — Modus verlassen und direkt anwenden.
        case noLongerNeeded
        /// Grundlage weg (Workspace leer) — nur verlassen.
        case obsolete
    }

    /// Gleicht die Auswahl an eine von außen geänderte Belegung an (anderes
    /// Fenster, Kontextmenü, Archivierung, `prune`). Verschwundene Chats
    /// fallen aus der Markierung; NEU hinzugekommene starten unmarkiert —
    /// sie sind an der Pane sichtbar als „verlässt" ausgewiesen, verschwinden
    /// also nie stillschweigend.
    func reconcile(withOccupied occupied: [UUID]) -> Reconciliation {
        candidateIDs = occupied
        retainedIDs.formIntersection(occupied)
        if occupied.isEmpty { return .obsolete }
        if occupied.count <= targetCapacity { return .noLongerNeeded }
        return .continues
    }
}
