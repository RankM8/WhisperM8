import Foundation

/// Reine, testbare Tastatur-Navigation für die „Neuer Chat"-Ordnersuche.
/// Bewusst OHNE Wrap-Around: die aktive Auswahl darf nicht aus der sichtbaren
/// Ergebnisliste herauslaufen (an den Rändern bleibt sie stehen).
enum ProjectPickerKeyboard {
    /// Nächstes Highlight beim Pfeiltasten-Druck, an den Rändern geklemmt.
    /// `direction`: +1 = runter, -1 = hoch. `nil`, wenn die Liste leer ist.
    static func move(from current: UUID?, in order: [UUID], direction: Int) -> UUID? {
        guard !order.isEmpty else { return nil }
        guard let current, let idx = order.firstIndex(of: current) else {
            return direction > 0 ? order.first : order.last
        }
        let next = idx + direction
        guard next >= 0, next < order.count else { return current } // clamp, kein Wrap
        return order[next]
    }

    /// Highlight nach einem Filterwechsel normalisieren: eine noch gültige
    /// Auswahl behalten, sonst auf das erste Ergebnis setzen (`nil` bei leerer
    /// Liste → kein Highlight, `Enter` löst nichts aus).
    static func normalize(_ current: UUID?, in order: [UUID]) -> UUID? {
        guard let current, order.contains(current) else { return order.first }
        return current
    }
}
