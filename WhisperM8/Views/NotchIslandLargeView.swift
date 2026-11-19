import SwiftUI

/// Die große Form in der Anzeige: Maße der offenen Form und der Umriss, der
/// gerade gezeichnet wird. Das Fenster stellt erst die Kapsel dar, aus der
/// die Form wächst (`isOpen == false`), im nächsten Bild die offene Form;
/// die Ansicht gleitet dazwischen. Beim Schließen umgekehrt.
struct NotchIslandLargeDisplay: Equatable {
    var form: NotchIslandLargeForm
    var outline: NotchIslandLargeOutline
    var isOpen: Bool

    static func open(_ form: NotchIslandLargeForm) -> NotchIslandLargeDisplay {
        NotchIslandLargeDisplay(form: form, outline: NotchIslandLargeGeometry.openOutline(form), isOpen: true)
    }

    static func closed(_ form: NotchIslandLargeForm, outline: NotchIslandLargeOutline) -> NotchIslandLargeDisplay {
        NotchIslandLargeDisplay(form: form, outline: outline, isOpen: false)
    }
}

/// Bewegung der großen Form: EINE Federbewegung für den Umriss (Breite, Höhe,
/// Lage, Ecken zusammen), der Inhalt blendet danach ein und vor dem Schließen
/// aus. Einmalig je Wechsel, keine Dauerbewegung. Mit „Bewegung reduzieren“
/// steht die Form sofort, nur der Inhalt blendet.
enum NotchIslandLargeMotion {
    static let shape = Animation.spring(response: 0.4, dampingFraction: 0.82)
    static let contentIn = Animation.easeOut(duration: 0.18).delay(0.2)
    static let contentOut = Animation.easeOut(duration: 0.1)
    /// Danach steht die offene Form; das Fenster darf auf sie schrumpfen.
    static let settleDelay: Duration = .milliseconds(560)
    /// Danach ist die Form zu; das Fenster wird wieder die Kapsel.
    static let closeDelay: Duration = .milliseconds(420)

    static func shapeAnimation(reduceMotion: Bool) -> Animation? { reduceMotion ? nil : shape }

    /// Einblenden des Inhalts: Mit „Bewegung reduzieren“ steht die Form
    /// sofort, der Inhalt wartet dann nicht auf sie.
    static func contentInAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.15) : contentIn
    }
}

/// Umriss der großen Form; gleitet zwischen Kapsel und offener Form. Sein
/// Rahmen ist das Fenster bzw. der Behälter: Die obere Mitte ist die Mitte
/// der Kamera an der Oberkante der Form.
struct NotchIslandLargeShape: Shape {
    var outline: NotchIslandLargeOutline

    var animatableData: AnimatablePair<
        AnimatablePair<CGFloat, CGFloat>, AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat>
    > {
        get {
            AnimatablePair(
                AnimatablePair(outline.centerOffset, outline.top),
                AnimatablePair(AnimatablePair(outline.width, outline.height), outline.radius))
        }
        set {
            outline.centerOffset = newValue.first.first
            outline.top = newValue.first.second
            outline.width = newValue.second.first.first
            outline.height = newValue.second.first.second
            outline.radius = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let frame = outline.rect(in: rect)
        guard frame.width > 0, frame.height > 0 else { return Path() }
        let limit = min(frame.width, frame.height) / 2
        let radius = max(0, min(outline.radius, limit))
        // Als Kapsel mit Kreisbögen (deckt sich mit der Kapsel in Ruhe),
        // sonst mit den weichen Ecken der offenen Form.
        return Path(roundedRect: frame, cornerRadius: radius, style: radius >= limit - 0.5 ? .circular : .continuous)
    }
}

/// Kopfzeile der großen Form: in der Mitte der Platz von Apples Insel (sie
/// liegt über unserem Fenster), links und rechts davon eigener Inhalt, auf
/// Höhe der Insel.
struct NotchIslandLargeHeader<Leading: View, Trailing: View>: View {
    let form: NotchIslandLargeForm
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        let half = form.size.width / 2
        let padding = NotchIslandLargeGeometry.padding
        // Jede Seite hat ihre feste Breite, auch ohne Inhalt: Ein leerer
        // Inhalt (keine Zähler) nähme sonst keinen Platz ein, und die andere
        // Seite rutschte unter Apples Insel.
        HStack(spacing: 0) {
            Color.clear
                .frame(width: max(0, half - padding - form.slotLeading))
                .overlay(alignment: .leading) { leading }
            Color.clear.frame(width: max(0, min(form.size.width - 2 * padding, form.slotLeading + form.slotTrailing)))
            Color.clear
                .frame(width: max(0, half - padding - form.slotTrailing))
                .overlay(alignment: .trailing) { trailing }
        }
        .lineLimit(1)
        .frame(height: max(0, form.headerHeight - NotchIslandLargeGeometry.headerGap))
        .frame(width: form.size.width, height: form.headerHeight, alignment: .top)
    }
}

