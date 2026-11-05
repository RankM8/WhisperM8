import Foundation
import XCTest
@testable import WhisperM8

/// Abbruch der Nacharbeit: ESC systemweit nur während der Nacharbeit, der
/// Abbruch-Merker greift auch ohne angemeldeten Lauf, und der Diktat-Bericht
/// hält geplanten Weg, Ergebnis und Grund fest.
@MainActor
final class PostProcessingCancelTests: XCTestCase {
    /// Spy statt Carbon-Hotkey: merkt sich, ob ESC angemeldet ist, und kann
    /// einen Tastendruck auslösen.
    private final class SpyCancelKey: CleanUpCancelKeyGrabbing {
        private(set) var activations = 0
        private(set) var isActive = false
        private var handler: (@MainActor () -> Void)?

        func activate(handler: @escaping @MainActor () -> Void) {
            activations += 1
            isActive = true
            self.handler = handler
        }

        func deactivate() {
            isActive = false
            handler = nil
        }

        @MainActor func pressEscape() { handler?() }
    }

    /// Prozessor, der während der Arbeit eine Aktion auslöst und dann ein
    /// Ergebnis oder einen Fehler liefert.
    private struct ScriptedProcessor: PostProcessing {
        var planned: PostProcessingEngine? = .gptBackend
        var duringRun: @MainActor () -> Void = {}
        var result: Result<PostProcessingRun, Error>

        func plannedEngine(for mode: OutputMode) -> PostProcessingEngine? { planned }

        func process(rawText: String, mode: OutputMode, language: String, contextBundle: TranscriptContextBundle) async throws -> String {
            try await processRun(rawText: rawText, mode: mode, language: language, contextBundle: contextBundle).text
        }

        func processRun(rawText: String, mode: OutputMode, language: String, contextBundle: TranscriptContextBundle) async throws -> PostProcessingRun {
            await duringRun()
            return try result.get()
        }
    }

    private var cleanMode: OutputMode {
        OutputMode(
            id: OutputMode.cleanID,
            name: "Clean",
            shortLabel: "Clean",
            kind: .builtIn,
            templateID: PostProcessingTemplate.cleanID,
            isEnabled: true,
            isDefault: false
        )
    }

    private func coordinator(processor: PostProcessing, key: SpyCancelKey) -> RecordingCoordinator {
        RecordingCoordinator(
            appState: .shared,
            postProcessingService: PostProcessingService(processor: processor),
            providerResolver: { .openai },
            modelResolver: { .openai_gpt4o },
            apiKeyResolver: { _ in nil },
            busyHotkeyNotifier: { _ in },
            cleanUpCancelKey: key
        )
    }

    private func withCleanState(_ body: () async throws -> Void) async rethrows {
        let appState = AppState.shared
        let saved = (appState.isRecording, appState.isTranscribing, appState.isPostProcessing, appState.lastError, appState.contextBundle)
        defer {
            (appState.isRecording, appState.isTranscribing, appState.isPostProcessing, appState.lastError, appState.contextBundle) = saved
        }
        appState.isRecording = false
        appState.isTranscribing = false
        appState.isPostProcessing = false
        appState.contextBundle = .empty
        try await body()
    }

    // MARK: - Coordinator

    func testEscapeIsGrabbedOnlyDuringCleanUpAndCancelYieldsRawText() async throws {
        try await withCleanState {
            let key = SpyCancelKey()
            var activeDuringRun = false
            let processor = ScriptedProcessor(
                duringRun: {
                    activeDuringRun = key.isActive
                    key.pressEscape()
                },
                // Der Weg liefert trotz Abbruch noch Text: gilt trotzdem nicht.
                result: .success(PostProcessingRun(text: "nachgearbeitet", engine: .gptBackend, gptProfile: "office"))
            )
            let coordinator = coordinator(processor: processor, key: key)

            let result = try await coordinator.processTranscriptIfNeeded("roh gesprochen", mode: cleanMode, language: "de", contextBundle: .empty)

            XCTAssertTrue(activeDuringRun, "ESC muss während der Nacharbeit systemweit angemeldet sein")
            XCTAssertFalse(key.isActive, "ESC muss danach wieder frei sein")
            XCTAssertEqual(key.activations, 1)
            XCTAssertEqual(result.finalText, "roh gesprochen")
            XCTAssertEqual(result.fallbackStatus, .rawFallback)
            XCTAssertEqual(result.postProcessing?.outcome, .cancelled)
            XCTAssertEqual(result.postProcessing?.plannedEngine, .gptBackend)
            XCTAssertNil(AppState.shared.lastError, "Ein Abbruch ist kein Fehler")
        }
    }

    func testFailureKeepsPlannedRouteAndReason() async throws {
        try await withCleanState {
            let key = SpyCancelKey()
            let error = PostProcessingError.bothEnginesFailed(backend: "aus", codex: "fehlt")
            let coordinator = coordinator(processor: ScriptedProcessor(result: .failure(error)), key: key)

            let result = try await coordinator.processTranscriptIfNeeded("roh", mode: cleanMode, language: "de", contextBundle: .empty)

            XCTAssertEqual(result.finalText, "roh")
            XCTAssertEqual(result.postProcessing?.outcome, .failed)
            XCTAssertEqual(result.postProcessing?.plannedEngine, .gptBackend)
            XCTAssertNil(result.postProcessing?.engine)
            XCTAssertEqual(result.postProcessing?.errorMessage, error.localizedDescription)
            XCTAssertFalse(key.isActive)
        }
    }

