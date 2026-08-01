import Foundation

/// Eine Zeile des gerenderten Verlaufs. Bewusst NUR Text + Stilkennung:
/// Farben, Schrift und Zeilenhöhe entscheidet die View — der Renderer
/// bleibt AppKit-frei und damit rein unit-testbar.
struct TranscriptTextLine: Equatable {
    enum Style: Equatable {
        /// Nutzer-Prompt (`❯ …`).
        case prompt
        /// Antworttext des Agenten (`⏺ …`).
        case answer
        /// Tool-Aufruf (`⏺ Read(datei.swift)`).
        case tool
        /// Ergebnis eines Tool-Aufrufs (`⎿ …`), eingerückt und gedimmt.
        case toolOutput
        /// Fehlgeschlagenes Tool-Ergebnis.
        case toolError
        /// Thinking-Block.
        case thinking
        /// Hinweiszeilen des Renderers („… +38 Zeilen", Bild-Platzhalter,
        /// System-Nachrichten).
        case meta
        /// Trennung zwischen zwei Nachrichten.
        case blank
    }

    var style: Style
    var text: String

    init(_ style: Style, _ text: String) {
        self.style = style
        self.text = text
    }
}

/// Rendert ein `AgentChatTranscript` als zeilenweisen Text im Stil der
/// Claude-Code-CLI: Prompt mit `❯`, Antwort mit `⏺`, Tool-Aufrufe mit dem
/// klassifizierten Kurz-Subject, Ergebnisse eingerückt mit `⎿`.
///
/// **Warum zeilenweise und nicht als View-Baum:** Die frühere Chat-Ansicht
/// baute pro Nachricht eine SwiftUI-Hierarchie. Deren Layout-Kosten wachsen
/// mit dem Inhalt statt mit der sichtbaren Fläche — bei sechs Grid-Panes mit
/// großen Transcripts hat das die App dauerhaft eingefroren (Vorfall
/// 01.08.2026: Main Thread endlos in `StackLayout.prioritize`). Ein flacher
/// Zeilenstrom lässt sich als EIN `NSTextView` mit fester Zeilenhöhe
/// darstellen; dann ist die Gesamthöhe `Zeilen × Zeilenhöhe` — exakt bekannt,
/// ohne irgendetwas vorausberechnen zu müssen.
///
/// Der Renderer ist synchron und rein; er läuft off-main
/// (`TranscriptTextDocument.build`).
enum TranscriptTextRenderer {
    /// Kürzungen. Sie betreffen AUSSCHLIESSLICH Tool-Ausgaben — genau wie
    /// die CLI, die lange Ergebnisse als „… +N Zeilen" zusammenfasst.
    /// Prompts, Antworttexte und Thinking bleiben immer vollständig; die
    /// alten Deckel (2000 Zeichen mitten im Fließtext) sind ersatzlos weg.
    struct Limits: Equatable {
        var toolOutputLines: Int
        var toolOutputChars: Int

        static let `default` = Limits(toolOutputLines: 12, toolOutputChars: 4000)
    }

    static func render(_ transcript: AgentChatTranscript, limits: Limits = .default) -> [TranscriptTextLine] {
        var lines: [TranscriptTextLine] = []
        lines.reserveCapacity(transcript.messages.count * 6)

        for message in transcript.messages {
            let before = lines.count
            for block in message.blocks {
                append(block: block, role: message.role, to: &lines, limits: limits)
            }
            // Nur wenn die Nachricht wirklich etwas beigetragen hat — leere
            // Blöcke (z. B. reine Metadaten-Messages) erzeugen sonst
            // Leerzeilen-Wüsten.
            if lines.count > before {
                lines.append(TranscriptTextLine(.blank, ""))
            }
        }

        // Abschließende Leerzeile trägt nichts.
        if lines.last?.style == .blank { lines.removeLast() }
        return lines
    }

    // MARK: - Blöcke

