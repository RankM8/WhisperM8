import Foundation

/// Blättert während der Aufnahme durch die Ausgabemodi (Steuerkreuz links/rechts).
enum OutputModeCycler {
    /// Nächster Modus mit Umlauf. Leere Liste → `nil`; ist `current` unbekannt
    /// oder `nil`, beginnt es beim ersten Modus.
    static func next<ID: Equatable>(current: ID?, in ids: [ID], step: Int) -> ID? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else { return ids.first }
        let count = ids.count
        let target = ((index + step) % count + count) % count
        return ids[target]
    }
}
