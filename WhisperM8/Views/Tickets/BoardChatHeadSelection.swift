import Foundation

// Kopf der Board-Chat-Spalte mit Controller und Tastatur (WM8-126,
// Entscheidung Giuliano 16.11.2026: „Kopfzeile verlängern“). Pur, neben
// `TicketHeaderSelection`.
//
// Weg: ▶ am rechten Ende einer Kopfzeile des Boards (bzw. der Triage) führt
// in den Kopf der Spalte. ◀ ▶ wandern durch dessen Knöpfe, ◀ auf dem ersten
// zurück an die Stelle im Kopf des Boards, von der man kam. ▼ führt in den
// Board-Chat, wenn sein Terminal hier steht, sonst zurück auf die Karte.
// Bewegen wählt nur aus; geschaltet wird mit Kreuz. Kein Knopf schickt etwas
// in einen Chat.

/// Ein Knopf im Kopf der Spalte, in der Reihenfolge am Bildschirm.
enum BoardChatHeadItem: Hashable, Sendable {
    /// Jarvis, Produkt-Chat oder ein von Hand gewählter Chat.
    case choice(UUID)
    /// „Anderer Chat …“: Liste der Chats, die Board-Chat werden können.
    case otherChat
    case openAsTab
    case hide
    /// Zugeklappte Spalte: der einzige Knopf, „Board-Chat zeigen“.
    case show
}

/// Ein Eintrag der Liste unter „Anderer Chat …“.
struct BoardChatHeadOption: Equatable, Identifiable, Sendable {
    var id: UUID
    /// Rufname („Vic“).
    var name: String
    /// Ganzer Titel für die zweite Zeile, Hilfe und Bedienungshilfen.
    var title: String
    var isRunning: Bool
}

/// Was der Kopf der Spalte zeigt, soweit es die Knöpfe bestimmt.
struct BoardChatHeadLayout: Equatable, Sendable {
    var items: [BoardChatHeadItem]
    /// Chats für die Liste unter „Anderer Chat …“.
    var others: [BoardChatHeadOption] = []
    /// Chat, der gerade in der Spalte steht.
    var current: UUID?

    /// - Parameters:
    ///   - choices: Knöpfe der Wahl (`BoardChatRules.choices`).
    ///   - canOpenAsTab: Das Terminal steht hier (wie der Knopf im Kopf).
    ///   - isCollapsed: Die Spalte ist zugeklappt; dann gibt es nur „zeigen“.
    static func make(choices: [BoardChatChoice], others: [BoardChatHeadOption], canOpenAsTab: Bool,
                     isCollapsed: Bool) -> BoardChatHeadLayout {
        let current = choices.first(where: \.isSelected)?.id
        guard !isCollapsed else { return BoardChatHeadLayout(items: [.show], others: [], current: current) }
        var items = choices.map { BoardChatHeadItem.choice($0.id) }
        items.append(.otherChat)
        if canOpenAsTab { items.append(.openAsTab) }
        items.append(.hide)
        return BoardChatHeadLayout(items: items, others: others, current: current)
    }
}

/// Ergebnis eines Schritts im Kopf der Spalte.
enum BoardChatHeadStep: Equatable {
    case item(BoardChatHeadItem)
    /// Am Rand: bleibt (still).
    case stay
    /// ◀ auf dem ersten Knopf: zurück in den Kopf des Boards.
    case backToBoardHeader
    /// ▼: in den Board-Chat bzw. zurück auf die Karte; entscheidet das Fenster.
    case down
}

enum BoardChatHeadSelection {
    /// Einstieg von links: der zuletzt gewählte Knopf, falls es ihn noch
    /// gibt, sonst der Chat, der in der Spalte steht, sonst der erste Knopf.
    static func entry(_ layout: BoardChatHeadLayout, remembering last: BoardChatHeadItem? = nil) -> BoardChatHeadItem? {
        if let last, layout.items.contains(last) { return last }
        if let current = layout.current, layout.items.contains(.choice(current)) { return .choice(current) }
        return layout.items.first
    }

    /// Stelle nach einer Änderung des Kopfs (anderer Chat gewählt, Spalte zu-
    /// oder aufgeklappt): derselbe Knopf, falls es ihn noch gibt, sonst der
    /// Einstieg. `nil` ohne Knöpfe.
    static func reconcile(_ item: BoardChatHeadItem, in layout: BoardChatHeadLayout) -> BoardChatHeadItem? {
        layout.items.contains(item) ? item : entry(layout)
    }

    /// ◀ ▶ ohne Umlauf; ▲ bleibt (darüber ist nichts).
    static func step(_ item: BoardChatHeadItem, _ direction: TicketBoardMove,
                     in layout: BoardChatHeadLayout) -> BoardChatHeadStep {
        guard let index = layout.items.firstIndex(of: item) else {
            return entry(layout).map { .item($0) } ?? .backToBoardHeader
        }
        switch direction {
        case .left: return index > 0 ? .item(layout.items[index - 1]) : .backToBoardHeader
        case .right: return index + 1 < layout.items.count ? .item(layout.items[index + 1]) : .stay
        case .up: return .stay
        case .down: return .down
        }
    }

    // MARK: Liste „Anderer Chat …“

    /// Chats, die als Board-Chat hineingeholt werden können: dieselben
    /// Kandidaten wie für Jarvis und Produkt-Chat (offene Tabs, laufende
    /// Chats, der gemerkte Jarvis; nie alle Chats), dieselbe Regel wie beim
    /// Hineinziehen (`BoardChatRules.rejection`: nur echte Agent-Chats dieses
    /// Projekts, nicht archiviert). Laufende zuerst, dann der zuletzt aktive.
    /// Der Chat, der schon in der Spalte steht, fehlt.
    static func others(_ candidates: [BoardChatCandidate], projectID: UUID, current: UUID?,
                       name: (String) -> String) -> [BoardChatHeadOption] {
        candidates
            .filter { candidate in
                candidate.id != current && BoardChatRules.rejection(
                    kind: candidate.kind, isArchived: candidate.isArchived,
                    projectID: candidate.projectID, boardProjectID: projectID) == nil
            }
            .sorted(by: BoardChatRules.ranksBefore)
            .map { BoardChatHeadOption(id: $0.id, name: name($0.title), title: $0.title, isRunning: $0.isRunning) }
    }

    /// ▲ ▼ in der Liste, ohne Umlauf.
    static func pickerStep(_ index: Int, _ direction: TicketBoardMove, count: Int) -> Int {
        guard count > 0 else { return 0 }
        switch direction {
        case .up: return max(0, index - 1)
        case .down: return min(count - 1, index + 1)
        case .left, .right: return min(max(index, 0), count - 1)
        }
    }
}
