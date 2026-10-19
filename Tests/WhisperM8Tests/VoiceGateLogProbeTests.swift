import XCTest
@testable import WhisperM8

/// LR-VG-002: Die Scharfschaltungsprüfung las alle 10 s bis zu 12 × 8 MiB Log
/// auf dem MainActor — ohne Cache, und ein an der 8-MiB-Grenze geschnittenes
/// Umlaut-Zeichen machte den ganzen Ausschnitt unlesbar.
/// LR-VG-001: Hypothesen und Tastendruck prüften Abschalten/Diktat nicht erneut.
final class VoiceGateLogProbeTests: XCTestCase {
    private var root: URL!
    private let now = ISO8601DateFormatter().date(from: "2026-10-19T10:00:00Z")!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vg-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dayDirectory(), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func dayDirectory() -> URL {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        return root.appendingPathComponent(String(format: "%04d/%02d/%02d", parts.year!, parts.month!, parts.day!))
    }

    private func probe(reads: CountingReader) -> CodexVoiceSessionProbe {
        CodexVoiceSessionProbe(
            logRoot: root,
            now: { self.now },
            codexRunningProvider: { true },
            logScanner: CodexVoiceLogScanner(readRange: reads.read)
        )
    }

    func testMarkerFoundWhenTailCutsThroughMultibyteCharacter() throws {
        // Datei > 8 MiB, der Schnitt bei `size - 8 MiB` trifft das Folgebyte eines „ä“.
        let limit = 8 * 1024 * 1024
        let marker = Array("\n2026-10-19T09:30:00.000Z info realtime_session_started\n".utf8)
        var data = Data(repeating: UInt8(ascii: "x"), count: 100)
        data.append(contentsOf: Array("ä".utf8))
        data.append(Data(repeating: UInt8(ascii: "a"), count: limit - 1 - marker.count))
        data.append(contentsOf: marker)
        XCTAssertEqual(data.count - limit, 101)
        try data.write(to: dayDirectory().appendingPathComponent("codex.log"))

        let reads = CountingReader()
        XCTAssertNotNil(probe(reads: reads).lastRealtimeSessionStart())
    }

    func testUnchangedLogIsReadOnlyOnce() throws {
        let log = dayDirectory().appendingPathComponent("codex.log")
        try "2026-10-19T09:30:00.000Z info realtime_session_started\n".write(to: log, atomically: true, encoding: .utf8)
        let reads = CountingReader()
        let probe = probe(reads: reads)
        XCTAssertNotNil(probe.lastRealtimeSessionStart())
        XCTAssertNotNil(probe.lastRealtimeSessionStart())
        XCTAssertEqual(reads.count, 1)
    }

    func testAppendedLogReadsOnlyNewTail() throws {
        let log = dayDirectory().appendingPathComponent("codex.log")
        let first = String(repeating: "2026-10-19T09:00:00.000Z info nichts\n", count: 2000)
        try first.write(to: log, atomically: true, encoding: .utf8)
        let reads = CountingReader()
        let probe = probe(reads: reads)
        XCTAssertNil(probe.lastRealtimeSessionStart())

        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("2026-10-19T09:45:00.000Z info realtime_session_started\n".utf8))
        try handle.close()

        let found = probe.lastRealtimeSessionStart()
        XCTAssertEqual(found, ISO8601DateFormatter().date(from: "2026-10-19T09:45:00Z"))
        XCTAssertEqual(reads.count, 2)
        XCTAssertGreaterThan(reads.lastOffset, 0, "zweiter Lauf liest nur den Zuwachs")
    }

    func testNoActionWhenDisabledOrDictating() {
        XCTAssertTrue(VoiceGateCoordinator.mayAct(isEnabled: true, dictationActive: false))
        XCTAssertFalse(VoiceGateCoordinator.mayAct(isEnabled: false, dictationActive: false))
        XCTAssertFalse(VoiceGateCoordinator.mayAct(isEnabled: true, dictationActive: true))
    }
}

private final class CountingReader: @unchecked Sendable {
    private(set) var count = 0
    private(set) var lastOffset: UInt64 = 0

    func read(_ url: URL, _ offset: UInt64) -> Data? {
        count += 1
        lastOffset = offset
        return CodexVoiceLogScanner.readFile(url, offset)
    }
}
