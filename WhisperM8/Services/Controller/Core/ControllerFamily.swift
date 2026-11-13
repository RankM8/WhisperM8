import Foundation

/// Hersteller-Familie eines Controllers (Plan `controller-xbox-paddles.md`,
/// Entscheidung 1). Sie bestimmt nur, wie Tasten heißen und welche Eingaben
/// es gibt; die Belegung nach Lage bleibt für alle gleich (A = Kreuz usw.).
enum ControllerFamily: String, CaseIterable, Sendable {
    case playStation, xbox, generic

    /// Rückfall über den Kategorie-Text des Frameworks („DualSense“,
    /// „Xbox One“), für Debug-Kanal und Tests. Die Live-Quelle bestimmt die
    /// Familie aus der Profilklasse.
    static func classify(productCategory: String) -> ControllerFamily {
        let text = productCategory.lowercased()
        if text.contains("xbox") { return .xbox }
        let playStation = ["dualsense", "dualshock", "playstation", "ps4", "ps5"]
        if playStation.contains(where: text.contains) { return .playStation }
        return .generic
    }

    /// Das Gerät hat ein Touchpad zum Drücken. Allgemeine Gamepads behalten
    /// wie bisher die PlayStation-Belegung samt Touchpad-Einträgen.
    var hasTouchpad: Bool { self != .xbox }
}

/// Was die Anzeige über den Controller der letzten Eingabe wissen muss:
/// Familie (Tastennamen) und ob es die Taste für den Zwischenablage-Verlauf
/// gibt (`.touchpad` — am DualSense das Touchpad, am Xbox-Controller der
/// Xbox-Knopf, sofern er über HID lesbar ist).
struct ControllerInputTraits: Equatable, Sendable {
    var family: ControllerFamily
    var hasTouchpad: Bool

    init(family: ControllerFamily = .playStation, hasTouchpad: Bool? = nil) {
        self.family = family
        self.hasTouchpad = hasTouchpad ?? family.hasTouchpad
    }

    /// Ohne Controller-Angabe: PlayStation-Zeichen wie bisher.
    static let standard = ControllerInputTraits()
}
