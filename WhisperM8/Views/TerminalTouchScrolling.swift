import CoreGraphics
import Foundation

// Reine Logik für die Finger-Bedienung des Chat-Terminals (WM8-136). Die
// AppKit-Anbindung steht in `TerminalTouchGestures`; Messung und Quellen in
// docs/features/agent-chats/ui/terminal.md („Touch-Display“).

/// Was ein Finger im Terminal tut, sobald er sich bewegt.
///
/// Apples Touch-Emulation in macOS 27 unterscheidet genauso: sofort bewegen
/// heißt scrollen, erst kurz halten und dann bewegen heißt ziehen (bei uns:
/// markieren). Gemessen wird die Ruhezeit bis zur ersten Bewegung, nicht die
/// Zeit bis zum Erkennen der Geste: Ein langsamer Wisch bleibt ein Wisch.
enum TerminalTouchIntent: Equatable {
    case scroll
    case select

    /// Ab dieser Ruhezeit markiert der Finger statt zu scrollen. Kurz genug,
    /// dass Markieren nicht träge wirkt, lang genug, dass kein Wisch versehentlich
    /// markiert (ein Wisch bewegt sich nach dem Aufsetzen praktisch sofort).
    static let holdThreshold: TimeInterval = 0.35

    static func decide(restBeforeMove: TimeInterval) -> TerminalTouchIntent {
        restBeforeMove >= holdThreshold ? .select : .scroll
    }
}

/// Wohin ein Finger-Scroll geht, gleich wie beim Trackpad:
/// - Alternate-Puffer (Vollbild-TUI): SGR-Mausrad an die TUI, wie
///   `TerminalScrollGuard`; ohne laufenden Prozess nirgends hin.
/// - Normaler Puffer mit Maus-Reporting: Mausrad-Knöpfe 4/5 an die TUI, wie
///   SwiftTerms `scrollWheel`.
/// - Sonst: der eigene Verlauf des Terminals.
enum TerminalTouchScrollRoute: Equatable {
    case scrollback
    case wheelToAlternateScreen
    case wheelToMouseReporting
    case ignore

    static func decide(
        isAlternateBuffer: Bool,
        mouseReportingActive: Bool,
        processRunning: Bool
    ) -> TerminalTouchScrollRoute {
        if isAlternateBuffer {
            return processRunning ? .wheelToAlternateScreen : .ignore
        }
        if mouseReportingActive {
            return processRunning ? .wheelToMouseReporting : .scrollback
        }
        return .scrollback
    }
}

/// Rechnet Fingerweg in ganze Terminal-Zeilen um und behält den Rest für den
/// nächsten Schritt, damit langsames Ziehen nicht verloren geht und schnelles
/// keine Zeilen überspringt (wie SwiftTerms `scrollWheel` für das Trackpad).
struct TerminalTouchLineAccumulator: Equatable {
    private(set) var remainder: CGFloat = 0

    /// `points` positiv = Finger nach unten = ältere Zeilen kommen ins Bild.
    /// Ergebnis positiv = so viele Zeilen hoch scrollen, negativ = runter.
    mutating func lines(forFingerTravel points: CGFloat, cellHeight: CGFloat) -> Int {
        guard cellHeight > 0, points.isFinite else { return 0 }
        remainder += points
        let whole = (remainder / cellHeight).rounded(.towardZero)
        remainder -= whole * cellHeight
        return Int(whole)
    }

    mutating func reset() {
        remainder = 0
    }
}

/// Schwung nach dem Loslassen, wie bei `NSScrollView`: die Geschwindigkeit
/// fällt exponentiell ab (Faktor 0,998 je Millisekunde, der Wert der normalen
/// Abbremsung bei Apple). Der Weg je Schritt ist das Integral über das
/// Zeitintervall, damit das Ergebnis nicht von der Bildrate abhängt.
struct TerminalTouchMomentum: Equatable {
    static let decelerationPerMillisecond: Double = 0.998
    /// Darunter gibt es keinen Schwung: ein langsam abgesetzter Finger soll
    /// stehen bleiben.
    static let minimumStartVelocity: CGFloat = 250
    /// Darunter endet der Schwung (Punkte je Sekunde).
    static let stopVelocity: CGFloat = 20
    static let maximumVelocity: CGFloat = 9000
    /// Obergrenze, falls ein Schritt ausbleibt (Fenster verdeckt, Pause).
    static let maximumStep: TimeInterval = 0.1

    /// Punkte je Sekunde, positiv = Finger nach unten (ältere Zeilen).
    private(set) var velocity: CGFloat

    init?(releaseVelocity: CGFloat) {
        guard releaseVelocity.isFinite, abs(releaseVelocity) >= Self.minimumStartVelocity else { return nil }
        velocity = max(-Self.maximumVelocity, min(Self.maximumVelocity, releaseVelocity))
    }

    var isFinished: Bool { abs(velocity) < Self.stopVelocity }

    /// Weg in Punkten für `interval` Sekunden; senkt danach die Geschwindigkeit.
    mutating func advance(by interval: TimeInterval) -> CGFloat {
        guard interval > 0, !isFinished else { return 0 }
        let dt = min(interval, Self.maximumStep)
        let decayPerSecond = pow(Self.decelerationPerMillisecond, 1000)
        let factor = pow(decayPerSecond, dt)
        let travel = CGFloat(Double(velocity) * (factor - 1) / log(decayPerSecond))
        velocity *= CGFloat(factor)
        return travel
    }

    mutating func stop() {
        velocity = 0
    }
}

/// Zählt Tipper wie Mausklicks: schnell nacheinander an fast derselben Stelle
/// ergibt 2 (Wort markieren) bzw. 3 (Zeile markieren) — dieselbe Wirkung wie
/// ein Doppel- und Dreifachklick in SwiftTerm.
struct TerminalTapCounter: Equatable {
    static let slop: CGFloat = 16
    private var lastTime: TimeInterval?
    private var lastPoint: CGPoint = .zero
    private(set) var count = 0

    mutating func register(at point: CGPoint, time: TimeInterval, interval: TimeInterval) -> Int {
        if let lastTime,
           time - lastTime <= interval,
           abs(point.x - lastPoint.x) <= Self.slop,
           abs(point.y - lastPoint.y) <= Self.slop {
            count = count >= 3 ? 1 : count + 1
        } else {
            count = 1
        }
        lastTime = time
        lastPoint = point
        return count
    }
}
