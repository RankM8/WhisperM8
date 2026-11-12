import Foundation

/// Wo die Menü-Karte des Controllers (Options) erscheint: am Chat, für den
/// sie gilt (Runde 5, freigegeben 12.11.2026). Pur, damit Lage, Kippen an
/// Rändern und Höhe in kleinen Fenstern Tests bekommen.
///
/// Koordinaten wie in SwiftUI: Ursprung oben links, y wächst nach unten.
enum ControllerMenuPlacement {
    /// Woran die Karte hängt.
    enum Anchor: Int, Sendable, CaseIterable {
        /// Kopf der Einzelansicht (dort sitzt der „…“-Knopf): Karte rechts
        /// bündig direkt darunter.
        case header
        /// Kopf der Kachel im Raster: Karte rechts bündig darunter.
        case tile
        /// Markierte Zeile der Liste links: Karte rechts daneben.
        case listRow

        /// Gibt es mehrere, gilt die Zeile der Liste vor der Kachel vor dem
        /// Kopf (in der Liste wirkt das Menü auf die markierte Zeile).
        static func preferred(_ available: Set<Anchor>) -> Anchor? {
            [.listRow, .tile, .header].first { available.contains($0) }
        }
    }

    /// Abstand zum Fensterrand.
    static let margin: CGFloat = 8
    /// Abstand zwischen Anker und Karte.
    static let gap: CGFloat = 6
    /// Darunter kippt die Karte über den Anker, wenn dort mehr Platz ist.
    static let comfortableHeight: CGFloat = 180

    struct Result: Equatable, Sendable {
        var frame: CGRect
        /// Der Inhalt ist höher als die Karte: Die Liste scrollt in ihr.
        var scrolls: Bool
    }

    /// - Parameters:
    ///   - anchor: Art und Rahmen des Ankers in `container`; ohne Anker unten
    ///     mittig über der Legende (wie vor Runde 5).
    ///   - contentHeight: volle Höhe der Karte ohne Scrollen.
    ///   - width: gewünschte Breite.
    ///   - container: Fläche des Fensters, in der die Karte liegt.
    ///   - bottomInset: unten freizuhalten (Legende).
    static func place(
        anchor: (kind: Anchor, rect: CGRect)?,
        contentHeight: CGFloat,
        width: CGFloat,
        container: CGRect,
        bottomInset: CGFloat
    ) -> Result {
        let usable = CGRect(
            x: container.minX + margin, y: container.minY + margin,
            width: max(0, container.width - 2 * margin),
            height: max(0, container.height - 2 * margin - bottomInset))
        let cardWidth = min(width, usable.width)
        guard let anchor else {
            let height = min(contentHeight, usable.height)
            let frame = CGRect(x: usable.midX - cardWidth / 2, y: usable.maxY - height, width: cardWidth, height: height)
            return Result(frame: frame, scrolls: height < contentHeight)
        }
        let rect = anchor.rect
        switch anchor.kind {
        case .header, .tile:
            let x = clamp(rect.maxX - cardWidth, usable.minX, usable.maxX - cardWidth)
            let below = usable.maxY - (rect.maxY + gap)
            let above = (rect.minY - gap) - usable.minY
            let y: CGFloat
            let height: CGFloat
            if contentHeight <= below || (below >= above && below >= comfortableHeight) {
                height = min(contentHeight, max(below, 0))
                y = rect.maxY + gap
            } else if above > below, above >= comfortableHeight || contentHeight <= above {
                height = min(contentHeight, above)
                y = rect.minY - gap - height
            } else {
                // Weder darunter noch darüber genug Platz (sehr kleines
                // Fenster): die Karte darf den Anker überdecken.
                height = min(contentHeight, usable.height)
                y = clamp(rect.maxY + gap, usable.minY, usable.maxY - height)
            }
            return Result(frame: CGRect(x: x, y: y, width: cardWidth, height: height), scrolls: height < contentHeight)
        case .listRow:
            var x = rect.maxX + gap
            if x + cardWidth > usable.maxX {
                let left = rect.minX - gap - cardWidth
                x = left >= usable.minX ? left : usable.maxX - cardWidth
            }
            x = clamp(x, usable.minX, usable.maxX - cardWidth)
            let height = min(contentHeight, usable.height)
            let y = clamp(rect.minY, usable.minY, usable.maxY - height)
            return Result(frame: CGRect(x: x, y: y, width: cardWidth, height: height), scrolls: height < contentHeight)
        }
    }

    private static func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        guard high >= low else { return low }
        return min(max(value, low), high)
    }
}
