import Foundation

/// Grid-Workspace: eine benannte, kuratierte Chat-Gruppe mit eigenem
/// Slot-Layout (docs/plans/grid-workspace-plan.html, Abschnitt 06).
///
/// Global in `agent-ui-state.json` persistiert; die Array-Reihenfolge in
/// `AgentUIState.gridWorkspaces` IST die Sidebar-Reihenfolge (bewusst keine
/// zweite Order-Liste, die divergieren könnte). Identität ist ausschließlich
/// `id` — doppelte Namen sind erlaubt.
///
/// Slots referenzieren Sessions (nicht Tabs) und sind POSITIONSSTABIL:
/// Entfernen/Archivieren setzt den Index auf `nil`, nichts rückt nach.
/// Dieselbe Session darf in mehreren Workspaces liegen (Referenzen, wie
/// Playlists), aber nie doppelt IM SELBEN Workspace.
struct AgentGridWorkspace: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var name: String
    /// Kanonisch `#RRGGBB` — ungültige Werte fallen auf den Akzent-Default.
    var colorHex: String
    /// Feste Slot-Positionen; `nil` = sichtbar leerer Slot.
    var slots: [UUID?]
    /// Sichtbare Slot-Anzahl, immer eine erlaubte Stufe (`allowedCapacities`).
    var capacity: Int
    /// Spalten-/Zeilen-Gewichte: positiv, endlich, Summe 1, exakt so viele
    /// Einträge wie Spalten bzw. Zeilen des Layouts. Ungültige Achsen werden
    /// gleichverteilt repariert.
    var columnFractions: [Double]
    var rowFractions: [Double]

    static let defaultName = "Workspace"
    static let defaultColorHex = "#6E6ADE"
    /// Erlaubte Kapazitäts-Stufen (Auto-Wachsen 2→3→4→6→9).
    static let allowedCapacities = [2, 3, 4, 6, 9]

    // MARK: - Layout-Geometrie

    /// Spalten/Zeilen je Stufe: 2 = 1×2 · 3 = „2 oben + 1 breit" (Slot 2
    /// spannt die untere Zeile) · 4 = 2×2 · 6 = 3×2 · 9 = 3×3.
    static func columns(forCapacity capacity: Int) -> Int {
        capacity >= 6 ? 3 : 2
    }

    static func rows(forCapacity capacity: Int) -> Int {
        switch capacity {
        case 9: return 3
        case 2: return 1
        default: return 2
        }
    }

    /// Kleinste erlaubte Stufe, die `count` Slots aufnehmen kann —
    /// mindestens 2, höchstens 9 (darüber wird deterministisch gekappt).
    static func smallestCapacity(fitting count: Int) -> Int {
        allowedCapacities.first { $0 >= count } ?? allowedCapacities.last!
    }

    /// Nächste Stufe fürs Auto-Wachsen (`nil` auf der Endstufe 9).
    static func nextCapacity(after capacity: Int) -> Int? {
        guard let index = allowedCapacities.firstIndex(of: capacity),
              index + 1 < allowedCapacities.count else { return nil }
        return allowedCapacities[index + 1]
    }

    static func equalFractions(count: Int) -> [Double] {
        let count = max(1, count)
        return Array(repeating: 1.0 / Double(count), count: count)
    }

    // MARK: - Init

    init(
        id: UUID = UUID(),
        name: String = AgentGridWorkspace.defaultName,
        colorHex: String = AgentGridWorkspace.defaultColorHex,
        slots: [UUID?] = [],
        capacity: Int = 2,
        columnFractions: [Double] = [],
        rowFractions: [Double] = []
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.slots = slots
        self.capacity = capacity
        self.columnFractions = columnFractions
        self.rowFractions = rowFractions
        normalize()
    }

    enum CodingKeys: String, CodingKey {
        case id, name, colorHex, slots, capacity, columnFractions, rowFractions
    }

    /// Manueller Decoder mit `decodeIfPresent` (Repo-Muster gegen den
    /// dokumentierten Tab-State-Totalverlust: ein fehlender Key in
    /// Bestandsdateien darf nie `keyNotFound` werfen — der
    /// `loadUIState`-Fallback verwirft sonst den kompletten UI-State).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? Self.defaultName
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? Self.defaultColorHex
        slots = try c.decodeIfPresent([UUID?].self, forKey: .slots) ?? []
        // Fehlende/unzulässige Kapazität: kleinste Stufe, die den höchsten
        // belegten Slot aufnimmt (mindestens 2) — normalize() gleicht danach ab.
        let decodedCapacity = try c.decodeIfPresent(Int.self, forKey: .capacity)
        capacity = decodedCapacity ?? 0
        columnFractions = try c.decodeIfPresent([Double].self, forKey: .columnFractions) ?? []
        rowFractions = try c.decodeIfPresent([Double].self, forKey: .rowFractions) ?? []
        normalize()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(colorHex, forKey: .colorHex)
        try c.encode(slots, forKey: .slots)
        try c.encode(capacity, forKey: .capacity)
        try c.encode(columnFractions, forKey: .columnFractions)
        try c.encode(rowFractions, forKey: .rowFractions)
    }

    // MARK: - Intrinsische Normalisierung

    /// Erzwingt ausschließlich die INTRINSISCHEN Invarianten (Name, Farbe,
    /// Kapazitäts-Stufe, Slot-Anzahl, Dedup, Fraction-Vektoren). Session-
    /// Existenz/Archivstatus prüft `AgentUIState.prune` — dem Decoder liegt
    /// kein `AgentWorkspace` vor.
    mutating func normalize() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        name = trimmed.isEmpty ? Self.defaultName : trimmed
        colorHex = Self.canonicalColorHex(colorHex) ?? Self.defaultColorHex

        // Doppelte Session im selben Workspace: erster Slot gewinnt, spätere
        // Treffer werden am eigenen Index nil — NIE kompaktieren.
        var seen = Set<UUID>()
        slots = slots.map { slot in
            guard let slot else { return nil }
            return seen.insert(slot).inserted ? slot : nil
        }

        // Kapazität: erlaubte Stufe, die alle belegten Slots aufnimmt.
        let highestOccupied = slots.indices.reversed().first { slots[$0] != nil }
        let requiredCount = max(
            highestOccupied.map { $0 + 1 } ?? 0,
            Self.allowedCapacities.contains(capacity) ? capacity : 0
        )
        capacity = Self.smallestCapacity(fitting: requiredCount)

        // Slot-Anzahl == Kapazität: Tail mit nil polstern bzw. deterministisch
        // kappen (Belegung jenseits von Index 8 wird verworfen — Endstufe 9).
        if slots.count < capacity {
            slots.append(contentsOf: Array(repeating: nil, count: capacity - slots.count))
        } else if slots.count > capacity {
            slots.removeSubrange(capacity...)
        }

        columnFractions = Self.normalizedFractions(
            columnFractions, count: Self.columns(forCapacity: capacity)
        )
        rowFractions = Self.normalizedFractions(
            rowFractions, count: Self.rows(forCapacity: capacity)
        )
    }

    func normalized() -> AgentGridWorkspace {
        var copy = self
        copy.normalize()
        return copy
    }

    /// Achsenweise Reparatur: falsche Anzahl, nicht-endliche, nichtpositive
    /// oder praktisch leere Summen → Gleichverteilung; sonst auf Summe 1
    /// normieren.
    static func normalizedFractions(_ fractions: [Double], count: Int) -> [Double] {
        guard fractions.count == count,
              fractions.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            return equalFractions(count: count)
        }
        let sum = fractions.reduce(0, +)
        guard sum.isFinite, sum > 0.001 else { return equalFractions(count: count) }
        return fractions.map { $0 / sum }
    }

    /// `#RRGGBB` (Groß-/Kleinschreibung egal, kanonisch Großbuchstaben) —
    /// alles andere ist ungültig.
    static func canonicalColorHex(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count == 7, value.hasPrefix("#") else { return nil }
        let digits = value.dropFirst()
        guard digits.allSatisfy({ $0.isHexDigit }) else { return nil }
        return "#" + digits.uppercased()
    }

    // MARK: - Abfragen

    var occupiedSessionIDs: [UUID] { slots.compactMap { $0 } }

    func slotIndex(of sessionID: UUID) -> Int? {
        slots.firstIndex(of: sessionID)
    }

    var firstFreeSlotIndex: Int? {
        slots.firstIndex(where: { $0 == nil })
    }
}
