import SwiftUI

// Options-Menü des Controllers als Karte am Chat (Runde 5, freigegeben
// 12.11.2026): in der Einzelansicht rechts unter dem Chat-Kopf, im Raster am
// Kopf der Kachel, in der Liste neben der markierten Zeile. Dunkel wie die
// Insel und die Diktat-Pille, Gruppen mit Überschrift.
//
// Leistung: Die Anker sind kleine eigene Ansichten, die nur bei offenem Menü
// einen Rahmen melden. Ist das Menü zu, gibt es keine Präferenz, und die
// Karte wird nicht gebaut; die großen Bodies lesen das `ControllerUIModel` nicht.

/// Rahmen der möglichen Anker, gesammelt im Fenster.
struct ControllerMenuAnchorKey: PreferenceKey {
    static let defaultValue: [ControllerMenuPlacement.Anchor: Anchor<CGRect>] = [:]

    static func reduce(
        value: inout [ControllerMenuPlacement.Anchor: Anchor<CGRect>],
        nextValue: () -> [ControllerMenuPlacement.Anchor: Anchor<CGRect>]
    ) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Meldet den Rahmen von Chat-Kopf oder Kachelkopf, solange das Menü für
/// diesen Chat im Inhalt offen ist. Als `.background` an den Kopf hängen.
struct ControllerMenuAnchorMark: View {
    let kind: ControllerMenuPlacement.Anchor
    let sessionID: UUID?
    @State private var model = ControllerUIModel.shared

    var body: some View {
        if let sessionID, model.area == .content, model.menu?.setup.sessionID == sessionID {
            Color.clear
                .anchorPreference(key: ControllerMenuAnchorKey.self, value: .bounds) { [kind: $0] }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

extension View {
    /// Hängt das Options-Menü an diese Fläche (Chat-Kopf, Kachelkopf).
    func controllerMenuAnchor(_ kind: ControllerMenuPlacement.Anchor, sessionID: UUID?) -> some View {
        background(ControllerMenuAnchorMark(kind: kind, sessionID: sessionID))
    }

    /// Options-Menü des Controllers als Karte am Chat (Kopf, Kachel oder
    /// Zeile der Liste) über dem ganzen Fenster. Ohne offenes Menü melden die
    /// Anker nichts, und es wird nichts gebaut.
    func controllerMenuCardOverlay(windowID: UUID) -> some View {
        overlayPreferenceValue(ControllerMenuAnchorKey.self) { anchors in
            ControllerMenuCardHost(windowID: windowID, anchors: anchors)
        }
    }
}

/// Feste Maße der Karte. Die Zeilen haben feste Höhen, damit sich die volle
/// Höhe ohne Messen (und ohne zweiten Layout-Durchlauf) ergibt.
enum ControllerMenuCardMetrics {
    static let width: CGFloat = 300
    static let padding: CGFloat = 6
    static let titleHeight: CGFloat = 32
    static let footerHeight: CGFloat = 26
    static let rowHeight: CGFloat = 28
    static let headingHeight: CGFloat = 22
    static let separatorHeight: CGFloat = 9
    static let listPadding: CGFloat = 4

    static func listHeight(_ rows: [ControllerMenuRow]) -> CGFloat {
        rows.reduce(2 * listPadding) { total, row in
            total + rowHeight + (row.groupHeading != nil ? headingHeight : 0)
                + (row.groupHeading == nil && row.startsGroup ? separatorHeight : 0)
        }
    }

    /// Volle Höhe: Titel, Trennlinie, Liste, Trennlinie, Fußzeile.
    static func contentHeight(_ rows: [ControllerMenuRow]) -> CGFloat {
        2 * padding + titleHeight + 1 + listHeight(rows) + 1 + footerHeight
    }
}

/// Die Karte selbst. Reine Darstellung.
struct ControllerMenuCard: View {
    let title: String
    let isSubmenu: Bool
    let rows: [ControllerMenuRow]
    let selectedID: String?
    /// Die Liste ist höher als der Platz: Sie scrollt in der Karte und hält
    /// die Markierung sichtbar.
    var scrolls = false

    private var palette: IslandPalette { .notch }
    private typealias Metrics = ControllerMenuCardMetrics

    init(title: String, isSubmenu: Bool, rows: [ControllerMenuRow], selectedID: String?, scrolls: Bool = false) {
        self.title = title
        self.isSubmenu = isSubmenu
        self.rows = rows
        self.selectedID = selectedID
        self.scrolls = scrolls
    }

    init(menu: ControllerMenuModel, fallbackTitle: String?, scrolls: Bool = false) {
        self.init(
            title: ControllerMenuRow.heading(of: menu, fallback: fallbackTitle),
            isSubmenu: menu.submenu != nil,
            rows: ControllerMenuRow.rows(of: menu),
            selectedID: ControllerMenuRow.selectedID(of: menu),
            scrolls: scrolls)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleBar
            divider
            if scrolls {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) { list }
                        .onAppear { scrollToSelection(proxy, animated: false) }
                        .onChange(of: selectedID) { _, _ in scrollToSelection(proxy, animated: true) }
                }
            } else {
                list
            }
            divider
            footer
        }
        .padding(Metrics.padding)
        // Die Breite gibt der Platz vor (höchstens `Metrics.width`), in sehr
        // kleinen Fenstern auch weniger.
        .frame(maxWidth: Metrics.width, alignment: .top)
        .background {
            PillGlassBackground(shape: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .pillGlassShadow()
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
    }

    private func scrollToSelection(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let selectedID else { return }
        if animated {
            // Beim Weitergehen nur so weit, bis die Zeile zu sehen ist.
            withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(selectedID) }
        } else {
            // Beim Öffnen die Markierung in die Mitte, mit Nachbarn darüber und darunter.
            proxy.scrollTo(selectedID, anchor: .center)
        }
    }

    private var divider: some View {
        Rectangle().fill(palette.line).frame(height: 1)
    }

    private var titleBar: some View {
        HStack(spacing: 6) {
            if isSubmenu {
                Text(verbatim: "‹")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.secondary)
            }
            Text(verbatim: title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.text)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text(verbatim: "Options")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.hint)
                .padding(.horizontal, 6)
                .frame(height: 18)
                .background(palette.key, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(palette.keyBorder, lineWidth: 1))
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .frame(height: Metrics.titleHeight)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                if let heading = row.groupHeading {
                    Text(verbatim: heading)
                        .font(.system(size: 11, weight: .semibold))
                        .textCase(.uppercase)
                        .tracking(0.6)
                        .foregroundStyle(palette.tertiary)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.top, 6)
                        .frame(height: Metrics.headingHeight, alignment: .bottomLeading)
                } else if row.startsGroup {
                    divider.padding(.horizontal, 8).frame(height: Metrics.separatorHeight)
                }
                self.row(row, marked: row.id == selectedID)
                    .id(row.id)
            }
        }
        .padding(.vertical, Metrics.listPadding)
    }

    private func row(_ row: ControllerMenuRow, marked: Bool) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: row.title)
                .font(.system(size: 13, weight: marked ? .medium : .regular))
                .foregroundStyle(row.enabled ? palette.text : palette.tertiary.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.tail)
            if let badge = row.badge {
                Text(verbatim: badge)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.working)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(palette.working.opacity(0.16), in: RoundedRectangle(cornerRadius: 5))
                    .fixedSize()
            }
            Spacer(minLength: 0)
            if let usage = row.usage {
                Text(verbatim: usage)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(usageColor(row.usageLevel))
                    .fixedSize()
            }
            if let hint = row.hint {
                Text(verbatim: hint)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Metrics.rowHeight)
        .background {
            if marked {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(palette.mark)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(palette.markBorder, lineWidth: 1.5))
            }
        }
    }

    private func usageColor(_ level: ControllerMenuRow.UsageLevel?) -> Color {
        switch level {
        case .low: return palette.working
        case .medium: return palette.awaiting
        case .high: return AppTheme.statusError
        case nil: return palette.tertiary
        }
    }

    private var footer: some View {
        Text(verbatim: isSubmenu
            ? String(localized: "✕ select · ○ back · Options closes")
            : String(localized: "✕ select · ○ or Options closes"))
            .font(.system(size: 11))
            .foregroundStyle(palette.secondary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: Metrics.footerHeight, maxHeight: Metrics.footerHeight, alignment: .leading)
    }
}

