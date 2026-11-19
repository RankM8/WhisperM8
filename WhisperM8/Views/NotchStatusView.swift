import SwiftUI

/// Alles, was die Notch-Ansicht zeichnet, als ein Wert. Dadurch ist die Ansicht
/// rein darstellend (Snapshots, Tests) und das Fenster entscheidet nur, wann
/// ein neuer Wert hineinkommt.
struct NotchDisplay: Equatable {
    enum Style: Equatable {
        /// An der Notch: schwarz, bündig an der Oberkante.
        case notch(width: CGFloat, height: CGFloat)
        /// An einer Kamera-Insel (Dynamic Island): schwarz. In Ruhe nur die
        /// Kapsel um die Kamera, seitlich um Zeichen und Zahl verbreitert
        /// (`NotchIslandGeometry`); Hinweis und Liste sind die große Form
        /// (`islandLarge`).
        case island(NotchIslandBand)
        /// Ohne Notch: Pille im dunklen Glas der Diktat-Pille, immer dunkel,
        /// verschiebbar.
        case pill
    }

    var style: Style
    var summary: NotchSummary
    var alert: NotchAlert?
    var isExpanded: Bool
    var sections: [NotchSection]
    /// Nur Pille: Sie sitzt in der unteren Bildschirmhälfte, die Liste wächst
    /// nach oben und der Kopf bleibt unten, wo die Pille war.
    var opensUpward = false
    /// Mit der Tastatur markierte Zeile (Hotkey „Statusliste öffnen“).
    var selectedRowID: UUID?
    /// Nur Kamera-Insel: Mitte der Kamera gegenüber der Mitte des Fensters.
    /// Ungleich 0, wenn das Band nur auf einer Seite einen Flügel hat und
    /// das Fenster genau so breit ist wie das Band.
    var cameraOffset: CGFloat = 0
    /// Nur Kamera-Insel: Hinweis oder Liste als große Form
    /// (`NotchIslandLargeStatusView`); `nil` in Ruhe.
    var islandLarge: NotchIslandLargeDisplay?
    /// Zweite Zeile des Hinweises in der großen Form (woran der Chat hängt
    /// bzw. sein Projekt).
    var alertDetail: String?

    /// An der Hardware (Notch oder Kamera-Insel): schwarz, nicht verschiebbar.
    var isNotch: Bool {
        if case .pill = style { return false }
        return true
    }

    /// Was die Anzeige gerade sagt, für VoiceOver (Kopfzeile und Fenster):
    /// der Hinweis, dann die Zähler.
    var accessibilitySummary: String {
        var parts: [String] = []
        if summary.working > 0 { parts.append(String(localized: "\(summary.working) working")) }
        if summary.waiting > 0 { parts.append(String(localized: "\(summary.waiting) waiting for you")) }
        if summary.errored > 0 { parts.append(String(localized: "\(summary.errored) with an error")) }
        if summary.freshDone > 0 { parts.append(String(localized: "\(summary.freshDone) just finished")) }
        if let alert, !isExpanded {
            parts.insert("\(alert.title), \(NotchAlertLabel.word(for: alert.kind))", at: 0)
        }
        return parts.isEmpty ? String(localized: "No active chats") : parts.joined(separator: ", ")
    }

    /// Höhe des Bands über der Zeile mit den Zählern (0 ohne Notch). An der
    /// Insel die Kapsel in der Menüleiste.
    var bandHeight: CGFloat {
        switch style {
        case .notch(_, let height): return height
        case .island(let band): return band.capsuleHeight
        case .pill: return 0
        }
    }
}

/// Farben der Anzeige. Immer dunkel: An der Notch ist die Hardware schwarz
/// (die Verlängerung muss nahtlos anschließen), ohne Notch sitzt die Anzeige
/// im dunklen Glas der Diktat-Pille.
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

    /// Pille ohne Notch: dieselben hellen Farben auf dunklem Glas; den
    /// Hintergrund zeichnet `PillGlassBackground`.
    static let pill: NotchPalette = {
        var palette = NotchPalette.notch
        palette.background = .clear
        return palette
    }()
}

