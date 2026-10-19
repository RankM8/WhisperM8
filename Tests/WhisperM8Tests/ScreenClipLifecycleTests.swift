import XCTest
@testable import WhisperM8

/// LR-DIK-009 / LR-DIK-010: Screen-Clip-Lebenszyklus (Frames am Clip, Abbruch während des Starts).
@MainActor
final class ScreenClipLifecycleTests: XCTestCase {
    private final class FakeClip: ScreenClipCapturing {
        var cancelled = false
        func stop(startedAt: Date?) async throws -> ContextAttachment {
            ContextAttachment(kind: .screenClip, fileURL: URL(fileURLWithPath: "/tmp/fake.mp4"))
        }
        func cancel() async throws { cancelled = true }
    }

    private final class Gate {
        var continuation: CheckedContinuation<Void, Never>?
    }

    func testCancelDuringStartStopsLateSessionAndLeavesNothingActive() async throws {
        let service = VisualContextCaptureService()
        let previous = AppPreferences.shared.isVisualContextCaptureEnabled
        AppPreferences.shared.isVisualContextCaptureEnabled = true
        defer { AppPreferences.shared.isVisualContextCaptureEnabled = previous }

        let fake = FakeClip()
        let gate = Gate()
        service.screenRecordingPermissionCheck = { true }
        service.clipStarter = { _, _ in
            await withCheckedContinuation { gate.continuation = $0 }
            return fake
        }

        let startTask = Task { try await service.startScreenClip(sourceApp: nil) }
        while gate.continuation == nil { await Task.yield() }

        await service.cancelActiveClip()      // Diktatabbruch während des Starts
        gate.continuation?.resume()

        do {
            try await startTask.value
            XCTFail("Start muss nach Abbruch scheitern")
        } catch is CancellationError {
        }
        XCTAssertTrue(fake.cancelled, "die spät gestartete Session muss gestoppt werden")
        XCTAssertFalse(service.isRecordingClip)
        XCTAssertFalse(service.hasClipInFlight)
    }

    func testRemovingScreenClipRemovesOnlyItsDerivedFrames() {
        let appState = AppState.shared
        let originalBundle = appState.contextBundle
        let wasRecording = appState.isRecording
        let wasClip = appState.isScreenClipRecording
        defer {
            appState.contextBundle = originalBundle
            appState.isRecording = wasRecording
            appState.isScreenClipRecording = wasClip
        }
        let clip = ContextAttachment(kind: .screenClip, fileURL: URL(fileURLWithPath: "/tmp/a.mp4"))
        let otherClip = ContextAttachment(kind: .screenClip, fileURL: URL(fileURLWithPath: "/tmp/b.mp4"))
        func frame(_ n: Int, of clip: ContextAttachment?) -> ContextAttachment {
            ContextAttachment(kind: .visualFrame, fileURL: URL(fileURLWithPath: "/tmp/f\(n).png"), sourceClipID: clip?.id)
        }
        let own = (1...3).map { frame($0, of: clip) }
        let foreign = frame(9, of: otherClip)
        let independent = frame(10, of: nil)
        appState.isRecording = true
        appState.isScreenClipRecording = false
        appState.contextBundle = TranscriptContextBundle(
            screenClips: [clip, otherClip],
            visualFrames: own + [foreign, independent]
        )
        let coordinator = RecordingCoordinator(appState: appState)

        coordinator.removeAttachmentFromContext(id: clip.id)

        XCTAssertEqual(appState.contextBundle.screenClips.map(\.id), [otherClip.id])
        XCTAssertEqual(Set(appState.contextBundle.visualFrames.map(\.id)), [foreign.id, independent.id])
    }
}

/// LR-DIK-028: Ausgabegröße des Screen-Clips für H.264 begrenzen.
final class ScreenClipOutputSizeTests: XCTestCase {
    func testUltrawideIsScaledDownKeepingAspectRatioAndEvenDimensions() {
        let size = ScreenClipOutputSize.fitted(width: 5120, height: 1440)
        XCTAssertLessThanOrEqual(size.width, ScreenClipOutputSize.maxWidth)
        XCTAssertEqual(size.width % 2, 0)
        XCTAssertEqual(size.height % 2, 0)
        XCTAssertEqual(Double(size.width) / Double(size.height), 5120.0 / 1440.0, accuracy: 0.02)
    }

    func testFullHDStaysUnchanged() {
        let size = ScreenClipOutputSize.fitted(width: 1920, height: 1080)
        XCTAssertEqual(size.width, 1920)
        XCTAssertEqual(size.height, 1080)
    }

    func testTallDisplayIsLimitedInHeightToo() {
        let size = ScreenClipOutputSize.fitted(width: 2160, height: 7680)
        XCTAssertLessThanOrEqual(size.height, ScreenClipOutputSize.maxHeight)
    }
}
