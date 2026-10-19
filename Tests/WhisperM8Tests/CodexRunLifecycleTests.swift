import Foundation
import XCTest
@testable import WhisperM8

/// LR-DIK-013 (Abschlussgarantie: Timeout + TERM→KILL) und LR-DIK-014 (Cancel-Slot je Lauf).
/// Keine echten Codex-Aufrufe: ein Fake-Skript ersetzt das Binary.
final class CodexRunLifecycleTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeScript(_ body: String) throws -> String {
        let url = tempDir.appendingPathComponent("fake-codex-\(UUID().uuidString).sh")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func makeProcessor(script: String, timeout: TimeInterval, registry: CodexProcessRegistry) -> CodexPostProcessor {
        CodexPostProcessor(
            statusProvider: { .signedIn },
            commandPathResolver: { script },
            registry: registry,
            timeoutProvider: { _ in timeout }
        )
    }

    private var promptMode: OutputMode {
        OutputMode.builtInModes.first { $0.id == OutputMode.promptID }!
    }

    func testHangingCodexIgnoringSigtermIsKilledAfterDeadline() async throws {
        // Ignoriert SIGTERM und hängt für immer.
        let script = try makeScript("trap '' TERM\nwhile :; do sleep 1; done")
        let registry = CodexProcessRegistry(killGrace: 0.5)
        let processor = makeProcessor(script: script, timeout: 1, registry: registry)

        let started = Date()
        do {
            _ = try await processor.process(rawText: "hallo", mode: promptMode, language: "de", contextBundle: .empty)
            XCTFail("Timeout erwartet")
        } catch let error as PostProcessingError {
            XCTAssertEqual(error, .timedOut(1))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 15, "Lauf muss nach Deadline + Gnadenfrist enden")
    }

    func testTaskCancellationStopsTheRun() async throws {
        let script = try makeScript("sleep 60")
        let registry = CodexProcessRegistry(killGrace: 0.5)
        let processor = makeProcessor(script: script, timeout: 120, registry: registry)

        let mode = promptMode
        let task = Task {
            try await processor.process(rawText: "hallo", mode: mode, language: "de", contextBundle: .empty)
        }
        try await Task.sleep(nanoseconds: 700_000_000)
        let started = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Abbruch erwartet")
        } catch let error as PostProcessingError {
            XCTAssertEqual(error, .userCancelled)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testCancelByOwnerOnlyHitsThatOwnersRun() throws {
        let registry = CodexProcessRegistry(killGrace: 0.5)
        func sleeper() throws -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["30"]
            try process.run()
            return process
        }
        let dictation = try sleeper()
        let testLab = try sleeper()
        let dictationID = UUID()
        let testLabID = UUID()
        defer { dictation.terminate(); testLab.terminate() }

        registry.register(dictation, runID: dictationID, owner: .dictation)
        registry.register(testLab, runID: testLabID, owner: .testLab)   // registriert zuletzt (früher: überschrieb den Slot)

        XCTAssertTrue(registry.cancel(owner: .dictation))
        dictation.waitUntilExit()

        XCTAssertFalse(dictation.isRunning, "Diktat-Lauf muss beendet sein")
        XCTAssertTrue(testLab.isRunning, "Test-Lab-Lauf darf vom Diktat-Abbruch nicht getroffen werden")
        XCTAssertEqual(registry.outcome(runID: dictationID), .cancelledByUser)
        XCTAssertEqual(registry.outcome(runID: testLabID), .none)
    }
}