/// Hinweis „braucht dich“ und Liste der Chats an der Kamera-Insel als große
/// Form. Rein darstellend: Das Fenster (`NotchStatusController`) entscheidet,
/// wann welcher Umriss gilt.
struct NotchIslandLargeStatusView: View {
    let display: NotchDisplay
    let large: NotchIslandLargeDisplay
    var onToggle: () -> Void = {}
    var onSelect: (UUID) -> Void = { _ in }
    var onTurnOff: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var palette: NotchPalette { .notch }

    var body: some View {
        let shape = NotchIslandLargeShape(outline: large.outline)
        ZStack(alignment: .top) {
            shape.fill(Color.black)
            closedContent
                .opacity(large.isOpen ? 0 : 1)
                .accessibilityHidden(true)
            openContent
                .frame(width: large.form.size.width, height: large.form.size.height, alignment: .top)
                .opacity(large.isOpen ? 1 : 0)
                .allowsHitTesting(large.isOpen)
                .animation(
                    large.isOpen
                        ? NotchIslandLargeMotion.contentInAnimation(reduceMotion: reduceMotion)
                        : NotchIslandLargeMotion.contentOut,
                    value: large.isOpen)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipShape(shape)
        .contentShape(shape)
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .onHover(perform: onHover)
        .animation(NotchIslandLargeMotion.shapeAnimation(reduceMotion: reduceMotion), value: large)
    }

    /// Zeichen und Zahl der Kapsel, aus der die Form wächst bzw. in die sie
    /// zurückgeht: Der Wechsel zwischen Kapsel und Form beginnt und endet
    /// ohne Sprung.
    @ViewBuilder
    private var closedContent: some View {
        if case .island(let band) = display.style {
            let signal = NotchIslandSignal(summary: display.summary)
            if band.detachedFrame != nil {
                NotchIslandBandRow.glyph(signal)
                    .frame(width: large.outline.width, height: large.outline.height)
                    .offset(x: large.outline.centerOffset, y: large.outline.top)
            } else {
                NotchIslandBandRow(band: band, signal: signal)
                    .frame(height: band.capsuleHeight)
                    .offset(x: band.centerOffset, y: band.topGap)
            }
        }
    }

    @ViewBuilder
    private var openContent: some View {
        if display.isExpanded {
            VStack(spacing: 0) {
                Button(action: onToggle) {
                    header.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: display.accessibilitySummary))
                .accessibilityHint(Text("Closes the chat list"))
                if display.sections.isEmpty {
                    Text("No active chats")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(palette.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, NotchIslandLargeGeometry.padding + NotchListMetrics.islandLarge.rowPadding)
                        .frame(height: NotchIslandLargeGeometry.emptyListHeight)
                }
                NotchChatList(
                    sections: display.sections, palette: palette, onSelect: onSelect, onTurnOff: onTurnOff,
                    selectedRowID: display.selectedRowID, metrics: .islandLarge)
            }
            .transition(.opacity)
        } else if let alert = display.alert {
            Button(action: onToggle) {
                VStack(spacing: 0) {
                    header
                    alertBody(alert)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: display.accessibilitySummary))
            .accessibilityHint(Text("Opens the chat list"))
            .transition(.opacity)
        }
    }

