import SwiftUI
@testable import WhisperM8

/// Geschlossene Chats ohne Verlaufsdatei: In der Sidebar steht rechts statt des
/// Status-Punkts ein Fragezeichen (Verlauf gelöscht) oder ein gestrichelter
/// Kreis (leerer Chat, nie eine Nachricht). Daneben die Verlaufsansicht für
/// beide Fälle. Ein normaler geschlossener Chat steht zum Vergleich oben.
extension UISnapshotGallery {
    @MainActor
    static func missingTranscriptFixtures() -> [Fixture] {
        let projectID = UUID()

        var normal = AgentChatSession(provider: .claude, projectID: projectID, title: "Sidebar: Badges aufräumen")
        normal.externalSessionID = "normal"
        normal.createdManually = true
        normal.status = .closed

        // Verlauf belegt (`lastTurnAt`), Datei weg: Claudes Cleanup.
        var deleted = AgentChatSession(provider: .claude, projectID: projectID, title: "Notch: Statusanzeige Entwurf")
        deleted.externalSessionID = "geloescht"
        deleted.createdManually = true
        deleted.status = .closed
        deleted.lastTurnAt = Date(timeIntervalSince1970: 1_780_000_000)

        // Nie eine Nachricht gesendet: Standardtitel, kein Turn.
        var empty = AgentChatSession(provider: .claude, projectID: projectID, title: "Claude Chat")
        empty.externalSessionID = "leer"
        empty.createdManually = true
        empty.status = .closed

        let statusStore = AgentSessionRuntimeStatusStore()

        func row(_ session: AgentChatSession, missing: Bool) -> some View {
            SessionListButton(
                session: session,
                isSelected: false,
                isOpenTab: false,
                accentColorHex: nil,
                statusStore: statusStore,
                isAutoRenaming: false,
                isMissingTranscript: missing,
                onSelect: {},
                onClose: {}
            )
        }

        return [
            Fixture(name: "sidebar-ohne-verlauf", size: CGSize(width: 300, height: 140)) {
                AnyView(VStack(alignment: .leading, spacing: 2) {
                    row(normal, missing: false)
                    row(deleted, missing: true)
                    row(empty, missing: true)
                    // Tooltips erscheinen im Bild nicht, darum hier als Text.
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "? = \(MissingTranscriptBadge.hint(for: deleted))")
                        Text(verbatim: "◌ = \(MissingTranscriptBadge.hint(for: empty))")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(AgentTheme.textSecondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(AppTheme.sidebar))
            },
            Fixture(name: "verlauf-ohne-datei-geloescht", size: CGSize(width: 560, height: 360)) {
                AnyView(TranscriptEmptyStateView(transcript: nil, session: deleted, onNewChatInProject: {}))
            },
            Fixture(name: "verlauf-ohne-datei-leer", size: CGSize(width: 560, height: 360)) {
                AnyView(TranscriptEmptyStateView(transcript: nil, session: empty, onNewChatInProject: {}))
            },
        ]
    }
}
