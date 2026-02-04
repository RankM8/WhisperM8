import Foundation

// MARK: - Protocol

protocol TranscriptionProvider {
    func transcribe(audioURL: URL, language: String?, audioDuration: TimeInterval?) async throws -> String
}

// MARK: - Timeout Calculation

/// Calculate appropriate timeout based on audio duration
/// - Base timeout: 180 seconds (3 minutes for API overhead)
/// - Per minute of audio: 120 seconds (2 minutes processing time)
/// - Minimum: 180 seconds (3 minutes)
/// - Maximum: 900 seconds (15 minutes)
private func calculateTimeout(for audioDuration: TimeInterval?) -> TimeInterval {
    let baseDuration: TimeInterval = 180
    let perMinute: TimeInterval = 120
    let minimum: TimeInterval = 180
    let maximum: TimeInterval = 900

    guard let duration = audioDuration, duration > 0 else {
        return minimum
    }

    let minutes = duration / 60.0
    let calculated = baseDuration + (minutes * perMinute)
    return min(max(calculated, minimum), maximum)
}

// MARK: - Custom URLSession

/// Create a URLSession with extended timeouts (URLSession.shared has 60s default which is too short)
private func createLongTimeoutSession(timeout: TimeInterval) -> URLSession {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = timeout
    config.timeoutIntervalForResource = timeout * 2  // Double for resource timeout
    return URLSession(configuration: config)
}

// MARK: - OpenAI Models

enum OpenAIModel: String, CaseIterable {
    case gpt4oTranscribe = "gpt-4o-transcribe"
    case whisper1 = "whisper-1"

    var displayName: String {
        switch self {
        case .gpt4oTranscribe: return "GPT-4o Transcribe (Schneller)"
        case .whisper1: return "Whisper (Stabiler)"
        }
    }

    var description: String {
        switch self {
        case .gpt4oTranscribe: return "Neuestes Modell, sehr schnell bei kurzen Audios"
        case .whisper1: return "Bewährtes Modell, zuverlässig bei langen Audios"
        }
    }
}

// MARK: - OpenAI Service

class OpenAITranscriptionService: TranscriptionProvider {
    private let apiKey: String
    private let model: OpenAIModel
    private let baseURL = URL(string: "https://api.openai.com/v1/audio/transcriptions")!

    init(apiKey: String, model: OpenAIModel = .gpt4oTranscribe) {
        self.apiKey = apiKey
        self.model = model
    }

    func transcribe(audioURL: URL, language: String?, audioDuration: TimeInterval? = nil) async throws -> String {
        let boundary = UUID().uuidString
        let timeout = calculateTimeout(for: audioDuration)

        Logger.debug("OpenAI transcription starting...")
        Logger.debug("- Timeout: \(Int(timeout))s")
        Logger.debug("- Audio duration: \(Int(audioDuration ?? 0))s")
        Logger.debug("- Model: \(model.rawValue)")

        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout

        let audioData: Data
        do {
            audioData = try Data(contentsOf: audioURL)
        } catch {
            Logger.debug("ERROR reading audio file: \(error)")
            throw error
        }

        let fileSizeMB = Double(audioData.count) / (1024 * 1024)
        Logger.debug("- File size: \(String(format: "%.2f", fileSizeMB)) MB")

        // Check file size limit (25 MB)
        if audioData.count > 25 * 1024 * 1024 {
            Logger.debug("ERROR: File too large!")
            throw TranscriptionError.fileTooLarge(sizeMB: fileSizeMB)
        }

        let body = buildMultipartBody(
            boundary: boundary,
            model: model.rawValue,
            audioData: audioData,
            filename: audioURL.lastPathComponent,
            language: language
        )

        Logger.debug("Uploading to OpenAI... (timeout: \(Int(timeout))s)")
        let startTime = Date()

        // Use custom session with extended timeouts (URLSession.shared has 60s default!)
        let session = createLongTimeoutSession(timeout: timeout)
        let (data, response) = try await session.upload(for: request, from: body)

        let elapsed = Date().timeIntervalSince(startTime)
        Logger.debug("Response received in \(String(format: "%.1f", elapsed))s")

        guard let httpResponse = response as? HTTPURLResponse else {
            Logger.debug("ERROR: Invalid response type")
            throw TranscriptionError.invalidResponse
        }

        Logger.debug("HTTP Status: \(httpResponse.statusCode)")

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            Logger.debug("ERROR: \(httpResponse.statusCode) - \(errorBody)")
            throw TranscriptionError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        let result: TranscriptionResponse
        do {
            result = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        } catch {
            let responseText = String(data: data, encoding: .utf8) ?? "Unable to decode"
            Logger.debug("ERROR decoding response: \(error)")
            Logger.debug("Raw response: \(responseText.prefix(500))")
            throw error
        }

        Logger.debug("SUCCESS! Text length: \(result.text.count) characters")
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

    func transcribe(audioURL: URL, language: String?, audioDuration: TimeInterval? = nil) async throws -> String {
        let boundary = UUID().uuidString
        let timeout = calculateTimeout(for: audioDuration)

        Logger.debug("Groq transcription starting...")
        Logger.debug("- Timeout: \(Int(timeout))s")
        Logger.debug("- Audio duration: \(Int(audioDuration ?? 0))s")
        Logger.debug("- Model: \(model)")

        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout

        let audioData = try Data(contentsOf: audioURL)
        let fileSizeMB = Double(audioData.count) / (1024 * 1024)
        Logger.debug("- File size: \(String(format: "%.2f", fileSizeMB)) MB")

        // Check file size limit (25 MB for free tier, 100 MB for paid via URL)
        if audioData.count > 25 * 1024 * 1024 {
            throw TranscriptionError.fileTooLarge(sizeMB: fileSizeMB)
        }

        let body = buildMultipartBody(
            boundary: boundary,
            model: model,
            audioData: audioData,
            filename: audioURL.lastPathComponent,
            language: language
        )

        Logger.debug("Uploading to Groq... (timeout: \(Int(timeout))s)")
        let startTime = Date()

        // Use custom session with extended timeouts
        let session = createLongTimeoutSession(timeout: timeout)
        let (data, response) = try await session.upload(for: request, from: body)

        let elapsed = Date().timeIntervalSince(startTime)
        Logger.debug("Response received in \(String(format: "%.1f", elapsed))s")

        guard let httpResponse = response as? HTTPURLResponse else {
            Logger.debug("ERROR: Invalid response type")
            throw TranscriptionError.invalidResponse
        }

        Logger.debug("HTTP Status: \(httpResponse.statusCode)")

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            Logger.debug("ERROR: \(httpResponse.statusCode) - \(errorBody)")
            throw TranscriptionError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        let result = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        Logger.debug("SUCCESS! Text length: \(result.text.count) characters")
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
