import Foundation

// Eingaben und Gesten des Controllers (docs/plans/controller-steuerung.md, Abschnitt 3.1).
// Alles hier ist pur: keine Hardware, keine Uhr, kein App-Zustand.

/// Logische Tasten, unabhängig vom Hersteller. Die Namen folgen dem DualSense,
/// gemeint ist jeweils die Position (Kreuz = untere Taste usw.).
enum ControllerButton: String, CaseIterable, Sendable {
    case cross, circle, square, triangle
    case dpadUp, dpadDown, dpadLeft, dpadRight
    case l1, r1, l2, r2, l3, r3
    case create, options, touchpad
    /// Paddles des Xbox Elite (Rückseite), Sofort-Tasten ohne Halten.
    case paddleUpperLeft, paddleLowerLeft, paddleUpperRight, paddleLowerRight

    /// Richtung, falls es eine Taste des Steuerkreuzes ist.
    var dpadDirection: ControllerDirection? {
        switch self {
        case .dpadUp: return .up
        case .dpadDown: return .down
        case .dpadLeft: return .left
        case .dpadRight: return .right
        default: return nil
        }
    }

    /// L2 und R2 kommen nur als Analogwert in den Kern.
    var isTrigger: Bool { self == .l2 || self == .r2 }

    var isBumper: Bool { self == .l1 || self == .r1 }
}

/// Die drei Ebenen der Controller-Insel (Runde 4). Eine Ebenen-Taste kurz
/// getippt wechselt den Chat wie bisher; gehalten wird sie zur Ebene, und die
/// anderen Tasten bekommen solange eine eigene Bedeutung.
enum ControllerLayer: String, CaseIterable, Sendable {
    /// L1: Schreiben (bis Zeilenanfang löschen, Zeilenumbruch).
    case writing
    /// R1: Schnellbefehle als Raute (Weiter, Modus, Befehle, Konto).
    case quickDraw
    /// L2: Wohin (Chats und Workspaces, nächster wartender Chat).
    case whereTo

    init?(key: ControllerButton) {
        switch key {
        case .l1: self = .writing
        case .r1: self = .quickDraw
        case .l2: self = .whereTo
        default: return nil
        }
    }

    var key: ControllerButton {
        switch self {
        case .writing: return .l1
        case .quickDraw: return .r1
        case .whereTo: return .l2
        }
    }
}

enum ControllerStickSide: String, CaseIterable, Sendable {
    case left, right
}

enum ControllerDirection: String, CaseIterable, Sendable {
    case up, down, left, right
}

/// Woher eine Bewegung kommt. Der Zusammenhang entscheidet, ob beide gleich wirken.
enum ControllerMoveSource: String, CaseIterable, Sendable {
    case dpad, leftStick
}

/// Rohe Eingabe, so wie die Hardware-Schicht sie liefert. Die Zeit kommt
/// getrennt als Parameter dazu.
enum ControllerInputEvent: Equatable, Sendable {
    case button(ControllerButton, pressed: Bool)
    /// Nur `.l2` und `.r2`, Wert 0…1.
    case trigger(ControllerButton, value: Float)
    /// Wertebereich je Achse −1…1, `y` positiv heißt oben.
    case stick(ControllerStickSide, x: Float, y: Float)
}

/// Diskrete Gesten, die der Erkenner aus den Eingaben macht. Nur diese gehen
/// an den MainActor.
enum ControllerGesture: Hashable, Sendable {
    /// Sofort-Taste wurde gedrückt.
    case press(ControllerButton)
    /// Tippen-oder-Halten-Taste vor der Halte-Schwelle losgelassen. Bei den
    /// Ebenen-Tasten (L1, R1, L2) nur, wenn keine andere Taste dazwischen kam.
    case tap(ControllerButton)
    /// Tippen-oder-Halten-Taste gedrückt, die Halte-Zeit läuft (für die Fortschrittsanzeige).
    case holdPending(ControllerButton, duration: TimeInterval)
    case holdBegan(ControllerButton)
    /// Taste wird weiter gehalten: Wiederholung wie bei einer gehaltenen
    /// Tastatur-Taste (nur Tasten aus `Config.holdRepeatButtons`).
    case holdRepeat(ControllerButton)
    /// Lange gehalten (nach `Config.holdRepeatLongAfter`): Wiederholung im
    /// zweiten, langsameren Takt — im Chat löscht Viereck dann ganze Wörter.
    case holdRepeatLong(ControllerButton)
    case holdEnded(ControllerButton)
    /// Vor Ablauf der Halte-Zeit losgelassen (zusammen mit `.tap`) oder durch `reset` gelöst.
    case holdCancelled(ControllerButton)
    /// L1 und R1 gemeinsam gedrückt, die Halte-Zeit für die Pause läuft.
    case chordPending(duration: TimeInterval)
    case chordCompleted
    case chordCancelled
    /// Ebenen-Taste seit der Halte-Schwelle gehalten: Die Insel erscheint.
    /// Kommt auch, wenn vorher schon eine Kombination lief.
    case layerBegan(ControllerLayer)
    /// Ebenen-Taste nach Halten oder Kombination losgelassen (kein `.tap`).
    case layerEnded(ControllerLayer)
    /// Ebene ohne Loslassen beendet: Pause-Akkord oder `reset`.
    case layerCancelled(ControllerLayer)
    /// Geste einer anderen Taste, während die Ebenen-Taste gehalten wird.
    /// Tasten wirken darin sofort beim Drücken (`.press`), ihr Loslassen ist
    /// still; Viereck wiederholt in der Ebene „Schreiben“ (`.holdRepeat`).
    indirect case inLayer(ControllerLayer, ControllerGesture)
    case move(ControllerDirection, source: ControllerMoveSource, isRepeat: Bool)
    /// Rechter Stick; positiv heißt nach unten scrollen.
    case scroll(lines: Int)
}
