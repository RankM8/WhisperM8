import Foundation

// MARK: - Protocol

protocol TranscriptionServiceProtocol {
    func transcribe(audioURL: URL, language: String?, audioDuration: TimeInterval?) async throws -> String
}
