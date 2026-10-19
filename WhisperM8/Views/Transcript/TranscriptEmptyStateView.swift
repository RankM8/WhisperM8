import SwiftUI

/// Zustandsanzeige für Sessions ohne lesbaren Verlauf — der einzige Fall, in
/// dem die Verlaufsansicht nichts darstellen kann.
///
/// Stammt aus der abgelösten Roh-Ansicht (`AgentChatTranscriptView`) und ist
/// bewusst erhalten geblieben: Der Resume-Hinweis und der Sonderfall
/// „Hintergrund-Agent ohne Short-ID" sind die einzige Stelle, an der dem User
/// erklärt wird, warum hier nichts steht und was er tun kann.
struct TranscriptEmptyStateView: View {
    /// `nil` heißt: kein Transcript verfügbar (JSONL existiert nicht).
    let transcript: AgentChatTranscript?
    let session: AgentChatSession
    /// Legt einen neuen Chat im selben Projekt an (Container reicht den
    /// Mechanismus der Chat-Ansicht durch). `nil` = Knopf entfällt.
    var onNewChatInProject: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusBanner
            emptyState
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "moon.zzz")
                .foregroundStyle(AgentTheme.textTertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(bannerTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AgentTheme.textPrimary)
                Text(bannerSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(AgentTheme.textSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(AgentTheme.surface)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(AgentTheme.border),
            alignment: .bottom
        )
    }

    /// `true` wenn das eine `.backgroundChat`-Session ist, deren Spawn nie
    /// abgeschlossen wurde (keine Short-ID). Fuer diesen Sonderfall taugt
    /// der "Resume oben"-Hinweis nicht, weil `claude attach` ohne Short-ID
    /// nicht laufen kann.
    private var isOrphanedBackgroundChat: Bool {
        session.isBackgroundChat && !session.hasBackgroundShortID
    }

    /// Leer nur im Lesefenster: Die letzte Zeile war größer als das Fenster,
    /// davor liegt Verlauf (LR-AK-007). Der Container zeigt dann oben
    /// „Früheren Verlauf laden“.
    private var isTruncatedOnly: Bool {
        transcript?.hasTruncatedHead == true
    }

    /// Die Session hatte schon einen Verlauf, die Datei ist aber weg: Claude
    /// räumt alte Transcripts selbst ab. Fortsetzen geht dann nicht mehr; früher
    /// stand hier trotzdem „Klick Resume“ (LR-AU-034).
    ///
    /// Die externe ID allein beweist das nicht: Sie wird schon bei `SessionStart`
    /// gebunden, das Transcript entsteht erst mit dem ersten Prompt. Darum zusätzlich
    /// ein nachweisbarer Turn (`lastTurnAt`) bzw. eine übernommene (nicht manuell
    /// angelegte) Session, deren Verlauf von außen kam.
    static func isTranscriptDeleted(transcript: AgentChatTranscript?, session: AgentChatSession) -> Bool {
        guard transcript == nil, !(session.externalSessionID ?? "").isEmpty, !session.isBackgroundChat else { return false }
        return session.lastTurnAt != nil || session.createdManually != true
    }

    private var isTranscriptDeleted: Bool {
        Self.isTranscriptDeleted(transcript: transcript, session: session)
    }

    private var bannerTitle: String {
        if isOrphanedBackgroundChat {
            return String(localized: "Background agent was not fully spawned")
        }
        if isTruncatedOnly {
            return String(localized: "Last entry is too large for the preview")
        }
        if isTranscriptDeleted {
            return String(localized: "History no longer available")
        }
        return transcript == nil
            ? String(localized: "Session not started yet")
            : String(localized: "Conversation is empty")
    }

    /// Beschriftung des Knopfs oben in der Kopfzeile — dieselbe Regel wie dort.
    /// Der Text verwies früher immer auf „Resume“, auch wenn der Knopf „Start“
    /// hieß (LR-AU-029).
    static func launchButtonLabel(for session: AgentChatSession) -> String {
        // Lokalisiert wie der Kopfzeilen-Button, sonst nennt der Text auf Deutsch
        // „Start“, während der Button „Starten“ heißt.
        ChatsUIStrings.startActionTitle(isRunning: false, hasExternalSession: session.externalSessionID != nil)
    }

    private var bannerSubtitle: String {
        if isOrphanedBackgroundChat {
            return String(localized: "This background session has no short ID, so it can't be attached. Close the tab or start it again.")
        }
        if isTranscriptDeleted {
            return String(localized: "\(session.provider.displayName) deleted the saved history of this chat.")
        }
        let label = Self.launchButtonLabel(for: session)
        return String(localized: "\(label) at the top starts \(session.provider.displayName) again.")
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: emptyStateIcon)
                .font(.system(size: 32))
                .foregroundStyle(AgentTheme.textTertiary)
                .accessibilityHidden(true)
            Text(emptyStateTitle)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AgentTheme.textPrimary)
            // Markdown ausdrücklich parsen: `Text(String)` zeigte `**` wörtlich.
            Text(Self.renderMarkdown(emptyStateDetail))
                .font(.system(size: 12))
                .foregroundStyle(AgentTheme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            if isTranscriptDeleted, let onNewChatInProject {
                Button("New Chat in Same Project", action: onNewChatInProject)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .padding(.top, 4)
            }
            if let id = session.externalSessionID, !id.isEmpty {
                // Rohe Session-ID nur auf Nachfrage — für Laien ohne Nutzen.
                DisclosureGroup("Details") {
                    Text("Session ID: \(id)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(AgentTheme.textTertiary)
                        .textSelection(.enabled)
                }
                .font(.system(size: 10))
                .foregroundStyle(AgentTheme.textTertiary)
                .frame(maxWidth: 360)
                .padding(.top, 4)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }

    static func renderMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }

    private var emptyStateIcon: String {
        if isOrphanedBackgroundChat { return "exclamationmark.triangle" }
        if isTranscriptDeleted { return "questionmark.circle" }
        return transcript == nil ? "play.rectangle" : "ellipsis.bubble"
    }

    private var emptyStateTitle: String {
        if isOrphanedBackgroundChat {
            return String(localized: "Background agent was not fully started")
        }
        if isTruncatedOnly {
            return String(localized: "Older messages are available")
        }
        if isTranscriptDeleted {
            return String(localized: "This chat can't be continued")
        }
        return transcript == nil
            ? String(localized: "This session has no conversation yet")
            : String(localized: "This conversation has no messages yet")
    }

    private var emptyStateDetail: String {
        if isTranscriptDeleted {
            return String(localized: "Start a **New chat** in the same project to keep working there. You can archive this chat from its context menu in the sidebar.")
        }
        return Self.detailText(
            isOrphanedBackgroundChat: isOrphanedBackgroundChat,
            isTruncatedOnly: isTruncatedOnly,
            launchLabel: Self.launchButtonLabel(for: session),
            providerName: session.provider.displayName
        )
    }

    static func detailText(isOrphanedBackgroundChat: Bool, isTruncatedOnly: Bool, launchLabel: String, providerName: String) -> String {
        if isOrphanedBackgroundChat {
            return String(localized: "Spawning this background agent was interrupted, so no short ID was saved. Close the tab from the context menu and start a new background agent if needed.")
        }
        if isTruncatedOnly {
            return String(localized: "The last entry (for example a large tool result) doesn't fit into the preview. Use **Load earlier history** at the top to see the messages before it.")
        }
        return String(localized: "Click **\(launchLabel)** at the top of the header to start \(providerName) and continue this session.")
    }
}
