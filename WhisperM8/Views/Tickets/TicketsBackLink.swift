import SwiftUI

/// Weg vom Board zurück zu den Chats (WM8-124): links im Kopf des Boards
/// „← Chats · <Name>“. Er führt dorthin, wohin auch L2 am Controller führt
/// (`backPlace()`), sonst zu dem, was hinter den Tickets steht (wie der
/// Ticket-Knopf in der Titelzone). Pur, damit Name und Ziel getestet sind.
enum TicketsBackLink {
    enum Route: Equatable {
        /// Zum vorigen Ort wie L2 (ein anderer Chat oder Workspace).
        case previousPlace
        /// Nur die Tickets schließen: Was dahinter steht, ist das Ziel.
        case closeTickets
    }

    struct Destination: Equatable {
        /// Name des Workspace oder Chats, `nil` ohne Namen („← Chats“).
        var name: String?
        var route: Route
    }

    /// - Parameters:
    ///   - previous: voriger Ort des Fensters (`backPlace()`), schon geprüft.
    ///   - behind: Ort hinter den Tickets (Auswahl und Raster des Fensters).
    ///   - name: Name eines Chats oder Workspace für die Beschriftung.
    static func destination(previous: ChatPlace?, behind: ChatPlace?, name: (ChatPlace) -> String?) -> Destination {
        switch previous {
        case .chat?, .workspace?:
            // Steht der vorige Ort schon hinter den Tickets, änderte L2 an der
            // Auswahl nichts; dann reicht es, die Tickets zu schließen.
            let route: Route = previous == behind ? .closeTickets : .previousPlace
            return Destination(name: previous.flatMap(name), route: route)
        case .tickets?, nil:
            // Ein anderes Board ist kein Weg zu den Chats.
            return Destination(name: behind.flatMap(name), route: .closeTickets)
        }
    }

    /// Längster Name auf dem Knopf; der Knopf selbst wird nie gekürzt.
    static let maximumNameLength = 24

    /// Beschriftung auf dem Knopf.
    static func title(_ destination: Destination) -> String {
        let flat = destination.name.map(TicketCopyText.flat)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !flat.isEmpty else { return String(localized: "Chats") }
        let name = flat.count > maximumNameLength ? String(flat.prefix(maximumNameLength - 1)) + "…" : flat
        return String(localized: "Chats · \(name)")
    }
}

/// Was der Kopf des Boards für den Rückweg braucht.
struct TicketsBackLinkModel {
    var destination: TicketsBackLink.Destination
    var go: () -> Void
}

/// Der Knopf selbst. Immer ganz sichtbar (der Name ist schon gekürzt);
/// eng wird es zuerst für die anderen Teile des Kopfs.
struct TicketsBackLinkButton: View {
    let link: TicketsBackLinkModel
    /// Enger Kopf der Triage: nur „← Chats“, der Name steht in der Hilfe.
    var compact = false

    var body: some View {
        let title = TicketsBackLink.title(link.destination)
        Button(action: link.go) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.left")
                    .font(.system(size: 11, weight: .semibold))
                Text(verbatim: compact ? String(localized: "Chats") : title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .fixedSize()
            .foregroundStyle(AgentTheme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(AgentTheme.hover, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(localized: "Back to \(title)"))
        .accessibilityLabel(String(localized: "Back to \(title)"))
    }
}
