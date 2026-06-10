import Foundation
import XCTest
@testable import WhisperM8

final class AgentSessionIndexerTests: XCTestCase {
    func testCodexSessionIndexerReadsSessionMetadata() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8CodexIndex-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("rollout.jsonl")
        try """
        {"type":"session_meta","timestamp":"2026-05-09T12:00:00.000Z","payload":{"id":"session-id","cwd":"/tmp/repo","timestamp":"2026-05-09T12:00:00.000Z","model":"gpt-5.5"}}
        {"type":"event_msg","payload":{"type":"started"}}
        """.write(to: file, atomically: true, encoding: .utf8)

        let sessions = CodexSessionIndexer(sessionsDirectory: root).indexedSessions()

        XCTAssertEqual(sessions.first?.provider, .codex)
        XCTAssertEqual(sessions.first?.externalSessionID, "session-id")
        XCTAssertEqual(sessions.first?.cwd, "/tmp/repo")
        XCTAssertEqual(sessions.first?.model, "gpt-5.5")
    }

    func testCodexSessionIndexerReadsOnlyBoundedMetadataPrefixAndUsesCache() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8CodexBoundedIndex-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("large-rollout.jsonl")
        let largeBody = String(repeating: "x", count: 2 * 1024 * 1024)
        try """
        {"type":"session_meta","timestamp":"2026-05-09T12:00:00.000Z","payload":{"id":"large-session","cwd":"/tmp/repo","timestamp":"2026-05-09T12:00:00.000Z","model":"gpt-5.5"}}
        \(largeBody)
        """.write(to: file, atomically: true, encoding: .utf8)

        var cache = AgentSessionIndexCache()
        let first = CodexSessionIndexer(sessionsDirectory: root).indexedSessionResult(cache: &cache)
        let second = CodexSessionIndexer(sessionsDirectory: root).indexedSessionResult(cache: &cache)

        XCTAssertEqual(first.sessions.first?.externalSessionID, "large-session")
        XCTAssertLessThanOrEqual(first.stats.bytesRead, 256 * 1024)
        XCTAssertEqual(first.stats.cacheMisses, 1)
        XCTAssertEqual(second.stats.cacheHits, 1)
        XCTAssertEqual(second.stats.bytesRead, 0)
    }

    func testCodexSessionIndexCacheInvalidatesWhenFileSizeChanges() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8CodexCacheInvalidation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("rollout.jsonl")
        try """
        {"type":"session_meta","timestamp":"2026-05-09T12:00:00.000Z","payload":{"id":"session-id","cwd":"/tmp/repo","timestamp":"2026-05-09T12:00:00.000Z","model":"gpt-5.5"}}
        """.write(to: file, atomically: true, encoding: .utf8)

        var cache = AgentSessionIndexCache()
        _ = CodexSessionIndexer(sessionsDirectory: root).indexedSessionResult(cache: &cache)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        handle.write(Data("\n{\"type\":\"event_msg\"}".utf8))
        try handle.close()

        let refreshed = CodexSessionIndexer(sessionsDirectory: root).indexedSessionResult(cache: &cache)

        XCTAssertEqual(refreshed.stats.cacheMisses, 1)
        XCTAssertEqual(refreshed.stats.cacheHits, 0)
        XCTAssertEqual(refreshed.sessions.first?.externalSessionID, "session-id")
    }

    func testCodexSessionIndexCacheRemembersSkippedFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8CodexSkippedCache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("not-a-session.jsonl")
        try #"{"type":"event_msg","payload":{"type":"started"}}"#
            .write(to: file, atomically: true, encoding: .utf8)

        var cache = AgentSessionIndexCache()
        let first = CodexSessionIndexer(sessionsDirectory: root).indexedSessionResult(cache: &cache)
        let second = CodexSessionIndexer(sessionsDirectory: root).indexedSessionResult(cache: &cache)

        XCTAssertEqual(first.sessions.count, 0)
        XCTAssertEqual(first.stats.cacheMisses, 1)
        XCTAssertGreaterThan(first.stats.bytesRead, 0)
        XCTAssertEqual(second.sessions.count, 0)
        XCTAssertEqual(second.stats.cacheHits, 1)
        XCTAssertEqual(second.stats.bytesRead, 0)
    }

    func testClaudeSessionIndexerReadsProjectJsonlMetadataAndSkipsWorktrees() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8ClaudeIndex-\(UUID().uuidString)", isDirectory: true)
        let projectDirectory = root.appendingPathComponent("-Users-test-repo", isDirectory: true)
        let worktreeDirectory = root.appendingPathComponent("-Users-test-repo--claude-worktrees-temp", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktreeDirectory, withIntermediateDirectories: true)

        try """
        {"type":"ai-title","aiTitle":"Fix hooks","sessionId":"11111111-1111-4111-8111-111111111111"}
        {"type":"user","timestamp":"2026-05-09T12:00:00.000Z","sessionId":"11111111-1111-4111-8111-111111111111","cwd":"/Users/test/repo","message":{"role":"user","content":"Fix this"}}
        """.write(
            to: projectDirectory.appendingPathComponent("11111111-1111-4111-8111-111111111111.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        try """
        {"type":"user","timestamp":"2026-05-09T12:00:00.000Z","sessionId":"22222222-2222-4222-8222-222222222222","cwd":"/Users/test/repo/.claude/worktrees/temp","message":{"role":"user","content":"Ignore this"}}
        """.write(
            to: worktreeDirectory.appendingPathComponent("22222222-2222-4222-8222-222222222222.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let sessions = ClaudeSessionIndexer(projectsDirectory: root).indexedSessions()

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.provider, .claude)
        XCTAssertEqual(sessions.first?.externalSessionID, "11111111-1111-4111-8111-111111111111")
        XCTAssertEqual(sessions.first?.cwd, "/Users/test/repo")
        XCTAssertEqual(sessions.first?.title, "Fix hooks")
    }

    func testClaudeSessionIndexerReadsBoundedLinesAndCachesResults() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8ClaudeBoundedIndex-\(UUID().uuidString)", isDirectory: true)
        let projectDirectory = root.appendingPathComponent("-Users-test-repo", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)

        let trailingLines = (0..<500).map { index in
            #"{"type":"assistant","timestamp":"2026-05-09T12:00:00.000Z","sessionId":"11111111-1111-4111-8111-111111111111","message":{"content":"line \#(index)"}}"#
        }.joined(separator: "\n")
        try """
        {"type":"ai-title","aiTitle":"Bounded Claude","sessionId":"11111111-1111-4111-8111-111111111111"}
        {"type":"user","timestamp":"2026-05-09T12:00:00.000Z","sessionId":"11111111-1111-4111-8111-111111111111","cwd":"/Users/test/repo","message":{"role":"user","content":"Fix this"}}
        \(trailingLines)
        """.write(
            to: projectDirectory.appendingPathComponent("11111111-1111-4111-8111-111111111111.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        var cache = AgentSessionIndexCache()
        let first = ClaudeSessionIndexer(projectsDirectory: root).indexedSessionResult(cache: &cache)
        let second = ClaudeSessionIndexer(projectsDirectory: root).indexedSessionResult(cache: &cache)

        XCTAssertEqual(first.sessions.first?.title, "Bounded Claude")
        XCTAssertLessThanOrEqual(first.stats.bytesRead, 1 * 1024 * 1024)
        XCTAssertEqual(first.stats.cacheMisses, 1)
        XCTAssertEqual(second.stats.cacheHits, 1)
        XCTAssertEqual(second.stats.bytesRead, 0)
    }
}
