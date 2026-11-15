import SwiftUI

/// Hinweiszeile in der Projektgruppe: „↑ 4 im Workspace „WM8 Aktiv““ mit den
/// Status-Punkten der Chats (WM8-80, Seitenleiste A). Die Chats stehen oben
/// im Workspace und nicht noch einmal im Projekt; ein Klick springt dorthin.
struct SidebarWorkspaceHintRow: View {
    let hint: SidebarWorkspaceHint
    /// Stabile Store-Referenz wie bei `SessionListButton`: Jeder Punkt hört
    /// nur auf den Status seines Chats, die Zeile selbst beobachtet nichts.
    let statusStore: AgentSessionRuntimeStatusStore
    var onJump: () -> Void

    var body: some View {
        Button(action: onJump) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 12)
                Text("\(hint.sessionIDs.count) in workspace “\(hint.name)”")
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 3) {
                    ForEach(hint.sessionIDs, id: \.self) { sessionID in
                        SidebarHintStatusDot(sessionID: sessionID, statusStore: statusStore)
                    }
                }
                .fixedSize()
                Spacer(minLength: 0)
            }
            .foregroundStyle(AgentTheme.textTertiary)
            .padding(.leading, 35)
            .padding(.trailing, 8)
            .frame(minHeight: 24, maxHeight: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("These chats are shown above in the workspace")
    }
}

/// Kleiner Status-Punkt eines Chats in der Hinweiszeile. Dieselbe Logik wie
/// in Zeile, Tab und Kopf (`AgentStatusIndicator`, kompakt); ein gestoppter
/// Chat bekommt einen leeren Platz, damit die Punkte nicht springen.
private struct SidebarHintStatusDot: View {
    let sessionID: UUID
    let statusStore: AgentSessionRuntimeStatusStore
    @State private var liveStatus: AgentSessionRuntimeStatus?

    var body: some View {
        Group {
            switch liveStatus {
            case .working, .awaitingInput, .idle, .errored:
                AgentStatusIndicator(status: liveStatus, compact: true)
            case .stopped, .none:
                Color.clear
            }
        }
        .frame(width: 7, height: 7)
        .onReceive(statusStore.statusPublisher(for: sessionID)) { liveStatus = $0 }
    }
}

/// Faltzeile „N gestoppt“ über den gestoppten Chats eines Projekts. Unter
/// „Aktiv“ zu, sonst offen; der Klick überstimmt das für diese Gruppe.
struct SidebarStoppedFoldRow: View {
    let count: Int
    let isOpen: Bool
    var onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .frame(width: 12)
                Text("\(count) stopped")
                    .font(.system(size: 11))
                    .monospacedDigit()
                Spacer(minLength: 0)
            }
            .foregroundStyle(AgentTheme.textTertiary)
            .padding(.leading, 35)
            .padding(.trailing, 8)
            .frame(minHeight: 24, maxHeight: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isOpen ? String(localized: "Hide stopped chats") : String(localized: "Show stopped chats"))
    }
}

/// Trenner vor den Projekten ohne laufende Chats (WM8-80).
struct SidebarCalmProjectsBand: View {
    var body: some View {
        Text("No running chats")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(AgentTheme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }
}
