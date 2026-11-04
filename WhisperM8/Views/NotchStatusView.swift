import SwiftUI

/// Alles, was die Notch-Ansicht zeichnet, als ein Wert. Dadurch ist die Ansicht
/// rein darstellend (Snapshots, Tests) und das Fenster entscheidet nur, wann
/// ein neuer Wert hineinkommt.
struct NotchDisplay: Equatable {
    enum Style: Equatable {
        /// An der Notch: schwarz, bündig an der Oberkante.
        case notch(width: CGFloat, height: CGFloat)
        /// Ohne Notch: Pille unter der Menüleiste, folgt hell/dunkel.
        case pill
    }

    var style: Style
    var summary: NotchSummary
    var alert: NotchAlert?
    var isExpanded: Bool
    var sections: [NotchSection]

    var isNotch: Bool {
        if case .notch = style { return true }
        return false
    }
}

/// Farben der Anzeige. An der Notch immer dunkel (die Hardware ist schwarz,
/// die Verlängerung muss nahtlos anschließen), als Pille wie der Rest der App.
struct NotchPalette {
    var background: Color
    var border: Color
    var text: Color
    var secondary: Color
    var tertiary: Color
    var working: Color
    var awaiting: Color
    var error: Color
    var idle: Color
    var rowHover: Color
    var attentionTint: Color

    static let notch = NotchPalette(
        background: .black,
        border: .clear,
        text: Color.white.opacity(0.94),
        secondary: Color.white.opacity(0.62),
        tertiary: Color.white.opacity(0.46),
        working: Color(red: 0.298, green: 0.765, blue: 0.541),
        awaiting: Color(red: 0.914, green: 0.725, blue: 0.286),
        error: Color(red: 0.898, green: 0.349, blue: 0.310),
        idle: Color.white.opacity(0.42),
        rowHover: Color.white.opacity(0.08),
        attentionTint: Color(red: 0.914, green: 0.725, blue: 0.286).opacity(0.12))

    static let pill = NotchPalette(
        background: AgentTheme.statusPill,
        border: AgentTheme.borderStrong,
        text: AgentTheme.textPrimary,
        secondary: AgentTheme.textSecondary,
        tertiary: AgentTheme.textTertiary,
        working: AgentTheme.statusWorking,
        awaiting: AgentTheme.statusAwaiting,
        error: AgentTheme.statusError,
        idle: AgentTheme.textTertiary,
        rowHover: AgentTheme.border,
        attentionTint: AgentTheme.statusAwaiting.opacity(0.13))
}

/// Statusanzeige an der Notch: Ruhezustand (Zähler), „braucht dich" (kurz
/// verbreitert) und aufgeklappte Liste. Keine eigene Dauerbewegung: das Fenster
/// wechselt die Größe einmalig, die Inhalte blenden einmal ein.
///
/// An der Notch füllt ein Band genau die Aussparung, der Inhalt hängt darunter
/// (`NotchGeometry.layout`). Die Menüleiste neben der Notch bleibt frei.
struct NotchStatusView: View {
    let display: NotchDisplay
    var onToggle: () -> Void = {}
    var onSelect: (UUID) -> Void = { _ in }
    /// Mauszeiger über der Anzeige (für das Aufklappen beim Darüberfahren).
    var onHover: (Bool) -> Void = { _ in }