/// Statusanzeige an der Notch: Ruhezustand (Zähler), „braucht dich" (kurz
/// verbreitert) und aufgeklappte Liste. Keine eigene Dauerbewegung: das Fenster
/// wechselt die Größe einmalig, die Inhalte blenden einmal ein.
///
/// An der Notch füllt ein Band genau die Aussparung, der Inhalt hängt darunter
/// (`NotchGeometry.layout`). Die Menüleiste neben der Notch bleibt frei. An
/// einer Kamera-Insel steht in Ruhe nur die Kapsel in der Menüleiste; Hinweis
/// und Liste zeichnet `NotchIslandLargeStatusView` als eine große Form.
struct NotchStatusView: View {
    let display: NotchDisplay
    var onToggle: () -> Void = {}
    var onSelect: (UUID) -> Void = { _ in }
    /// Knopf unten links in der Liste: Anzeige ganz ausschalten.
    var onTurnOff: () -> Void = {}
    /// Mauszeiger über der Anzeige (für das Aufklappen beim Darüberfahren).
    var onHover: (Bool) -> Void = { _ in }

    private var palette: NotchPalette { display.isNotch ? .notch : .pill }

    var body: some View {
        if let large = display.islandLarge {
            NotchIslandLargeStatusView(
                display: display, large: large, onToggle: onToggle, onSelect: onSelect,
                onTurnOff: onTurnOff, onHover: onHover)
        } else {
            standard
        }
    }

