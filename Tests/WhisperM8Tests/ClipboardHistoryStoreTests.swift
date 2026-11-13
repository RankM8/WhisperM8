import AppKit
import XCTest
@testable import WhisperM8

final class ClipboardHistoryStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-store-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore(limits: ClipboardHistoryStore.Limits = .init()) -> ClipboardHistoryStore {
        ClipboardHistoryStore(directory: directory, limits: limits, debounceSeconds: 0.01)
    }

    private func text(_ value: String, at seconds: TimeInterval = 0, app: String? = nil) -> ClipboardCapture {
        ClipboardCapture(text: value, sourceName: app, date: Date(timeIntervalSince1970: seconds))
    }

    private func pngData(width: Int = 8, height: Int = 6) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        return rep.representation(using: .png, properties: [:])!
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func testPersistenceRoundtripAndPermissions() throws {
        let store = makeStore()
        store.add(text("hello world", at: 10, app: "Safari"), maxItems: 50)
        store.add(text("second", at: 20), maxItems: 50)
        store.flush()

        let loaded = ClipboardHistoryStore.loadIndex(directory: directory)
        XCTAssertEqual(loaded.map(\.preview), ["second", "hello world"])
        XCTAssertEqual(loaded.last?.sourceName, "Safari")
        XCTAssertEqual(loaded.last?.lastCopiedAt, Date(timeIntervalSince1970: 10))

        XCTAssertEqual(try permissions(directory), 0o700)
        XCTAssertEqual(try permissions(directory.appendingPathComponent("index.json")), 0o600)
    }

    func testReloadFromDiskInNewStore() {
        let first = makeStore()
        first.add(text("persisted", at: 1), maxItems: 50)
        first.flush()
        XCTAssertEqual(makeStore().snapshot().map(\.preview), ["persisted"])
    }

    func testDuplicateMovesToTopInsteadOfDoubling() {
        let store = makeStore()
        store.add(text("a", at: 1), maxItems: 50)
        store.add(text("b", at: 2), maxItems: 50)
        store.add(text("a", at: 3), maxItems: 50)
        let entries = store.snapshot()
        XCTAssertEqual(entries.map(\.preview), ["a", "b"])
        XCTAssertEqual(entries[0].copyCount, 2)
    }

    func testTrimDropsOldestUnpinnedAndKeepsPins() {
        let store = makeStore()
        store.add(text("pinned", at: 1), maxItems: 2)
        store.setPinned(id: store.snapshot()[0].id, pinned: true)
        for index in 2...6 { store.add(text("e\(index)", at: TimeInterval(index)), maxItems: 2) }
        let previews = store.snapshot().map(\.preview)
        XCTAssertEqual(Set(previews), ["pinned", "e5", "e6"])
    }

    func testLargeTextAndRichFormatsGoToBlobFiles() throws {
        var limits = ClipboardHistoryStore.Limits()
        limits.maxInlineTextChars = 10
        let store = makeStore(limits: limits)
        var capture = text("this text is longer than ten characters", at: 5)
        capture.rtf = Data("{\\rtf1 hi}".utf8)
        capture.html = Data("<b>hi</b>".utf8)
        store.add(capture, maxItems: 10)
        store.flush()

        let entry = try XCTUnwrap(store.snapshot().first)
        XCTAssertNil(entry.text)
        let textFile = try XCTUnwrap(entry.textFile)
        XCTAssertEqual(store.fullText(of: entry), "this text is longer than ten characters")
        for file in [textFile, try XCTUnwrap(entry.rtfFile), try XCTUnwrap(entry.htmlFile)] {
            XCTAssertEqual(try permissions(directory.appendingPathComponent(file)), 0o600, file)
        }
    }

    func testImageIsStoredAsPNGFile() throws {
        let store = makeStore()
        store.add(ClipboardCapture(imageData: pngData(width: 8, height: 6), imageIsPNG: true), maxItems: 10)
        let entry = try XCTUnwrap(store.snapshot().first)
        XCTAssertEqual(entry.kind, .image)
        XCTAssertEqual(entry.imageWidth, 8)
        XCTAssertEqual(entry.imageHeight, 6)
        let file = try XCTUnwrap(entry.imageFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(file).path))
        XCTAssertEqual(try permissions(directory.appendingPathComponent(file)), 0o600)
    }

    func testTIFFImageIsConvertedToPNG() throws {
        let tiff = try XCTUnwrap(NSBitmapImageRep(data: pngData())?.tiffRepresentation)
        let store = makeStore()
        store.add(ClipboardCapture(imageData: tiff, imageIsPNG: false), maxItems: 10)
        let entry = try XCTUnwrap(store.snapshot().first)
        let data = try Data(contentsOf: directory.appendingPathComponent(try XCTUnwrap(entry.imageFile)))
        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    func testOversizedImageAndEmptyTextAreIgnored() {
        var limits = ClipboardHistoryStore.Limits()
        limits.maxImageBytes = 10
        let store = makeStore(limits: limits)
        store.add(ClipboardCapture(imageData: pngData(), imageIsPNG: true), maxItems: 10)
        store.add(text("   \n  "), maxItems: 10)
        XCTAssertTrue(store.snapshot().isEmpty)
    }

    func testFileURLsBecomeFilesEntry() throws {
        let store = makeStore()
        store.add(ClipboardCapture(text: "report.pdf", filePaths: ["/Users/demo/report.pdf", "/Users/demo/b.txt"]), maxItems: 10)
        let entry = try XCTUnwrap(store.snapshot().first)
        XCTAssertEqual(entry.kind, .files)
        XCTAssertEqual(entry.filePaths, ["/Users/demo/report.pdf", "/Users/demo/b.txt"])
        XCTAssertEqual(entry.preview, "report.pdf, b.txt")
    }

    func testDeleteRemovesBlobFiles() throws {
        let store = makeStore()
        store.add(ClipboardCapture(imageData: pngData(), imageIsPNG: true), maxItems: 10)
        let entry = try XCTUnwrap(store.snapshot().first)
        let file = directory.appendingPathComponent(try XCTUnwrap(entry.imageFile))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        store.delete(id: entry.id)
        store.waitUntilIdle()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(store.snapshot().isEmpty)
    }

    func testClearKeepsPinnedWhenAsked() {
        let store = makeStore()
        store.add(text("keep", at: 1), maxItems: 10)
        store.setPinned(id: store.snapshot()[0].id, pinned: true)
        store.add(text("drop", at: 2), maxItems: 10)
        store.clear(keepPinned: true)
        XCTAssertEqual(store.snapshot().map(\.preview), ["keep"])
        store.clear()
        XCTAssertTrue(store.snapshot().isEmpty)
    }

    func testBumpMovesEntryToTop() {
        let store = makeStore()
        store.add(text("old", at: 1), maxItems: 10)
        store.add(text("new", at: 2), maxItems: 10)
        let old = store.snapshot().first { $0.preview == "old" }!
        store.bump(id: old.id, at: Date(timeIntervalSince1970: 50))
        XCTAssertEqual(ClipboardHistoryCore.chronological(store.snapshot()).first?.preview, "old")
    }

    func testBrokenIndexMeansEmptyHistory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("index.json"))
        XCTAssertTrue(ClipboardHistoryStore.loadIndex(directory: directory).isEmpty)
    }

    func testUnreadableIndexIsSetAsideAndItsFilesStay() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ kaputt".utf8).write(to: directory.appendingPathComponent("index.json"))
        try Data("blob".utf8).write(to: directory.appendingPathComponent("abc.txt"))
        let store = makeStore()
        XCTAssertTrue(store.snapshot().isEmpty)
        store.add(text("neu"), maxItems: 10)
        store.flush()
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(names.contains { $0.hasPrefix(ClipboardHistoryStore.brokenIndexPrefix) }, "kaputter Index beiseitegelegt")
        XCTAssertTrue(names.contains("abc.txt"), "Dateien eines unlesbaren Index werden nicht weggeräumt")
        XCTAssertEqual(ClipboardHistoryStore.loadIndex(directory: directory).map(\.preview), ["neu"])
        // Auch beim nächsten Start bleibt alles liegen, erst „Verlauf leeren“ räumt.
        let again = makeStore()
        XCTAssertEqual(again.snapshot().map(\.preview), ["neu"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("abc.txt").path))
        again.clear()
        again.flush()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["index.json"])
    }

    func testOneBrokenEntryDoesNotCostTheWholeHistory() throws {
        let store = makeStore()
        store.add(text("eins", at: 1), maxItems: 10)
        store.add(text("zwei", at: 2), maxItems: 10)
        store.flush()
        let url = directory.appendingPathComponent("index.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var entries = try XCTUnwrap(json["entries"] as? [[String: Any]])
        entries[0]["kind"] = "hologram"
        entries.append(["unsinn": true])
        json["entries"] = entries
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        XCTAssertEqual(ClipboardHistoryStore.loadIndex(directory: directory).count, 1)
    }

    func testOrphanBlobsFromACrashAreRemovedOnLoad() throws {
        let store = makeStore()
        store.add(text("bleibt", at: 1), maxItems: 10)
        store.flush()
        try Data("geheimer Rest".utf8).write(to: directory.appendingPathComponent("dead-beef.txt"))
        try Data("x".utf8).write(to: directory.appendingPathComponent(".index.json.1234.tmp"))
        XCTAssertEqual(makeStore().snapshot().map(\.preview), ["bleibt"])
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(names.sorted(), ["index.json"])
    }

    func testClearWithoutPinsEmptiesTheFolder() throws {
        let store = makeStore()
        store.add(ClipboardCapture(imageData: pngData(), imageIsPNG: true), maxItems: 10)
        store.add(text(String(repeating: "lang ", count: 5000)), maxItems: 10)
        store.flush()
        try Data("rest".utf8).write(to: directory.appendingPathComponent("orphan.png"))
        store.clear()
        store.flush()
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(names, ["index.json"])
        XCTAssertTrue(ClipboardHistoryStore.loadIndex(directory: directory).isEmpty)
    }

    /// Fußzeile „Clear History…“ und Löschen: Der Index auf der Platte ist
    /// sofort ohne die Texte, nicht erst nach dem Debounce. Sonst kämen sie nach
    /// einem Absturz in diesem Fenster beim nächsten Start zurück.
    func testClearAndDeleteWriteTheIndexImmediately() throws {
        let store = ClipboardHistoryStore(directory: directory, debounceSeconds: 60)
        store.add(text("bleibt", at: 1), maxItems: 10)
        store.add(ClipboardCapture(imageData: pngData(), imageIsPNG: true, date: Date(timeIntervalSince1970: 2)), maxItems: 10)
        store.add(text("geheim-eins", at: 3), maxItems: 10)
        store.add(text("geheim-zwei", at: 4), maxItems: 10)
        let entries = store.snapshot()
        let pinned = try XCTUnwrap(entries.first { $0.text == "bleibt" })
        let image = try XCTUnwrap(entries.first { $0.kind == .image })
        let imageFile = directory.appendingPathComponent(try XCTUnwrap(image.imageFile))
        store.setPinned(id: pinned.id, pinned: true)
        store.flush()

        let deleted = try XCTUnwrap(entries.first { $0.text == "geheim-zwei" })
        store.delete(id: deleted.id)
        store.waitUntilIdle()
        XCTAssertEqual(ClipboardHistoryStore.loadIndex(directory: directory).count, 3)

        store.clear(keepPinned: true)
        store.waitUntilIdle()
        XCTAssertEqual(ClipboardHistoryStore.loadIndex(directory: directory).map(\.id), [pinned.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: imageFile.path))
        let raw = String(decoding: try Data(contentsOf: directory.appendingPathComponent("index.json")), as: UTF8.self)
        XCTAssertFalse(raw.contains("geheim"))
    }

    /// Nach `flush()` läuft kein geplantes Schreiben mehr nach (der Wackler in
    /// `testClearWithoutPinsEmptiesTheFolder`: Temp-Datei beim Auflisten).
    func testFlushCancelsThePendingWrite() throws {
        let store = ClipboardHistoryStore(directory: directory, debounceSeconds: 0.05)
        store.add(text("eins"), maxItems: 10)
        store.flush()
        let index = directory.appendingPathComponent("index.json")
        let before = try FileManager.default.attributesOfItem(atPath: index.path)[.systemFileNumber] as? NSNumber
        Thread.sleep(forTimeInterval: 0.25)
        store.waitUntilIdle()
        let after = try FileManager.default.attributesOfItem(atPath: index.path)[.systemFileNumber] as? NSNumber
        XCTAssertEqual(before, after)
    }

    func testArchiveIsStoredWithPermissionsAndDeletedWithTheEntry() throws {
        let store = makeStore()
        let archive = ClipboardArchive(items: [[
            ClipboardRepresentation(type: "public.utf8-plain-text", data: Data("Zelle".utf8)),
            ClipboardRepresentation(type: "com.apple.numbers.table", data: Data([1, 2, 3])),
        ]])
        store.add(ClipboardCapture(text: "Zelle", archive: archive), maxItems: 10)
        let entry = try XCTUnwrap(store.snapshot().first)
        let file = directory.appendingPathComponent(try XCTUnwrap(entry.archiveFile))
        XCTAssertEqual(try permissions(file), 0o600)
        XCTAssertEqual(ClipboardArchive.decode(try Data(contentsOf: file)), archive)
        store.delete(id: entry.id)
        store.waitUntilIdle()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testPlainTextNeedsNoArchive() throws {
        let store = makeStore()
        let archive = ClipboardArchive(items: [[ClipboardRepresentation(type: "public.utf8-plain-text", data: Data("x".utf8))]])
        store.add(ClipboardCapture(text: "x", archive: archive), maxItems: 10)
        XCTAssertNil(try XCTUnwrap(store.snapshot().first).archiveFile)
    }

    func testLongTextIsSearchableInFullWithoutDiskAccess() throws {
        var limits = ClipboardHistoryStore.Limits()
        limits.maxInlineTextChars = 100
        let store = makeStore(limits: limits)
        let log = (1...4000).map { "line \($0) ok" }.joined(separator: "\n") + "\nFATAL: Ölstand kritisch in worker-7"
        store.add(text(log, at: 1), maxItems: 10)
        store.add(text("kurz", at: 2), maxItems: 10)
        let entries = store.snapshot()
        let index = store.searchSnapshot()
        // Datei weg: die Suche braucht sie nicht mehr.
        let long = try XCTUnwrap(entries.first { $0.textFile != nil })
        try FileManager.default.removeItem(at: directory.appendingPathComponent(try XCTUnwrap(long.textFile)))
        let found = ClipboardHistoryCore.search(entries, query: "olstand WORKER-7") { index.haystack(for: $0.id) ?? [] }
        XCTAssertEqual(found.map(\.id), [long.id])
        XCTAssertEqual(long.charCount, log.count)
    }

    func testSearchIndexReloadsLongTextsFromDisk() {
        var limits = ClipboardHistoryStore.Limits()
        limits.maxInlineTextChars = 10
        let first = makeStore(limits: limits)
        first.add(text("anfang " + String(repeating: "x", count: 50) + " needle-am-ende", at: 1), maxItems: 10)
        first.flush()
        let second = makeStore(limits: limits)
        let entries = second.snapshot()
        let index = second.searchSnapshot()
        XCTAssertEqual(ClipboardHistoryCore.search(entries, query: "needle-am-ende") { index.haystack(for: $0.id) ?? [] }.count, 1)
    }

    func testObserveDeliversLoadedStateAndChanges() {
        let store = makeStore()
        let loaded = expectation(description: "geladen")
        let changed = expectation(description: "geändert")
        store.observe { state in
            if state.entries.isEmpty { loaded.fulfill() }
            if state.entries.count == 1, state.search.haystack(for: state.entries[0].id) != nil { changed.fulfill() }
        }
        store.add(text("x"), maxItems: 10)
        wait(for: [loaded, changed], timeout: 2)
    }
}
