import CoreGraphics
import Foundation
import Observation

/// Situation A des Ctrl+Tab-Switchers (Plan `docs/plans/tab-switcher-workspace.md`,
/// Slice S5): Grid sichtbar → KEIN Overlay, die echten Panes werden markiert.
/// Pure Logik, window-frei → unit-testbar (`TabSwitcherGridMarkingTests`).
enum TabSwitcherGridMarking {
    /// Rolle einer Pane während des Durchlaufs.
    enum PaneRole: Equatable {
        /// Kein Durchlauf (oder kein Grid-Umfang): Pane unverändert.
        case inactive
        /// Durchlauf aktiv, Pane ist nicht das Ziel → leicht abgedunkelt.
        case dimmed
        /// Hervorgehobenes Ziel → Akzent-Rahmen + Status-Chip.
        case target
    }

    /// Rolle für einen Slot. `sessionID == nil` = leerer Slot — wird wie
    /// jede Nicht-Ziel-Pane abgedunkelt (er ist nie Ziel, der Umfang
    /// überspringt ihn).
    static func role(sessionID: UUID?, isActive: Bool, highlightedID: UUID?) -> PaneRole {
        guard isActive else { return .inactive }
        guard let sessionID, sessionID == highlightedID else { return .dimmed }
        return .target
    }

    // MARK: - Pfeiltasten (geometrisch)

    /// Ziel einer Pfeiltaste bei gehaltenem Ctrl — dieselbe Geometrie wie die
    /// ⌃⌘-Pfeile (`GridFocusNavigator`: rechts/links in der Zeile, oben/unten
    /// entlang der Spalte, Spann-Slots zählen für jede überdeckte Spalte).
    ///
    /// „Belegt" heißt hier: Slot-Session ist im Umfang (`order`) — leere
    /// Slots und Übernahme-Platzhalter (Tab in einem anderen Fenster) werden
    /// in der Richtung übersprungen, genau wie im Ctrl+Tab-Durchlauf.
    /// Kein Wrap-around (wie ⌃⌘-Pfeile): am Rand → `nil`, das Highlight
    /// bleibt stehen.
    ///
    /// Liegt das Highlight (noch) nicht im Workspace, startet die Suche bei
    /// Slot 0 — gleicher Rückfall wie `moveGridFocus`.
    static func arrowTarget(
        from highlightedID: UUID?,
        direction: GridFocusDirection,
        entity: AgentGridWorkspace,
        order: [UUID]
    ) -> UUID? {
        let eligible = Set(order)
        let occupied = entity.slots.map { slot in slot.map { eligible.contains($0) } ?? false }
        let currentIndex = highlightedID.flatMap { entity.slotIndex(of: $0) } ?? 0
        guard let index = GridFocusNavigator.target(
            from: currentIndex,
            direction: direction,
            layout: AgentGridAutoLayout.forCapacity(entity.capacity),
            occupied: occupied
        ), entity.slots.indices.contains(index) else { return nil }
        return entity.slots[index]
    }

    /// Pfeiltasten-KeyCode → Richtung (`nil` = keine Pfeiltaste).
    static func direction(keyCode: UInt16) -> GridFocusDirection? {
        switch keyCode {
        case 123: return .left
        case 124: return .right
        case 125: return .down
        case 126: return .up
        default: return nil
        }
    }

    // MARK: - Status-Chip

    /// Größe und Stufe des Status-Chips oben links in der Ziel-Pane.
    struct Chip: Equatable {
        var detail: TabSwitcherTileDetail
        var size: CGSize
    }

    static let chipInset: CGFloat = 8
    static let chipMaxWidth: CGFloat = 280
    /// Darunter passt nicht einmal Status + Titel lesbar — dann trägt nur
    /// der Akzent-Rahmen die Markierung.
    static let chipMinWidth: CGFloat = 120
    static let chipCompactHeight: CGFloat = 70
    static let chipFullHeight: CGFloat = 92

    /// Chip passend zur Pane-Größe — kleine Stufe der `TabSwitcherTile`.
    /// Die Stand-Zeile kommt nur, wenn der Chip dabei höchstens die halbe
    /// Pane bedeckt (das Terminal soll sichtbar bleiben — Grund, warum es
    /// in Situation A kein Overlay gibt); schmale Panes verlieren erst die
    /// Dauer, nie den Status. `nil` = Pane zu klein für einen Chip.
    static func chip(forPaneSize paneSize: CGSize) -> Chip? {
        let width = min(chipMaxWidth, paneSize.width - 2 * chipInset)
        let availableHeight = paneSize.height - 2 * chipInset
        guard width >= chipMinWidth, availableHeight >= chipCompactHeight else { return nil }

        if width >= 200, availableHeight >= 2 * chipFullHeight {
            return Chip(detail: .full, size: CGSize(width: width, height: chipFullHeight))
        }
        let detail: TabSwitcherTileDetail = width >= 170 ? .withoutActivity : .statusAndTitle
        return Chip(detail: detail, size: CGSize(width: width, height: chipCompactHeight))
    }
}

/// Kleiner, EIGENER Beobachtungswert der Grid-Markierung (Situation A).
///
/// Warum nicht `tabSwitcher` (`@State` der AgentChatsView) direkt in die
/// Slots reichen: Jeder Ctrl+Tab-Schritt schreibt das Highlight — läse der
/// Grid-Body es, würde pro Schritt die gesamte AgentChatsView samt
/// `AgentGridSplitContainer` und aller Terminal-Panes neu ausgewertet. Die
/// AgentChatsView hält nur die REFERENZ (`@State`, stabil, im Body nie
/// dereferenziert); gelesen werden `isActive`/`highlightedID` ausschließlich
/// in den kleinen Pane-Overlays (`TabSwitcherGridPaneMarking`). Observation
/// invalidiert damit pro Schritt nur diese Overlays (≤ 9 winzige Views).
///
/// Gespiegelt wird im Key-/Maus-Event-Pfad (`syncTabSwitcherGridMarking`),
/// nie aus einem Body. Writes sind diff-gated — `@Observable` meldet sonst
/// auch gleiche Werte als Änderung.
@MainActor
@Observable
final class TabSwitcherGridMarkingState {
    private(set) var isActive = false
    private(set) var highlightedID: UUID?
    /// Ziele des Durchlaufs (Umfang) — Klick auf eine Pane außerhalb bricht ab.
    private(set) var targetIDs: Set<UUID> = []

    func update(highlightedID: UUID?, targets: [UUID]) {
        if !isActive { isActive = true }
        if self.highlightedID != highlightedID { self.highlightedID = highlightedID }
        let targetSet = Set(targets)
        if targetIDs != targetSet { targetIDs = targetSet }
    }

    func reset() {
        if isActive { isActive = false }
        if highlightedID != nil { highlightedID = nil }
        if !targetIDs.isEmpty { targetIDs = [] }
    }
}
