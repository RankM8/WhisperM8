import CoreGraphics
import Foundation

/// Die Anordnung eines Workspace — Zellen statt fester Plaetze.
///
/// **Warum nicht `AgentGridWorkspace`:** Dort ist die Position die Identitaet
/// (`slots: [UUID?]` plus feste `capacity`). Daraus folgt eine Zwickmuehle:
/// Verdichten wuerde Positionen aendern, also darf es nicht automatisch
/// passieren; automatisch anordnen wuerde Positionen aendern, also darf es das
/// auch nicht. Uebrig bleibt Handarbeit — genau die Bedienprobleme, um die es
/// geht. Hier ist die Anordnung ein ERGEBNIS, keine Eingabe.
///
/// Plan und Begruendung: `docs/plans/workspace-umbau/`.
struct WorkspaceLayout: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var colorHex: String

    /// Die Chats, gruppiert in Zellen. Die Reihenfolge ist Lesereihenfolge,
    /// NICHT Bildschirmposition — die berechnet `LayoutGeometry`.
    var cells: [Cell]

    /// Wie die Flaeche aufgeteilt wird.
    var arrangement: Arrangement

    /// Absichtlich gestapelt: Chat → Anker-Chat. Ueberlebt jede Neuanordnung.
    ///
    /// Ohne das waere die automatische Anordnung schaedlich: Wer zwei Chats
    /// bewusst uebereinandergelegt hat, verloere die Gruppierung beim naechsten
    /// Verdichten. Automatik darf Unentschiedenes ordnen, aber nie
    /// Entschiedenes ueberschreiben — das ist die Regel, die den ganzen Umbau
    /// ertraeglich macht.
    var bindings: [UUID: UUID]

    /// Nur bei abgeleiteten Layouts (Projekt-Workspaces): Chats, die der
    /// Nutzer ausgeblendet hat. Loeschen geht dort nicht, weil die
    /// Mitgliedschaft aus dem Projekt folgt.
    var hidden: [UUID]

    /// Woher die Mitgliedschaft kommt.
    var source: Source

    /// KEIN `guest`-Feld. Der Gast war fuer den Sidebar-Klick gedacht — und der
    /// verlaesst den Workspace, statt einen Gast anzulegen (Entscheidung E1/E3).
    /// Damit entfallen ein Feld, ein Sonderfall in jeder Layout-Berechnung und
    /// die Frage, wann ein Gast endet.

    init(
        id: UUID = UUID(),
        name: String = "Workspace",
        colorHex: String = "#6E6ADE",
        cells: [Cell] = [],
        arrangement: Arrangement = .automatic,
        bindings: [UUID: UUID] = [:],
        hidden: [UUID] = [],
        source: Source = .manual
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.cells = cells
        self.arrangement = arrangement
        self.bindings = bindings
        self.hidden = hidden
        self.source = source
    }

    /// Alle Sessions in Lesereihenfolge, ueber alle Zellen und Stapel hinweg.
    var allSessions: [UUID] { cells.flatMap(\.sessions) }

    /// Die sichtbaren Sessions — genau eine je Zelle.
    var visibleSessions: [UUID] { cells.map(\.active) }

    func cell(containing session: UUID) -> Cell? {
        cells.first { $0.sessions.contains(session) }
    }
}

extension WorkspaceLayout {
    /// Eine Flaeche mit einem Stapel von Chats, von denen einer sichtbar ist.
    ///
    /// **Nie leer** — das ist der Unterschied zu `slots: [UUID?]`. Wird der
    /// letzte Chat entfernt, verschwindet die Zelle und die Flaeche verdichtet
    /// sich. Genau das war mit „muss ich klein machen" gemeint.
    struct Cell: Identifiable, Codable, Equatable {
        var id: UUID
        /// Mindestens ein Eintrag; der Normalisierer entfernt leere Zellen.
        var sessions: [UUID]
        /// Welcher sichtbar ist. Muss in `sessions` enthalten sein.
        var active: UUID

        init(id: UUID = UUID(), sessions: [UUID], active: UUID? = nil) {
            self.id = id
            self.sessions = sessions
            self.active = active ?? sessions.first ?? UUID()
        }

        /// Bequemlichkeit fuer den haeufigsten Fall: eine Zelle, ein Chat.
        init(id: UUID = UUID(), session: UUID) {
            self.init(id: id, sessions: [session], active: session)
        }

        var isStacked: Bool { sessions.count > 1 }
    }

    /// Wie die Flaeche aufgeteilt wird.
    enum Arrangement: Codable, Equatable {
        /// Ergibt sich aus der Zellenzahl. Der Normalfall — kein Loch, keine
        /// Stufe, keine Handarbeit.
        case automatic
        /// Der Nutzer hat geteilt oder gezogen; sein Baum gilt, bis er ihn
        /// ueber den sichtbaren Schalter loest (Entscheidung F6).
        case manual(SplitNode)

        var isAutomatic: Bool {
            if case .automatic = self { return true }
            return false
        }

        var tree: SplitNode? {
            if case let .manual(node) = self { return node }
            return nil
        }
    }

    /// Ein n-aerer Teilungsbaum. Blaetter zeigen auf Zellen.
    indirect enum SplitNode: Codable, Equatable {
        case leaf(cellID: UUID)
        case split(axis: Axis, children: [SplitNode], fractions: [Double])

        /// Alle Zell-IDs in Lesereihenfolge. Grundlage der Invariantenpruefung
        /// „jedes Blatt zeigt auf eine existierende Zelle, jede Zelle kommt
        /// genau einmal vor".
        var leafIDs: [UUID] {
            switch self {
            case let .leaf(cellID):
                return [cellID]
            case let .split(_, children, _):
                return children.flatMap(\.leafIDs)
            }
        }
    }

    enum Axis: String, Codable, Equatable {
        /// Kinder liegen nebeneinander (senkrechte Trenner).
        case horizontal
        /// Kinder liegen uebereinander (waagerechte Trenner).
        case vertical
    }

    /// Woher die Mitgliedschaft kommt.
    enum Source: Codable, Equatable {
        /// Der Nutzer bestimmt die Mitglieder.
        case manual
        /// Mitglieder folgen aus dem Projekt; `hidden` blendet aus.
        case project(UUID)

        var isDerived: Bool {
            if case .project = self { return true }
            return false
        }
    }
}
