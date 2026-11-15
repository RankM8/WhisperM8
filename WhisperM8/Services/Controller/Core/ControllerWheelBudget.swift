import Foundation

/// Deckel für Mausrad-Schritte, die der rechte Stick im Alternate-Puffer an
/// eine TUI schickt (WM8-116). Dort wird jede Zeile ein Mausrad-Schritt, und
/// viele TUIs scrollen je Schritt drei Zeilen. Beim Anstieg am Anschlag kämen
/// sonst bis zu 300 Schritte je Sekunde an; der Deckel lässt höchstens das
/// Dreifache des bisherigen Höchsttempos durch (90 je Sekunde). Bis 30 je
/// Sekunde ändert sich nichts.
///
/// Eimer mit Nachfüllung: `capacity` Schritte auf einmal (so viel wie ein
/// Aufruf ohnehin höchstens schickt), danach `stepsPerSecond`.
struct ControllerWheelBudget: Equatable, Sendable {
    var stepsPerSecond: Double = 90
    var capacity: Double = 30
    private var tokens: Double?
    private var lastUpdate: TimeInterval?

    init(stepsPerSecond: Double = 90, capacity: Double = 30) {
        self.stepsPerSecond = stepsPerSecond
        self.capacity = capacity
    }

    /// Wie viele der gewünschten `steps` jetzt raus dürfen. Der Rest verfällt
    /// (kein Nachholen, sonst liefe die TUI nach dem Loslassen weiter).
    mutating func take(_ steps: Int, at time: TimeInterval) -> Int {
        var available = tokens ?? capacity
        if let lastUpdate { available = min(capacity, available + max(0, time - lastUpdate) * stepsPerSecond) }
        let granted = min(max(0, steps), Int(available.rounded(.down)))
        tokens = available - Double(granted)
        lastUpdate = time
        return granted
    }
}
