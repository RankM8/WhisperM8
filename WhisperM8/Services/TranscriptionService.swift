import Foundation

// MARK: - Protocol

protocol TranscriptionProvider {
    func transcribe(audioURL: URL, language: String?) async throws -> String
}

// MARK: - OpenAI Service

class OpenAITranscriptionService: TranscriptionProvider {
    private let apiKey: String
    private let baseURL = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    private let model = "gpt-4o-transcribe"

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func transcribe(audioURL: URL, language: String?) async throws -> String {
        let boundary = UUID().uuidString

        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        let audioData = try Data(contentsOf: audioURL)
        let body = buildMultipartBody(
            boundary: boundary,
            model: model,
            audioData: audioData,
            filename: audioURL.lastPathComponent,
            language: language
        )

        let (data, response) = try await URLSession.shared.upload(for: request, from: body)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw TranscriptionError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        let result = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        return result.text
    }
}

// MARK: - Groq Service

class GroqTranscriptionService: TranscriptionProvider {
    private let apiKey: String
    private let baseURL = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
    private let model = "whisper-large-v3"

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func transcribe(audioURL: URL, language: String?) async throws -> String {
        let boundary = UUID().uuidString

        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        let audioData = try Data(contentsOf: audioURL)
        let body = buildMultipartBody(
            boundary: boundary,
            model: model,
            audioData: audioData,
            filename: audioURL.lastPathComponent,
            language: language
        )

        let (data, response) = try await URLSession.shared.upload(for: request, from: body)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw TranscriptionError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        let result = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        return result.text
    }
}

// MARK: - Shared Helpers

private func buildMultipartBody(
    boundary: String,
    model: String,
    audioData: Data,
    filename: String,
    language: String?
) -> Data {
    var body = Data()

    // Model field
    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
    body.append("\(model)\r\n".data(using: .utf8)!)

    // Language field (optional)
    if let language = language, !language.isEmpty {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(language)\r\n".data(using: .utf8)!)
    }

    // Audio file
    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
    body.append("Content-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
    body.append(audioData)
    body.append("\r\n".data(using: .utf8)!)

    // End boundary
    body.append("--\(boundary)--\r\n".data(using: .utf8)!)

    return body
}

// MARK: - Response Model

struct TranscriptionResponse: Codable {
    let text: String
}

// MARK: - Errors

enum TranscriptionError: LocalizedError {
    case invalidResponse
    case apiError(statusCode: Int, message: String)
    case missingAPIKey

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Ungültige Antwort vom Server."
        case .apiError(let statusCode, let message):
            if statusCode == 401 {
                return "Ungültiger API-Key. Bitte überprüfe deine Einstellungen."
            } else if statusCode == 429 {
                return "Zu viele Anfragen. Bitte warte einen Moment."
            }
            return "API-Fehler (\(statusCode)): \(message)"
        case .missingAPIKey:
            return "Kein API-Key konfiguriert. Bitte gib deinen API-Key in den Einstellungen ein."
        }
    }
}
