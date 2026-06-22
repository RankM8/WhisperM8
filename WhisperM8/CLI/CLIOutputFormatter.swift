import Foundation

// MARK: - Ergebnis

/// Zusammengefügtes Endergebnis einer Transkription (über alle Chunks hinweg).
struct CLITranscriptResult {
    var text: String
    var segments: [TranscriptionSegment]
    var language: String?
    var duration: Double?
    var provider: String
    var model: String
}

// MARK: - Stitching

enum CLITranscriptStitcher {
    /// Fügt die Chunk-Ergebnisse zusammen und verschiebt die Segment-Timestamps
    /// um den jeweiligen Chunk-Offset, sodass sie über die volle Länge monoton
    /// sind. Da silence-aware (ohne Overlap) geschnitten wird, ist kein
    /// Dedup nötig — die Texte werden einfach konkateniert.
    static func stitch(_ parts: [(transcription: DetailedTranscription, offset: Double)])
        -> (text: String, segments: [TranscriptionSegment], language: String?, duration: Double?) {
        var texts: [String] = []
        var segments: [TranscriptionSegment] = []
        var language: String?
        var maxEnd: Double = 0

        for part in parts {
            let trimmed = part.transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { texts.append(trimmed) }
            if language == nil { language = part.transcription.language }
            for segment in part.transcription.segments {
                let shifted = TranscriptionSegment(
                    start: segment.start + part.offset,
                    end: segment.end + part.offset,
                    text: segment.text
                )
                segments.append(shifted)
                maxEnd = max(maxEnd, shifted.end)
            }
        }

        return (texts.joined(separator: " "), segments, language, maxEnd > 0 ? maxEnd : nil)
    }
}

// MARK: - Rendering

enum CLIOutputFormatter {
    static func render(_ result: CLITranscriptResult, as format: CLIOutputFormat) -> String {
        switch format {
        case .txt:
            return result.text
        case .srt:
            return renderSRT(result.segments)
        case .vtt:
            return renderVTT(result.segments)
        case .json:
            return renderJSON(result)
        }
    }

    // MARK: SRT

    static func renderSRT(_ segments: [TranscriptionSegment]) -> String {
        var lines: [String] = []
        for (index, segment) in segments.enumerated() {
            lines.append("\(index + 1)")
            lines.append("\(timecode(segment.start, millisSeparator: ",")) --> \(timecode(segment.end, millisSeparator: ","))")
            lines.append(segment.text.trimmingCharacters(in: .whitespaces))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: VTT

    static func renderVTT(_ segments: [TranscriptionSegment]) -> String {
        var lines: [String] = ["WEBVTT", ""]
        for segment in segments {
            lines.append("\(timecode(segment.start, millisSeparator: ".")) --> \(timecode(segment.end, millisSeparator: "."))")
            lines.append(segment.text.trimmingCharacters(in: .whitespaces))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: JSON

    private struct JSONOutput: Encodable {
        let text: String
        let language: String?
        let duration: Double?
        let provider: String
        let model: String
        let segments: [TranscriptionSegment]
    }

    static func renderJSON(_ result: CLITranscriptResult) -> String {
        let payload = JSONOutput(
            text: result.text,
            language: result.language,
            duration: result.duration,
            provider: result.provider,
            model: result.model,
            segments: result.segments
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(payload),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    // MARK: Timecode

    /// `HH:MM:SS,mmm` (SRT) bzw. `HH:MM:SS.mmm` (VTT).
    static func timecode(_ seconds: Double, millisSeparator: String) -> String {
        let clamped = max(0, seconds)
        let totalMillis = Int((clamped * 1000).rounded())
        let millis = totalMillis % 1000
        let totalSeconds = totalMillis / 1000
        let secs = totalSeconds % 60
        let mins = (totalSeconds / 60) % 60
        let hours = totalSeconds / 3600
        return String(format: "%02d:%02d:%02d%@%03d", hours, mins, secs, millisSeparator, millis)
    }
}
