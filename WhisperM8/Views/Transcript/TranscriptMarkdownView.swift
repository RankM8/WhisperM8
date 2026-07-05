import SwiftUI

/// Rendert Assistant-Antwort-Text als leichtes Markdown: Blöcke via
/// `MarkdownBlockParser`, Inline-Formatierung via `AttributedString(markdown:)`
/// (mit Plaintext-Fallback bei kaputtem Markdown). Kein externes Package.
struct TranscriptMarkdownView: View {
    let text: String

    var body: some View {
        let blocks = MarkdownBlockParser.parse(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            inlineText(text)
                .font(.system(size: 13))
                .foregroundStyle(AgentTheme.textPrimary)
                .lineSpacing(2.5)
        case .heading(let level, let text):
            inlineText(text)
                .font(.system(size: headingSize(level), weight: .bold))
                .foregroundStyle(AgentTheme.textPrimary)
                .padding(.top, 4)
        case .codeFence(_, let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(AgentTheme.textPrimary)
                    .textSelection(.enabled)
                    .padding(9)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AgentTheme.background)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(AgentTheme.border, lineWidth: 1))
        case .list(let items, let ordered):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(ordered ? "\(index + 1)." : "•")
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(AgentTheme.textTertiary)
                        inlineText(item)
                            .font(.system(size: 13))
                            .foregroundStyle(AgentTheme.textPrimary)
                            .lineSpacing(2)
                    }
                }
            }
            .padding(.leading, 2)
        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(AgentTheme.borderStrong)
                    .frame(width: 2)
                inlineText(text)
                    .font(.system(size: 13))
                    .foregroundStyle(AgentTheme.textSecondary)
            }
        case .table(let raw):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(raw)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(AgentTheme.textPrimary)
                    .textSelection(.enabled)
                    .padding(9)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AgentTheme.background)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        case .divider:
            Rectangle()
                .fill(AgentTheme.border)
                .frame(height: 1)
                .padding(.vertical, 2)
        }
    }

    /// Inline-Markdown (fett, `code`, Links) tolerant auflösen. Zeilenumbrüche
    /// innerhalb des Blocks bleiben erhalten (`inlineOnlyPreservingWhitespace`).
    private func inlineText(_ raw: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: raw,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(raw)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 16
        case 2: return 14.5
        default: return 13.5
        }
    }
}
