import AVFoundation
import XCTest
@testable import WhisperM8

// MARK: - Fakes

private struct FakeEngineError: Error {}

private final class FakeRecorderEngine: RecorderEngine {
    var isRunning = true
    var notificationSource: AnyObject? { self }
    var format: AVAudioFormat? = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false
    )
    var installTapError: Error?
    var startError: Error?
    private(set) var installTapCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var handler: ((AVAudioPCMBuffer) -> Void)?

    func currentInputFormat() -> AVAudioFormat? { format }
    func removeTap() { handler = nil }
    func installTap(format: AVAudioFormat, handler: @escaping (AVAudioPCMBuffer) -> Void) throws {
        installTapCount += 1
        if let installTapError { throw installTapError }
        self.handler = handler
    }
    func prepare() {}
    func start() throws {
        startCount += 1
        if let startError { throw startError }
        isRunning = true
    }
    func stop() {
        stopCount += 1
        isRunning = false
    }

    func deliver(_ buffer: AVAudioPCMBuffer) { handler?(buffer) }
}

private final class FakeWriter: RecordingFileWriter {
    /// Ab dem n-ten Aufruf (1-basiert) wirft `write`; nil = nie.
    var failFromCall: Int?
    private(set) var calls = 0
    func write(from buffer: AVAudioPCMBuffer) throws {
        calls += 1
        if let failFromCall, calls >= failFromCall { throw FakeEngineError() }
    }
}

/// Hält die Wartefunktion des Recorders an, bis der Test sie freigibt.
private final class SleepGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var open = false
    private var waiterCount = 0

    var waiters: Int { lock.withLock { waiterCount } }

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if open { lock.unlock(); c.resume(); return }
            waiterCount += 1
            continuations.append(c)
            lock.unlock()
        }
    }

    func release() {
        lock.lock()
        open = true
        let all = continuations
        continuations = []
        lock.unlock()
        all.forEach { $0.resume() }
    }
}

// MARK: - Tests

