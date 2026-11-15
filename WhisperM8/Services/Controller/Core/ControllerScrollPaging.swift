import Foundation

/// Bildschirmweise blättern (R1 + rechter Stick, WM8-116): wie viele Zeilen
/// ein Stoß weitergeht.
enum ControllerScrollPaging {
    /// So viele Zeilen des alten Bildschirms bleiben nach einem Schritt
    /// sichtbar, damit man den Anschluss findet.
    static let overlapLines = 3

    /// Zeilen für `step` Bildschirme bei `rows` sichtbaren Zeilen, positiv
    /// nach unten. Mindestens eine Zeile je Schritt, auch in einer sehr
    /// flachen Kachel.
    static func lines(step: Int, rows: Int) -> Int {
        step * max(1, rows - overlapLines)
    }
}
