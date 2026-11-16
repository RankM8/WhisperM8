import SwiftUI

/// Leiste über dem Terminal eines Chats: Meldungen aus der Warteschlange
/// warten (WM8-123). Liest nur den eigenen Eintrag in `QueueHoldNotices`;
/// ändert er sich, wird nur diese Leiste neu ausgewertet, nicht die
/// Chat-Ansicht. Kein Hover: Text und Grund stehen immer da.
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
                Text(QueueHoldNotices.hint(for: notice.reason))
                    .font(.system(size: 11))
                    .foregroundStyle(AgentTheme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.10))
        .accessibilityElement(children: .combine)
    }
}
