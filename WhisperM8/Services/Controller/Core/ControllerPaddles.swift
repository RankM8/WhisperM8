import Foundation

// Paddles des Xbox Elite (Plan `controller-xbox-paddles.md`, „Paddles im
// Kern“): vier eigene logische Tasten mit frei wählbarer Belegung. Sie sind
// Sofort-Tasten — ein Druck, eine Aktion, kein Halten, keine Wiederholung.

/// Lage eines Paddles auf der Rückseite, von hinten gesehen wie in der Hand.
enum ControllerPaddle: String, CaseIterable, Sendable {
    case upperLeft, lowerLeft, upperRight, lowerRight

    var button: ControllerButton {
        switch self {
        case .upperLeft: return .paddleUpperLeft
        case .lowerLeft: return .paddleLowerLeft
        case .upperRight: return .paddleUpperRight
        case .lowerRight: return .paddleLowerRight
        }
    }

    init?(button: ControllerButton) {
        guard let paddle = Self.allCases.first(where: { $0.button == button }) else { return nil }
        self = paddle
    }

    /// Zählung des Elite: P1 oben rechts, P2 unten rechts, P3 oben links,
    /// P4 unten links.
    var eliteNumber: Int {
        switch self {
        case .upperRight: return 1
        case .lowerRight: return 2
        case .upperLeft: return 3
        case .lowerLeft: return 4
        }
    }
}

extension ControllerButton {
    var isPaddle: Bool { ControllerPaddle(button: self) != nil }
}

/// Bit der Paddle-Maske im HID-Bericht (Consumer-Seite 0x0C, Usage 0x81) ↔
/// Lage, gemessen 13.11.2026 (Elite Series 2, Bluetooth LE): Die Bits folgen
/// der Elite-Zählung, Bit 1 = P1 oben rechts, 2 = P2 unten rechts, 4 = P3
/// oben links, 8 = P4 unten links. Weicht ein Modell ab, nur diese Tabelle
/// ändern.
enum XboxPaddleBits {
    static let table: [(bit: UInt32, paddle: ControllerPaddle)] = [
        (0x1, .upperRight), // P1
        (0x2, .lowerRight), // P2
        (0x4, .upperLeft),  // P3
        (0x8, .lowerLeft),  // P4
    ]

    static func paddles(in mask: UInt32) -> Set<ControllerPaddle> {
        Set(table.filter { mask & $0.bit != 0 }.map(\.paddle))
    }

    /// Wechsel von `old` nach `new` als Tastenereignisse, in der Reihenfolge
    /// der Tabelle: erst Loslassen, dann Drücken.
    static func changes(from old: UInt32, to new: UInt32) -> [(paddle: ControllerPaddle, pressed: Bool)] {
        let released = table.filter { old & $0.bit != 0 && new & $0.bit == 0 }.map { ($0.paddle, false) }
        let pressed = table.filter { old & $0.bit == 0 && new & $0.bit != 0 }.map { ($0.paddle, true) }
        return released + pressed
    }
}

/// Was ein Paddle auslöst: die feste Auswahlliste der Einstellungen.
/// Gespeichert als Rohwert.
enum ControllerPaddleBinding: String, CaseIterable, Sendable {
    case nextWaiting
    case answer
    case sendNow
    case cycleMode
    case lastChat
    case pasteNewest
    case undo
    case clipboardHistory
    case pause
    case claudeWorkflows
    case claudeTasks
    case none

    /// Aktion im Chat; die übrigen Zusammenhänge filtert die Belegung.
    var action: ControllerAction? {
        switch self {
        case .nextWaiting: return .nextWaitingChat
        case .answer: return .answerNextWaiting
        case .sendNow: return .sendNowOrContinue
        case .cycleMode: return .cycleMode
        case .lastChat: return .lastChat
        case .pasteNewest: return .pasteNewest
        case .undo: return .chatKey(.undo)
        case .clipboardHistory: return .clipboardToggle
        case .pause: return .pauseToggle
        case .claudeWorkflows: return .slashCommand("/workflows")
        case .claudeTasks: return .slashCommand("/tasks")
        case .none: return nil
        }
    }

    /// Schreibt etwas in einen Chat (geht in der Liste nicht).
    var needsChat: Bool {
        switch self {
        case .sendNow, .cycleMode, .pasteNewest, .undo, .claudeWorkflows, .claudeTasks: return true
        default: return false
        }
    }
}

/// Belegung aller vier Paddles.
struct ControllerPaddleBindings: Equatable, Sendable {
    var upperLeft: ControllerPaddleBinding
    var lowerLeft: ControllerPaddleBinding
    var upperRight: ControllerPaddleBinding
    var lowerRight: ControllerPaddleBinding

    /// Standard (Entscheidung 4): oben links nächster wartender Chat, unten
    /// links Antworten, oben rechts Jetzt senden / Weiter, unten rechts Modus.
    static let standard = ControllerPaddleBindings(
        upperLeft: .nextWaiting, lowerLeft: .answer, upperRight: .sendNow, lowerRight: .cycleMode)

    static func standardBinding(for paddle: ControllerPaddle) -> ControllerPaddleBinding {
        standard[paddle]
    }

    subscript(paddle: ControllerPaddle) -> ControllerPaddleBinding {
        get {
            switch paddle {
            case .upperLeft: return upperLeft
            case .lowerLeft: return lowerLeft
            case .upperRight: return upperRight
            case .lowerRight: return lowerRight
            }
        }
        set {
            switch paddle {
            case .upperLeft: upperLeft = newValue
            case .lowerLeft: lowerLeft = newValue
            case .upperRight: upperRight = newValue
            case .lowerRight: lowerRight = newValue
            }
        }
    }

    /// Aus gespeicherten Rohwerten; fehlende oder unbekannte Werte gelten als
    /// Standard dieses Paddles (vorwärtsverträglich).
    init(rawValues: (ControllerPaddle) -> String?) {
        var bindings = Self.standard
        for paddle in ControllerPaddle.allCases {
            if let raw = rawValues(paddle), let binding = ControllerPaddleBinding(rawValue: raw) {
                bindings[paddle] = binding
            }
        }
        self = bindings
    }

    init(upperLeft: ControllerPaddleBinding, lowerLeft: ControllerPaddleBinding,
         upperRight: ControllerPaddleBinding, lowerRight: ControllerPaddleBinding) {
        self.upperLeft = upperLeft
        self.lowerLeft = lowerLeft
        self.upperRight = upperRight
        self.lowerRight = lowerRight
    }
}
