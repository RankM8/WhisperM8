import CoreGraphics
import Foundation

/// Bestimmt, was ein Zug an einer Bildschirmposition bedeutet — pur und ohne
/// Maus, damit jede Zone, jede Kante und jeder Randfall unter Tests steht.
///
/// **Warum das getrennt ist:** Drag-Interaktion laesst sich nicht sinnvoll
/// automatisiert pruefen; die Entscheidung „was passiert beim Loslassen"
/// dagegen schon. Genau dort sitzen die Fehler, die man sonst erst im Betrieb
/// bemerkt. Die Oberflaeche liefert Position und Rechtecke, bekommt ein Ziel
/// zurueck und muss nichts weiter wissen.
enum LayoutDropResolver {

    /// Was beim Loslassen geschieht.
    enum Target: Equatable {
        /// Inhalt der Flaeche ersetzen (aeusserer Ring).
        case replace(cellID: UUID)
        /// Auf den Stapel legen (innerer Kern).
        case stack(cellID: UUID)
        /// Neue Flaeche an dieser Kante (Entscheidung E7).
        case edge(cellID: UUID, edge: LayoutEngine.Edge)
        /// Kein gueltiges Ziel.
        case none
    }

    /// Wie breit der Kantenbereich ist, als Anteil der jeweiligen Seite.
    ///
    /// 18 % klingt viel, ist aber noetig: Bei neun Flaechen ist eine Kante nur
    /// wenige Dutzend Punkte breit, und ein Ziel, das man nicht trifft,
    /// existiert praktisch nicht. Nach oben begrenzt, damit die Kante bei
    /// grossen Flaechen nicht den halben Rand frisst.
    static let edgeFraction: CGFloat = 0.18
    static let maximumEdgeInset: CGFloat = 64

    /// Wie gross der innere Kern ist, als Anteil der Flaeche.
    ///
    /// Der Kern stapelt, der Ring dazwischen ersetzt. Beides muss ohne
    /// Erklaerung treffbar sein — deshalb bekommt der Kern die Mitte, wo die
    /// Maus ohnehin landet, wenn man „auf diese Flaeche" zielt.
    static let coreFraction: CGFloat = 0.5

    /// Loest eine Position gegen die Flaechen auf.
    ///
    /// - Parameter excluding: Die Zelle, aus der gezogen wird. Sie kommt als
    ///   Ziel nicht in Frage — ein Chat auf sich selbst zu ziehen ergaebe
    ///   nichts und wuerde beim Loslassen nur flackern.
    static func resolve(
        point: CGPoint,
        frames: [UUID: CGRect],
        excluding sourceCellID: UUID? = nil
    ) -> Target {
        // Deterministisch bei Ueberlappung oder exakt getroffener Kante:
        // Die Sortierung macht das Ergebnis unabhaengig von der
        // Dictionary-Reihenfolge, die zwischen Laeufen wechseln kann.
        let kandidaten = frames
            .filter { $0.value.contains(point) && $0.key != sourceCellID }
            .sorted { $0.key.uuidString < $1.key.uuidString }

        guard let (cellID, frame) = kandidaten.first else { return .none }
        guard frame.width > 0, frame.height > 0 else { return .none }

        // Kante zuerst pruefen: Sie ist die ausdruecklichere Absicht. Wer den
        // Rand trifft, will dort eine neue Flaeche, nicht „irgendwo in dieser".
        if let edge = edge(for: point, in: frame) {
            return .edge(cellID: cellID, edge: edge)
        }

        let kern = frame.insetBy(
            dx: frame.width * (1 - coreFraction) / 2,
            dy: frame.height * (1 - coreFraction) / 2
        )
        return kern.contains(point) ? .stack(cellID: cellID) : .replace(cellID: cellID)
    }

    /// Welche Kante die Position trifft — `nil`, wenn keine.
    private static func edge(for point: CGPoint, in frame: CGRect) -> LayoutEngine.Edge? {
        let horizontalInset = min(frame.width * edgeFraction, maximumEdgeInset)
        let verticalInset = min(frame.height * edgeFraction, maximumEdgeInset)

        let vonLinks = point.x - frame.minX
        let vonRechts = frame.maxX - point.x
        let vonOben = point.y - frame.minY
        let vonUnten = frame.maxY - point.y

        // Naechstliegende Kante gewinnt. In einer Ecke waeren zwei zugleich
        // getroffen — dann entscheidet der kleinere Abstand, damit das
        // Ergebnis nicht von der Prueferreihenfolge abhaengt.
        var beste: (edge: LayoutEngine.Edge, abstand: CGFloat)?
        func pruefe(_ edge: LayoutEngine.Edge, _ abstand: CGFloat, _ grenze: CGFloat) {
            guard abstand <= grenze else { return }
            if beste == nil || abstand < beste!.abstand { beste = (edge, abstand) }
        }
        pruefe(.leading, vonLinks, horizontalInset)
        pruefe(.trailing, vonRechts, horizontalInset)
        pruefe(.top, vonOben, verticalInset)
        pruefe(.bottom, vonUnten, verticalInset)

        return beste?.edge
    }

    /// Wendet ein Ziel auf ein Layout an.
    ///
    /// Damit liegt die gesamte Zug-Semantik an einer Stelle: Die Oberflaeche
    /// bestimmt das Ziel, ruft dies auf und bekommt ein gueltiges Layout —
    /// ohne zu wissen, welche Engine-Funktion dahintersteht.
    static func apply(
        _ target: Target,
        session: UUID,
        to layout: WorkspaceLayout
    ) -> WorkspaceLayout {
        switch target {
        case let .replace(cellID):
            return LayoutEngine.drop(session, onto: cellID, mode: .replace, in: layout)
        case let .stack(cellID):
            return LayoutEngine.drop(session, onto: cellID, mode: .stack, in: layout)
        case let .edge(cellID, edge):
            return LayoutEngine.insert(session, atEdge: edge, of: cellID, in: layout)
        case .none:
            return layout
        }
    }
}