    private var palette: NotchPalette { display.isNotch ? .notch : .pill }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onToggle) {
                header
                    .contentShape(shape)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(headerAccessibilityLabel)
            .accessibilityHint(display.isExpanded ? Text("Closes the chat list") : Text("Opens the chat list"))

            if display.isExpanded {
                NotchChatList(sections: display.sections, palette: palette, onSelect: onSelect)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(shape.fill(palette.background))
        // Mittig gezogen und danach beschnitten: sichtbar bleibt 1 pt innen.
        .overlay(shape.stroke(palette.border, lineWidth: display.isNotch ? 0 : 2))
        .clipShape(shape)
        .contentShape(shape)
        .ignoresSafeArea()
        .onHover(perform: onHover)
        .animation(.easeOut(duration: 0.22), value: display)
    }

    private var shape: AnyShape {
        if case .notch(let notchWidth, let notchHeight) = display.style {
            return AnyShape(NotchHangingShape(
                bandWidth: notchWidth, bandHeight: notchHeight,
                bottomRadius: display.isExpanded ? 18 : 11))
        }
        let radius: CGFloat = display.isExpanded ? 16 : NotchGeometry.pillHeight / 2
        return AnyShape(UnevenRoundedRectangle(
            topLeadingRadius: radius, bottomLeadingRadius: radius,
            bottomTrailingRadius: radius, topTrailingRadius: radius))
    }

    // MARK: Kopfzeile

    @ViewBuilder
    private var header: some View {
        switch display.style {
        case .notch(_, let notchHeight):
            VStack(spacing: 0) {
                // Die Aussparung selbst: schwarz, ohne Inhalt.
                Color.clear.frame(height: notchHeight)
                headerRow
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity)
                    .frame(height: NotchGeometry.chinHeight)
            }
        case .pill:
            headerRow
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity)
                .frame(height: NotchGeometry.pillHeight)
        }
    }

    /// Zähler, im Alarm der Chat-Name mit den arbeitenden Chats davor.
    @ViewBuilder
    private var headerRow: some View {
        HStack(spacing: 12) {
            if let alert = display.alert, !display.isExpanded {
                if display.summary.working > 0 { chip(.working, display.summary.working) }
                NotchAlertLabel(alert: alert, palette: palette)
            } else {
                chips
            }
        }
    }

    @ViewBuilder
    private var chips: some View {
        if display.summary.working > 0 { chip(.working, display.summary.working) }
        if display.summary.waiting > 0 { chip(.waiting, display.summary.waiting) }
        if display.summary.errored > 0 { chip(.errored, display.summary.errored) }
        if display.summary.freshDone > 0 { chip(.done, display.summary.freshDone) }
        if !display.summary.hasActivity {
            Text("No active chats")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.secondary)
        }
    }

    private func chip(_ kind: NotchChip.Kind, _ count: Int) -> some View {
        NotchChip(kind: kind, count: count, palette: palette)
    }

    private var headerAccessibilityLabel: Text {
        var parts: [String] = []
        let summary = display.summary
        if summary.working > 0 { parts.append(String(localized: "\(summary.working) working")) }
        if summary.waiting > 0 { parts.append(String(localized: "\(summary.waiting) waiting for you")) }
        if summary.errored > 0 { parts.append(String(localized: "\(summary.errored) with an error")) }
        if summary.freshDone > 0 { parts.append(String(localized: "\(summary.freshDone) just finished")) }
        if let alert = display.alert, !display.isExpanded {
            parts.insert("\(alert.title), \(NotchAlertLabel.word(for: alert.kind))", at: 0)
        }
        if parts.isEmpty { return Text("No active chats") }
        return Text(parts.joined(separator: ", "))
    }
}

// MARK: - Bausteine

/// Umriss an der Notch: oben ein Band in Breite der Aussparung, darunter der
/// Körper. Ist der Körper breiter, gehen Band und Körper mit kleinen
/// Hohlkehlen ineinander über (wie die Menüleiste an der Notch).
struct NotchHangingShape: Shape {
    var bandWidth: CGFloat
    var bandHeight: CGFloat
    var bottomRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let width = rect.width
        let bandW = min(bandWidth, width)
        let bandH = min(bandHeight, rect.height)
        let bodyH = rect.height - bandH
        let side = (width - bandW) / 2
        let bottom = max(0, min(bottomRadius, bodyH / 2, width / 2))

        let minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        let bandMinX = minX + side, bandMaxX = bandMinX + bandW
        let bodyTop = minY + bandH
        var path = Path()

        guard side >= 0.5 else {
            // Körper so breit wie die Notch: Rechteck mit runden unteren Ecken.
            path.move(to: CGPoint(x: minX, y: minY))
            path.addLine(to: CGPoint(x: maxX, y: minY))
            corner(&path, CGPoint(x: maxX, y: maxY), CGPoint(x: minX, y: maxY), bottom)
            corner(&path, CGPoint(x: minX, y: maxY), CGPoint(x: minX, y: minY), bottom)
            path.closeSubpath()
            return path
        }

        let fillet = max(0, min(6, side / 2, bandH))
        let top = max(0, min(8, side - fillet, bodyH - bottom))
        path.move(to: CGPoint(x: bandMinX, y: minY))
        path.addLine(to: CGPoint(x: bandMaxX, y: minY))
        corner(&path, CGPoint(x: bandMaxX, y: bodyTop), CGPoint(x: maxX, y: bodyTop), fillet)
        corner(&path, CGPoint(x: maxX, y: bodyTop), CGPoint(x: maxX, y: maxY), top)
        corner(&path, CGPoint(x: maxX, y: maxY), CGPoint(x: minX, y: maxY), bottom)
        corner(&path, CGPoint(x: minX, y: maxY), CGPoint(x: minX, y: bodyTop), bottom)
        corner(&path, CGPoint(x: minX, y: bodyTop), CGPoint(x: bandMinX, y: bodyTop), top)
        corner(&path, CGPoint(x: bandMinX, y: bodyTop), CGPoint(x: bandMinX, y: minY), fillet)
        path.closeSubpath()
        return path
    }

    /// Ecke bei `point`, gerundet in Richtung `next`; Radius 0 ergibt eine Spitze.
    private func corner(_ path: inout Path, _ point: CGPoint, _ next: CGPoint, _ radius: CGFloat) {
        if radius < 0.5 {
            path.addLine(to: point)
        } else {
            path.addArc(tangent1End: point, tangent2End: next, radius: radius)
        }
    }
}

