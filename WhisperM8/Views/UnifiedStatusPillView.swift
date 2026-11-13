import SwiftUI

/// Die vereinte Pille in Ruhe, beim Hinweis „braucht dich“ und mit offener
/// Statusliste — auf Bildschirmen ohne Notch. Gezeichnet exakt wie die
/// Diktat-Pille: dieselbe Höhe (40 pt), dasselbe dunkle Glas mit feinem
/// hellem Rand (`PillGlassBackground`), derselbe im Fenster gezeichnete
/// Schatten (`pillGlassShadow`), dieselbe Schrift. In Ruhe ist sie nur
/// schmaler: der Kern als stille graue Linie, daneben die Zähler.
///
/// Rein darstellend: alles kommt aus `NotchDisplay`. Maus (Klick, Ziehen,
/// Doppelklick) behandelt die Hosting-View; die Knöpfe hier sind für
/// VoiceOver und die Zeilen der Liste.
struct UnifiedStatusPillView: View {
    let display: NotchDisplay
    var onToggle: () -> Void = {}
    var onStartDictation: () -> Void = {}
    var onSelect: (UUID) -> Void = { _ in }
    var onTurnOff: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }
    /// Sichtbarer Rahmen der Pille und des Kerns (SwiftUI-Koordinaten der
    /// Hosting-View, oben links), für Treffer-Fläche und Klickziel.
    var onLayout: (_ pill: CGRect, _ core: CGRect) -> Void = { _, _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var coreFrame: CGRect = .zero

    private var palette: NotchPalette { .pill }

    var body: some View {
        pill
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: display.opensUpward ? .bottom : .top)
            .padding(UnifiedPillGeometry.shadowMargin)
            .ignoresSafeArea()
            .environment(\.colorScheme, .dark)
    }

    private var pill: some View {
        VStack(spacing: 0) {
            if display.isExpanded, display.opensUpward { list }
            header
            if display.isExpanded, !display.opensUpward { list }
        }
        .frame(width: display.isExpanded ? NotchGeometry.pillExpandedWidth : nil)
        .background { glass }
        .clipShape(shape)
        .contentShape(shape)
        .pillGlassShadow()
        .onHover(perform: onHover)
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { onLayout(geometry.frame(in: .global), coreFrame) }
                    .onChange(of: geometry.frame(in: .global)) { _, frame in onLayout(frame, coreFrame) }
                    .onChange(of: coreFrame) { _, core in onLayout(geometry.frame(in: .global), core) }
            }
        }
        .animation(reduceMotion ? nil : .pill, value: display)
    }

    /// Dasselbe Glas wie die Diktat-Pille: Kapsel zu, abgerundetes Rechteck offen.
    @ViewBuilder
    private var glass: some View {
        if display.isExpanded {
            PillGlassBackground(shape: RoundedRectangle(cornerRadius: PillGlass.cornerRadius, style: .continuous), unified: true)
        } else {
            PillGlassBackground(shape: Capsule(), unified: true)
        }
    }

    private var shape: AnyShape {
        display.isExpanded
            ? AnyShape(RoundedRectangle(cornerRadius: PillGlass.cornerRadius, style: .continuous))
            : AnyShape(Capsule())
    }

    private var list: some View {
        NotchChatList(
            sections: display.sections, palette: palette, onSelect: onSelect, onTurnOff: onTurnOff,
            turnOffTitle: "Hide status in the pill",
            turnOffHelp: String(localized: "Hides the chat status in the pill. The pill still shows up for dictation. Turn it back on in Settings or the menu bar."),
            selectedRowID: display.selectedRowID)
            .transition(.opacity)
    }

    // MARK: Pillen-Zeile

    private var header: some View {
        HStack(spacing: 0) {
            Button(action: onStartDictation) {
                PillRestCoreView()
                    .background {
                        GeometryReader { geometry in
                            Color.clear
                                .onAppear { coreFrame = geometry.frame(in: .global) }
                                .onChange(of: geometry.frame(in: .global)) { _, frame in coreFrame = frame }
                        }
                    }
            }
            .buttonStyle(.plain)
            .padding(.leading, 2)
            .accessibilityLabel(Text("Start dictation"))

            Button(action: onToggle) {
                status
            }
            .buttonStyle(.plain)
            .accessibilityLabel(headerAccessibilityLabel)
            .accessibilityHint(display.isExpanded ? Text("Closes the chat list") : Text("Opens the chat list"))
        }
        .padding(.horizontal, PillMetrics.horizontalPadding)
        .frame(height: PillMetrics.height)
        .frame(maxWidth: display.isExpanded ? .infinity : nil)
    }

    private var status: some View {
        UnifiedPillRestStatus(summary: display.summary, alert: display.isExpanded ? nil : display.alert)
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

/// Rechte Seite der ruhenden Pille: Zähler bzw. „braucht dich“. Geteilt mit
/// dem Ruhebild der Diktat-Pille (`UnifiedPillRestLookView`), damit der
/// Übergang ins Diktat ohne Sprung beginnt.
struct UnifiedPillRestStatus: View {
    let summary: NotchSummary
    let alert: NotchAlert?

    private var palette: NotchPalette { .pill }

    var body: some View {
        if let alert {
            UnifiedPillAlertLabel(alert: alert, palette: palette)
        } else if summary.hasActivity {
            HStack(spacing: 11) {
                if summary.working > 0 { chip(.working, summary.working) }
                if summary.waiting > 0 { chip(.waiting, summary.waiting) }
                if summary.errored > 0 { chip(.errored, summary.errored) }
                if summary.freshDone > 0 { chip(.done, summary.freshDone) }
            }
            .padding(.leading, 9)
            .padding(.trailing, 10)
        }
    }

    private func chip(_ kind: NotchChip.Kind, _ count: Int) -> some View {
        NotchChip(kind: kind, count: count, palette: palette, font: .system(size: 12.5, weight: .semibold))
    }
}

/// Der ruhende Kern: dieselbe Kapsel wie der Kern der Diktat-Pille
/// (`PillCoreView`, 28 pt hoch, mindestens 46 pt breit, fünf Balken), aber
/// grau und flach — WhisperM8 ist da, das Mikrofon ist aus. Keine Bewegung.
struct PillRestCoreView: View {
    var body: some View {
        HStack(spacing: PillMetrics.barSpacing) {
            ForEach(0..<5, id: \.self) { _ in
                Capsule()
                    .fill(Color.white.opacity(0.30))
                    .frame(width: PillMetrics.barWidth, height: 3)
            }
        }
        .padding(.horizontal, 10)
        .frame(minWidth: PillMetrics.coreMinWidth)
        .frame(height: PillMetrics.coreHeight)
        .background { Capsule().fill(Color.white.opacity(0.05)) }
        .overlay { Capsule().strokeBorder(Color.white.opacity(0.09), lineWidth: 1) }
        .contentShape(Capsule())
        .help(String(localized: "Start dictation"))
    }
}

/// „braucht dich“ in der Pille: Punkt, Chat-Name, kurzes Wort, „+n“. Schrift
/// wie die Diktat-Pille (12,5 pt).
struct UnifiedPillAlertLabel: View {
    let alert: NotchAlert
    let palette: NotchPalette

    var body: some View {
        HStack(spacing: 7) {
            NotchStatusDot(status: status, palette: palette)
            Text(alert.title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(palette.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 190, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            Text(NotchAlertLabel.word(for: alert.kind))
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(tint)
                .fixedSize()
            if alert.extraCount > 0 {
                Text(verbatim: "+ \(alert.extraCount)")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(palette.tertiary)
                    .fixedSize()
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, 12)
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
}

/// Raute bzw. Ring für wartende Chats und Fehler, ganz links in der
/// Diktat-Pille (hinter einem feinen Trenner). „Arbeitet“ und „fertig“
/// fallen beim Diktat weg.
struct DictationStatusBadgeView: View {
    let badge: DictationStatusBadge

    var body: some View {
        HStack(spacing: 6) {
            if badge.waiting > 0 {
                NotchChip(kind: .waiting, count: badge.waiting, palette: .pill,
                          font: .system(size: 12.5, weight: .semibold))
            }
            if badge.errored > 0 {
                NotchChip(kind: .errored, count: badge.errored, palette: .pill,
                          font: .system(size: 12.5, weight: .semibold))
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: Text {
        var parts: [String] = []
        if badge.waiting > 0 { parts.append(String(localized: "\(badge.waiting) waiting for you")) }
        if badge.errored > 0 { parts.append(String(localized: "\(badge.errored) with an error")) }
        return Text(parts.joined(separator: ", "))
    }
}
