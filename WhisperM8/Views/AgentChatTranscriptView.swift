import SwiftUI

/// Read-only Chat-Anzeige fuer geschlossene Claude- oder Codex-Sessions.
/// Rendert die vom `ClaudeTranscriptReader` / `CodexTranscriptReader`
/// geparsten `AgentChatMessage`s in einer scrollbaren Liste — User-Bubbles
/// rechts/akzentuiert, Assistant-Bubbles links, Tool-Calls als monospace
/// Box, Thinking-Bloecke initial collapsed.
///
/// Die ScrollView startet am Ende (juengste Message) — wie ein Chat-App.
struct AgentChatTranscriptView: View {
    /// `nil` heisst: kein Transcript verfuegbar (JSONL existiert nicht). Wird
    /// dann als spezieller Empty-State angezeigt mit Hinweis auf Resume.
    let transcript: AgentChatTranscript?
    let session: AgentChatSession
    /// Nachlade-Hook fuer tail-gelesene Transcripts (Owner vergroessert sein
    /// Lesefenster) — greift wenn alle geladenen Messages sichtbar sind,
    /// die Datei aber vor dem Fenster weiteren Verlauf hat.
    var history: TranscriptHistoryState = .idle
    var loadHint: String?
    var onLoadEarlierHistory: (() -> Void)?

    /// Wie viele Messages initial ueber `ForEach` ausgegeben werden.
    /// SwiftUI's LazyVStack mit `.defaultScrollAnchor(.bottom)` muss intern
    /// jede Item-Hoehe vorausberechnen um die Scroll-Position am Ende zu
    /// landen. Bei >1000 Messages kollabiert dadurch der Main-Thread im
    /// Initial-Layout-Pass. Wir loesen das mit einem expliziten Window —
    /// Default 300 Messages, "Earlier"-Button laedt weitere Batches.
    private static let initialMessageWindow = 300
    private static let messageBatchIncrement = 300

    @State private var visibleCount: Int = initialMessageWindow

    /// Sichere Liste der Messages — leer falls Transcript fehlt.
    private var allMessages: [AgentChatMessage] {
        transcript?.messages ?? []
    }

    /// Die tatsaechlich gerenderten Messages — Suffix von allMessages.
    private var visibleMessages: ArraySlice<AgentChatMessage> {
        guard !allMessages.isEmpty else { return [] }
        let start = max(0, allMessages.count - visibleCount)
        return allMessages[start..<allMessages.count]
    }

    private var hasMoreEarlier: Bool {
        visibleMessages.count < allMessages.count
    }

    private var hiddenEarlierCount: Int {
        max(0, allMessages.count - visibleMessages.count)
    }

