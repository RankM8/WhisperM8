import XCTest
@testable import WhisperM8

/// Diktat-Ergebnisse im Zwischenablage-Verlauf: wann sie hineinkommen, dass
/// Modus und Ziel-App mitgespeichert werden und alte Indexdateien lesbar bleiben.
final class ClipboardDictationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-dictation-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private var enabled: ClipboardSettings {
        var settings = ClipboardSettings()
        settings.enabled = true
        return settings
    }

    func testDictationBecomesCaptureWithModeAndTargetApp() throws {
        let capture = try XCTUnwrap(ClipboardHistoryCore.dictationCapture(
            text: "Klar, mache ich bis morgen.", modeName: "Slack",
            targetBundleID: "com.tinyspeck.slackmacgap", targetName: "Slack",
            settings: enabled
        ))
        XCTAssertEqual(capture.text, "Klar, mache ich bis morgen.")
        XCTAssertEqual(capture.dictationMode, "Slack")
        XCTAssertEqual(capture.sourceBundleID, "com.tinyspeck.slackmacgap")
        XCTAssertEqual(capture.sourceName, "Slack")
    }

    func testNoCaptureWhenHistoryOffOrPaused() {
        XCTAssertNil(ClipboardHistoryCore.dictationCapture(
            text: "x", modeName: "Fast", targetBundleID: nil, targetName: nil, settings: ClipboardSettings()
        ))
        var paused = enabled
        paused.paused = true
        XCTAssertNil(ClipboardHistoryCore.dictationCapture(
            text: "x", modeName: "Fast", targetBundleID: nil, targetName: nil, settings: paused
        ))
    }

    func testNoCaptureForExcludedTargetApp() {
        XCTAssertNil(ClipboardHistoryCore.dictationCapture(
            text: "geheim", modeName: "Fast",
            targetBundleID: "com.1password.1password", targetName: "1Password", settings: enabled
        ))
    }

    func testNoCaptureForEmptyText() {
        XCTAssertNil(ClipboardHistoryCore.dictationCapture(
            text: "  \n ", modeName: "Fast", targetBundleID: nil, targetName: nil, settings: enabled
        ))
    }

    func testWorksWithoutTargetApp() throws {
        let capture = try XCTUnwrap(ClipboardHistoryCore.dictationCapture(
            text: "nur kopiert", modeName: "Clean", targetBundleID: nil, targetName: nil, settings: enabled
        ))
        XCTAssertNil(capture.sourceName)
        XCTAssertEqual(capture.dictationMode, "Clean")
    }

    func testStoreKeepsDictationModeAcrossReload() throws {
        let store = ClipboardHistoryStore(directory: directory, debounceSeconds: 0.01)
        let capture = try XCTUnwrap(ClipboardHistoryCore.dictationCapture(
            text: "Diktierter Satz", modeName: "Email", targetBundleID: "com.apple.mail", targetName: "Mail",
            settings: enabled
        ))
        store.add(capture, maxItems: 50)
        store.add(ClipboardCapture(text: "normale Kopie"), maxItems: 50)
        store.flush()

        let loaded = ClipboardHistoryStore.loadIndex(directory: directory)
        XCTAssertEqual(loaded.first { $0.preview == "Diktierter Satz" }?.dictationMode, "Email")
        XCTAssertNil(loaded.first { $0.preview == "normale Kopie" }?.dictationMode)
    }

    func testOldIndexWithoutDictationFieldStillDecodes() throws {
        let json = """
        [{"id":"a","kind":"text","createdAt":0,"lastCopiedAt":0,"copyCount":1,"isPinned":false,
          "contentHash":"h","preview":"alt","text":"alt"}]
        """
        let entries = try JSONDecoder().decode([ClipboardEntry].self, from: Data(json.utf8))
        XCTAssertEqual(entries.first?.preview, "alt")
        XCTAssertNil(entries.first?.dictationMode)
    }

    func testCLIShowsDictationMode() {
        var entry = ClipboardEntry(
            id: "d", kind: .text, createdAt: Date(), lastCopiedAt: Date(), copyCount: 1, isPinned: false,
            sourceBundleID: nil, sourceName: "Safari", contentHash: "h", preview: "Hallo", text: "Hallo"
        )
        entry.dictationMode = "Slack"
        let context = ClipboardCLIFormatter.Context(
            settings: enabled, directory: directory, fullText: { $0.text }, now: Date()
        )
        XCTAssertEqual(ClipboardCLIFormatter.summary(entry, number: 1, context: context)["dictationMode"] as? String, "Slack")
        XCTAssertTrue(ClipboardCLIFormatter.listing([(1, entry)], json: false, context: context).contains("Diktat Slack"))
    }
}
