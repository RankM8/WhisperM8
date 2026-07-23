import Foundation
import XCTest
@testable import WhisperM8

final class AgentSessionIndexCacheStoreTests: XCTestCase {
    func testDiskRoundtripPreservesFractionalModificationDateAndWarmScanHitsCache() throws {
        let fixture = try makeCodexFixture(name: "fractional-mtime")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let cacheURL = fixture.root.appendingPathComponent("cache/index.json")
        let store = AgentSessionIndexCacheStore(fileURL: cacheURL)
        let mtime = Date(timeIntervalSince1970: 1_700_000_000.123_456)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: fixture.file.path)

        var cache = AgentSessionIndexCache()
        let cold = CodexSessionIndexer(sessionsDirectory: fixture.sessionsRoot)
            .indexedSessionResult(cache: &cache)
        XCTAssertEqual(cold.stats.cacheMisses, 1)
        XCTAssertTrue(store.save(&cache))

        var reloaded = store.load()
        let warm = CodexSessionIndexer(sessionsDirectory: fixture.sessionsRoot)
            .indexedSessionResult(cache: &reloaded)

        XCTAssertEqual(warm.sessions.first?.externalSessionID, "fractional-mtime")
        XCTAssertEqual(warm.stats.cacheHits, 1)
        XCTAssertEqual(warm.stats.cacheMisses, 0)
        XCTAssertEqual(warm.stats.bytesRead, 0)
        XCTAssertFalse(store.save(&reloaded))
    }

    func testSameSizeModificationWithinSameSecondInvalidatesCache() throws {
        let fixture = try makeCodexFixture(name: "mtime-only")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = AgentSessionIndexCacheStore(
            fileURL: fixture.root.appendingPathComponent("cache/index.json")
        )
        let firstMtime = Date(timeIntervalSince1970: 1_700_000_000.125)
        try FileManager.default.setAttributes([.modificationDate: firstMtime], ofItemAtPath: fixture.file.path)

        var cache = AgentSessionIndexCache()
        _ = CodexSessionIndexer(sessionsDirectory: fixture.sessionsRoot)
            .indexedSessionResult(cache: &cache)
        XCTAssertTrue(store.save(&cache))

        var reloaded = store.load()
        let secondMtime = Date(timeIntervalSince1970: 1_700_000_000.625)
        try FileManager.default.setAttributes([.modificationDate: secondMtime], ofItemAtPath: fixture.file.path)
        let refreshed = CodexSessionIndexer(sessionsDirectory: fixture.sessionsRoot)
            .indexedSessionResult(cache: &reloaded)

        XCTAssertEqual(refreshed.stats.cacheHits, 0)
        XCTAssertEqual(refreshed.stats.cacheMisses, 1)
        XCTAssertGreaterThan(refreshed.stats.bytesRead, 0)
    }

    func testNegativeCacheEntrySurvivesDiskRoundtrip() throws {
        let root = uniqueRoot("negative")
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        let invalidFile = sessionsRoot.appendingPathComponent("invalid.jsonl")
        try #"{"type":"event_msg","payload":{"type":"started"}}"#
            .write(
                to: invalidFile,
                atomically: true,
                encoding: .utf8
            )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_001.375)],
            ofItemAtPath: invalidFile.path
        )
        let store = AgentSessionIndexCacheStore(
            fileURL: root.appendingPathComponent("cache/index.json")
        )

        var cache = AgentSessionIndexCache()
        let cold = CodexSessionIndexer(sessionsDirectory: sessionsRoot)
            .indexedSessionResult(cache: &cache)
        XCTAssertEqual(cold.stats.cacheMisses, 1)
        XCTAssertTrue(store.save(&cache))

        var reloaded = store.load()
        let warm = CodexSessionIndexer(sessionsDirectory: sessionsRoot)
            .indexedSessionResult(cache: &reloaded)

        XCTAssertTrue(warm.sessions.isEmpty)
        XCTAssertEqual(warm.stats.cacheHits, 1)
        XCTAssertEqual(warm.stats.bytesRead, 0)
    }

    func testLegacyCacheIsDiscardedAndRewrittenWithCurrentSchema() throws {
        let root = uniqueRoot("legacy")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cacheURL = root.appendingPathComponent("index.json")
        try """
        {"entries":{"codex:/tmp/legacy.jsonl":{"fileSize":42,"modifiedAt":"2026-07-22T20:00:00Z","session":null}}}
        """.write(to: cacheURL, atomically: true, encoding: .utf8)
        let store = AgentSessionIndexCacheStore(fileURL: cacheURL)

        var cache = store.load()

        XCTAssertTrue(cache.invalidatedLegacyFormat)
        XCTAssertTrue(cache.isDirty)
        XCTAssertEqual(cache.entryCount, 0)
        XCTAssertTrue(store.save(&cache))
        XCTAssertFalse(cache.invalidatedLegacyFormat)
        XCTAssertFalse(cache.isDirty)

        let data = try Data(contentsOf: cacheURL)
        let rootObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(rootObject["schemaVersion"] as? Int, AgentSessionIndexCache.currentSchemaVersion)
    }

    func testSuccessfulEnumerationPrunesDeletedEntries() throws {
        let fixture = try makeCodexFixture(name: "kept")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let removedFile = fixture.sessionsRoot.appendingPathComponent("removed.jsonl")
        try codexTranscript(id: "removed").write(
            to: removedFile,
            atomically: true,
            encoding: .utf8
        )

        var cache = AgentSessionIndexCache()
        _ = CodexSessionIndexer(sessionsDirectory: fixture.sessionsRoot)
            .indexedSessionResult(cache: &cache)
        XCTAssertEqual(cache.entryCount, 2)
        cache.markPersisted()
        try FileManager.default.removeItem(at: removedFile)

        let refreshed = CodexSessionIndexer(sessionsDirectory: fixture.sessionsRoot)
            .indexedSessionResult(cache: &cache)

        XCTAssertEqual(refreshed.stats.prunedCacheEntries, 1)
        XCTAssertEqual(cache.entryCount, 1)
        XCTAssertTrue(cache.isDirty)
    }

    func testMissingRootDoesNotPruneItsCacheEntries() throws {
        let fixture = try makeCodexFixture(name: "missing-root")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var cache = AgentSessionIndexCache()
        _ = CodexSessionIndexer(sessionsDirectory: fixture.sessionsRoot)
            .indexedSessionResult(cache: &cache)
        XCTAssertEqual(cache.entryCount, 1)
        cache.markPersisted()
        try FileManager.default.removeItem(at: fixture.sessionsRoot)

        let refreshed = CodexSessionIndexer(sessionsDirectory: fixture.sessionsRoot)
            .indexedSessionResult(cache: &cache)

        XCTAssertEqual(refreshed.stats.prunedCacheEntries, 0)
        XCTAssertEqual(cache.entryCount, 1)
        XCTAssertFalse(cache.isDirty)
    }

    func testPruningIsIsolatedByProviderAndExactRootBoundary() {
        let parent = uniqueRoot("isolation")
        let root = parent.appendingPathComponent("sessions", isDirectory: true)
        let siblingRoot = parent.appendingPathComponent("sessions-old", isDirectory: true)
        let rootFile = root.appendingPathComponent("root.jsonl")
        let siblingFile = siblingRoot.appendingPathComponent("sibling.jsonl")
        let metadata = AgentSessionIndexCache.FileMetadata(
            fileSize: 42,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_002.5),
            createdAt: nil
        )
        var cache = AgentSessionIndexCache()
        cache[.codex, rootFile, metadata] = nil
        cache[.codex, siblingFile, metadata] = nil
        cache[.claude, rootFile, metadata] = nil

        let pruned = cache.prune(provider: .codex, rootURL: root, keeping: [])

        XCTAssertEqual(pruned, 1)
        XCTAssertEqual(cache.entryCount, 2)
        assertCacheHit(cache.lookup(provider: .codex, fileURL: siblingFile, metadata: metadata))
        assertCacheHit(cache.lookup(provider: .claude, fileURL: rootFile, metadata: metadata))
    }

    private func assertCacheHit(
        _ lookup: AgentSessionIndexCache.Lookup,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .hit = lookup else {
            XCTFail("Cache-Lookup war ein Miss", file: file, line: line)
            return
        }
    }

    private func makeCodexFixture(name: String) throws -> (
        root: URL,
        sessionsRoot: URL,
        file: URL
    ) {
        let root = uniqueRoot(name)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        let file = sessionsRoot.appendingPathComponent("rollout.jsonl")
        try codexTranscript(id: name).write(to: file, atomically: true, encoding: .utf8)
        return (root, sessionsRoot, file)
    }

    private func uniqueRoot(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8IndexCache-\(name)-\(UUID().uuidString)", isDirectory: true)
    }

    private func codexTranscript(id: String) -> String {
        """
        {"type":"session_meta","timestamp":"2026-05-09T12:00:00.000Z","payload":{"id":"\(id)","cwd":"/tmp/repo","timestamp":"2026-05-09T12:00:00.000Z","model":"gpt-5.5"}}
        """
    }
}
