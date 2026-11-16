import SwiftUI

// MARK: - Reiter mit den Ansichten aus Linear (WM8-125)

/// Die Reiterzeile unter dem Kopf: Favoriten aus Linear, was nicht passt unter
/// „Mehr“. Mit der Maus ist „Mehr“ ein Menü-Knopf (kein `.contextMenu`); mit
/// Controller und Tastatur öffnet Kreuz bzw. Return die Liste darunter.
///
/// Kosten: liest Katalog, gezeigte Ansicht und die gemessene Breite. Ein Abruf
/// der Tickets ändert keins davon; nur ein Reiterwechsel zeichnet die Zeile neu.
struct TicketViewTabsBar: View {
    let model: TicketBoardViewModel

    var body: some View {
        let tabs = model.tabs
        HStack(spacing: TicketViewTabs.spacing) {
            ForEach(tabs.shown) { view in
                TicketViewTabButton(name: view.name, isActive: view.id == model.activeViewID) {
                    model.selectView(view.id)
                }
                .ticketHeaderRing(.view(view.id), model: model)
            }
            if !tabs.more.isEmpty {
                TicketMoreViewsButton(model: model, views: tabs.more)
                    .ticketHeaderRing(.moreViews, model: model)
                    .anchorPreference(key: TicketMorePickerAnchorKey.self, value: .bounds) { $0 }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Gemessen wird die ganze Zeile, nicht die Reiter: So ändert das
        // Verschieben unter „Mehr“ die Messung nicht (keine Schleife).
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { model.setTabsWidth($0) }
        .overlayPreferenceValue(TicketMorePickerAnchorKey.self) { anchor in
            GeometryReader { geometry in
                if let anchor {
                    let rect = geometry[anchor]
                    TicketMoreViewsList(model: model, views: tabs.more)
                        .offset(x: rect.minX, y: rect.maxY + 4)
                }
            }
        }
        .zIndex(1)
    }
}

struct TicketViewTabButton: View {
    let name: String
    let isActive: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            Text(verbatim: name)
                .font(.system(size: TicketViewTabMetrics.fontSize, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? AgentTheme.textPrimary : AgentTheme.textSecondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, TicketViewTabMetrics.horizontalPadding)
                .padding(.vertical, 5)
                .background(isActive ? AgentTheme.selection : Color.clear,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : [.isButton])
    }
}

/// „Mehr · 3“: Menü mit den Ansichten, die nicht in die Zeile passen. Steht die
/// gezeigte Ansicht darin, heißt der Knopf wie sie.
struct TicketMoreViewsButton: View {
    let model: TicketBoardViewModel
    let views: [TicketView]

    var body: some View {
        Menu {
            ForEach(views) { view in
                Button { model.selectView(view.id) } label: { Text(verbatim: view.name) }
            }
        } label: {
            Text("More · \(views.count)")
                .font(.system(size: TicketViewTabMetrics.fontSize))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(AgentTheme.textSecondary)
        .padding(.horizontal, 6)
        .help(Text("More views"))
    }
}

/// Unter den Reitern: was die Ansicht tut, ihre Zahl, ein Link nach Linear
/// und, falls nötig, der Hinweis auf eine Gruppierung, die WhisperM8 nicht kennt.
struct TicketViewInfoLine: View {
    let model: TicketBoardViewModel
    let load: TicketBoardLoad
    let openURL: (URL) -> Void

    var body: some View {
        let presentation = model.presentation
        HStack(spacing: 6) {
            if let view = model.activeView {
                Text(verbatim: TicketBoardText.viewSummary(view, count: presentation.visibleCount))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let url = view.url.flatMap(URL.init(string:)), url.scheme == "https" {
                    Button { openURL(url) } label: { Text("Open in Linear") }
                        .buttonStyle(.link)
                        .fixedSize()
                }
            } else if model.catalog.views.isEmpty {
                // Ohne Ansichten (keine Favoriten, Fehler): alle offenen Tickets des Teams.
                Text("All open tickets · grouped by status · \(presentation.visibleCount) tickets")
                    .lineLimit(1)
            }
            if let problem = load.viewProblem {
                Text(verbatim: "· " + problem)
                    .foregroundStyle(AgentTheme.statusError)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .foregroundStyle(AgentTheme.textSecondary)
    }
}
