import XCTest

@testable import WhisperM8

/// Der Watcher muss Änderungen an `models_cache.json` melden — auch nach dem
/// atomaren Replace (Rename), mit dem die Codex-CLI die Datei aktualisiert.
@MainActor
final class CodexModelCatalogWatcherTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalog-watcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testReportsInPlaceWriteAndAtomicReplace() async throws {
        let url = directory.appendingPathComponent("models_cache.json")
        try Data("{\"models\":[]}".utf8).write(to: url)

        var changes = 0
        let changed = expectation(description: "Änderung gemeldet")
        changed.expectedFulfillmentCount = 2
        let watcher = CodexModelCatalogWatcher(
            url: url,
            onCatalogChanged: {
                changes += 1
                changed.fulfill()
            },
            debounceInterval: 0.05,
            rearmInterval: 0.05
        )
        watcher.start()
        XCTAssertTrue(watcher.isWatching)

        // 1) In-Place-Write.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.close()

        // 2) Atomarer Replace (so schreibt die Codex-CLI).
        try await Task.sleep(nanoseconds: 150_000_000)
        let staging = directory.appendingPathComponent("models_cache.json.tmp")
        try Data("{\"models\":[{\"slug\":\"gpt-7\"}]}".utf8).write(to: staging)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: staging)

        await fulfillment(of: [changed], timeout: 3)
        XCTAssertEqual(changes, 2)

        // Nach dem Replace ist die Source neu bewaffnet.
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(watcher.isWatching, "Nach Rename muss der Watcher neu bewaffnet sein")
        watcher.stop()
        XCTAssertFalse(watcher.isWatching)
    }

    func testMissingFileIsRetriedUntilItAppears() async throws {
        let url = directory.appendingPathComponent("models_cache.json")
        let watcher = CodexModelCatalogWatcher(
            url: url,
            onCatalogChanged: {},
            debounceInterval: 0.05,
            rearmInterval: 0.05
        )
        watcher.start()
        XCTAssertFalse(watcher.isWatching)

        try Data("{}".utf8).write(to: url)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(watcher.isWatching)
        watcher.stop()
    }
}
