import Foundation

/// Kleine Menü-Liste für den Controller: Einträge, die an oder aus sind, und
/// eine Auswahl, die mit Umlauf wandert und ausgegraute Einträge überspringt.
/// Grundlage für das Options-Menü im Chat (beide Ebenen) und das Menü im
/// Zwischenablage-Verlauf; gezeichnet werden beide mit demselben Panel.
struct ControllerListMenu<ID: Hashable & Sendable>: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        var id: ID
        var enabled: Bool
    }

    private(set) var entries: [Entry]
    private(set) var selected: ID?

    init(entries: [Entry], selected: ID? = nil) {
        self.entries = entries
        self.selected = selected
        normalize()
    }

    /// Markierung beginnt auf `start`, auch wenn der Eintrag aus ist (etwa das
    /// aktuelle Konto im Konto-Menü); Kreuz geht dort nicht, der erste Schritt
    /// führt zum nächsten aktiven Eintrag. Ohne `start` wie `init(entries:)`.
    init(entries: [Entry], start: ID?) {
        self.entries = entries
        if let start, entries.contains(where: { $0.id == start }) {
            selected = start
        } else {
            selected = nil
            normalize()
        }
    }

    func isEnabled(_ id: ID) -> Bool {
        entries.first { $0.id == id }?.enabled ?? false
    }

    /// Ausgewählter Eintrag, sofern er an ist.
    var selectedEnabled: ID? {
        selected.flatMap { isEnabled($0) ? $0 : nil }
    }

    /// Auswahl direkt setzen, sofern der Eintrag an ist.
    mutating func select(_ id: ID) {
        if isEnabled(id) { selected = id }
    }

    /// Um `step` aktive Einträge weiter, mit Umlauf.
    mutating func move(_ step: Int) {
        guard step != 0, entries.contains(where: \.enabled) else { return }
        var index = selected.flatMap { id in entries.firstIndex { $0.id == id } } ?? -1
        let direction = step > 0 ? 1 : -1
        let count = entries.count
        for _ in 0..<abs(step) {
            repeat {
                index = ((index + direction) % count + count) % count
            } while !entries[index].enabled
        }
        selected = entries[index].id
    }

    /// Auswahl auf einen aktiven Eintrag setzen (beim Öffnen oder wenn der
    /// gewählte ausgegraut ist). Ohne aktive Einträge bleibt sie leer.
    mutating func normalize() {
        if let selected, isEnabled(selected) { return }
        selected = entries.first(where: \.enabled)?.id
    }
}
