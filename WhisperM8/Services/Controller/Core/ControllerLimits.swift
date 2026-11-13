import Foundation

// Limits-Karte der R1-Insel (Insel-Paket): alle Claude- und GPT-Konten mit
// 5-Stunden- und Wochenfenster, solange R1 gehalten ist. Pur; die Zahlen
// kommen aus `AccountLimitsStore`, gebaut im Ereignis-Pfad.

/// Ampel wie im Limits-Popover (`UsageGaugeLine`): unter 50 % grün, ab 50 %
/// gelb, ab 80 % rot. Alle Werte sind verbraucht.
enum ControllerLimitLevel: String, Sendable {
    case low, medium, high

    init?(percent: Double?) {
        guard let percent else { return nil }
        if percent >= 80 {
            self = .high
        } else if percent >= 50 {
            self = .medium
        } else {
            self = .low
        }
    }
}

/// Eine Konto-Zeile der Karte.
struct ControllerAccountLimitRow: Equatable, Sendable, Identifiable {
    var kind: ControllerAccountChoice.Kind
    var name: String
    var fiveHour: Double?
    var week: Double?
    var fiveHourResetsAt: Date?
    var weekResetsAt: Date?
    /// Text aus dem Popover statt der Balken (Login abgelaufen, offline …),
    /// fertig formuliert im Ereignis-Pfad.
    var problem: String?
    /// Das Problem macht die Zahlen wertlos (Login beendet, kein Token, GPT
    /// ohne Zahlen): Text statt Balken. Sonst (offline, Token läuft gleich
    /// wieder) stehen die letzten Zahlen da.
    var problemReplacesNumbers = false
    /// Konto des Ziel-Chats („dieser Chat“).
    var isCurrentChat = false

    var id: String { "\(kind.rawValue):\(name)" }
    var hasNumbers: Bool { fiveHour != nil || week != nil }
}

/// Konten der Limits-Karte, wie die beiden Popovers sie zeigen. Einmal beim
/// Öffnen der Karte gelesen (das Lesen der Profile ist Platten-I/O); neue
/// Zahlen danach ordnen sich nur diesen Namen zu.
struct ControllerLimitAccounts: Equatable, Sendable {
    var claude: [String] = []
    var gpt: [String] = []
}

/// Die Karte: oben Claude, darunter GPT, höchstens `maxVisibleRows` Konten
/// sichtbar; der linke Stick (oder ▲▼) scrollt. Ohne Markierung, nur ein
/// Fenster über den Zeilen.
struct ControllerLimitsCard: Equatable, Sendable {
    static var maxVisibleRows: Int { 6 }

    private(set) var rows: [ControllerAccountLimitRow]
    private(set) var firstVisibleIndex = 0
    /// Letzter Stand der Zahlen; `nil`: noch keiner.
    var updatedAt: Date?
    /// Ein Abruf läuft („aktualisiere …“).
    var isLoading: Bool
    /// ✕ holt die Zahlen frisch. Während eines Diktats nicht: Dort ist ✕
    /// unter R1 „geht nicht“, die Fußzeile bietet es dann nicht an.
    var canRefresh = true

    /// - Parameter rows: Konten in der Reihenfolge der Popovers; die Karte
    ///   ordnet Claude vor GPT und scrollt so, dass das Konto des Chats zu
    ///   sehen ist.
    init(rows: [ControllerAccountLimitRow], updatedAt: Date?, isLoading: Bool) {
        self.rows = Self.ordered(rows)
        self.updatedAt = updatedAt
        self.isLoading = isLoading
        if let current = self.rows.firstIndex(where: \.isCurrentChat) {
            firstVisibleIndex = Self.clamp(current - Self.maxVisibleRows + 1, count: self.rows.count)
        }
    }

    private static func ordered(_ rows: [ControllerAccountLimitRow]) -> [ControllerAccountLimitRow] {
        rows.filter { $0.kind == .claude } + rows.filter { $0.kind == .gpt }
    }

    private static func clamp(_ index: Int, count: Int) -> Int {
        max(0, min(index, max(0, count - maxVisibleRows)))
    }

    var visibleRows: ArraySlice<ControllerAccountLimitRow> {
        let end = min(rows.count, firstVisibleIndex + Self.maxVisibleRows)
        return rows[firstVisibleIndex..<end]
    }

    var hiddenAbove: Int { firstVisibleIndex }
    var hiddenBelow: Int { rows.count - firstVisibleIndex - visibleRows.count }
    var canScroll: Bool { rows.count > Self.maxVisibleRows }

    /// Eine Zeile weiter; am Rand bleibt sie stehen. `false`, wenn sich nichts
    /// bewegt hat.
    @discardableResult
    mutating func scroll(_ step: Int) -> Bool {
        let target = Self.clamp(firstVisibleIndex + step, count: rows.count)
        guard target != firstVisibleIndex else { return false }
        firstVisibleIndex = target
        return true
    }

    /// Neue Zahlen kamen an: Zeilen tauschen, die Lage bleibt (soweit sie passt).
    mutating func update(rows: [ControllerAccountLimitRow], updatedAt: Date?, isLoading: Bool) {
        self.rows = Self.ordered(rows)
        self.updatedAt = updatedAt
        self.isLoading = isLoading
        firstVisibleIndex = Self.clamp(firstVisibleIndex, count: self.rows.count)
    }

    /// Beginnt mit dieser Zeile ein neuer Abschnitt (Claude bzw. GPT)?
    func startsSection(_ row: ControllerAccountLimitRow) -> Bool {
        guard let index = rows.firstIndex(where: { $0.id == row.id }) else { return false }
        return index == 0 || rows[index - 1].kind != row.kind
    }
}

/// Wie die Rücksetzzeit dasteht: unter einem Tag als Dauer („in 2 h 10 min“),
/// sonst mit Wochentag und Uhrzeit — dieselbe Grenze wie `UsageResetDateFormat`.
enum ControllerResetStyle: Equatable, Sendable {
    case duration(minutes: Int)
    case dayAndTime

    static func of(_ resetsAt: Date?, now: Date) -> ControllerResetStyle? {
        guard let resetsAt else { return nil }
        let seconds = resetsAt.timeIntervalSince(now)
        guard seconds <= 86_400 else { return .dayAndTime }
        return .duration(minutes: max(0, Int((seconds / 60).rounded(.up))))
    }
}
