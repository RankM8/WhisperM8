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

    func testOnChangeFiresAfterAdd() {
        let store = makeStore()
        let expectation = expectation(description: "change")
        store.onChange = { entries in
            if entries.count == 1 { expectation.fulfill() }
        }
        store.add(text("x"), maxItems: 10)
        wait(for: [expectation], timeout: 2)
    }
}
