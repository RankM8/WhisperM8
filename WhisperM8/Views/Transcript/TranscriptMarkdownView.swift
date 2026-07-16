import SwiftUI

/// Rendert Assistant-Antwort-Text als leichtes Markdown: Blöcke via
/// `MarkdownBlockParser`, Inline-Formatierung via `AttributedString(markdown:)`
/// (mit Plaintext-Fallback bei kaputtem Markdown). Typografie nach
/// docs/design/chat-summary-ui.html Rev 2: ruhige Listen, Hairline-Tabellen,
/// H4-Abschnitte mit Trennlinie. Kein externes Package.
struct TranscriptMarkdownView: View {
    let text: String

    /// Parse-Ergebnis wird im Init aufgelöst (Cache-Hit = Lookup statt
    /// Re-Parse pro Body-Aufruf) und der Input vorher hart gedeckelt —
    /// Megabyte-Texte haben sonst CoreText-Layouts erzeugt, die die App
    /// beim Scrollen eingefroren haben (siehe TranscriptRenderLimits).
    private let blocks: [MarkdownBlock]
    private let truncatedCount: Int

    init(text: String) {
        self.text = text
        let clipped = TranscriptRenderLimits.clip(text, max: TranscriptRenderLimits.markdownChars)
        self.truncatedCount = clipped.truncatedCount
        self.blocks = MarkdownRenderCache.shared.blocks(for: clipped.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                blockView(block, isFirst: index == 0)
            }
            if truncatedCount > 0 {
                Text(TranscriptRenderLimits.truncationHint(truncatedCount))
                    .font(.system(size: 10))
                    .foregroundStyle(AgentTheme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock, isFirst: Bool) -> some View {
        switch block {
        case .paragraph(let text):
            inlineText(text)
                .font(.system(size: 13))
                .foregroundStyle(AgentTheme.textPrimary)
                .lineSpacing(2.5)
        case .heading(let level, let text):
            // Abschnitts-Überschrift: ab der zweiten mit Hairline darüber —
            // lange Berichte lesen sich als Dokument, nicht als Fließtext.
            VStack(alignment: .leading, spacing: 6) {
                if !isFirst {
                    Rectangle()
                        .fill(AgentTheme.border)
                        .frame(height: 1)
                }
                inlineText(text)
                    .font(.system(size: headingSize(level), weight: .bold))
                    .foregroundStyle(AgentTheme.textPrimary)
            }
            .padding(.top, isFirst ? 0 : 6)
        case .codeFence(_, let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(AgentTheme.textSecondary)
                    .textSelection(.enabled)
                    .lineSpacing(2)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AgentTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(AgentTheme.border, lineWidth: 1))
        case .list(let items, let ordered):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if ordered {
                            Text("\(index + 1).")
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(AgentTheme.textTertiary)
                                .frame(minWidth: 16, alignment: .trailing)
                        } else {
                            Circle()
                                .fill(AgentTheme.textTertiary)
                                .frame(width: 4, height: 4)
                                .padding(.top, 6)
                        }
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
            tableView(raw)
        case .divider:
            Rectangle()
                .fill(AgentTheme.border)
                .frame(height: 1)
                .padding(.vertical, 2)
        }
    }

    // MARK: - Tabelle (Hairlines statt Monospace-Härte)

    @ViewBuilder
    private func tableView(_ raw: String) -> some View {
        if let table = MarkdownTable.parse(raw) {
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 0, verticalSpacing: 0) {
                    if !table.headers.isEmpty {
                        GridRow {
                            ForEach(Array(table.headers.enumerated()), id: \.offset) { _, header in
                                Text(header.uppercased())
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .tracking(0.5)
                                    .foregroundStyle(AgentTheme.textTertiary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 5)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(AgentTheme.surface)
                                    .overlay(Rectangle().frame(height: 1).foregroundStyle(AgentTheme.border), alignment: .bottom)
                            }
                        }
                    }
                    ForEach(Array(table.rows.enumerated()), id: \.offset) { rowIndex, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                inlineText(cell)
                                    .font(.system(size: 12).monospacedDigit())
                                    .foregroundStyle(AgentTheme.textPrimary)
                                    .lineSpacing(1.5)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 5)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .overlay(alignment: .bottom) {
                                        if rowIndex < table.rows.count - 1 {
                                            Rectangle().frame(height: 1).foregroundStyle(AgentTheme.border)
                                        }
                                    }
                            }
                        }
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(AgentTheme.border, lineWidth: 1))
        } else {
            // Unparsebar → Monospace-Fallback, nichts geht verloren.
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
        }
    }

    /// Inline-Markdown (fett, `code`, Links) tolerant auflösen. Zeilenumbrüche
    /// innerhalb des Blocks bleiben erhalten (`inlineOnlyPreservingWhitespace`).
    /// Über den Prozess-Cache — `AttributedString(markdown:)` ist zu teuer,
    /// um pro Body-Aufruf zu laufen.
    private func inlineText(_ raw: String) -> Text {
        if let attributed = MarkdownRenderCache.shared.inlineAttributed(for: raw) {
            return Text(attributed)
        }
        return Text(raw)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 15.5
        case 2: return 14
        default: return 13
        }
    }
}
