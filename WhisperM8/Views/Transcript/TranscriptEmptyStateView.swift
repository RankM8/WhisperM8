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

    private var bannerTitle: String {
        if isOrphanedBackgroundChat {
            return "Hintergrund-Agent unvollständig gespawnt"
        }
        return transcript == nil
            ? "Session noch nicht gestartet"
            : "Konversation ist leer"
    }

    private var bannerSubtitle: String {
        if isOrphanedBackgroundChat {
            return "Diese Hintergrund-Session hat keine Short-ID — Attach ist nicht möglich. Tab schließen oder neu starten."
        }
        return "Resume oben startet \(session.provider.displayName) erneut."
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: emptyStateIcon)
                .font(.system(size: 32))
                .foregroundStyle(AgentTheme.textTertiary)
            Text(emptyStateTitle)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AgentTheme.textPrimary)
            Text(emptyStateDetail)
                .font(.system(size: 12))
                .foregroundStyle(AgentTheme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            if let id = session.externalSessionID, !id.isEmpty {
                Text("Session-ID: \(id)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(AgentTheme.textTertiary)
                    .textSelection(.enabled)
                    .padding(.top, 4)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }

    private var emptyStateIcon: String {
        if isOrphanedBackgroundChat { return "exclamationmark.triangle" }
        return transcript == nil ? "play.rectangle" : "ellipsis.bubble"
    }

    private var emptyStateTitle: String {
        if isOrphanedBackgroundChat {
            return "Hintergrund-Agent wurde nicht vollständig gestartet"
        }
        return transcript == nil
            ? "Diese Session hat noch keine Konversation"
            : "Diese Konversation enthaelt noch keine Nachrichten"
    }

    private var emptyStateDetail: String {
        if isOrphanedBackgroundChat {
            return "Der Spawn dieses Hintergrund-Agents wurde unterbrochen, sodass keine Short-ID gespeichert ist. Schließe den Tab über das Kontextmenü und starte bei Bedarf einen neuen Hintergrund-Agent."
        }
        return "Klick **Resume** oben in der Header-Leiste, um \(session.provider.displayName) zu starten und mit dieser Session weiterzumachen."
    }
}