    private var standard: some View {
        VStack(spacing: 0) {
            if display.isExpanded, display.opensUpward { list }
            Button(action: onToggle) {
                header
                    .contentShape(shape)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(headerAccessibilityLabel)
            .accessibilityHint(display.isExpanded ? Text("Closes the chat list") : Text("Opens the chat list"))
            if display.isExpanded, !display.opensUpward { list }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: display.opensUpward ? .bottom : .top)
        .background { background }
        .clipShape(shape)
        .contentShape(shape)
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .onHover(perform: onHover)
        .animation(.easeOut(duration: 0.22), value: display)
    }

    private var list: some View {
        NotchChatList(sections: display.sections, palette: palette, onSelect: onSelect, onTurnOff: onTurnOff)
            .transition(.opacity)
    }

    /// An der Notch schwarz, ohne Notch das Glas der Diktat-Pille.
    @ViewBuilder
    private var background: some View {
        if display.isNotch {
            shape.fill(palette.background)
        } else if display.isExpanded {
            PillGlassBackground(shape: RoundedRectangle(cornerRadius: PillGlass.cornerRadius, style: .continuous))
        } else {
            PillGlassBackground(shape: Capsule())
        }
    }

    private var shape: AnyShape {
        if case .notch(let notchWidth, let notchHeight) = display.style {
            return AnyShape(NotchHangingShape(
                bandWidth: notchWidth, bandHeight: notchHeight,
                bottomRadius: display.isExpanded ? 18 : 11))
        }
        if case .island(let band) = display.style {
            // Neben Apples aktiver Insel: ein eigener kleiner Kreis.
            if band.detachedFrame != nil { return AnyShape(Capsule()) }
            return AnyShape(NotchHangingShape(
                bandWidth: band.width, bandHeight: display.bandHeight,
                bottomRadius: 11, topRadius: band.topRadius,
                bandOffset: display.cameraOffset + band.centerOffset))
        }
        if display.isExpanded {
            return AnyShape(RoundedRectangle(cornerRadius: PillGlass.cornerRadius, style: .continuous))
        }
        return AnyShape(Capsule())
    }

    // MARK: Kopfzeile

    @ViewBuilder
    private var header: some View {
        switch display.style {
        case .island(let band):
            if band.detachedFrame != nil {
                NotchIslandBandRow.glyph(NotchIslandSignal(summary: display.summary))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Die Kapsel um die Kamera mit Zeichen und Zahl daneben.
                NotchIslandBandRow(band: band, signal: NotchIslandSignal(summary: display.summary))
                    .frame(height: band.capsuleHeight)
                    .offset(x: display.cameraOffset + band.centerOffset)
            }
        case .notch:
            VStack(spacing: 0) {
                // Die Aussparung selbst: schwarz, ohne Inhalt.
                Color.clear.frame(height: display.bandHeight)
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

    private var headerRow: some View {
        NotchHeaderRow(display: display)
    }

    private var headerAccessibilityLabel: Text { Text(verbatim: display.accessibilitySummary) }
}

/// Zähler, im Alarm der Chat-Name mit den arbeitenden Chats davor: Kopfzeile
/// der Anzeige. Geteilt mit dem Ruhebild der Diktat-Zeile an der Notch
/// (`UnifiedPillRestLookView`), damit der Übergang ins Diktat ohne Sprung
/// beginnt.
struct NotchHeaderRow: View {
    let display: NotchDisplay

    private var palette: NotchPalette { display.isNotch ? .notch : .pill }

    /// Schrift wie in der Diktat-Pille (12,5 pt, mittel); an der Notch wie bisher.
    private var chipFont: Font {
        display.isNotch
            ? .system(size: 12, weight: .semibold)
            : .system(size: 12.5, weight: .medium)
    }

    var body: some View {
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
            if display.isExpanded || display.isNotch {
                Text("No active chats")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.secondary)
            } else {
                // Dauerhafte Pille ohne Aktivität: nur ein ruhiger Punkt, wie
                // eine Notch, an der nichts los ist. Klick öffnet die Liste.
                NotchStatusDot(status: .idle, palette: palette)
            }
        }
    }

    private func chip(_ kind: NotchChip.Kind, _ count: Int) -> some View {
        NotchChip(kind: kind, count: count, palette: palette, font: chipFont)
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
    /// Kamera-Insel: Das Band schwebt unter der Oberkante, seine oberen Ecken
    /// sind rund; ohne Körper ist es eine Kapsel. 0 an der Notch.
    var topRadius: CGFloat = 0
    /// Kamera-Insel: Mitte des Bands gegenüber der Mitte des Rahmens (ein
    /// einzelner Flügel, oder das Fenster ist nur so breit wie das Band).
    var bandOffset: CGFloat = 0

    /// Der untere Radius gleitet mit (Notch-Anzeige auf und zu, Diktat-Zeile
    /// aus dem Ruhebild und zurück), statt am Anfang zu springen. An der
    /// Insel gleiten auch Höhe, Breite und Lage des Bands (Kapsel wird
    /// seitlich breiter bzw. zum Hals bis unter die Menüleiste); an der
    /// Notch ändern sie sich nie.
    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(bottomRadius, bandHeight), AnimatablePair(bandWidth, bandOffset)) }
        set {
            bottomRadius = newValue.first.first
            bandHeight = newValue.first.second
            bandWidth = newValue.second.first
            bandOffset = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        if topRadius > 0 { return islandPath(in: rect) }
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

    /// Kamera-Insel: Das Band beginnt mit runden Ecken (obere Hälfte der
    /// Kapsel). Ohne Körper schließt es unten genauso rund, mit Körper läuft
    /// es gerade hinunter und geht mit Hohlkehlen in ihn über.
    private func islandPath(in rect: CGRect) -> Path {
        let bandW = min(bandWidth, rect.width)
        let bandH = min(bandHeight, rect.height)
        let bodyH = rect.height - bandH
        let minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        let slack = (rect.width - bandW) / 2
        // Das Band bleibt im Rahmen, auch mitten in einer Animation.
        let bandMinX = minX + min(max(0, slack + bandOffset), rect.width - bandW)
        let bandMaxX = bandMinX + bandW
        let left = bandMinX - minX, right = maxX - bandMaxX
        let bodyTop = minY + bandH

        guard bodyH >= 0.5 else {
            let band = CGRect(x: bandMinX, y: minY, width: bandW, height: bandH)
            return Path(roundedRect: band, cornerRadius: min(topRadius, bandH / 2, bandW / 2))
        }

        let crown = max(0, min(topRadius, bandH, bandW / 2))
        let bottom = max(0, min(bottomRadius, bodyH / 2, rect.width / 2))
        func fillet(_ side: CGFloat) -> CGFloat { max(0, min(6, side / 2, bandH - crown)) }
        func top(_ side: CGFloat) -> CGFloat { max(0, min(8, side - fillet(side), bodyH - bottom)) }

        var path = Path()
        path.move(to: CGPoint(x: bandMinX + crown, y: minY))
        corner(&path, CGPoint(x: bandMaxX, y: minY), CGPoint(x: bandMaxX, y: bodyTop), crown)
        if right >= 0.5 {
            corner(&path, CGPoint(x: bandMaxX, y: bodyTop), CGPoint(x: maxX, y: bodyTop), fillet(right))
            corner(&path, CGPoint(x: maxX, y: bodyTop), CGPoint(x: maxX, y: maxY), top(right))
        }
        corner(&path, CGPoint(x: maxX, y: maxY), CGPoint(x: minX, y: maxY), bottom)
        corner(&path, CGPoint(x: minX, y: maxY), CGPoint(x: minX, y: bodyTop), bottom)
        if left >= 0.5 {
            corner(&path, CGPoint(x: minX, y: bodyTop), CGPoint(x: bandMinX, y: bodyTop), top(left))
            corner(&path, CGPoint(x: bandMinX, y: bodyTop), CGPoint(x: bandMinX, y: minY), fillet(left))
        }
        corner(&path, CGPoint(x: bandMinX, y: minY), CGPoint(x: bandMaxX, y: minY), crown)
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

/// Inhalt der Kapsel an der Kamera-Insel: auf einer Seite der Kamera das
/// Zeichen des wichtigsten Zustands, kompakt mit seiner Zahl daneben, minimal
/// allein. Beides steht dicht an der Kamera, wie bei Apples Insel. Geteilt
/// mit dem Ruhebild der Diktat-Pille.
struct NotchIslandBandRow: View {
    let band: NotchIslandBand
    let signal: NotchIslandSignal?

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if band.hasLeadingContent { content }
            }
            .padding(.trailing, 5)
            .frame(width: band.leadingContent, alignment: .trailing)
            Color.clear.frame(width: max(0, band.width - band.leadingContent - band.trailingContent))
            Group {
                if band.hasTrailingContent { content }
            }
            .padding(.leading, 5)
            .frame(width: band.trailingContent, alignment: .leading)
        }
        .frame(width: band.width)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        if let signal {
            HStack(spacing: 5) {
                Self.glyph(signal)
                if band.showsValue {
                    Text(verbatim: signal.text)
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(color(signal.kind))
                        .fixedSize()
                }
            }
        }
    }

    @ViewBuilder
    static func glyph(_ signal: NotchIslandSignal?) -> some View {
        switch signal?.kind {
        case nil: EmptyView()
        case .waiting: NotchStatusDot(status: .awaitingInput, palette: .notch, size: 9)
        case .errored: NotchStatusDot(status: .errored, palette: .notch, size: 9)
        case .working: NotchStatusDot(status: .working, palette: .notch, size: 9)
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(NotchPalette.notch.secondary)
                .frame(width: 9, height: 9)
        }
    }

    private func color(_ kind: NotchIslandSignal.Kind) -> Color {
        switch kind {
        case .waiting: return NotchPalette.notch.awaiting
        case .errored: return NotchPalette.notch.error
        case .working: return NotchPalette.notch.working
        case .done: return NotchPalette.notch.secondary
        }
    }
}

struct NotchChip: View {
    enum Kind { case working, waiting, errored, done }