/// Legt die Karte in das Fenster: am gemeldeten Anker, sonst unten mittig.
/// `anchors` kommen aus `overlayPreferenceValue`; ohne offenes Menü (oder
/// in einem Fenster, das nicht vorne ist) zeichnet sie nichts.
struct ControllerMenuCardHost: View {
    let windowID: UUID
    let anchors: [ControllerMenuPlacement.Anchor: Anchor<CGRect>]
    @State private var model = ControllerUIModel.shared
    @State private var windows = AgentWindowStore.shared
    @AppStorage(PreferenceKeys.controllerLegendEnabled) private var legendEnabled = true

    var body: some View {
        if windows.keyAgentChatWindowID == windowID, let menu = model.menu {
            ControllerMenuCardResolver(
                menu: menu, fallbackTitle: model.targetTitle, anchors: anchors,
                bottomInset: legendEnabled ? ControllerLegendBar.height : 0)
                .transition(.opacity)
        }
    }
}

/// Löst die Anker im Fenster auf und legt die Karte an ihren Platz. Ohne
/// Beobachtung, damit Snapshots dieselbe Platzierung zeigen.
struct ControllerMenuCardResolver: View {
    let menu: ControllerMenuModel
    let fallbackTitle: String?
    let anchors: [ControllerMenuPlacement.Anchor: Anchor<CGRect>]
    let bottomInset: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let kind = ControllerMenuPlacement.Anchor.preferred(Set(anchors.keys))
            let resolved = kind.flatMap { kind in anchors[kind].map { (kind: kind, rect: proxy[$0]) } }
            ControllerMenuCardLayer(
                menu: menu, fallbackTitle: fallbackTitle, anchor: resolved,
                container: CGRect(origin: .zero, size: proxy.size), bottomInset: bottomInset)
        }
    }
}

/// Karte an ihrem Platz.
struct ControllerMenuCardLayer: View {
    let menu: ControllerMenuModel
    let fallbackTitle: String?
    let anchor: (kind: ControllerMenuPlacement.Anchor, rect: CGRect)?
    let container: CGRect
    let bottomInset: CGFloat

    var body: some View {
        let rows = ControllerMenuRow.rows(of: menu)
        let placement = ControllerMenuPlacement.place(
            anchor: anchor, contentHeight: ControllerMenuCardMetrics.contentHeight(rows),
            width: ControllerMenuCardMetrics.width, container: container, bottomInset: bottomInset)
        ControllerMenuCard(
            title: ControllerMenuRow.heading(of: menu, fallback: fallbackTitle),
            isSubmenu: menu.submenu != nil, rows: rows,
            selectedID: ControllerMenuRow.selectedID(of: menu), scrolls: placement.scrolls)
            .frame(width: placement.frame.width, height: placement.frame.height, alignment: .top)
            .position(x: placement.frame.midX, y: placement.frame.midY)
    }
}