@MainActor
final class AudioRecorderStateTests: XCTestCase {
    private let mono16k = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false
    )!
    private var center: NotificationCenter!
    private var tempFiles: [URL] = []

    override func setUp() {
        super.setUp()
        center = NotificationCenter()
    }

    override func tearDown() {
        tempFiles.forEach { try? FileManager.default.removeItem(at: $0) }
        tempFiles = []
        super.tearDown()
    }

    private func makeRecorder(sleeper: ((UInt64) async -> Void)? = nil) -> AudioRecorder {
        let recorder = AudioRecorder()
        recorder.notificationCenter = center
        recorder.sleeper = sleeper ?? { _ in }
        return recorder
    }

    private func tempURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rec-state-\(UUID().uuidString).m4a")
        try? Data([1, 2, 3, 4]).write(to: url)
        tempFiles.append(url)
        return url
    }

    private func buffer() -> AVAudioPCMBuffer {
        let b = AVAudioPCMBuffer(pcmFormat: mono16k, frameCapacity: 160)!
        b.frameLength = 160
        return b
    }

    @discardableResult
    private func beginSession(
        _ recorder: AudioRecorder,
        engine: FakeRecorderEngine,
        writer: FakeWriter = FakeWriter()
    ) throws -> URL {
        let url = tempURL()
        try recorder.beginSession(engine: engine, inputFormat: mono16k, file: writer, url: url)
        return url
    }

    private func waitMain(_ description: String, timeout: TimeInterval = 2, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), description)
    }

    // MARK: LR-DIK-004

    func testFormatFailureAfterDeviceChangeKeepsPartialRecording() async throws {
        let recorder = makeRecorder()
        let engine = FakeRecorderEngine()
        let writer = FakeWriter()
        let url = try beginSession(recorder, engine: engine, writer: writer)
        for _ in 0..<3 { engine.deliver(buffer()) }

        var interruptions: [RecordingInterruption] = []
        recorder.onInterruption = { interruptions.append($0) }

        engine.format = nil // Gerät weg: dauerhaft kein gültiges Format
        await recorder.handleConfigurationChange()

        XCTAssertEqual(interruptions, [.deviceLost], "Coordinator muss über das Ende informiert werden")
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(recorder.stopRecording(), url, "Teilaufnahme muss beim Stop geliefert werden")
        XCTAssertNil(recorder.stopRecording(), "Teilaufnahme wird nur einmal ausgeliefert")
    }

    func testTapReinstallFailureEndsRecordingAndKeepsPartial() async throws {
        let recorder = makeRecorder()
        let engine = FakeRecorderEngine()
        let url = try beginSession(recorder, engine: engine)
        engine.deliver(buffer())

        var interruptions: [RecordingInterruption] = []
        recorder.onInterruption = { interruptions.append($0) }

        engine.installTapError = FakeEngineError()
        await recorder.handleConfigurationChange()

        XCTAssertEqual(interruptions.count, 1)
        XCTAssertFalse(recorder.isRecording, "Ohne Tap darf das Flag nicht auf Aufnahme stehen bleiben")
        XCTAssertEqual(recorder.stopRecording(), url)
    }

    func testEngineRestartFailureEndsRecordingAndKeepsPartial() async throws {
        let recorder = makeRecorder()
        let engine = FakeRecorderEngine()
        let url = try beginSession(recorder, engine: engine)
        engine.deliver(buffer())

        var interruptions: [RecordingInterruption] = []
        recorder.onInterruption = { interruptions.append($0) }

        engine.startError = FakeEngineError()
        await recorder.handleConfigurationChange()

        XCTAssertEqual(interruptions.count, 1)
        XCTAssertEqual(recorder.stopRecording(), url)
    }

    func testInterruptionWithoutAnyAudioDeliversNoFile() async throws {
        let recorder = makeRecorder()
        let engine = FakeRecorderEngine()
        try beginSession(recorder, engine: engine)

        var interruptions: [RecordingInterruption] = []
        recorder.onInterruption = { interruptions.append($0) }
        engine.format = nil
        await recorder.handleConfigurationChange()

        XCTAssertEqual(interruptions, [.deviceLost])
        XCTAssertNil(recorder.stopRecording(), "Ohne geschriebenes Audio gibt es nichts zu retten")
    }

    // MARK: LR-DIK-005

    func testStaleReconfigurationDoesNotTouchOldEngineAfterStop() async throws {
        let gate = SleepGate()
        let recorder = makeRecorder(sleeper: { _ in await gate.wait() })
        let engine = FakeRecorderEngine()
        try beginSession(recorder, engine: engine)
        XCTAssertEqual(engine.installTapCount, 1)

        let task = Task { @MainActor in await recorder.handleConfigurationChange() }
        await waitMain("Rekonfiguration hängt in der Stabilisierung") { gate.waiters == 1 }

        _ = recorder.stopRecording()
        gate.release()
        await task.value

        XCTAssertEqual(engine.installTapCount, 1, "Alte Fortsetzung darf keinen Tap mehr installieren")
        XCTAssertEqual(engine.startCount, 1, "Alte Fortsetzung darf die Engine nicht erneut starten (1 = Erststart)")
    }

    func testStaleReconfigurationDoesNotTouchNewRun() async throws {
        let gate = SleepGate()
        let recorder = makeRecorder(sleeper: { _ in await gate.wait() })
        let oldEngine = FakeRecorderEngine()
        try beginSession(recorder, engine: oldEngine)

        let task = Task { @MainActor in await recorder.handleConfigurationChange() }
        await waitMain("Rekonfiguration hängt in der Stabilisierung") { gate.waiters == 1 }

        _ = recorder.stopRecording()
        let newEngine = FakeRecorderEngine()
        try beginSession(recorder, engine: newEngine)
        gate.release()
        await task.value

        XCTAssertEqual(oldEngine.installTapCount, 1)
        XCTAssertEqual(oldEngine.startCount, 1)
        XCTAssertEqual(newEngine.installTapCount, 1, "Neuer Lauf darf nicht angefasst werden")
        XCTAssertEqual(newEngine.startCount, 1)
        XCTAssertTrue(recorder.isRecording)
        // Der neue Lauf muss weiter normal umkonfigurierbar sein (isRestarting nicht verklemmt).
        center.post(name: .AVAudioEngineConfigurationChange, object: newEngine)
        await waitMain("neuer Lauf reagiert weiter auf Gerätewechsel") { newEngine.installTapCount == 2 }
    }

    // MARK: LR-DIK-006

    func testWriteFailureEscalatesExactlyOnceAndKeepsPartial() async throws {
        let recorder = makeRecorder()
        let engine = FakeRecorderEngine()
        let writer = FakeWriter()
        writer.failFromCall = 3
        let url = try beginSession(recorder, engine: engine, writer: writer)

        var interruptions: [RecordingInterruption] = []
        recorder.onInterruption = { interruptions.append($0) }

        for _ in 0..<8 { engine.deliver(buffer()) }
        await waitMain("Schreibfehler wird gemeldet") { !interruptions.isEmpty }
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(interruptions.count, 1, "onInterruption genau einmal")
        if case .writeFailed = interruptions.first {} else {
            XCTFail("falscher Grund: \(String(describing: interruptions.first))")
        }
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(recorder.stopRecording(), url, "Bis dahin geschriebenes Audio bleibt erhalten")
    }

    // MARK: LR-DIK-026

    func testConfigurationChangeIsObservedForFixedDeviceToo() async throws {
        let recorder = makeRecorder()
        let engine = FakeRecorderEngine()
        // beginSession ohne System-Default-Flag = fest gewähltes Gerät
        try beginSession(recorder, engine: engine)

        center.post(name: .AVAudioEngineConfigurationChange, object: engine)
        await waitMain("Konfigurationswechsel wird auch bei festem Gerät behandelt") {
            engine.installTapCount == 2 && engine.startCount == 2
        }
    }

    func testStoppedEngineIsDetectedByHealthCheckAndRestarted() async throws {
        let recorder = makeRecorder()
        let engine = FakeRecorderEngine()
        try beginSession(recorder, engine: engine)

        engine.isRunning = false // z. B. nach Ruhezustand, ohne Notification
        for _ in 0..<AudioRecorder.healthCheckTicksBeforeRecovery { recorder.checkEngineHealth() }

        await waitMain("stehende Engine wird neu gestartet") { engine.startCount == 2 && engine.isRunning }
        XCTAssertTrue(recorder.isRecording)
    }

    func testStoppedEngineThatCannotRestartEndsRecordingVisibly() async throws {
        let recorder = makeRecorder()
        let engine = FakeRecorderEngine()
        let url = try beginSession(recorder, engine: engine)
        engine.deliver(buffer())

        var interruptions: [RecordingInterruption] = []
        recorder.onInterruption = { interruptions.append($0) }

        engine.isRunning = false
        engine.startError = FakeEngineError()
        for _ in 0..<AudioRecorder.healthCheckTicksBeforeRecovery { recorder.checkEngineHealth() }

        await waitMain("Aufnahme endet sichtbar") { !interruptions.isEmpty }
        XCTAssertEqual(recorder.stopRecording(), url)
    }
}
