import SwiftUI

/// Stand-Kachel des Ctrl+Tab-Switchers (Plan
/// `docs/plans/tab-switcher-workspace.md`, Slice S3) — EINE Kachel für alle
/// drei Situationen: C Projekt-Liste (`.row`), B Mini-Map und A
/// Grid-Markierung (`.card`, Stufe je nach Platz).
///
/// - Status flächig: Hintergrund-Tönung + Rand in der Statusfarbe (Farben wie
///   `AgentStatusIndicator`: Grün nur für „arbeitet", Amber für „wartet",
///   Rot für Fehler, ruhende Zustände grau).
/// - Farbe allein trägt keine Bedeutung: Status immer auch als Wort und
///   Symbol (`TabSwitcherTileModel`).
/// - Stufen (`TabSwitcherTileDetail`): voll / ohne Stand-Zeile / nur
///   Status + Titel.
///
/// Performance: rein darstellend — alle Werte kommen fertig im Modell, kein
/// Store-Zugriff, kein I/O, kein `.contextMenu`. Die Dauer tickt nur, weil
/// der Aufrufer (das Overlay) das Modell in einer `TimelineView` neu baut.
struct TabSwitcherTile: View {
    /// Anordnung der Inhalte.
    enum Arrangement {
        /// Listenzeile in voller Breite (~56 pt): Status links, Titel +
        /// Stand-Zeile in der Mitte, Dauer rechts.
        case row
        /// Kachel im Raster (Mini-Map, Grid): Status-Kopfzeile, darunter
        /// Titel und Stand-Zeile.
        case card
    }

    let model: TabSwitcherTileModel
    var detail: TabSwitcherTileDetail = .full
    var arrangement: Arrangement = .card
    /// Keyboard-Highlight des Durchlaufs (Akzent-Rahmen).
    var isHighlighted: Bool = false
    /// Der Chat, von dem der Durchlauf ausging („Hier").
    var isCurrent: Bool = false
    /// Nur visuelle Hover-Verstärkung — verschiebt nie das Highlight.
    var isHovered: Bool = false

    private let cornerRadius: CGFloat = 10

    var body: some View {
        content
            .background(background)
            .overlay(border)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText)
            .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }

    @ViewBuilder
    private var content: some View {
        switch arrangement {
        case .row: rowContent
        case .card: cardContent
        }
    }

    // MARK: - Listenzeile (Situation C)

    private var rowContent: some View {
        HStack(spacing: 10) {
            // Feste Breite: Titel aller Zeilen beginnen auf derselben Kante.
            statusLabel(text: model.statusWord)
                .frame(width: 84, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                title(lineLimit: 1)
                if detail.showsActivity, let line = model.activityLine {
                    activityText(line, lineLimit: 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isCurrent { hereBadge }
            if detail.showsDuration, let duration = model.durationText {
                Text(duration)
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(AgentTheme.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    // MARK: - Rasterkachel (Situation A/B)

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                statusLabel(text: model.header(detail: detail))
                Spacer(minLength: 4)
                if isCurrent { hereBadge }
            }
            title(lineLimit: detail.showsActivity ? 1 : 2)
            if detail.showsActivity, let line = model.activityLine {
                activityText(line, lineLimit: 2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Bausteine

    private func statusLabel(text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: model.symbolName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(symbolTint)
            Text(text)
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(wordTint)
                .lineLimit(1)
        }
    }

    private func title(lineLimit: Int) -> some View {
        Text(model.title)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(isHighlighted ? AgentTheme.textPrimary : AgentTheme.textSecondary)
            .lineLimit(lineLimit)
            .truncationMode(.tail)
            .multilineTextAlignment(.leading)
    }

    private func activityText(_ line: String, lineLimit: Int) -> some View {
        Text(line)
            .font(.system(size: 10.5))
            .foregroundStyle(AgentTheme.textTertiary)
            .lineLimit(lineLimit)
            .truncationMode(.tail)
            .multilineTextAlignment(.leading)
    }

    private var hereBadge: some View {
        Text("Hier")
            .font(.system(size: 8.5, weight: .bold))
            .foregroundStyle(AgentTheme.accent)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(AgentTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 3))
            .fixedSize()
    }

    // MARK: - Fläche und Rand

    private var background: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(isHighlighted ? AgentTheme.selectionStrong : AgentTheme.control.opacity(isHovered ? 0.9 : 0.45))
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(statusTint.opacity(isHighlighted ? 0.20 : (isHovered ? 0.15 : 0.10)))
        }
    }

    private var border: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .strokeBorder(
                isHighlighted ? AgentTheme.accent.opacity(0.9) : statusTint.opacity(0.45),
                lineWidth: isHighlighted ? 2 : 1
            )
    }

    // MARK: - Farben (gleiche Zuordnung wie `AgentStatusIndicator`)

    private var statusTint: Color {
        switch model.status {
        case .working: return AgentTheme.statusWorking
        case .awaitingInput: return AgentTheme.statusAwaiting
        case .errored: return AgentTheme.statusError
        case .idle, .stopped, nil: return AgentTheme.textTertiary
        }
    }

    private var symbolTint: Color {
        switch model.status {
        case .idle: return AgentTheme.textSecondary
        default: return statusTint
        }
    }

    /// Ruhende Zustände bekommen ein lesbares Grau statt der blassen Tönung.
    private var wordTint: Color {
        switch model.status {
        case .working, .awaitingInput, .errored: return statusTint
        case .idle, .stopped, nil: return AgentTheme.textSecondary
        }
    }

    private var accessibilityText: String {
        var parts = [model.title, model.header(detail: .withoutActivity)]
        if let line = model.activityLine { parts.append(line) }
        if isCurrent { parts.append("aktueller Chat") }
        return parts.joined(separator: ", ")
    }
}