    private var isReallyEmpty: Bool {
        allMessages.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusBanner

            if isReallyEmpty {
                emptyState
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if hasMoreEarlier || canLoadEarlierHistory || history.isLoading
                            || history.lastLoadedDelta != nil || history.reachedStart {
                            historySection
                                .padding(.horizontal, 16)
                                .padding(.top, 8)
                        }
                        ForEach(visibleMessages) { message in
                            messageRow(message)
                                .padding(.horizontal, 16)
                        }
                    }
                    .padding(.vertical, 14)
                }
                .defaultScrollAnchor(.bottom)
            }
        }
        .background(AgentTheme.background)
        .onChange(of: allMessages.count) { old, new in
            // Nur bei SCHRUMPFENDEM Transcript (Session-Wechsel) resetten.
            // Wachstum = Live-Append oder nachgeladener Verlauf — da muss
            // das (ggf. praeventiv geweitete) Fenster erhalten bleiben.
            if new < old {
                visibleCount = Self.initialMessageWindow
            }
        }
    }

    /// Alle geladenen Messages sichtbar, aber die Datei hat davor noch
    /// Verlauf → Nachladen von der Platte anbieten.
    private var canLoadEarlierHistory: Bool {
        !hasMoreEarlier && transcript?.hasTruncatedHead == true && onLoadEarlierHistory != nil
    }

    /// Vier Zustände, identisch zur Timeline (geteilte Bausteine).
    @ViewBuilder
    private var historySection: some View {
        VStack(spacing: 7) {
            if history.isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Verlauf wird geladen …")
                        .font(.system(size: 11))
                        .foregroundStyle(AgentTheme.textTertiary)
                }
                .padding(.vertical, 5)
            } else {
                if let delta = history.lastLoadedDelta {
                    Text(delta > 0 ? "✓ \(delta) ältere Nachrichten geladen" : "✓ Verlauf aktualisiert")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(AgentTheme.statusWorking)
                }
                if hasMoreEarlier {
                    TranscriptHistoryPill(title: "\(hiddenEarlierCount) frühere Nachrichten anzeigen", detail: nil) {
                        visibleCount = min(allMessages.count, visibleCount + Self.messageBatchIncrement)
                    }
                } else if canLoadEarlierHistory {
                    TranscriptHistoryPill(title: "Früheren Verlauf laden", detail: loadHint) {
                        // Fenster praeventiv weiten, damit die nachgeladenen
                        // Messages direkt sichtbar sind.
                        visibleCount += Self.messageBatchIncrement
                        onLoadEarlierHistory?()
                    }
                } else if history.reachedStart {
                    TranscriptHistoryStartMarker()
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var statusBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: isReallyEmpty ? "moon.zzz" : "checkmark.bubble")
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
        if isReallyEmpty {
            if isOrphanedBackgroundChat {
                return "Hintergrund-Agent unvollständig gespawnt"
            }
            return transcript == nil
                ? "Session noch nicht gestartet"
                : "Konversation ist leer"
        }
        return "Konversation geladen"
    }

    private var bannerSubtitle: String {
        if isOrphanedBackgroundChat && isReallyEmpty {
            return "Diese Hintergrund-Session hat keine Short-ID — Attach ist nicht möglich. Tab schließen oder neu starten."
        }
        let resumeHint = "Resume oben startet \(session.provider.displayName) erneut."
        if isReallyEmpty {
            return resumeHint
        }
        let total = allMessages.count
        if hasMoreEarlier {
            return "\(visibleMessages.count) von \(total) Nachrichten · " + resumeHint
        }
        return "\(total) Nachrichten · " + resumeHint
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

    @ViewBuilder
    private func messageRow(_ message: AgentChatMessage) -> some View {
        VStack(alignment: alignment(for: message.role), spacing: 4) {
            HStack(spacing: 6) {
                Text(roleLabel(for: message.role))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AgentTheme.textTertiary)
                    .textCase(.uppercase)
                if let ts = message.timestamp {
                    Text(timeLabel(ts))
                        .font(.system(size: 10))
                        .foregroundStyle(AgentTheme.textTertiary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(message.blocks.enumerated()), id: \.offset) { _, block in
                    blockView(block, role: message.role)
                }
            }
            .padding(12)
            .background(bubbleBackground(for: message.role))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(AgentTheme.border.opacity(0.6), lineWidth: 1)
            )
            .frame(maxWidth: .infinity, alignment: bubbleAlignment(for: message.role))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: AgentChatBlock, role: AgentChatMessage.Role) -> some View {
        switch block {
        case .text(let text):
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(AgentTheme.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .toolUse(let name, let input):
            toolUseBlock(name: name, input: input)
        case .toolResult(let content, let isError):
            toolResultBlock(content: content, isError: isError)
        case .imagePlaceholder(let mediaType, let byteSize):
            imagePlaceholderBlock(mediaType: mediaType, byteSize: byteSize)
        case .thinking(let text):
            thinkingBlock(text)
        }
    }

    @ViewBuilder
    private func toolUseBlock(name: String, input: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "wrench.adjustable")
                    .font(.system(size: 10))
                Text(name)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(AgentTheme.textSecondary)
            if !input.isEmpty {
                Text(input)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(AgentTheme.textPrimary)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AgentTheme.background)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    @ViewBuilder
    private func toolResultBlock(content: String, isError: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: isError ? "exclamationmark.triangle" : "arrow.turn.down.right")
                    .font(.system(size: 10))
                Text(isError ? "Tool-Fehler" : "Tool-Ergebnis")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(isError ? Color.orange : AgentTheme.textSecondary)
            Text(content.prefix(2000).description)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(AgentTheme.textPrimary)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AgentTheme.background)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            if content.count > 2000 {
                Text("… \(content.count - 2000) weitere Zeichen abgeschnitten")
                    .font(.system(size: 10))
                    .foregroundStyle(AgentTheme.textTertiary)
            }
        }
    }

    @ViewBuilder
    private func imagePlaceholderBlock(mediaType: String, byteSize: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "photo")
                .foregroundStyle(AgentTheme.textTertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Bild angehaengt")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AgentTheme.textPrimary)
                Text("\(mediaType) · \(byteCountLabel(byteSize))")
                    .font(.system(size: 10))
                    .foregroundStyle(AgentTheme.textTertiary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AgentTheme.background)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func thinkingBlock(_ text: String) -> some View {
        DisclosureGroup {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(AgentTheme.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "brain")
                    .font(.system(size: 10))
                Text("Thinking")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(AgentTheme.textTertiary)
        }
        .padding(8)
        .background(AgentTheme.background.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Helpers

    private func alignment(for role: AgentChatMessage.Role) -> HorizontalAlignment {
        // Wir lassen alle Bubbles links ausgerichtet — die unterschiedlichen
        // Hintergrundfarben + Role-Label markieren visuell die Trennung. Ein
        // rechts-orientiertes User-Layout wirkt im Code-Kontext oft fremd.
        .leading
    }

    private func bubbleAlignment(for role: AgentChatMessage.Role) -> Alignment { .leading }

    private func bubbleBackground(for role: AgentChatMessage.Role) -> Color {
        switch role {
        case .user:      return AgentTheme.surface
        case .assistant: return AgentTheme.background.opacity(0.6)
        case .system:    return AgentTheme.surface.opacity(0.5)
        }
    }

    private func roleLabel(for role: AgentChatMessage.Role) -> String {
        switch role {
        case .user:      return "Du"
        case .assistant: return session.provider.displayName
        case .system:    return "System"
        }
    }

    private func timeLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func byteCountLabel(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
