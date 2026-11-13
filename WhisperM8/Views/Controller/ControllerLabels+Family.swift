import SwiftUI

// Tastennamen und -zeichen je Controller-Familie (Plan
// `controller-xbox-paddles.md`, „Tastennamen für Xbox und PlayStation“). Die
// Belegung folgt der Lage: A ist die untere Taste wie Kreuz, View sitzt wie
// Create, Menu wie Options. Allgemeine Gamepads zeigen die PlayStation-Zeichen.

extension ControllerButton {
    /// Name der Taste für den Tasten-Test.
    func displayName(_ family: ControllerFamily) -> String {
        if family == .xbox, let name = xboxDisplayName { return name }
        switch self {
        case .cross: return String(localized: "Cross")
        case .circle: return String(localized: "Circle")
        case .square: return String(localized: "Square")
        case .triangle: return String(localized: "Triangle")
        case .dpadUp: return String(localized: "D-pad up")
        case .dpadDown: return String(localized: "D-pad down")
        case .dpadLeft: return String(localized: "D-pad left")
        case .dpadRight: return String(localized: "D-pad right")
        case .l1: return "L1"
        case .r1: return "R1"
        case .l2: return "L2"
        case .r2: return "R2"
        case .l3: return String(localized: "Left stick click")
        case .r3: return String(localized: "Right stick click")
        case .create: return "Create"
        case .options: return "Options"
        case .touchpad: return "Touchpad"
        case .paddleUpperLeft, .paddleLowerLeft, .paddleUpperRight, .paddleLowerRight:
            return ControllerPaddle(button: self)?.displayName ?? rawValue
        }
    }

    private var xboxDisplayName: String? {
        switch self {
        case .cross: return String(localized: "A button")
        case .circle: return String(localized: "B button")
        case .square: return String(localized: "X button")
        case .triangle: return String(localized: "Y button")
        case .l1: return String(localized: "Left bumper")
        case .r1: return String(localized: "Right bumper")
        case .l2: return String(localized: "Left trigger")
        case .r2: return String(localized: "Right trigger")
        case .create: return String(localized: "View button")
        case .options: return String(localized: "Menu button")
        // Am Xbox-Controller übernimmt der Xbox-Knopf die Rolle des Touchpads.
        case .touchpad: return String(localized: "Xbox button")
        default: return nil
        }
    }

    /// Zeichen auf dem Tasten-Symbol. Bewusst feste Zeichen statt SF Symbols:
    /// Sie sehen in jeder macOS-Version gleich aus. Buchstaben bleiben
    /// einfarbig wie die PlayStation-Zeichen.
    func glyph(_ family: ControllerFamily) -> String {
        if family == .xbox, let glyph = xboxGlyph { return glyph }
        switch self {
        case .cross: return "✕"
        case .circle: return "○"
        case .square: return "□"
        case .triangle: return "△"
        case .dpadUp: return "▲"
        case .dpadDown: return "▼"
        case .dpadLeft: return "◀"
        case .dpadRight: return "▶"
        case .l1: return "L1"
        case .r1: return "R1"
        case .l2: return "L2"
        case .r2: return "R2"
        case .l3: return "L3"
        case .r3: return "R3"
        case .create: return "Create"
        case .options: return "Options"
        case .touchpad: return "Touchpad"
        case .paddleUpperLeft, .paddleLowerLeft, .paddleUpperRight, .paddleLowerRight:
            return ControllerPaddle(button: self).map { "P\($0.eliteNumber)" } ?? rawValue
        }
    }

    private var xboxGlyph: String? {
        switch self {
        case .cross: return "A"
        case .circle: return "B"
        case .square: return "X"
        case .triangle: return "Y"
        case .l1: return "LB"
        case .r1: return "RB"
        case .l2: return "LT"
        case .r2: return "RT"
        case .l3: return "LS"
        case .r3: return "RS"
        case .create: return "View"
        case .options: return "Menu"
        case .touchpad: return "Xbox"
        default: return nil
        }
    }

    /// Runde Tasten (Symbole, Steuerkreuz) gegen eckige (Schultertasten, Text).
    var isRoundGlyph: Bool {
        switch self {
        case .cross, .circle, .square, .triangle, .dpadUp, .dpadDown, .dpadLeft, .dpadRight: return true
        default: return false
        }
    }
}

extension ControllerPaddle {
    /// „Upper left paddle (P3)“ — Lage und Elite-Zählung.
    var displayName: String {
        let number = "P\(eliteNumber)"
        switch self {
        case .upperLeft: return String(localized: "Upper left paddle (\(number))")
        case .lowerLeft: return String(localized: "Lower left paddle (\(number))")
        case .upperRight: return String(localized: "Upper right paddle (\(number))")
        case .lowerRight: return String(localized: "Lower right paddle (\(number))")
        }
    }
}

extension ControllerFamily {
    /// „das Touchpad“ bzw. „den Xbox-Knopf“ in Erklärtexten.
    var touchpadPhrase: String {
        self == .xbox ? String(localized: "the Xbox button") : String(localized: "the touchpad")
    }
}

private struct ControllerFamilyKey: EnvironmentKey {
    static let defaultValue: ControllerFamily = .playStation
}

extension EnvironmentValues {
    /// Familie des Controllers der letzten Eingabe. Gesetzt an den Wurzeln,
    /// die `ControllerStatus` ohnehin beobachten (Legende, Verlauf,
    /// Einstellungen, Insel, Menü); gelesen von den Tasten-Symbolen.
    var controllerFamily: ControllerFamily {
        get { self[ControllerFamilyKey.self] }
        set { self[ControllerFamilyKey.self] = newValue }
    }
}