    let kind: Kind
    let count: Int
    let palette: NotchPalette
    var font: Font = .system(size: 12, weight: .semibold)

    var body: some View {
        HStack(spacing: 6) {
            symbol
            Text("\(count)")
                .font(font)
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

    private var status: AgentSessionRuntimeStatus { Self.status(for: alert.kind) }

    private var tint: Color { Self.tint(for: alert.kind, palette: palette) }

    static func status(for kind: NotchAlertKind) -> AgentSessionRuntimeStatus {
        switch kind {
        case .awaitingInput: return .awaitingInput
        case .errored: return .errored
        case .finished: return .idle
        }
    }

    static func tint(for kind: NotchAlertKind, palette: NotchPalette) -> Color {
        switch kind {
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
    var onTurnOff: () -> Void = {}
    /// Text des Ausschalters unten links (vereinte Pille: „Status in der
    /// Pille ausblenden“).
    var turnOffTitle: LocalizedStringKey = "Turn off notch"
    var turnOffHelp: String = String(localized: "Hides the chat status at the notch. Turn it back on in Settings or the menu bar.")
    /// Mit der Tastatur markierte Zeile.
    var selectedRowID: UUID?
    /// Maße der Zeilen (große Form an der Kamera-Insel: `.islandLarge`).
    var metrics: NotchListMetrics = .standard

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(sections) { section in
                            sectionTitle(section.kind)
                            ForEach(section.rows) { row in
                                NotchRowButton(
                                    row: row, palette: palette, isSelected: row.id == selectedRowID, metrics: metrics
                                ) {
                                    onSelect(row.id)
                                }
                                .id(row.id)
                            }
                        }
                    }
                    .padding(.horizontal, metrics.listPadding)
                }
                .scrollIndicators(.hidden)
                .onChange(of: selectedRowID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }

            HStack {
                // Sichtbarer Ausschalter direkt in der Notch. Wieder an:
                // Einstellungen, Menüleiste oder Hotkey.
                Button(action: onTurnOff) {
                    HStack(spacing: 4) {
                        Image(systemName: "power")
                        Text(turnOffTitle)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.secondary)
                .help(turnOffHelp)
                Spacer()
                Text("Esc closes")
            }
            .font(.system(size: metrics.footerSize))
            .foregroundStyle(palette.tertiary)
            .padding(.horizontal, metrics.listPadding + metrics.rowPadding)
            .frame(height: metrics.footerHeight)
        }
        .padding(.bottom, metrics.bottomPadding)
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
        .font(.system(size: metrics.sectionSize, weight: .semibold))
        .textCase(.uppercase)
        .tracking(0.6)
        .foregroundStyle(palette.tertiary)
        .padding(.horizontal, metrics.rowPadding)
        .frame(height: metrics.sectionTitleHeight, alignment: .bottom)
        .padding(.bottom, 2)
        .accessibilityAddTraits(.isHeader)
    }
}

struct NotchRowButton: View {
    let row: NotchRow
    let palette: NotchPalette
    var isSelected = false
    var metrics: NotchListMetrics = .standard
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: metrics.centersRow ? .center : .top, spacing: metrics.rowSpacing) {
                NotchStatusDot(status: row.status, palette: palette, size: metrics.dotSize)
                    .padding(.top, metrics.centersRow ? 0 : 4)
                VStack(alignment: .leading, spacing: metrics.centersRow ? 3 : 2) {
                    Text(row.title)
                        .font(.system(size: metrics.titleSize, weight: .semibold))
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                    Text(row.activityLine ?? row.project ?? "")
                        .font(.system(size: metrics.detailSize))
                        .foregroundStyle(palette.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: metrics.centersRow ? 3 : 2) {
                    Text(row.headline)
                        .font(.system(size: metrics.detailSize))
                        .foregroundStyle(palette.tertiary)
                        .lineLimit(1)
                    if row.activityLine != nil, let project = row.project {
                        Text(project)
                            .font(.system(size: metrics.detailSize))
                            .foregroundStyle(palette.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, metrics.rowPadding)
            .padding(.vertical, metrics.centersRow ? 0 : 6)
            .frame(height: metrics.rowHeight, alignment: metrics.centersRow ? .center : .top)
            .background {
                // Große Zeilen: 1 pt Luft, damit zwei gefärbte Felder
                // untereinander nicht zusammenlaufen.
                RoundedRectangle(cornerRadius: metrics.rowRadius)
                    .fill(background)
                    .padding(.vertical, metrics.centersRow ? 1 : 0)
            }
            .overlay {
                if isSelected, metrics.outlinesSelection {
                    RoundedRectangle(cornerRadius: metrics.rowRadius, style: .continuous)
                        .strokeBorder(palette.text.opacity(0.7), lineWidth: 2)
                        .padding(.vertical, 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(AgentRowAccessibility.summary(title: row.title, status: row.status, project: row.project))
    }

    /// Wartende Zeilen leicht amber, Fehler leicht rot, sonst nur beim Darüberfahren.
    private var background: Color {
        if isSelected { return palette.rowHover.opacity(2) }
        guard row.category == .needsYou else { return isHovering ? palette.rowHover : .clear }
        return row.status == .errored ? palette.error.opacity(0.14) : palette.attentionTint
    }
}
