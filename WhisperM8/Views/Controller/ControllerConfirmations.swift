import Observation
import SwiftUI

/// Rückfragen für Aktionen aus dem Options-Menü des Controllers, die etwas
/// beenden (Review Runde 5, Befund 7): Hintergrund-Agent stoppen, Subagent-Job
/// stoppen. Je Fenster eine offene Rückfrage; bestätigt wird wie jede
/// Rückfrage der Seitenleiste (Kreuz = Return über die Tastatur-Brücke).
@MainActor
@Observable
final class ControllerConfirmations {
    static let shared = ControllerConfirmations()

    struct Pending: Equatable {
        enum Kind: Equatable {
            case backgroundStop, stopJob
        }

        var kind: Kind
        var sessionID: UUID
        var title: String
    }

    var pending: [UUID: Pending] = [:]

    func isOpen(in windowID: UUID) -> Bool { pending[windowID] != nil }
}

/// Zeigt die Rückfrage eines Fensters. Eigener kleiner Baustein, damit nur er
/// die offene Rückfrage beobachtet, nicht der Body von `AgentChatsView`.
struct ControllerConfirmationDialog: ViewModifier {
    let windowID: UUID
    let perform: (ControllerConfirmations.Pending) -> Void
    @State private var store = ControllerConfirmations.shared

    func body(content: Content) -> some View {
        let pending = store.pending[windowID]
        return content.confirmationDialog(
            pending.map(Self.title) ?? "",
            isPresented: Binding(
                get: { store.pending[windowID] != nil },
                set: { if !$0 { store.pending[windowID] = nil } }),
            presenting: pending
        ) { pending in
            Button(String(localized: "Stop"), role: .destructive) {
                store.pending[windowID] = nil
                perform(pending)
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { pending in
            Text(verbatim: pending.title)
        }
    }

    private static func title(_ pending: ControllerConfirmations.Pending) -> String {
        switch pending.kind {
        case .backgroundStop: return String(localized: "Stop this background agent?")
        case .stopJob: return String(localized: "Stop this job?")
        }
    }
}