    /// Zähler links und rechts von Apples Insel: was Aufmerksamkeit braucht
    /// und was arbeitet links, frisch Fertiges rechts.
    private var header: some View {
        let font = Font.system(size: 14, weight: .semibold)
        return NotchIslandLargeHeader(form: large.form) {
            HStack(spacing: 12) {
                if display.summary.waiting > 0 {
                    NotchChip(kind: .waiting, count: display.summary.waiting, palette: palette, font: font)
                }
                if display.summary.errored > 0 {
                    NotchChip(kind: .errored, count: display.summary.errored, palette: palette, font: font)
                }
                if display.summary.working > 0 {
                    NotchChip(kind: .working, count: display.summary.working, palette: palette, font: font)
                }
            }
        } trailing: {
            if display.summary.freshDone > 0 {
                NotchChip(kind: .done, count: display.summary.freshDone, palette: palette, font: font)
            }
        }
    }

    private func alertBody(_ alert: NotchAlert) -> some View {
        HStack(spacing: 12) {
            NotchStatusDot(status: NotchAlertLabel.status(for: alert.kind), palette: palette, size: 12)
            VStack(alignment: .leading, spacing: 3) {
                Text(alert.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.text)
                if let detail = display.alertDetail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(palette.secondary)
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(NotchAlertLabel.word(for: alert.kind))
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(NotchAlertLabel.tint(for: alert.kind, palette: palette))
                .fixedSize()
            if alert.extraCount > 0 {
                Text("+\(alert.extraCount)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.secondary)
                    .fixedSize()
            }
        }
        .padding(.horizontal, NotchIslandLargeGeometry.padding + 6)
        .padding(.bottom, NotchIslandLargeGeometry.bottomPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Maße einer Chat-Liste: wie bisher an Notch und Pille, oder groß in der
/// aufgeklappten Form an der Kamera-Insel (größere Schrift, höhere Zeilen,
/// rundere Felder).
struct NotchListMetrics {
    var rowHeight: CGFloat
    /// Höhe des Zwischentitels ohne die 2 pt Abstand darunter.
    var sectionTitleHeight: CGFloat
    var footerHeight: CGFloat
    var titleSize: CGFloat
    var detailSize: CGFloat
    var sectionSize: CGFloat
    var footerSize: CGFloat
    var dotSize: CGFloat
    var rowRadius: CGFloat
    /// Abstand zwischen Punkt und Text.
    var rowSpacing: CGFloat
    /// Innenrand einer Zeile, links und rechts.
    var rowPadding: CGFloat
    /// Rand der Liste, links und rechts.
    var listPadding: CGFloat
    var bottomPadding: CGFloat
    /// Punkt und Text stehen mittig in der Zeile (sonst oben).
    var centersRow: Bool
    /// Die mit der Tastatur markierte Zeile ist zusätzlich umrandet.
    var outlinesSelection: Bool

    static let standard = NotchListMetrics(
        rowHeight: NotchGeometry.rowHeight, sectionTitleHeight: NotchGeometry.sectionHeaderHeight,
        footerHeight: NotchGeometry.footerHeight, titleSize: 12.5, detailSize: 11, sectionSize: 11, footerSize: 11,
        dotSize: 8, rowRadius: 8, rowSpacing: 10, rowPadding: 8, listPadding: 8, bottomPadding: 4,
        centersRow: false, outlinesSelection: false)

    static let islandLarge = NotchListMetrics(
        rowHeight: NotchIslandLargeGeometry.rowHeight,
        sectionTitleHeight: NotchIslandLargeGeometry.sectionHeaderHeight - 2,
        footerHeight: NotchIslandLargeGeometry.footerHeight, titleSize: 15, detailSize: 12.5, sectionSize: 11.5,
        footerSize: 12, dotSize: 10, rowRadius: 16, rowSpacing: 12, rowPadding: 14,
        listPadding: NotchIslandLargeGeometry.padding, bottomPadding: NotchIslandLargeGeometry.bottomPadding,
        centersRow: true, outlinesSelection: true)
}
