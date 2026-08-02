import CoreGraphics
import Foundation

/// Der Zustand eines laufenden Zuges — pur, ohne Mausereignisse.
///
/// **Warum getrennt von der Ansicht:** Ein Zug hat mehr Zustaende als es
/// aussieht — noch nicht begonnen, begonnen aber unter der Schwelle, aktiv,
/// ueber einem Ziel, ueber keinem. Jeder Uebergang ist eine Stelle, an der
/// „ein Klick wird versehentlich zum Zug" passieren kann. Hier laesst sich das
/// pruefen; in einer SwiftUI-Geste nicht.
///
/// Die Ansicht meldet nur `begin`, `move`, `end` und liest ab, was zu zeichnen
/// ist.
struct LayoutDragState: Equatable {
    /// Ab dieser Bewegung gilt es als Zug. Darunter bleibt es ein Klick.
    ///
    /// Vier Punkte klingt wenig, ist aber bewusst so knapp: Wer eine Flaeche
    /// packt und schiebt, bewegt sich sofort weiter; wer klickt, zittert
    /// hoechstens ein, zwei Punkte. Ein groesserer Wert liesse den Zug traege
    /// anspringen.
    static let threshold: CGFloat = 4

    enum Phase: Equatable {
        /// Nichts los.
        case idle
        /// Maus ist unten, aber die Schwelle noch nicht ueberschritten —
        /// bis hierhin ist es ein Klick.
        case pending(session: UUID, origin: CGPoint)
        /// Es wird gezogen.
        case dragging(session: UUID, origin: CGPoint, current: CGPoint)
    }

    private(set) var phase: Phase = .idle
    /// Das aktuelle Ziel — nur waehrend `dragging` gesetzt.
    private(set) var target: LayoutDropResolver.Target = .none

    var isDragging: Bool {
        if case .dragging = phase { return true }
        return false
    }

    /// Die gezogene Session, sobald wirklich gezogen wird.
    var draggedSession: UUID? {
        if case let .dragging(session, _, _) = phase { return session }
        return nil
    }

    /// Wo der Zeiger gerade ist — fuer das Ziehbild.
    var currentPoint: CGPoint? {
        if case let .dragging(_, _, current) = phase { return current }
        return nil
    }

    // MARK: - Uebergaenge

    mutating func begin(session: UUID, at point: CGPoint) {
        phase = .pending(session: session, origin: point)
        target = .none
    }

    /// Bewegung melden. Loest den Zug aus, sobald die Schwelle faellt.
    ///
    /// `frames` und `sourceCellID` werden gebraucht, um das Ziel gleich
    /// mitzubestimmen — so kennt die Ansicht nach jedem Aufruf den Zustand
    /// vollstaendig und muss nichts nachrechnen.
    mutating func move(
        to point: CGPoint,
        frames: [UUID: CGRect],
        sourceCellID: UUID?
    ) {
        switch phase {
        case .idle:
            return

        case let .pending(session, origin):
            let dx = point.x - origin.x
            let dy = point.y - origin.y
            guard (dx * dx + dy * dy).squareRoot() >= Self.threshold else { return }
            phase = .dragging(session: session, origin: origin, current: point)
            target = LayoutDropResolver.resolve(
                point: point, frames: frames, excluding: sourceCellID
            )

        case let .dragging(session, origin, _):
            phase = .dragging(session: session, origin: origin, current: point)
            target = LayoutDropResolver.resolve(
                point: point, frames: frames, excluding: sourceCellID
            )
        }
    }

    /// Beendet den Zug und liefert, was anzuwenden ist.
    ///
    /// Gibt `nil` zurueck, wenn es ein Klick war oder kein Ziel getroffen
    /// wurde — dann darf die Ansicht das Layout nicht anfassen.
    mutating func end() -> (session: UUID, target: LayoutDropResolver.Target)? {
        defer { phase = .idle; target = .none }
        guard case let .dragging(session, _, _) = phase, target != .none else {
            return nil
        }
        return (session, target)
    }

    /// Bricht ab, ohne etwas anzuwenden (Escape, Fensterwechsel).
    mutating func cancel() {
        phase = .idle
        target = .none
    }
}
