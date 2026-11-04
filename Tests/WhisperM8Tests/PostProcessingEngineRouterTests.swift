import Foundation
import XCTest
@testable import WhisperM8

/// Weiche der Diktat-Nacharbeit: welcher Modus welchen Weg nimmt und wann
/// die Codex-CLI für das GPT-Backend einspringt.
final class PostProcessingEngineRouterTests: XCTestCase {
    private final class FakeProcessor: PostProcessing, @unchecked Sendable {
        var result: Result<PostProcessingRun, Error>
        private(set) var calls = 0

        init(_ result: Result<PostProcessingRun, Error>) {
            self.result = result
        }

        func process(rawText: String, mode: OutputMode, language: String, contextBundle: TranscriptContextBundle) async throws -> String {
            try await processRun(rawText: rawText, mode: mode, language: language, contextBundle: contextBundle).text
        }

        func processRun(rawText: String, mode: OutputMode, language: String, contextBundle: TranscriptContextBundle) async throws -> PostProcessingRun {
            calls += 1
            return try result.get()
        }
    }

    private func mode(projectAccess: ProjectAccessPolicy = .off) -> OutputMode {
        OutputMode(
            id: OutputMode.slackID,
            name: "Slack",
            shortLabel: "Slack",
            kind: .builtIn,
            templateID: PostProcessingTemplate.slackID,
            isEnabled: true,
            isDefault: false,
            projectAccess: projectAccess
        )
    }

    private let backendRun = PostProcessingRun(text: "vom Backend", engine: .gptBackend, gptProfile: "office")
    private let codexRun = PostProcessingRun(text: "von Codex", engine: .codexCLI)

    private func run(
        _ router: PostProcessingEngineRouter,
        mode: OutputMode
    ) async throws -> PostProcessingRun {
        try await router.processRun(rawText: "roh", mode: mode, language: "de", contextBundle: .empty)
    }

    func testTextModeUsesBackend() async throws {
        let backend = FakeProcessor(.success(backendRun))
        let codex = FakeProcessor(.success(codexRun))
        let result = try await run(PostProcessingEngineRouter(backend: backend, codex: codex, isBackendPreferred: { true }), mode: mode())

        XCTAssertEqual(result, backendRun)
        XCTAssertEqual(codex.calls, 0)
    }

    func testModesWithProjectAccessAlwaysUseCodex() async throws {
        let backend = FakeProcessor(.success(backendRun))
        let codex = FakeProcessor(.success(codexRun))
        let router = PostProcessingEngineRouter(backend: backend, codex: codex, isBackendPreferred: { true })

        let result = try await run(router, mode: mode(projectAccess: .readOnly))
        XCTAssertEqual(result.engine, .codexCLI)
        XCTAssertNil(result.fallbackReason)
        XCTAssertEqual(backend.calls, 0)
        XCTAssertEqual(router.plannedEngine(for: mode(projectAccess: .readOnly)), .codexCLI)
    }

    func testSwitchOffOrBackendOffUsesCodex() async throws {
        let backend = FakeProcessor(.success(backendRun))
        let codex = FakeProcessor(.success(codexRun))
        let result = try await run(PostProcessingEngineRouter(backend: backend, codex: codex, isBackendPreferred: { false }), mode: mode())

        XCTAssertEqual(result.engine, .codexCLI)
        XCTAssertEqual(backend.calls, 0)
    }

    func testBackendFailureFallsBackToCodexAndNamesTheReason() async throws {
        let backend = FakeProcessor(.failure(GPTBackendPostProcessingError.rateLimited))
        let codex = FakeProcessor(.success(codexRun))
        let result = try await run(PostProcessingEngineRouter(backend: backend, codex: codex, isBackendPreferred: { true }), mode: mode())

        XCTAssertEqual(result.text, "von Codex")
        XCTAssertEqual(result.engine, .codexCLI)
        XCTAssertEqual(result.fallbackReason, GPTBackendPostProcessingError.rateLimited.localizedDescription)
        XCTAssertEqual(codex.calls, 1)
    }

    func testCancelTimeoutAndTaskCancellationDoNotFallBack() async {
        for error: Error in [PostProcessingError.userCancelled, PostProcessingError.timedOut(90), CancellationError()] {
            let backend = FakeProcessor(.failure(error))
            let codex = FakeProcessor(.success(codexRun))
            do {
                _ = try await run(PostProcessingEngineRouter(backend: backend, codex: codex, isBackendPreferred: { true }), mode: mode())
                XCTFail("\(error) muss durchgehen")
            } catch {
                XCTAssertEqual(codex.calls, 0, "kein zweiter Weg nach \(error)")
            }
        }
    }

    func testBothFailingNamesBothReasons() async {
        let backend = FakeProcessor(.failure(GPTBackendPostProcessingError.notAuthenticated))
        let codex = FakeProcessor(.failure(PostProcessingError.codexUnavailable("Codex CLI is not installed.")))
        do {
            _ = try await run(PostProcessingEngineRouter(backend: backend, codex: codex, isBackendPreferred: { true }), mode: mode())
            XCTFail("Fehler erwartet")
        } catch {
            XCTAssertEqual(
                error as? PostProcessingError,
                .bothEnginesFailed(
                    backend: GPTBackendPostProcessingError.notAuthenticated.localizedDescription,
                    codex: "Codex CLI is not installed."
                )
            )
        }
    }

    func testCancelDuringCodexFallbackStaysACancel() async {
        let backend = FakeProcessor(.failure(GPTBackendPostProcessingError.emptyResponse))
        let codex = FakeProcessor(.failure(PostProcessingError.userCancelled))
        do {
            _ = try await run(PostProcessingEngineRouter(backend: backend, codex: codex, isBackendPreferred: { true }), mode: mode())
            XCTFail("Abbruch erwartet")
        } catch {
            XCTAssertEqual(error as? PostProcessingError, .userCancelled)
        }
    }

    func testServiceAppliesDashFilterAndKeepsEngine() async throws {
        let backend = FakeProcessor(.success(PostProcessingRun(text: "A – B", engine: .gptBackend, gptProfile: "main")))
        let service = PostProcessingService(
            processor: PostProcessingEngineRouter(backend: backend, codex: FakeProcessor(.success(codexRun)), isBackendPreferred: { true })
        )
        let result = try await service.processRun(rawText: "roh", mode: mode(), language: "de")
        XCTAssertFalse(result.text.contains("–"))
        XCTAssertEqual(result.engine, .gptBackend)
        XCTAssertEqual(result.gptProfile, "main")
    }

    func testCodexTimeoutIsShortForTextModesOnly() {
        XCTAssertEqual(CodexPostProcessor.defaultTimeout(for: mode()), 90)
        XCTAssertEqual(CodexPostProcessor.defaultTimeout(for: mode(projectAccess: .readOnly)), 900)
    }

    func testTimeoutMessageUsesSecondsBelowTwoMinutes() {
        XCTAssertTrue(PostProcessingError.timedOut(90).localizedDescription.contains("90"))
        XCTAssertTrue(PostProcessingError.timedOut(900).localizedDescription.contains("15"))
    }
}
