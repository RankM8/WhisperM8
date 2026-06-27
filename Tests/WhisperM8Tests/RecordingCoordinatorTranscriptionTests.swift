import Foundation
import XCTest
@testable import WhisperM8

private struct SentinelError: Error {}

/// Fake-Service, der vor der Delivery wirft — so bleibt der Test auf den
/// Resolver-/Factory-Seam beschränkt (keine Clipboard-/Overlay-Seiteneffekte).
private final class ThrowingTranscriptionService: TranscriptionServiceProtocol {
    func transcribe(audioURL: URL, language: String?, audioDuration: TimeInterval?) async throws -> String {
        throw SentinelError()
    }
}

/// Phase-3 Test-Seam (S5): verifiziert die Resolver-DI von
/// `transcribeAndDeliver` — ohne Keychain/Settings/Netzwerk. Beide Pfade werfen
/// vor der Delivery, lesen `AppState.shared` also nur (keine Mutation).
@MainActor
final class RecordingCoordinatorTranscriptionTests: XCTestCase {
    private func tempAudio() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-\(UUID().uuidString).m4a")
        try Data([0, 1, 2, 3]).write(to: url)
        return url
    }

    func testThrowsMissingAPIKeyWhenResolverReturnsNil() async throws {
        let audio = try tempAudio()
        defer { try? FileManager.default.removeItem(at: audio) }

        var factoryCalled = false
        let coordinator = RecordingCoordinator(
            appState: .shared,
            providerResolver: { .openai },
            modelResolver: { .openai_gpt4o },
            apiKeyResolver: { _ in nil },
            transcriberFactory: { _, _, _ in
                factoryCalled = true
                return ThrowingTranscriptionService()
            }
        )

        do {
            try await coordinator.transcribeAndDeliver(
                audioURL: audio, audioDuration: 1, outputMode: .defaultMode(), contextBundle: .empty
            )
            XCTFail("Expected TranscriptionError.missingAPIKey")
        } catch TranscriptionError.missingAPIKey {
            // erwartet
        }
        XCTAssertFalse(factoryCalled, "Ohne API-Key darf die Service-Factory nicht aufgerufen werden")
    }

    func testResolverWiringPassesProviderModelKeyToFactory() async throws {
        let audio = try tempAudio()
        defer { try? FileManager.default.removeItem(at: audio) }

        var recorded: (TranscriptionProvider, TranscriptionModel, String)?
        let coordinator = RecordingCoordinator(
            appState: .shared,
            providerResolver: { .groq },
            modelResolver: { .groq_whisper_v3 },
            apiKeyResolver: { _ in "secret-key" },
            transcriberFactory: { provider, model, apiKey in
                recorded = (provider, model, apiKey)
                return ThrowingTranscriptionService()
            }
        )

        do {
            try await coordinator.transcribeAndDeliver(
                audioURL: audio, audioDuration: 1, outputMode: .defaultMode(), contextBundle: .empty
            )
            XCTFail("Expected SentinelError from fake service")
        } catch is SentinelError {
            // erwartet — Fake-Service wirft vor der Delivery
        }
        XCTAssertEqual(recorded?.0, .groq)
        XCTAssertEqual(recorded?.1, .groq_whisper_v3)
        XCTAssertEqual(recorded?.2, "secret-key")
    }
}
