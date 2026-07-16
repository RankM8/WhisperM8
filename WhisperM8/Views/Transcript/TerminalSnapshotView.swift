import SwiftUI

/// Read-only-Anzeige eines persistierten Terminal-Stands (Stufe 1:
/// Plaintext, monospace). Zeigt beendete Chats so, wie das Terminal beim
/// Prozessende stand — inklusive CLI-Hinweis wie
/// `Resume this session with: claude --resume <id>`.
///
/// Render-Topologie bewusst gedeckelt (Lehre aus dem Transcript-Hang):
/// der Snapshot ist auf 2000 Zeilen begrenzt (TerminalSnapshotStore) und
/// wird in Blöcke à 50 Zeilen gestückelt — LazyVStack materialisiert nur
/// sichtbare Blöcke, kein Mega-Text im CoreText-Layout.
struct TerminalSnapshotView: View {
    let snapshot: TerminalSnapshot

    /// Zeilen pro Text-Block (Layout-Granularität der LazyVStack).
    private static let linesPerChunk = 50

    private var chunks: [String] {
        let lines = snapshot.text.components(separatedBy: "\n")
        return stride(from: 0, to: lines.count, by: Self.linesPerChunk).map { start in
            lines[start..<min(start + Self.linesPerChunk, lines.count)].joined(separator: "\n")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            captureInfoStrip
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(chunks.enumerated()), id: \.offset) { _, chunk in
                        Text(chunk)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(AgentTheme.textPrimary)
                            .textSelection(.enabled)
                            .lineSpacing(1.5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom)
        }
        .background(AgentTheme.background)
    }

    /// Schmale Info-Zeile: wann dieser Terminal-Stand eingefroren wurde.
    private var captureInfoStrip: some View {
        HStack(spacing: 6) {
            Image(systemName: "camera")
                .font(.system(size: 9))
            Text("Terminal-Stand vom \(Self.captureFormatter.string(from: snapshot.capturedAt))")
                .font(.system(size: 10.5))
            Spacer()
        }
        .foregroundStyle(AgentTheme.textTertiary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(AgentTheme.surface.opacity(0.6))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(AgentTheme.border),
            alignment: .bottom
        )
    }

    private static let captureFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}