    private static func append(
        block: AgentChatBlock,
        role: AgentChatMessage.Role,
        to lines: inout [TranscriptTextLine],
        limits: Limits
    ) {
        switch block {
        case .text(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            switch role {
            case .user:
                appendWrapped(trimmed, marker: "❯ ", style: .prompt, to: &lines)
            case .assistant:
                appendWrapped(trimmed, marker: "⏺ ", style: .answer, to: &lines)
            case .system:
                appendWrapped(trimmed, marker: "· ", style: .meta, to: &lines)
            }

        case .thinking(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            appendWrapped(trimmed, marker: "✻ ", style: .thinking, to: &lines)

        case .toolUse(let name, let input):
            let classified = ToolCallClassifier.classify(name: name, input: input)
            let subject = singleLine(classified.subject)
            let detail = classified.detail.map { " · " + singleLine($0) } ?? ""
            lines.append(TranscriptTextLine(.tool, "⏺ \(name)(\(subject))\(detail)"))

        case .toolResult(let content, let isError):
            appendToolOutput(content, isError: isError, to: &lines, limits: limits)

        case .imagePlaceholder(let mediaType, let byteSize):
            let size = ByteCountFormatter.string(fromByteCount: Int64(byteSize), countStyle: .file)
            lines.append(TranscriptTextLine(.meta, "  ⎿  [Bild · \(mediaType) · \(size)]"))
        }
    }

    /// Mehrzeiligen Text mit Marker in der ersten Zeile ausgeben; Folgezeilen
    /// werden auf Markerbreite eingerückt, damit der Block optisch zusammen
    /// bleibt (genau wie in der CLI).
    private static func appendWrapped(
        _ text: String,
        marker: String,
        style: TranscriptTextLine.Style,
        to lines: inout [TranscriptTextLine]
    ) {
        let indent = String(repeating: " ", count: marker.count)
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(raw)
            lines.append(TranscriptTextLine(style, (index == 0 ? marker : indent) + line))
        }
    }

    /// Tool-Ergebnis wie die CLI: erste Zeilen zeigen, Rest zählen. Die
    /// vollständige Ausgabe steckt weiterhin im Transcript — hier wird nur
    /// die Darstellung gerafft, damit ein `git log` mit 4000 Zeilen nicht den
    /// ganzen Verlauf zuschüttet.
    private static func appendToolOutput(
        _ content: String,
        isError: Bool,
        to lines: inout [TranscriptTextLine],
        limits: Limits
    ) {
        let style: TranscriptTextLine.Style = isError ? .toolError : .toolOutput
        let clipped = content.count > limits.toolOutputChars
            ? String(content.prefix(limits.toolOutputChars))
            : content
        let all = clipped.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let meaningful = all.drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !meaningful.isEmpty else { return }

        let shown = meaningful.prefix(limits.toolOutputLines)
        for (index, line) in shown.enumerated() {
            lines.append(TranscriptTextLine(style, (index == 0 ? "  ⎿  " : "     ") + line))
        }

        let hiddenLines = meaningful.count - shown.count
        let hiddenChars = content.count - clipped.count
        if hiddenLines > 0 || hiddenChars > 0 {
            var hint = "     … "
            if hiddenLines > 0 {
                hint += "+\(hiddenLines) \(hiddenLines == 1 ? "Zeile" : "Zeilen")"
            }
            if hiddenChars > 0 {
                hint += hiddenLines > 0 ? ", " : ""
                hint += "+\(hiddenChars) Zeichen"
            }
            lines.append(TranscriptTextLine(.meta, hint))
        }
    }

    /// Subjects dürfen die Zeilenstruktur nicht sprengen — ein
    /// mehrzeiliges Bash-Kommando wird zu einer Zeile mit `↵`-Marken.
    private static func singleLine(_ text: String) -> String {
        let joined = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ↵ ")
        return joined.count > 120 ? String(joined.prefix(120)) + "…" : joined
    }
}
