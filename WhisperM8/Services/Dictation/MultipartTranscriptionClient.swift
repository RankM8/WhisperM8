import Foundation

// MARK: - Timeout Calculation

/// Calculate appropriate timeout based on audio duration
/// - Base timeout: 180 seconds (3 minutes for API overhead)
/// - Per minute of audio: 120 seconds (2 minutes processing time)
/// - Minimum: 180 seconds (3 minutes)
/// - Maximum: 900 seconds (15 minutes)
func calculateTimeout(for audioDuration: TimeInterval?) -> TimeInterval {
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

// MARK: - Multipart Client

final class MultipartTranscriptionClient: TranscriptionServiceProtocol {
    private let apiKey: String
    private let config: ProviderConfig
    /// Phase-3-Test-Seam: Default erzeugt die echte Long-Timeout-Session;
    /// Tests reichen eine URLProtocol-gestubte Session herein.
    private let sessionProvider: (TimeInterval) -> URLSession

    init(
        apiKey: String,
        config: ProviderConfig,
        sessionProvider: @escaping (TimeInterval) -> URLSession = { createLongTimeoutSession(timeout: $0) }
    ) {
        self.apiKey = apiKey
        self.config = config
        self.sessionProvider = sessionProvider
    }

    func transcribe(audioURL: URL, language: String?, audioDuration: TimeInterval? = nil) async throws -> String {
        // Bestehender Diktat-Pfad: response_format wird bewusst NICHT gesetzt
        // (Provider-Default = json mit `{text}`), damit das Verhalten 1:1 bleibt.
        let data = try await uploadTranscription(
            audioURL: audioURL,
            language: language,
            responseFormat: nil,
            audioDuration: audioDuration
        )

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

    /// CLI-Pfad: fordert je nach gewünschtem Ausgabeformat Segmente an
    /// (`verbose_json`) und liefert Text + Timestamps zurück. Whisper-Modelle
    /// liefern Segmente; `gpt-4o-transcribe` kann nur `json`/`text`.
    func transcribeDetailed(
        audioURL: URL,
        language: String?,
        responseFormat: TranscriptionResponseFormat,
        audioDuration: TimeInterval? = nil
    ) async throws -> DetailedTranscription {
        let data = try await uploadTranscription(
            audioURL: audioURL,
            language: language,
            responseFormat: responseFormat,
            audioDuration: audioDuration
        )

        switch responseFormat {
        case .verboseJSON:
            let verbose: VerboseTranscriptionResponse
            do {
                verbose = try JSONDecoder().decode(VerboseTranscriptionResponse.self, from: data)
            } catch {
                let responseText = String(data: data, encoding: .utf8) ?? "Unable to decode"
                Logger.debug("ERROR decoding verbose response: \(error)")
                Logger.debug("Raw response: \(responseText.prefix(500))")
                throw error
            }
            return DetailedTranscription(
                text: verbose.text,
                segments: (verbose.segments ?? []).map {
                    TranscriptionSegment(start: $0.start, end: $0.end, text: $0.text)
                },
                language: verbose.language,
                duration: verbose.duration
            )
        case .json:
            let result = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
            return DetailedTranscription(text: result.text, segments: [], language: nil, duration: nil)
        case .text, .srt, .vtt:
            // Provider liefert hier den fertigen Body (Plaintext bzw. SRT/VTT);
            // wir reichen ihn als `text` durch, ohne Segmente.
            let body = String(data: data, encoding: .utf8) ?? ""
            return DetailedTranscription(text: body, segments: [], language: nil, duration: nil)
        }
    }

    /// Gemeinsamer HTTP-Upload für Diktat- und CLI-Pfad. Liefert den rohen
    /// 200-Response-Body; die Dekodierung übernimmt der jeweilige Aufrufer.
    private func uploadTranscription(
        audioURL: URL,
        language: String?,
        responseFormat: TranscriptionResponseFormat?,
        audioDuration: TimeInterval?
    ) async throws -> Data {
        let boundary = UUID().uuidString
        let timeout = calculateTimeout(for: audioDuration)

        Logger.debug("\(config.name) transcription starting...")
        Logger.debug("- Timeout: \(Int(timeout))s")
        Logger.debug("- Audio duration: \(Int(audioDuration ?? 0))s")
        Logger.debug("- Model: \(config.model)")

        var request = URLRequest(url: config.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout

        // Größen-Check über Datei-Attribute statt Voll-Load — die Audio-Daten
        // werden für den Upload nie komplett in den Speicher geladen.
        let fileSize: Int
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: audioURL.path)
            fileSize = (attributes[.size] as? Int) ?? 0
        } catch {
            Logger.debug("ERROR reading audio file attributes: \(error)")
            throw error
        }

        let fileSizeMB = Double(fileSize) / (1024 * 1024)
        Logger.debug("- File size: \(String(format: "%.2f", fileSizeMB)) MB")

        if fileSize > config.maxFileSizeBytes {
            Logger.debug("ERROR: File too large!")
            throw TranscriptionError.fileTooLarge(sizeMB: fileSizeMB)
        }

        // Multipart-Body in eine Temp-Datei streamen und via
        // `upload(for:fromFile:)` hochladen: URLSession liest die Datei dann
        // selbst gepuffert, statt dass wir Audio + Body doppelt im RAM halten.
        let bodyFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisperm8-upload-\(UUID().uuidString).tmp")
        // defer VOR dem Writer-Call registrieren: Wirft der Writer mittendrin
        // (z. B. Platte voll bei der Chunk-Copy), darf die teilgeschriebene
        // Body-Datei nicht liegen bleiben.
        defer { try? FileManager.default.removeItem(at: bodyFileURL) }
        try MultipartFormDataFileWriter.writeAudioTranscriptionBody(
            to: bodyFileURL,
            boundary: boundary,
            model: config.model,
            audioFileURL: audioURL,
            filename: audioURL.lastPathComponent,
            language: language,
            responseFormat: responseFormat?.rawValue
        )

        Logger.debug("Uploading to \(config.name)... (timeout: \(Int(timeout))s)")
        let startTime = Date()

        // Pro Call eine Session mit passendem Timeout; ohne Invalidate würde
        // jede davon bis zum App-Ende weiterleben.
        let session = sessionProvider(timeout)
        defer { session.finishTasksAndInvalidate() }
        // Der async-Upload ist kooperativ cancelbar: Wird der umgebende Task
        // gecancelt (Cancel-Button/ESC während "Transcribing…"), bricht
        // URLSession den Request ab und wirft `URLError(.cancelled)`.
        let (data, response) = try await session.upload(for: request, fromFile: bodyFileURL)

        let elapsed = Date().timeIntervalSince(startTime)
        Logger.debug("Response received in \(String(format: "%.1f", elapsed))s")

        guard let httpResponse = response as? HTTPURLResponse else {
            Logger.debug("ERROR: Invalid response type")
            throw TranscriptionError.invalidResponse
        }

        Logger.debug("HTTP Status: \(httpResponse.statusCode)")

        guard httpResponse.statusCode == 200 else {
            let errorBody = sanitizedErrorBody(data)
            Logger.debug("ERROR: \(httpResponse.statusCode) - \(errorBody)")
            throw TranscriptionError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        return data
    }

    private func sanitizedErrorBody(_ data: Data) -> String {
        let rawBody = String(data: data, encoding: .utf8) ?? "Unknown error"
        let trimmed = rawBody.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(500))
    }
}

// MARK: - Shared Helpers

/// Schreibt den multipart/form-data-Body in eine Datei, ohne die Audio-Daten
/// komplett in den Speicher zu laden (Chunk-Copy in 1-MiB-Schritten). Das
/// Envelope-Format ist identisch zum früheren In-Memory-Builder.
struct MultipartFormDataFileWriter {
    static func writeAudioTranscriptionBody(
        to destinationURL: URL,
        boundary: String,
        model: String,
        audioFileURL: URL,
        filename: String,
        language: String?,
        responseFormat: String? = nil
    ) throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: destinationURL)
        guard fileManager.createFile(atPath: destinationURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let output = try FileHandle(forWritingTo: destinationURL)
        defer { try? output.close() }

        var prefix = Data()
        prefix.append(Data("--\(boundary)\r\n".utf8))
        prefix.append(Data("Content-Disposition: form-data; name=\"model\"\r\n\r\n".utf8))
        prefix.append(Data("\(model)\r\n".utf8))

        if let language, !language.isEmpty {
            prefix.append(Data("--\(boundary)\r\n".utf8))
            prefix.append(Data("Content-Disposition: form-data; name=\"language\"\r\n\r\n".utf8))
            prefix.append(Data("\(language)\r\n".utf8))
        }

        // `response_format` wird nur gesetzt, wenn explizit angefordert (CLI-Pfad).
        // Der Diktat-Pfad übergibt nil → Provider-Default (json) → Body unverändert.
        if let responseFormat, !responseFormat.isEmpty {
            prefix.append(Data("--\(boundary)\r\n".utf8))
            prefix.append(Data("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".utf8))
            prefix.append(Data("\(responseFormat)\r\n".utf8))
        }

        prefix.append(Data("--\(boundary)\r\n".utf8))
        prefix.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8))
        prefix.append(Data("Content-Type: audio/m4a\r\n\r\n".utf8))
        try output.write(contentsOf: prefix)

        let input = try FileHandle(forReadingFrom: audioFileURL)
        defer { try? input.close() }
        while true {
            // autoreleasepool hält den Speicher flach: `read(upToCount:)`
            // liefert autoreleased NSData-Puffer.
            let chunk = try autoreleasepool { try input.read(upToCount: 1024 * 1024) }
            guard let chunk, !chunk.isEmpty else { break }
            try output.write(contentsOf: chunk)
        }

        try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
    }
}

struct ProviderConfig: Sendable {
    let name: String
    let endpoint: URL
    let model: String
    let maxFileSizeBytes: Int

    static func openAI(model: String) -> ProviderConfig {
        ProviderConfig(
            name: "OpenAI",
            endpoint: URL(string: "https://api.openai.com/v1/audio/transcriptions")!,
            model: model,
            maxFileSizeBytes: 25 * 1024 * 1024
        )
    }

    static func groq(model: String) -> ProviderConfig {
        ProviderConfig(
            name: "Groq",
            endpoint: URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!,
            model: model,
            maxFileSizeBytes: 25 * 1024 * 1024
        )
    }
}
