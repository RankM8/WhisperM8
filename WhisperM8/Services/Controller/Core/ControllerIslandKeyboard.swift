import Foundation

// Insel per Tastatur, Paket 2 (WM8-104, Variante B): Schnellbefehle als
// Buchstaben in derselben Insel wie „Wohin“. Pures Modell; der Ausführer baut
// es beim Öffnen, die Ansicht zeichnet es nur.

/// Ein Buchstabe der Tastenzeile. Gewählt nach dem Anfangsbuchstaben und ohne
/// Y/Z (QWERTZ und QWERTY tauschen sie). Erkannt über den keyCode (ANSI-Lage).
enum KeyboardIslandCommand: String, CaseIterable, Sendable {
    // Für den aktuellen Chat (Kopf der Insel), nicht für die markierte Zeile.
    case sendNow, cycleMode, transcript, commands, account
    // Für die App.
    case limits, alerts, stayAwake, clipboard

    static let chatCommands: [KeyboardIslandCommand] = [.sendNow, .cycleMode, .transcript, .commands, .account]
    static let appCommands: [KeyboardIslandCommand] = [.limits, .alerts, .stayAwake, .clipboard]

    var isChatCommand: Bool { Self.chatCommands.contains(self) }

    /// Buchstabe auf QWERTZ und QWERTY; die Ansicht zeigt den des aktuellen
    /// Layouts, wenn er abweicht.
    var letter: String {
        switch self {
        case .sendNow: return "S"
        case .cycleMode: return "M"
        case .transcript: return "O"
        case .commands: return "B"
        case .account: return "K"
        case .limits: return "L"
        case .alerts: return "N"
        case .stayAwake: return "A"
        case .clipboard: return "C"
        }
    }

    /// keyCode der Taste (ANSI-Lage, auf QWERTZ dieselbe).
    var keyCode: UInt16 {
        switch self {
        case .sendNow: return 1
        case .cycleMode: return 46
        case .transcript: return 31
        case .commands: return 11
        case .account: return 40
        case .limits: return 37
        case .alerts: return 45
        case .stayAwake: return 0
        case .clipboard: return 8
        }
    }

    static func command(keyCode: UInt16) -> KeyboardIslandCommand? {
        allCases.first { $0.keyCode == keyCode }
    }

    /// Eintrag des Options-Menüs bzw. der R1-Raute, dessen Weg der Buchstabe nimmt.
    var menuItem: ControllerMenuItem? {
        switch self {
        case .sendNow: return .continueWork
        case .cycleMode: return .cycleMode
        case .commands: return .commands
        case .account: return .switchAccount
        default: return nil
        }
    }

    /// Feld der App-Raute unter R1, dessen Weg der Buchstabe nimmt.
    var appSlot: ControllerAppSlot? {
        switch self {
        case .limits: return .limits
        case .alerts: return .alerts
        case .stayAwake: return .stayAwake
        case .clipboard: return .clipboard
        default: return nil
        }
    }
}

/// Was die Insel per Tastatur über „Wohin“ hinaus zeigt: die Tastenzeile, die
/// Bestätigung eines Schalters, die Limits-Karte und den Spickzettel.
struct ControllerKeyboardCommands: Equatable, Sendable {
    /// Dieselben Regeln wie die R1-Raute: an/aus, Hinweis, App-Schalter,
    /// Bestätigung, Limits-Karte, gedrückte Felder.
    var slots: ControllerQuickDrawSlots
    /// O: ausführliches Transkript (Ctrl+O), nur Claude.
    var transcriptEnabled: Bool
    var transcriptHit = false
    /// Titel des aktuellen Chats: „für ‹Chat›“ über den Chat-Befehlen, damit
    /// man sie nicht mit der Markierung verwechselt.
    var chatTitle: String?
    /// ?: Schreib-Tasten statt der Liste, solange ⌥ gehalten ist.
    var cheatSheet = false
    /// ⌥ loslassen wechselt zum markierten Eintrag. Nach einem Schalter, der
    /// Karte oder dem Spickzettel nicht mehr, bis die Markierung sich bewegt
    /// („⌥ los: nichts wechselt“).
    var releaseSwitches = true
    /// Buchstabe des aktuellen Layouts je Befehl, wenn er abweicht.
    var letters: [KeyboardIslandCommand: String] = [:]

    var dictating: Bool { slots.note == .dictating }

    func isEnabled(_ command: KeyboardIslandCommand) -> Bool {
        switch command {
        case .transcript: return transcriptEnabled && !dictating && slots.note != .question
        case .limits, .alerts, .stayAwake, .clipboard: return true
        default: return command.menuItem.map(slots.enabled.contains) ?? false
        }
    }

    func isHit(_ command: KeyboardIslandCommand) -> Bool {
        if command == .transcript { return transcriptHit }
        if let item = command.menuItem { return slots.hit == item }
        return command.appSlot.map { slots.appHit == $0 } ?? false
    }

    func letter(_ command: KeyboardIslandCommand) -> String { letters[command] ?? command.letter }
}
