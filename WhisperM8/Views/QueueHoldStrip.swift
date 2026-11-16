import SwiftUI

/// Pille oben rechts im Terminal eines Chats: Meldungen aus der Warteschlange
/// warten (WM8-123). Liest nur den eigenen Eintrag in `QueueHoldNotices`;
/// ändert er sich, wird nur diese Pille neu ausgewertet, nicht die
/// Chat-Ansicht.
///
/// Liegt als Überlagerung über dem Terminal und verschiebt nichts: Als
/// eigene Zeile darüber änderte sie beim Erscheinen und Verschwinden die
/// Höhe des Terminals, Claude zeichnete neu und das Bild sprang, oft mitten
/// beim Tippen. Oben rechts, weil Claudes Feld und Ausgabe links beginnen; ein
/// Streifen über die ganze Breite verdeckte in einem kurzen Chat genau das
/// Eingabefeld (Entscheidung Giuliano 16.11.2026).
///
/// Kein Hover-only: Der Grund steht immer in der Pille. Der zweite Satz, wie
/// die Meldung frei wird, steht in `.help` und in der Bedienungshilfe. Damit
/// `.help` wirkt, nimmt die Pillenfläche selbst die Maus an; daneben geht
/// jeder Klick ans Terminal.
struct QueueHoldStrip: View {
    let sessionID: UUID
    var notices: QueueHoldNotices = .shared

    var body: some View {
        if let notice = notices.notices[sessionID] {
            QueueHoldStripContent(notice: notice)
        }
    }
}

/// Der gezeichnete Teil, ohne Zustand (Snapshot-Fixture). Eine Zeile; ist das
/// Terminal schmaler als der Text, wird gekürzt statt umgebrochen.
struct QueueHoldStripContent: View {
    let notice: QueueHoldNotices.Notice

    var body: some View {
        let text = QueueHoldNotices.text(for: notice)
        let hint = QueueHoldNotices.hint(for: notice)
        HStack(spacing: 5) {
            Image(systemName: "tray.full")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.orange)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AgentTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        // Deckend: Darunter läuft Terminal-Text, der sonst durchschiene.
        .background(Capsule().fill(Color.orange.opacity(0.14)))
        .background(Capsule().fill(AgentTheme.panel))
        .overlay(Capsule().strokeBorder(Color.orange.opacity(0.45), lineWidth: 1))
        .compositingGroup()
        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
        .help(hint)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: text))
        .accessibilityHint(Text(verbatim: hint))
    }

    /// Abstand zur Ecke des Terminals; rechts mehr, damit der Scroller frei bleibt.
    static let topInset: CGFloat = 6
    static let trailingInset: CGFloat = 16
    static let leadingInset: CGFloat = 8
}
