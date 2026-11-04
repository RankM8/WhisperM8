import AppKit
import XCTest
@testable import WhisperM8

@MainActor
final class ClipboardMonitorTests: XCTestCase {
    private var directory: URL!
    private var pasteboard: NSPasteboard!
    private var store: ClipboardHistoryStore!
    private var currentSettings = ClipboardSettings(enabled: true)
    private var frontmost: (bundleID: String?, name: String?) = ("com.apple.Safari", "Safari")

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-monitor-\(UUID().uuidString)", isDirectory: true)
        pasteboard = NSPasteboard(name: NSPasteboard.Name("whisperm8-test-\(UUID().uuidString)"))
        store = ClipboardHistoryStore(directory: directory, debounceSeconds: 0.01)
        currentSettings = ClipboardSettings(enabled: true)
        frontmost = ("com.apple.Safari", "Safari")
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeMonitor() -> ClipboardMonitor {
        ClipboardMonitor(
            store: store, pasteboard: pasteboard, interval: 0.5,
            settings: { [unowned self] in self.currentSettings },
            frontmostApp: { [unowned self] in self.frontmost }
        )
    }

    private func copy(_ text: String, extraTypes: [String] = []) {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        for type in extraTypes { item.setData(Data([1]), forType: NSPasteboard.PasteboardType(type)) }
        pasteboard.writeObjects([item])
    }

    private func entries() -> [ClipboardEntry] {
        store.waitUntilIdle()
        return store.snapshot()
    }

    func testStoresNewCopyWithSourceApp() {
        let monitor = makeMonitor()
        monitor.start(); monitor.stop()
        copy("hello")
        monitor.tick()
        let result = entries()
        XCTAssertEqual(result.map(\.preview), ["hello"])
        XCTAssertEqual(result.first?.sourceName, "Safari")
        XCTAssertEqual(result.first?.sourceBundleID, "com.apple.Safari")
    }

    func testIgnoresContentAlreadyPresentWhenStarted() {
        copy("before")
        let monitor = makeMonitor()
        monitor.start(); monitor.stop()
        monitor.tick()
        XCTAssertTrue(entries().isEmpty)
    }

    func testSameChangeCountIsReadOnlyOnce() {
        let monitor = makeMonitor()
        monitor.start(); monitor.stop()
        copy("once")
        monitor.tick(); monitor.tick(); monitor.tick()
        XCTAssertEqual(entries().count, 1)
    }

    func testSkipsConfidentialAndExcludedApp() {
        let monitor = makeMonitor()
        monitor.start(); monitor.stop()
        copy("secret", extraTypes: ["org.nspasteboard.ConcealedType"])
        monitor.tick()
        frontmost = ("com.1password.1password", "1Password")
        copy("from password manager")
        monitor.tick()
        XCTAssertTrue(entries().isEmpty)
        XCTAssertEqual(monitor.skippedCount, 2)
    }

    func testSkipsWhenDisabledOrPaused() {
        let monitor = makeMonitor()
        monitor.start(); monitor.stop()
        currentSettings.paused = true
        copy("paused")
        monitor.tick()
        currentSettings.paused = false
        currentSettings.enabled = false
        copy("disabled")
        monitor.tick()
        XCTAssertTrue(entries().isEmpty)
    }

    func testOwnMarkerIsIgnored() {
        let monitor = makeMonitor()
        monitor.start(); monitor.stop()
        copy("from our own paste", extraTypes: [ClipboardInternalMarker.typeName])
        monitor.tick()
        XCTAssertTrue(entries().isEmpty)
    }

    func testInternalWriteWindowSuppressesAndSettles() {
        let monitor = makeMonitor()
        monitor.start(); monitor.stop()
        ClipboardInternalWrites.begin()
        copy("dictation paste")
        monitor.tick()   // mitten im eigenen Schreibvorgang
        copy("restored")
        ClipboardInternalWrites.end(pasteboard: pasteboard)
        monitor.tick()   // Grundlinie übernommen
        XCTAssertTrue(entries().isEmpty)
        // Eine echte Kopie danach wird wieder erfasst.
        copy("real copy")
        monitor.tick()
        XCTAssertEqual(entries().map(\.preview), ["real copy"])
    }

    func testDuplicateCopyMovesEntryUp() {
        let monitor = makeMonitor()
        monitor.start(); monitor.stop()
        copy("a"); monitor.tick()
        copy("b"); monitor.tick()
        copy("a"); monitor.tick()
        let result = entries()
        XCTAssertEqual(result.map(\.preview), ["a", "b"])
    }

    func testCapturesRichTextAlongsidePlain() throws {
        let monitor = makeMonitor()
        monitor.start(); monitor.stop()
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString("bold", forType: .string)
        item.setData(Data("{\\rtf1 bold}".utf8), forType: .rtf)
        item.setData(Data("<b>bold</b>".utf8), forType: .html)
        pasteboard.writeObjects([item])
        monitor.tick()
        let entry = try XCTUnwrap(entries().first)
        XCTAssertNotNil(entry.rtfFile)
        XCTAssertNotNil(entry.htmlFile)
    }

    func testFileURLsAreCapturedAsFiles() throws {
        let monitor = makeMonitor()
        monitor.start(); monitor.stop()
        let file = directory.appendingPathComponent("x.txt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: file)
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
        monitor.tick()
        let entry = try XCTUnwrap(entries().first)
        XCTAssertEqual(entry.kind, .files)
        XCTAssertEqual(entry.filePaths?.first.map { URL(fileURLWithPath: $0).lastPathComponent }, "x.txt")
    }
}
