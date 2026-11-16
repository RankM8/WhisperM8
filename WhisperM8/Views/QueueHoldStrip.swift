import SwiftUI

/// Leiste oben im Terminal eines Chats: Meldungen aus der Warteschlange
/// warten (WM8-123). Liest nur den eigenen Eintrag in `QueueHoldNotices`;
/// ändert er sich, wird nur diese Leiste neu ausgewertet, nicht die
/// Chat-Ansicht. Kein Hover: Text und Grund stehen immer da.
///
/// Liegt als Überlagerung über dem Terminal und verschiebt nichts: Als
/// eigene Zeile darüber änderte sie beim Erscheinen und Verschwinden die
/// Höhe des Terminals, Claude zeichnete neu und das Bild sprang, oft mitten
/// beim Tippen. Mausklicks gehen durch die Leiste ans Terminal.
struct QueueHoldStrip: View {
    let sessionID: UUID
    var notices: QueueHoldNotices = .shared

    var body: some View {
        if let notice = notices.notices[sessionID] {
            QueueHoldStripContent(notice: notice)
        }
    }
}

/// Der gezeichnete Teil, ohne Zustand (Snapshot-Fixture).
struct QueueHoldStripContent: View {
    let notice: QueueHoldNotices.Notice

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "tray.full")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(QueueHoldNotices.text(for: notice))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AgentTheme.textPrimary)
                Text(QueueHoldNotices.hint(for: notice))
                    .font(.system(size: 11))
                    .foregroundStyle(AgentTheme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        // Deckend: Darunter läuft Terminal-Text, der sonst durchschiene.
        .background(Color.orange.opacity(0.10))
        .background(AgentTheme.panel)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AgentTheme.border).frame(height: 1)
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
        .accessibilityElement(children: .combine)
    }
}
