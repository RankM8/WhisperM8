import Foundation

/// Zustandsloser Hit-Test für das Tab-Strip-Band — pur und getestet.
///
/// Hintergrund (Vorfall 2026-08-23): Der fensterweite `scrollWheel`-Monitor
/// wurde allein über das `onHover`-Flag `isHoveringTabStrip` gegated. SwiftUI
/// verliert das `onHover(false)` aber, wenn z. B. ein Kontextmenü oder ein
/// Drag über der Leiste dazwischenkommt — das Flag blieb auf `true` hängen
/// und der Monitor konsumierte JEDES Mausrad-Event im Fenster: Scrollen war
/// in Sidebar UND Chats tot, bis die Maus zufällig wieder über die Leiste
/// fuhr. Ein Koordinaten-Check zum Event-Zeitpunkt kann prinzipbedingt nicht
/// hängen bleiben — jedes Event entscheidet frisch.
///
/// Koordinaten bewusst gemischt: Y kommt rein aus AppKit
/// (`locationInWindow.y` gegen die contentView-Höhe, Ursprung unten links —
/// dasselbe Muster wie der Doppelklick-Zoom, funktioniert in Fenster- und
/// Vollbildmodus), X aus der window-relativ GEMESSENEN Strip-Spanne
/// (`stripFrameInWindow`, gleicher Ursprung am linken Fensterrand). Die
/// frühere fragile SwiftUI-Y-Umrechnung (Titelleisten-Versatz im
/// Fenstermodus) wird damit NICHT wieder eingeführt.
enum TabStripBand {
    /// Höhe der Tab-Zeile (34pt seit dem Chrome-Redesign) — eine Quelle für
    /// Scroll-Gating UND Doppelklick-Zoom, damit die Bänder nie divergieren.
    static let height: CGFloat = 34

    /// `true`, wenn der Punkt (AppKit-Fensterkoordinaten) im obersten Band
    /// liegt UND innerhalb der gemessenen X-Spanne des Strips. Eine leere
    /// Spanne (Breite 0 = noch nicht gemessen, z. B. vor dem ersten Layout)
    /// trifft nie — dann wird lieber ein Strip-Scroll verschluckt als ein
    /// Fenster-Scroll gekapert.
    static func contains(
        _ locationInWindow: CGPoint,
        contentViewHeight: CGFloat,
        stripFrame: CGRect
    ) -> Bool {
        guard stripFrame.width > 0 else { return false }
        guard locationInWindow.y >= contentViewHeight - height else { return false }
        return locationInWindow.x >= stripFrame.minX
            && locationInWindow.x <= stripFrame.maxX
    }
}
