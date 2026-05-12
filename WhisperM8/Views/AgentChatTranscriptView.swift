import SwiftUI

/// Read-only Chat-Anzeige fuer geschlossene Claude- oder Codex-Sessions.
/// Rendert die vom `ClaudeTranscriptReader` / `CodexTranscriptReader`
/// geparsten `AgentChatMessage`s in einer scrollbaren Liste — User-Bubbles
/// rechts/akzentuiert, Assistant-Bubbles links, Tool-Calls als monospace
/// Box, Thinking-Bloecke initial collapsed.
///
/// Die ScrollView startet am Ende (juengste Message) — wie ein Chat-App.
struct AgentChatTranscriptView: View {
    let transcript: AgentChatTranscript
    let session: AgentChatSession

    /// Wie viele Messages initial ueber `ForEach` ausgegeben werden.
    /// SwiftUI's LazyVStack mit `.defaultScrollAnchor(.bottom)` muss intern
    /// jede Item-Hoehe vorausberechnen um die Scroll-Position am Ende zu
    /// landen. Bei >1000 Messages kollabiert dadurch der Main-Thread im
    /// Initial-Layout-Pass. Wir loesen das mit einem expliziten Window —
    /// Default 300 Messages, "Earlier"-Button laedt weitere Batches.
    private static let initialMessageWindow = 300
    private static let messageBatchIncrement = 300

    @State private var visibleCount: Int = initialMessageWindow

    /// Die tatsaechlich gerenderten Messages — Suffix von `transcript.messages`.
    private var visibleMessages: ArraySlice<AgentChatMessage> {
        guard !transcript.messages.isEmpty else { return [] }
        let start = max(0, transcript.messages.count - visibleCount)
        return transcript.messages[start..<transcript.messages.count]
    }

    private var hasMoreEarlier: Bool {
        visibleMessages.count < transcript.messages.count
    }

    private var hiddenEarlierCount: Int {
        max(0, transcript.messages.count - visibleMessages.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusBanner

            if transcript.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if hasMoreEarlier {
                            earlierButton
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
        .onChange(of: transcript.messages.count) { _, _ in
            // Neuer Transcript geladen → Window zuruecksetzen auf die letzten N.
            visibleCount = Self.initialMessageWindow
        }
    }

    @ViewBuilder
    private var earlierButton: some View {
        Button {
            visibleCount = min(
                transcript.messages.count,
                visibleCount + Self.messageBatchIncrement
            )
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.circle")
                    .font(.system(size: 12))
                Text("\(hiddenEarlierCount) frühere Nachrichten laden")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(AgentTheme.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(AgentTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(AgentTheme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var statusBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.bubble")
                .foregroundStyle(AgentTheme.textTertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Konversation geladen")
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

    private var bannerSubtitle: String {
        let total = transcript.messages.count
        let resumeHint = "Resume oben startet \(session.provider.displayName) erneut."
        if hasMoreEarlier {
            return "\(visibleMessages.count) von \(total) Nachrichten · " + resumeHint
        }
        return "\(total) Nachrichten · " + resumeHint
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "ellipsis.bubble")
                .font(.system(size: 28))
                .foregroundStyle(AgentTheme.textTertiary)
            Text("Noch keine Nachrichten in dieser Session")
                .font(.system(size: 13))
                .foregroundStyle(AgentTheme.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
