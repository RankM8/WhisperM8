import Foundation

/// Einträge des Menüs hinter Options (Plan, „Menü (Options)“). Die Felder sind fest.
enum ControllerMenuItem: String, CaseIterable, Sendable {
    /// „Weiter“ senden.
    case continueWork
    /// „/“ ins Eingabefeld, nicht gesendet.
    case slashCommands
    /// Modus wechseln (Shift+Tab).
    case cycleMode
    /// `/compact` ins Eingabefeld, nicht gesendet.
    case compact
    case closeTab
    case showBindings
    case pause

    /// Einträge, die Text in den Chat schreiben. Bei offener Rückfrage
    /// ausgegraut, weil dort nie Text hineinlaufen darf.
    var writesText: Bool {
        switch self {
        case .continueWork, .slashCommands, .compact: return true
        case .cycleMode, .closeTab, .showBindings, .pause: return false
        }
    }
}

struct ControllerMenuModel: Equatable, Sendable {
    var selected: ControllerMenuItem = .continueWork

    init(selected: ControllerMenuItem = .continueWork) {
        self.selected = selected
    }

    func items(dialogOpen: Bool) -> [(item: ControllerMenuItem, enabled: Bool)] {
        ControllerMenuItem.allCases.map { ($0, Self.isEnabled($0, dialogOpen: dialogOpen)) }
    }

    static func isEnabled(_ item: ControllerMenuItem, dialogOpen: Bool) -> Bool {
        !(dialogOpen && item.writesText)
    }

    /// Bewegt die Auswahl um `step` aktive Einträge, mit Umlauf. Ausgegraute
    /// Einträge werden übersprungen.
    mutating func move(_ step: Int, dialogOpen: Bool) {
        let all = ControllerMenuItem.allCases
        guard step != 0,
              all.contains(where: { Self.isEnabled($0, dialogOpen: dialogOpen) }),
              var index = all.firstIndex(of: selected) else { return }
        let direction = step > 0 ? 1 : -1
        for _ in 0..<abs(step) {
            repeat {
                index = (index + direction + all.count) % all.count
            } while !Self.isEnabled(all[index], dialogOpen: dialogOpen)
        }
        selected = all[index]
    }

    /// Setzt die Auswahl auf einen aktiven Eintrag, falls sie gerade auf
    /// einem ausgegrauten steht (etwa beim Öffnen während einer Rückfrage).
    mutating func normalize(dialogOpen: Bool) {
        guard !Self.isEnabled(selected, dialogOpen: dialogOpen) else { return }
        move(1, dialogOpen: dialogOpen)
    }
}
