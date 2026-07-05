import SwiftUI

/// Die stille Aktivitätszeile einer Runde („▸ 14 Tool-Aufrufe · 3 Dateien ·
/// 1 Fehler · 6 Min") — aufklappbar zu den Detail-Steps. Im Live-Modus
/// aktualisiert die Summary in place, statt Zeilen anzuhängen (ruhige View).
struct TimelineActivityRow: View {
    let steps: [TranscriptStep]
    let stats: TranscriptActivityStats
    let isLive: Bool

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.28)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    summaryText
                }
                .font(.system(size: 11.5))
                .foregroundStyle(AgentTheme.textTertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(steps) { step in
                        TimelineStepRow(step: step)
                    }
                }
                .padding(.leading, 14)
                .padding(.top, 8)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(AgentTheme.border)
                        .frame(width: 2)
                        .padding(.top, 8)
                }
                .transition(.opacity)
            }
        }
    }

    /// Summary mit rot eingefärbtem Fehler-Anteil (Text-Konkatenation).
    private var summaryText: Text {
        var parts: [Text] = []
        parts.append(Text(stats.toolCallCount == 1 ? "1 Tool-Aufruf" : "\(stats.toolCallCount) Tool-Aufrufe"))
        if stats.fileCount > 0 {
            parts.append(Text(stats.fileCount == 1 ? "1 Datei" : "\(stats.fileCount) Dateien"))
        }
        if stats.errorCount > 0 {
            parts.append(Text("\(stats.errorCount) Fehler").foregroundStyle(AgentTheme.statusError))
        }
        if stats.thinkingCount > 0 {
            parts.append(Text("Thinking (\(stats.thinkingCount))"))
        }
        if let duration = stats.duration {
            parts.append(Text(Self.durationLabel(duration)))
        }
        if isLive {
            parts.append(Text("läuft …").foregroundStyle(AgentTheme.statusWorking))
        }
        return parts.dropFirst().reduce(parts[0]) { $0 + Text(" · ") + $1 }
    }

    static func durationLabel(_ duration: TimeInterval) -> String {
        if duration < 90 { return "\(Int(duration.rounded())) s" }
        return "\(Int((duration / 60).rounded())) Min"
    }
}

/// Eine Detail-Zeile der Aktivität: Op-Glyph (W/E/R/$) + Subject + Meta.
/// Klick klappt den VOLLEN Input/Result des Steps auf — die Timeline
/// versteckt nichts, sie sortiert nur.
struct TimelineStepRow: View {
    let step: TranscriptStep

    @State private var isExpanded = false
    @State private var isHovering = false

    /// Render-Deckel pro Pre-Block; der komplette Inhalt bleibt über die
    /// Roh-Ansicht erreichbar.
    private static let maxDetailCharacters = 8000

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) {
                    isExpanded.toggle()
                }
            } label: {
                headerRow
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }

            if isExpanded {
                expandedDetail
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 1.5)
    }

    // MARK: - Kopfzeile

    @ViewBuilder
    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text(glyph)
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .foregroundStyle(glyphColor)
                .frame(width: 12, alignment: .center)
            Text(title)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(step.isError ? AgentTheme.statusError : (isHovering ? AgentTheme.textPrimary : AgentTheme.textSecondary))
                .lineLimit(isExpanded ? 3 : 1)
                .truncationMode(.middle)
            if let meta {
                Text(meta)
                    .font(.system(size: 10))
                    .foregroundStyle(step.isError ? AgentTheme.statusError : AgentTheme.textTertiary)
                    .lineLimit(1)
            }
        }
    }

    private var glyph: String {
        switch step.kind {
        case .tool(let tool): return tool.op.glyph
        case .thinking: return "∴"
        case .note: return "¶"
        case .system: return "!"
        }
    }

    private var glyphColor: Color {
        switch step.kind {
        case .tool(let tool):
            if tool.isError { return AgentTheme.statusError }
            switch tool.op {
            case .write: return AgentTheme.accentDiffPos
            case .edit: return AgentTheme.accent
            case .bash: return AgentTheme.statusAwaiting
            case .read, .search, .web, .task, .mcp, .other: return AgentTheme.textTertiary
            }
        case .thinking, .note: return AgentTheme.textTertiary
        case .system: return AgentTheme.statusAwaiting
        }
    }

    private var title: String {
        switch step.kind {
        case .tool(let tool): return tool.subject
        case .thinking: return "Thinking"
        case .note(let text): return text.replacingOccurrences(of: "\n", with: " ")
        case .system(let text): return text.replacingOccurrences(of: "\n", with: " ")
        }
    }

    private var meta: String? {
        if case .tool(let tool) = step.kind { return tool.detail }
        return nil
    }

    // MARK: - Aufklappung (voller Input/Result)

    @ViewBuilder
    private var expandedDetail: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch step.kind {
            case .tool(let tool):
                if !tool.input.isEmpty {
                    preBlock(label: "\(tool.name) — Input", content: tool.input, isError: false)
                }
                if let result = tool.result, !result.isEmpty {
                    preBlock(label: tool.isError ? "Ergebnis (Fehler)" : "Ergebnis", content: result, isError: tool.isError)
                }
                if tool.input.isEmpty && (tool.result ?? "").isEmpty {
                    Text("Kein Input/Output aufgezeichnet.")
                        .font(.system(size: 10))
                        .foregroundStyle(AgentTheme.textTertiary)
                }
            case .thinking(let text):
                preBlock(label: "Thinking", content: text, isError: false)
            case .note(let text):
                TranscriptMarkdownView(text: text)
                    .padding(.vertical, 2)
            case .system(let text):
                preBlock(label: "System", content: text, isError: false)
            }
        }
        .padding(.leading, 21)
    }

    @ViewBuilder
    private func preBlock(label: String, content: String, isError: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.4)
                .textCase(.uppercase)
                .foregroundStyle(isError ? AgentTheme.statusError : AgentTheme.textTertiary)
            Text(String(content.prefix(Self.maxDetailCharacters)))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(AgentTheme.textSecondary)
                .textSelection(.enabled)
                .lineSpacing(2)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AgentTheme.background)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isError ? AgentTheme.statusError.opacity(0.25) : AgentTheme.border, lineWidth: 1)
                )
            if content.count > Self.maxDetailCharacters {
                Text("… \(content.count - Self.maxDetailCharacters) weitere Zeichen — vollständig in der Roh-Ansicht")
                    .font(.system(size: 9.5))
                    .foregroundStyle(AgentTheme.textTertiary)
            }
        }
    }
}
