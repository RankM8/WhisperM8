import Foundation

/// Reine, testbare Multi-Select-Semantik der Tab-Leiste (Browser-/Finder-artig).
///
/// Zwei getrennte Begriffe (HIG: Focus vs. Selection):
/// - `active`    = der angezeigte Tab (Anker, treibt das Terminal) = `selectedSessionID`.
/// - `selection` = Mehrfach-Auswahl. Invariante: **leer** bei Einzel-Auswahl,
///   sonst **≥ 2** IDs (enthält dann `active`). So ist „nur ein Tab" eindeutig
///   von „Gruppe" trennbar — Bulk-/Multi-Drag fragt einfach `selection`.
struct TabSelectionOutcome: Equatable {
    let active: UUID
    let selection: Set<UUID>
}

enum TabSelectionResolver {
    /// Normaler Klick: nur dieser Tab aktiv, keine Mehrfach-Auswahl.
    static func click(_ id: UUID) -> TabSelectionOutcome {
        TabSelectionOutcome(active: id, selection: [])
    }

    /// Cmd-Klick: toggelt `id`. Bei bisher leerer Auswahl wird mit dem alten
    /// `active` geseedet, damit der erste Cmd-Klick eine 2er-Gruppe bildet.
    static func commandClick(_ id: UUID, active: UUID?, selection: Set<UUID>) -> TabSelectionOutcome {
        var set = selection.isEmpty ? Set([active].compactMap { $0 }) : selection
        if set.contains(id) {
            set.remove(id)
        } else {
            set.insert(id)
        }
        let newActive = set.contains(id) ? id : (set.first ?? id)
        // <= 1 → auf „Einzel-Auswahl" (leere Menge) kollabieren.
        return TabSelectionOutcome(active: newActive, selection: set.count <= 1 ? [] : set)
    }

    /// Shift-Klick: zusammenhängender Bereich vom Anker (`anchor`, i.d.R. der
    /// aktive Tab) bis `id` in der sichtbaren Reihenfolge `order`.
    static func shiftClick(_ id: UUID, anchor: UUID?, order: [UUID]) -> TabSelectionOutcome {
        guard let anchor,
              let ai = order.firstIndex(of: anchor),
              let bi = order.firstIndex(of: id) else {
            return TabSelectionOutcome(active: id, selection: [])
        }
        let range = Set(order[min(ai, bi)...max(ai, bi)])
        return TabSelectionOutcome(active: id, selection: range.count <= 1 ? [] : range)
    }
}
