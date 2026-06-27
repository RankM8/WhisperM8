import Foundation

// MARK: - Response Model

struct TranscriptionResponse: Codable {
    let text: String
}

// MARK: - Detailed Transcription (CLI: Timestamps + Formate)

/// Gewünschtes API-`response_format`. Der CLI-Pfad nutzt `verbose_json` für
/// Segmente (Whisper-Modelle) bzw. `json` für `gpt-4o-transcribe`.
enum TranscriptionResponseFormat: String {
    case json
    case text
    case verboseJSON = "verbose_json"
    case srt
    case vtt
}

/// Ein Transkript-Segment mit Sekunden-Timestamps (für SRT/VTT/JSON).
struct TranscriptionSegment: Equatable, Codable, Sendable {
    var start: Double
    var end: Double
    var text: String
}

/// Reichhaltiges Transkriptions-Ergebnis: Volltext plus (falls vom Modell
/// geliefert) Segmente, erkannte Sprache und Audio-Dauer.
struct DetailedTranscription: Equatable, Sendable {
    var text: String
    var segments: [TranscriptionSegment]
    var language: String?
    var duration: Double?
}

/// Dekodiert die `verbose_json`-Antwort von OpenAI/Groq.
struct VerboseTranscriptionResponse: Decodable {
    struct Segment: Decodable {
        let start: Double
        let end: Double
        let text: String
    }
    let text: String
    let language: String?
    let duration: Double?
    let segments: [Segment]?
}

// MARK: - Errors

enum TranscriptionError: LocalizedError {
    case invalidResponse
    case apiError(statusCode: Int, message: String)
    case missingAPIKey
    case fileTooLarge(sizeMB: Double)
    case timeout

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from server."
        case .apiError(let statusCode, let message):
            if statusCode == 401 {
                return "Invalid API key. Please check your settings."
            } else if statusCode == 429 {
                return "Too many requests. Please wait a moment."
            } else if statusCode == 413 {
                return "Audio file too large. Maximum is 25 MB."
            }
            return "API error (\(statusCode)): \(message)"
        case .missingAPIKey:
            return "No API key configured. Please enter your API key in settings."
        case .fileTooLarge(let sizeMB):
            return "Audio file too large (\(String(format: "%.1f", sizeMB)) MB). Maximum is 25 MB."
        case .timeout:
            return "Request timed out. Please try a shorter recording."
        }
    }
}
