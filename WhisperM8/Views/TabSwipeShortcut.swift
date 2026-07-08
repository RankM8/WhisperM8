import AppKit

/// Reine, testbare Richtungs-Erkennung für den Drei-Finger-Swipe-Tab-Wechsel.
///
/// Voraussetzung (Systemeinstellungen → Trackpad → Weitere Gesten): „Zwischen
/// Seiten blättern" muss Drei-Finger-Swipes einschließen und „Zwischen
/// Vollbild-Apps streichen" auf VIER Finger stehen — sonst konsumiert der
/// Window Server die Geste für Spaces, bevor die App ein `.swipe`-Event sieht.
///
/// Gewünschte Semantik: Finger nach rechts → Tab rechts, Finger nach links →
/// Tab links. `.swipe`-Events sind diskret (`deltaX = ±1`); AppKit meldet
/// `deltaX > 0` für einen Swipe nach LINKS (Blätter-Konvention „zurück").
/// Sollte die manuelle QA auf realer Hardware das Gegenteil zeigen (die
/// Konvention ist historisch schlecht dokumentiert), dreht sich NUR das
/// Vorzeichen-Mapping hier — kein anderer Code.
enum TabSwipeShortcut {
    /// Tab-Wechsel-Richtung: `+1` (Tab rechts) / `-1` (Tab links) / `nil`
    /// (kein horizontaler Anteil, z. B. vertikaler Swipe mit `deltaX == 0`).
    static func direction(deltaX: CGFloat) -> Int? {
        if deltaX < 0 { return +1 }   // Finger nach rechts → Tab rechts
        if deltaX > 0 { return -1 }   // Finger nach links → Tab links
        return nil
    }
}
