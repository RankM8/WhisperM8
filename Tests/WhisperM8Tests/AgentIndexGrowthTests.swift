import CoreServices
import Foundation
import XCTest
@testable import WhisperM8

/// LR-AK-033: Wachsende Transcripts duerfen den Indexer nicht bei jedem Scan
/// zu einem Neu-Parse des 1-MB-Kopfes zwingen.
final class AgentIndexGrowthTests: XCTestCase {
    private func makeRoot(_ name: String) throws -> (root: URL, project: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("-Users-test-repo", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        return (root, project)
    }

    /// Kopf mit > 200 Zeilen: ab hier ist der Parse-Ausschnitt gesaettigt.
    private func saturatedHead(title: String = "Kopf-Titel") -> String {
        let id = "11111111-1111-4111-8111-111111111111"
        var lines = [
            #"{"type":"ai-title","aiTitle":"\#(title)","sessionId":"\#(id)"}"#,
            #"{"type":"user","timestamp":"2026-05-09T12:00:00.000Z","sessionId":"\#(id)","cwd":"/Users/test/repo","message":{"role":"user","content":"Fix this"}}"#,
        ]
        for index in 0..<300 {
            lines.append(#"{"type":"assistant","timestamp":"2026-05-09T12:00:01.000Z","sessionId":"\#(id)","message":{"content":"zeile \#(index)"}}"#)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func append(_ text: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        handle.write(Data(text.utf8))
        try handle.close()
    }

    func testGrowingFileWithSaturatedHeadIsNotReparsed() throws {
        let (root, project) = try makeRoot("WhisperM8GrowthSaturated")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = project.appendingPathComponent("11111111-1111-4111-8111-111111111111.jsonl")
        try saturatedHead().write(to: file, atomically: true, encoding: .utf8)

        var cache = AgentSessionIndexCache()
        let indexer = ClaudeSessionIndexer(projectsDirectory: root)
        let first = indexer.indexedSessionResult(cache: &cache)
        XCTAssertEqual(first.stats.parsedFiles, 1)

        try append(#"{"type":"assistant","timestamp":"2026-05-09T12:05:00.000Z","message":{"content":"mehr"}}"# + "\n", to: file)
        let future = Date().addingTimeInterval(120)
        try FileManager.default.setAttributes([.modificationDate: future], ofItemAtPath: file.path)

        let second = indexer.indexedSessionResult(cache: &cache)
        XCTAssertEqual(second.stats.parsedFiles, 0, "gesaettigter Kopf darf nicht neu geparst werden")
        XCTAssertEqual(second.stats.bytesRead, 0)
        XCTAssertEqual(second.sessions.count, 1)
        XCTAssertEqual(second.sessions.first?.title, "Kopf-Titel")
        XCTAssertEqual(second.sessions.first?.externalSessionID, "11111111-1111-4111-8111-111111111111")
        XCTAssertEqual(second.sessions.first?.cwd, "/Users/test/repo")
        let lastActivity = try XCTUnwrap(second.sessions.first?.lastActivityAt)
        XCTAssertEqual(lastActivity.timeIntervalSince1970, future.timeIntervalSince1970, accuracy: 1)
        XCTAssertGreaterThan(lastActivity, try XCTUnwrap(first.sessions.first?.lastActivityAt))

        // Cache-Eintrag traegt die neue Groesse: ein dritter Scan ist ein Treffer.
        let third = indexer.indexedSessionResult(cache: &cache)
        XCTAssertEqual(third.stats.cacheHits, 1)
    }

    /// Review W0: Worktree-Sessions verwirft der Indexer — das erste cwd steht
    /// im Kopf und ändert sich durch Anhängen nie. Wachstum darf sie deshalb
    /// nicht bei jedem Scan neu parsen (Worktree-Chats sind der Normalfall).
    func testGrowingWorktreeSessionIsNotReparsed() throws {
        let (root, project) = try makeRoot("WhisperM8GrowthWorktree")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = project.appendingPathComponent("22222222-2222-4222-8222-222222222222.jsonl")
        try (#"{"type":"user","timestamp":"2026-05-09T12:00:00.000Z","sessionId":"22222222-2222-4222-8222-222222222222","cwd":"/Users/test/repo/.claude/worktrees/w0","message":{"role":"user","content":"Arbeite"}}"# + "\n")
            .write(to: file, atomically: true, encoding: .utf8)

        var cache = AgentSessionIndexCache()
        let indexer = ClaudeSessionIndexer(projectsDirectory: root)
        let first = indexer.indexedSessionResult(cache: &cache)
        XCTAssertEqual(first.stats.skippedFiles, 1)
        XCTAssertTrue(first.sessions.isEmpty)

        try append(#"{"type":"assistant","timestamp":"2026-05-09T12:05:00.000Z","message":{"content":"mehr"}}"# + "\n", to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(120)], ofItemAtPath: file.path)

        let second = indexer.indexedSessionResult(cache: &cache)
        XCTAssertEqual(second.stats.bytesRead, 0, "verworfener Worktree-Kopf darf nicht neu gelesen werden")
        XCTAssertEqual(second.stats.parsedFiles, 0)
        XCTAssertTrue(second.sessions.isEmpty)
    }

    /// Gegenprobe: Fehlt das cwd in einem noch nicht gesättigten Kopf, kann es
    /// mit der nächsten Zeile kommen — dann muss neu geparst werden.
    func testGrowingFileWithoutCwdIsReparsedUntilCwdArrives() throws {
        let (root, project) = try makeRoot("WhisperM8GrowthNoCwd")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = project.appendingPathComponent("33333333-3333-4333-8333-333333333333.jsonl")
        try (#"{"type":"summary","summary":"leer"}"# + "\n").write(to: file, atomically: true, encoding: .utf8)

        var cache = AgentSessionIndexCache()
        let indexer = ClaudeSessionIndexer(projectsDirectory: root)
        XCTAssertTrue(indexer.indexedSessionResult(cache: &cache).sessions.isEmpty)

        try append(#"{"type":"user","timestamp":"2026-05-09T12:00:00.000Z","sessionId":"33333333-3333-4333-8333-333333333333","cwd":"/Users/test/repo","message":{"role":"user","content":"Jetzt"}}"# + "\n", to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(120)], ofItemAtPath: file.path)

        let second = indexer.indexedSessionResult(cache: &cache)
        XCTAssertEqual(second.stats.parsedFiles, 1)
        XCTAssertEqual(second.sessions.first?.cwd, "/Users/test/repo")
    }

    func testGrowingFileWithoutSaturatedHeadIsStillReparsed() throws {
        let (root, project) = try makeRoot("WhisperM8GrowthSmall")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = project.appendingPathComponent("11111111-1111-4111-8111-111111111111.jsonl")
        try (#"{"type":"user","timestamp":"2026-05-09T12:00:00.000Z","sessionId":"11111111-1111-4111-8111-111111111111","cwd":"/Users/test/repo","message":{"role":"user","content":"Erster Prompt"}}"# + "\n")
            .write(to: file, atomically: true, encoding: .utf8)

        var cache = AgentSessionIndexCache()
        let indexer = ClaudeSessionIndexer(projectsDirectory: root)
        _ = indexer.indexedSessionResult(cache: &cache)
        try append(#"{"type":"custom-title","customTitle":"Umbenannt"}"# + "\n", to: file)
        let second = indexer.indexedSessionResult(cache: &cache)

        // Kleiner Kopf: das neue custom-title liegt noch im Fenster -> Neu-Parse.
        XCTAssertEqual(second.stats.parsedFiles, 1)
        XCTAssertEqual(second.sessions.first?.title, "Umbenannt")
    }

    func testShrunkFileInvalidatesSaturatedEntry() throws {
        let (root, project) = try makeRoot("WhisperM8GrowthShrink")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = project.appendingPathComponent("11111111-1111-4111-8111-111111111111.jsonl")
        try saturatedHead(title: "Alt").write(to: file, atomically: true, encoding: .utf8)
        var cache = AgentSessionIndexCache()
        let indexer = ClaudeSessionIndexer(projectsDirectory: root)
        _ = indexer.indexedSessionResult(cache: &cache)

        // Umgeschriebene, kleinere Datei -> echter Neu-Parse.
        try saturatedHead(title: "Neu").components(separatedBy: "\n").prefix(250).joined(separator: "\n")
            .write(to: file, atomically: true, encoding: .utf8)
        let second = indexer.indexedSessionResult(cache: &cache)
        XCTAssertEqual(second.stats.parsedFiles, 1)
        XCTAssertEqual(second.sessions.first?.title, "Neu")
    }

    func testCodexGrowingFileKeepsMetaWithoutReparse() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8GrowthCodex-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("rollout.jsonl")
        try (#"{"type":"session_meta","payload":{"id":"codex-1","cwd":"/tmp/repo","timestamp":"2026-05-09T12:00:00.000Z","model":"gpt-5.5"}}"#
            + "\n{\"type\":\"event_msg\"}\n")
            .write(to: file, atomically: true, encoding: .utf8)

        var cache = AgentSessionIndexCache()
        let indexer = CodexSessionIndexer(sessionsDirectory: root)
        _ = indexer.indexedSessionResult(cache: &cache)
        try append("{\"type\":\"event_msg\"}\n", to: file)
        let future = Date().addingTimeInterval(60)
        try FileManager.default.setAttributes([.modificationDate: future], ofItemAtPath: file.path)
        let second = indexer.indexedSessionResult(cache: &cache)

        XCTAssertEqual(second.stats.parsedFiles, 0)
        XCTAssertEqual(second.stats.bytesRead, 0)
        XCTAssertEqual(second.sessions.first?.externalSessionID, "codex-1")
        XCTAssertEqual(second.sessions.first?.model, "gpt-5.5")
        XCTAssertEqual(try XCTUnwrap(second.sessions.first?.lastActivityAt).timeIntervalSince1970,
                       future.timeIntervalSince1970, accuracy: 1)
    }

    // MARK: FSEvents (C)

    func testOnlyStructuralFSEventFlagsTriggerScan() {
        let created = UInt32(kFSEventStreamEventFlagItemCreated)
        let renamed = UInt32(kFSEventStreamEventFlagItemRenamed)
        let removed = UInt32(kFSEventStreamEventFlagItemRemoved)
        let modified = UInt32(kFSEventStreamEventFlagItemModified)
        XCTAssertTrue(AgentDirectoryEventMonitor.triggersScan(flags: created))
        XCTAssertTrue(AgentDirectoryEventMonitor.triggersScan(flags: renamed))
        XCTAssertTrue(AgentDirectoryEventMonitor.triggersScan(flags: removed))
        XCTAssertTrue(AgentDirectoryEventMonitor.triggersScan(flags: created | modified))
        XCTAssertFalse(AgentDirectoryEventMonitor.triggersScan(flags: modified))
        XCTAssertFalse(AgentDirectoryEventMonitor.triggersScan(flags: modified | UInt32(kFSEventStreamEventFlagItemInodeMetaMod)))
    }

    // MARK: Cooldown (D)

    func testAdaptiveCooldownIsAtLeastThreeTimesScanDuration() {
        XCTAssertEqual(AgentScanCoordinator.adaptiveCooldown(base: 10, lastScanDuration: 0.2), 10)
        XCTAssertEqual(AgentScanCoordinator.adaptiveCooldown(base: 10, lastScanDuration: 8), 24)
        XCTAssertEqual(AgentScanCoordinator.adaptiveCooldown(base: 30, lastScanDuration: nil), 30)
    }

    // MARK: Benchmark

    /// Parsezeit fuer einen ~1-MB-Kopf. Ausgabe nur zur Messung (Befund-Zahlen).
    func testBenchmarkHeadParseOneMegabyte() throws {
        let (root, project) = try makeRoot("WhisperM8GrowthBench")
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "11111111-1111-4111-8111-111111111111"
        let filler = String(repeating: "x", count: 5000)
        var lines = [#"{"type":"ai-title","aiTitle":"Bench","sessionId":"\#(id)"}"#,
                     #"{"type":"user","timestamp":"2026-05-09T12:00:00.000Z","sessionId":"\#(id)","cwd":"/Users/test/repo","message":{"role":"user","content":"Bench"}}"#]
        for index in 0..<250 {
            lines.append(#"{"type":"assistant","timestamp":"2026-05-09T12:00:01.000Z","sessionId":"\#(id)","message":{"content":"\#(index) \#(filler)"}}"#)
        }
        let file = project.appendingPathComponent("\(id).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let indexer = ClaudeSessionIndexer(projectsDirectory: root)

        var parseTimes: [Double] = []
        for run in 0..<5 {
            var cache = AgentSessionIndexCache()
            let start = Date()
            let result = indexer.indexedSessionResult(cache: &cache)
            parseTimes.append(Date().timeIntervalSince(start) * 1000)
            XCTAssertEqual(result.sessions.first?.title, "Bench", "run \(run)")
        }
        // Wachstum + Folge-Scan (Pfad B)
        var cache = AgentSessionIndexCache()
        _ = indexer.indexedSessionResult(cache: &cache)
        try append("{\"type\":\"assistant\"}\n", to: file)
        let start = Date()
        _ = indexer.indexedSessionResult(cache: &cache)
        let growthMs = Date().timeIntervalSince(start) * 1000
        print("BENCH head-parse ms: \(parseTimes.map { String(format: "%.1f", $0) }) growth-rescan ms: \(String(format: "%.1f", growthMs))")
    }
}
