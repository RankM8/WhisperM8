import CoreGraphics
import Foundation

/// Gemerkte Lage der Pille auf einem Bildschirm ohne Notch: Mittelpunkt als
/// Anteil am Bildschirmrahmen (0…1, `y` von unten wie Cocoa). Anteile statt
/// Punkten, damit die Pille nach einem Auflösungswechsel an derselben Stelle
/// sitzt.
struct NotchPillPosition: Equatable, Codable {
    var x: Double
    var y: Double
}

/// Ort der Anzeige auf einem Bildschirm: an der Notch oder als Pille.
struct NotchPlacement: Equatable {
    enum Kind: String, CaseIterable {
        /// An der Hardware-Notch, wie bisher: nur sichtbar, wenn etwas los ist.
        case notch
        /// Schwarze Pille auf einem Bildschirm ohne Notch: immer sichtbar,
        /// mit der Maus verschiebbar.
        case pill
    }

    var kind: Kind
    var screen: NotchScreenInfo
}

/// Lage der Pille ohne Notch (Anzeige und Controller-Insel). Rein, ohne
/// Bildschirm testbar; alle Rahmen in globalen Cocoa-Koordinaten.
enum NotchPillPlacement {
    /// Ab dieser Mausbewegung wird aus einem Klick ein Ziehen (wie bei der
    /// Diktat-Pille: die ganze Fläche zieht, darunter zählt es als Klick).
    static let dragThreshold: CGFloat = 4

    // MARK: Wo die Anzeige steht

    /// An welchen Bildschirmen die Anzeige steht.
    ///
    /// - Notch: der gewählte Bildschirm (`NotchGeometry.selectScreen`), wenn er
    ///   eine Notch hat — unverändert.
    /// - Pille: der Bildschirm des Agent-Chats-Fensters, wenn er keine Notch
    ///   hat. Ohne Agent-Chats-Fenster (oder liegt es an einer Notch) der
    ///   gewählte Bildschirm, falls der keine Notch hat.
    ///
    /// Höchstens eine Notch und eine Pille, nie zweimal derselbe Bildschirm.
    static func placements(
        choice: NotchScreenChoice,
        screens: [NotchScreenInfo],
        mainDisplayID: UInt32?,
        agentWindowDisplayID: UInt32?
    ) -> [NotchPlacement] {
        guard let chosen = NotchGeometry.selectScreen(choice: choice, screens: screens, mainDisplayID: mainDisplayID)
        else { return [] }
        var result: [NotchPlacement] = []
        if chosen.hasNotch { result.append(NotchPlacement(kind: .notch, screen: chosen)) }
        let agentScreen = agentWindowDisplayID.flatMap { id in screens.first { $0.displayID == id } }
        if let agentScreen, !agentScreen.hasNotch {
            result.append(NotchPlacement(kind: .pill, screen: agentScreen))
        } else if !chosen.hasNotch {
            result.append(NotchPlacement(kind: .pill, screen: chosen))
        }
        return result
    }

    // MARK: Lage auf dem Bildschirm

    /// Höhe der Menüleiste; ohne Angabe (automatisch ausgeblendet) der
    /// Ersatzwert, wenn `fallback` gesetzt ist.
    static func menuBarHeight(_ screen: NotchScreenInfo, fallback: Bool) -> CGFloat {
        let measured = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
        return measured > 0 || !fallback ? measured : NotchGeometry.fallbackMenuBarHeight
    }

    /// Bereich, in dem die Pille liegen darf: der sichtbare Bereich des
    /// Bildschirms (ohne Menüleiste und Dock), wie bei der Diktat-Pille
    /// (`OverlayFrameResolver.clampedPanelOrigin`).
    static func usableArea(_ screen: NotchScreenInfo, fallbackMenuBar: Bool = true) -> CGRect {
        let top = min(screen.visibleFrame.maxY, screen.frame.maxY - menuBarHeight(screen, fallback: fallbackMenuBar))
        return CGRect(x: screen.visibleFrame.minX, y: screen.visibleFrame.minY,
                      width: screen.visibleFrame.width, height: max(0, top - screen.visibleFrame.minY))
    }

    /// Mittelpunkt der Pille ohne gemerkte Lage: oben mittig unter der Menüleiste.
    static func defaultCenter(_ screen: NotchScreenInfo, fallbackMenuBar: Bool = true) -> CGPoint {
        let top = screen.frame.maxY - menuBarHeight(screen, fallback: fallbackMenuBar) - NotchGeometry.pillTopGap
        return CGPoint(x: screen.frame.midX, y: top - NotchGeometry.pillHeight / 2)
    }

    /// Mittelpunkt der Pille: gemerkte Lage oder oben mittig, immer so, dass
    /// eine Pille in Ruhe-Höhe ganz auf dem Bildschirm liegt.
    static func center(
        _ screen: NotchScreenInfo, stored: NotchPillPosition?, fallbackMenuBar: Bool = true
    ) -> CGPoint {
        guard let stored else { return defaultCenter(screen, fallbackMenuBar: fallbackMenuBar) }
        let raw = CGPoint(x: screen.frame.minX + CGFloat(stored.x) * screen.frame.width,
                          y: screen.frame.minY + CGFloat(stored.y) * screen.frame.height)
        let size = CGSize(width: NotchGeometry.pillCompactWidth(chipCount: 0), height: NotchGeometry.pillHeight)
        let frame = clamp(CGRect(x: raw.x - size.width / 2, y: raw.y - size.height / 2,
                                 width: size.width, height: size.height),
                          to: usableArea(screen, fallbackMenuBar: fallbackMenuBar))
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    /// Gemerkte Lage für einen Mittelpunkt (nach dem Ziehen).
    static func position(forCenter center: CGPoint, on screen: NotchScreenInfo) -> NotchPillPosition {
        NotchPillPosition(
            x: Double((center.x - screen.frame.minX) / max(1, screen.frame.width)),
            y: Double((center.y - screen.frame.minY) / max(1, screen.frame.height)))
    }

    /// Sitzt die Pille in der unteren Bildschirmhälfte, öffnet alles nach oben.
    static func opensUpward(center: CGPoint, on screen: NotchScreenInfo) -> Bool {
        center.y < screen.frame.midY
    }

    /// Rahmen für Inhalt der Größe `size`, der aus der Pille wächst: waagrecht
    /// um ihre Mitte, senkrecht ab ihrer Oberkante nach unten bzw. ab ihrer
    /// Unterkante nach oben. Immer ganz auf dem Bildschirm (unter der
    /// Menüleiste); reicht der Platz nicht, wird verschoben.
    static func frame(
        size: CGSize, growingFrom center: CGPoint, on screen: NotchScreenInfo, fallbackMenuBar: Bool = true
    ) -> CGRect {
        let half = NotchGeometry.pillHeight / 2
        let y = opensUpward(center: center, on: screen) ? center.y - half : center.y + half - size.height
        let rect = CGRect(x: center.x - size.width / 2, y: y, width: size.width, height: size.height)
        return clamp(rect, to: usableArea(screen, fallbackMenuBar: fallbackMenuBar))
    }

    /// Schiebt `rect` in `area`; ist es größer, bleibt die Ober- bzw. linke Kante.
    static func clamp(_ rect: CGRect, to area: CGRect) -> CGRect {
        var result = rect
        result.origin.x = min(max(rect.minX, area.minX), max(area.minX, area.maxX - rect.width))
        result.origin.y = max(min(rect.minY, area.maxY - rect.height), min(area.minY, area.maxY - rect.height))
        return result
    }
}