    func testSuccessAndFallbackAreReportedApart() async throws {
        try await withCleanState {
            let direct = try await coordinator(
                processor: ScriptedProcessor(result: .success(PostProcessingRun(text: "gut", engine: .gptBackend, gptProfile: "main"))),
                key: SpyCancelKey()
            ).processTranscriptIfNeeded("roh", mode: cleanMode, language: "de", contextBundle: .empty)
            XCTAssertEqual(direct.finalText, "gut")
            XCTAssertEqual(direct.postProcessing?.outcome, .succeeded)
            XCTAssertEqual(direct.postProcessing?.engine, .gptBackend)
            XCTAssertEqual(direct.postProcessing?.gptProfile, "main")

            let fallback = try await coordinator(
                processor: ScriptedProcessor(result: .success(PostProcessingRun(text: "gut", engine: .codexCLI, fallbackReason: "429"))),
                key: SpyCancelKey()
            ).processTranscriptIfNeeded("roh", mode: cleanMode, language: "de", contextBundle: .empty)
            XCTAssertEqual(fallback.postProcessing?.outcome, .fellBack)
            XCTAssertEqual(fallback.postProcessing?.engine, .codexCLI)
            XCTAssertEqual(fallback.postProcessing?.fallbackReason, "429")
        }
    }

    // MARK: - Merker in den Wegen

    func testCancelBetweenBackendFailureAndCodexStartsNoCodex() async {
        final class Counter: PostProcessing, @unchecked Sendable {
            var calls = 0
            func process(rawText: String, mode: OutputMode, language: String, contextBundle: TranscriptContextBundle) async throws -> String {
                calls += 1
                return "von Codex"
            }
        }
        let token = PostProcessingCancelToken()
        let codex = Counter()
        let backend = ScriptedProcessor(
            duringRun: { token.cancel() },
            result: .failure(GPTBackendPostProcessingError.rateLimited)
        )
        let router = PostProcessingEngineRouter(backend: backend, codex: codex, isBackendPreferred: { true })

        do {
            _ = try await PostProcessingCancelToken.$current.withValue(token) {
                try await router.processRun(rawText: "roh", mode: self.cleanMode, language: "de", contextBundle: .empty)
            }
            XCTFail("Abbruch erwartet")
        } catch {
            XCTAssertEqual(error as? PostProcessingError, .userCancelled)
        }
        XCTAssertEqual(codex.calls, 0)
    }

    func testCancelBeforeCodexSpawnStartsNoProcess() async {
        let token = PostProcessingCancelToken()
        token.cancel()
        var resolved = 0
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("templates-\(UUID().uuidString).json")
        let codex = CodexPostProcessor(
            templateStore: PostProcessingTemplateStore(fileURL: missing),
            statusProvider: { .signedIn },
            commandPathResolver: {
                resolved += 1
                return "/usr/bin/false"
            }
        )
        do {
            _ = try await PostProcessingCancelToken.$current.withValue(token) {
                try await codex.process(rawText: "roh", mode: self.cleanMode, language: "de", contextBundle: .empty)
            }
            XCTFail("Abbruch erwartet")
        } catch {
            XCTAssertEqual(error as? PostProcessingError, .userCancelled)
        }
        XCTAssertEqual(resolved, 0, "Codex darf nach dem Abbruch nicht starten")
    }

    func testCancelDuringBackendPreparationEndsRunAsCancel() async {
        let token = PostProcessingCancelToken()
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("templates-\(UUID().uuidString).json")
        let dependencies = GPTBackendPostProcessingDependencies(
            isBackendEnabled: { true },
            // Abbruch genau in der Vorbereitung, bevor der Lauf angemeldet ist.
            activeProfile: {
                token.cancel()
                return nil
            },
            knownPort: { _ in 18_765 },
            ensureRunning: { _ in .success(()) },
            proxyModels: { nil },
            supportsFast: { _ in false },
            sessionProvider: { _ in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [GPTBackendStubURLProtocol.self]
                return URLSession(configuration: configuration)
            }
        )
        GPTBackendStubURLProtocol.handler = { _ in .hang }
        defer { GPTBackendStubURLProtocol.reset() }
        let backend = GPTBackendPostProcessor(
            templateStore: PostProcessingTemplateStore(fileURL: missing),
            dependencies: dependencies,
            registry: GPTBackendRunRegistry(),
            visualInputModeRaw: { CodexVisualInputMode.defaultMode.rawValue }
        )
        do {
            _ = try await PostProcessingCancelToken.$current.withValue(token) {
                try await backend.processRun(rawText: "roh", mode: self.cleanMode, language: "de", contextBundle: .empty)
            }
            XCTFail("Abbruch erwartet")
        } catch {
            XCTAssertEqual(error as? PostProcessingError, .userCancelled)
        }
    }
}