/// Statuspunkt in den Formen von `AgentStatusAccessibility` (Scheibe, Raute,
/// Ring), aber mit der Palette der Anzeige statt der Theme-Farben.
struct NotchStatusDot: View {
    let status: AgentSessionRuntimeStatus?
    let palette: NotchPalette
    var size: CGFloat = 8

    var body: some View {
        Group {
            switch AgentStatusAccessibility.shape(for: status) {
            case .disc:
                Circle().fill(palette.working)
            case .diamond:
                RoundedRectangle(cornerRadius: size * 0.12)
                    .fill(palette.awaiting)
                    .frame(width: size * 0.8, height: size * 0.8)
                    .rotationEffect(.degrees(45))
            case .hollowRing:
                Circle().strokeBorder(palette.error, lineWidth: 1.5)
            case .idleDisc:
                Circle().fill(palette.idle)
            case .none:
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct NotchChip: View {
    enum Kind { case working, waiting, errored, done }

    let kind: Kind
    let count: Int
    let palette: NotchPalette

    var body: some View {
        HStack(spacing: 6) {
            symbol
            Text("\(count)")
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(color)
        }
    }

    private var color: Color {
        switch kind {
        case .working: return palette.working
        case .waiting: return palette.awaiting
        case .errored: return palette.error
        case .done: return palette.secondary
        }
    }

    @ViewBuilder
    private var symbol: some View {
        switch kind {
        case .working: NotchStatusDot(status: .working, palette: palette)
        case .waiting: NotchStatusDot(status: .awaitingInput, palette: palette)
        case .errored: NotchStatusDot(status: .errored, palette: palette)
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 8, height: 8)
        }
    }
}

/// „braucht dich": Punkt, Chat-Name, kurzes Wort (wartet, Fehler, fertig).
struct NotchAlertLabel: View {
    let alert: NotchAlert
    let palette: NotchPalette

    var body: some View {
        HStack(spacing: 8) {
            NotchStatusDot(status: status, palette: palette)
            Text(alert.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.text)
                .lineLimit(1)
                .truncationMode(.tail)
            word
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .fixedSize()
            if alert.extraCount > 0 {
                Text("+\(alert.extraCount)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.secondary)
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var status: AgentSessionRuntimeStatus {
        switch alert.kind {
        case .awaitingInput: return .awaitingInput
        case .errored: return .errored
        case .finished: return .idle
        }
    }

    private var tint: Color {
        switch alert.kind {
        case .awaitingInput: return palette.awaiting
        case .errored: return palette.error
        case .finished: return palette.secondary
        }
    }

    private var word: Text { Text(Self.word(for: alert.kind)) }

    static func word(for kind: NotchAlertKind) -> String {
        switch kind {
        case .awaitingInput: return String(localized: "waiting")
        case .errored: return String(localized: "failed")
        case .finished: return String(localized: "done")
        }
    }
}

// MARK: - Liste

struct NotchChatList: View {
    let sections: [NotchSection]
    let palette: NotchPalette
    var onSelect: (UUID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(sections) { section in
                        sectionTitle(section.kind)
                        ForEach(section.rows) { row in
                            NotchRowButton(row: row, palette: palette) { onSelect(row.id) }
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.hidden)

            HStack {
                Text("Click a row to open the chat")
                Spacer()
                Text("Esc closes")
            }
            .font(.system(size: 11))
            .foregroundStyle(palette.tertiary)
            .padding(.horizontal, 16)
            .frame(height: NotchGeometry.footerHeight)
        }
        .padding(.bottom, 4)
    }

    private func sectionTitle(_ kind: NotchSectionKind) -> some View {
        Group {
            switch kind {
            case .needsYou: Text("Needs you")
            case .freshDone: Text("Just finished")
            case .working: Text("Working")
            case .ready: Text("Ready")
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .textCase(.uppercase)
        .tracking(0.6)
        .foregroundStyle(palette.tertiary)
        .padding(.horizontal, 8)
        .frame(height: NotchGeometry.sectionHeaderHeight, alignment: .bottom)
        .padding(.bottom, 2)
        .accessibilityAddTraits(.isHeader)
    }
}

struct NotchRowButton: View {
    let row: NotchRow
    let palette: NotchPalette
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                NotchStatusDot(status: row.status, palette: palette)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                    Text(row.activityLine ?? row.project ?? "")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(row.headline)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.tertiary)
                        .lineLimit(1)
                    if row.activityLine != nil, let project = row.project {
                        Text(project)
                            .font(.system(size: 11))
                            .foregroundStyle(palette.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(height: NotchGeometry.rowHeight, alignment: .top)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(background))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(AgentRowAccessibility.summary(title: row.title, status: row.status, project: row.project))
    }

    /// Wartende Zeilen leicht amber, Fehler leicht rot, sonst nur beim Darüberfahren.
    private var background: Color {
        guard row.category == .needsYou else { return isHovering ? palette.rowHover : .clear }
        return row.status == .errored ? palette.error.opacity(0.14) : palette.attentionTint
    }
}
