import AppKit
import XCTest
@testable import WhisperM8

/// Fenster und CLI rund um Diktate: Filter „Nur Diktate“, Rückfrage beim
/// Leeren, Roh-Transkript (wann es behalten wird, Suche, CLI).
@MainActor
final class ClipboardDictationWindowTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 50_000)

    private func entry(_ id: String, _ text: String, ago: TimeInterval, mode: String? = nil, original: String? = nil, pinned: Bool = false) -> ClipboardEntry {
        let date = now.addingTimeInterval(-ago)
        var entry = ClipboardEntry(
            id: id, kind: .text, createdAt: date, lastCopiedAt: date, copyCount: 1, isPinned: pinned,
            sourceBundleID: nil, sourceName: nil, contentHash: ClipboardEntry.hash(text: text),
            preview: ClipboardEntry.makePreview(from: text), text: text
        )
        entry.dictationMode = mode
        entry.dictationOriginal = original
        return entry
    }

    private var sample: [ClipboardEntry] {
        [
            entry("copy", "https://example.com", ago: 5),
            entry("dict1", "Klar, bis morgen.", ago: 10, mode: "Slack", original: "jo klar mach ich bis morgen"),
            entry("pin", "ssh deploy@host", ago: 500, pinned: true),
            entry("dict2", "Meeting um zehn", ago: 30, mode: "Fast"),
        ]
    }

    private func makeModel(_ entries: [ClipboardEntry]) -> ClipboardHistoryViewModel {
        let model = ClipboardHistoryViewModel(
            loaders: .init(fullText: { $0.text }, image: { _, _ in nil }, appIcon: { _ in nil }), now: { self.now }
        )
        model.setEntries(entries)
        return model
    }

    // MARK: Filter

    func testDictationFilterShowsOnlyDictationsAndNumbersFollowIt() {
        let model = makeModel(sample)
        var pasted: [String] = []
        model.actions.paste = { entry, _ in pasted.append(entry.id) }

        model.filter = .dictations
        XCTAssertEqual(model.visible.map(\.id), ["dict1", "dict2"])
        XCTAssertEqual(model.selectedID, "dict1")
        model.handle(.quickSelect(2))
        XCTAssertEqual(pasted, ["dict2"])
    }

    func testFilterCombinesWithSearch() {
        let model = makeModel(sample)
        model.filter = .dictations
        model.query = "meeting"
        XCTAssertEqual(model.visible.map(\.id), ["dict2"])
        model.filter = .all
        XCTAssertEqual(model.visible.map(\.id), ["dict2"])
    }

    func testCommandDTogglesFilterAndResetGoesBackToAll() {
        XCTAssertEqual(ClipboardKeyCommand.resolve(keyCode: 2, characters: "d", modifiers: .command), .toggleDictationFilter)
        XCTAssertNil(ClipboardKeyCommand.resolve(keyCode: 2, characters: "d", modifiers: []))

        let model = makeModel(sample)
        model.handle(.toggleDictationFilter)
        XCTAssertEqual(model.filter, .dictations)
        model.handle(.toggleDictationFilter)
        XCTAssertEqual(model.filter, .all)

        model.filter = .dictations
        model.isConfirmingClear = true
        model.reset()
        XCTAssertEqual(model.filter, .all)
        XCTAssertFalse(model.isConfirmingClear)
    }

    func testSearchFindsWordsOnlyInTheOriginalTranscript() {
        let model = makeModel(sample)
        model.query = "jo klar"
        XCTAssertEqual(model.visible.map(\.id), ["dict1"])
    }

    // MARK: Verlauf leeren

    func testClearAsksFirstAndEscapeCancelsBeforeClosing() {
        let model = makeModel(sample)
        var cleared = 0
        var closed = 0
        model.actions.clearUnpinned = { cleared += 1 }
        model.actions.close = { closed += 1 }

        model.isConfirmingClear = true
        model.handle(.close)
        XCTAssertFalse(model.isConfirmingClear)
        XCTAssertEqual(closed, 0)
        XCTAssertEqual(cleared, 0)

        model.handle(.close)
        XCTAssertEqual(closed, 1)

        model.isConfirmingClear = true
        model.confirmClear()
        XCTAssertEqual(cleared, 1)
        XCTAssertFalse(model.isConfirmingClear)
    }

    func testClearUnpinnedKeepsPinsInTheStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-clear-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardHistoryStore(directory: directory, debounceSeconds: 0.01)
        store.add(ClipboardCapture(text: "behalten"), maxItems: 50)
        store.add(ClipboardCapture(text: "weg"), maxItems: 50)
        store.waitUntilIdle()
        let keep = try XCTUnwrap(store.snapshot().first { $0.preview == "behalten" })
        store.setPinned(id: keep.id, pinned: true)
        store.clear(keepPinned: true)
        store.waitUntilIdle()
        XCTAssertEqual(store.snapshot().map(\.preview), ["behalten"])
    }

    // MARK: Roh-Transkript

    func testOriginalIsKeptOnlyWhenItDiffers() {
        XCTAssertEqual(ClipboardHistoryCore.keptOriginal("jo klar", text: "Klar."), "jo klar")
        XCTAssertNil(ClipboardHistoryCore.keptOriginal("Klar.", text: "Klar."))
        XCTAssertNil(ClipboardHistoryCore.keptOriginal(" Klar. \n", text: "Klar."))
        XCTAssertNil(ClipboardHistoryCore.keptOriginal("   ", text: "Klar."))
        XCTAssertNil(ClipboardHistoryCore.keptOriginal(nil, text: "Klar."))
        let huge = String(repeating: "a", count: ClipboardHistoryCore.maxDictationOriginalChars + 1)
        XCTAssertNil(ClipboardHistoryCore.keptOriginal(huge, text: "kurz"))
    }

    func testRecordCarriesOriginalOnlyForPostProcessingModes() throws {
        let fast = try XCTUnwrap(OutputMode.builtInModes.first { $0.id == OutputMode.rawID })
        let slack = try XCTUnwrap(OutputMode.builtInModes.first { $0.id == OutputMode.slackID })
        XCTAssertNil(DictationHistoryRecord.make(finalText: "a", rawText: "a", mode: fast, targetApp: nil).original)
        XCTAssertEqual(DictationHistoryRecord.make(finalText: "Klar.", rawText: "jo klar", mode: slack, targetApp: nil).original, "jo klar")
    }

    func testDictationCaptureStoresOriginalAndStoreKeepsIt() throws {
        var settings = ClipboardSettings()
        settings.enabled = true
        let capture = try XCTUnwrap(ClipboardHistoryCore.dictationCapture(
            text: "Klar, bis morgen.", original: "jo klar bis morgen", modeName: "Slack",
            targetBundleID: nil, targetName: nil, settings: settings
        ))
        XCTAssertEqual(capture.dictationOriginal, "jo klar bis morgen")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-original-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardHistoryStore(directory: directory, debounceSeconds: 0.01)
        store.add(capture, maxItems: 50)
        store.flush()
        XCTAssertEqual(ClipboardHistoryStore.loadIndex(directory: directory).first?.dictationOriginal, "jo klar bis morgen")
    }

    // MARK: CLI

    func testCLIParsesOriginalFlag() throws {
        XCTAssertEqual(
            try ClipboardCLIArguments.parse(["get", "1", "--original"]),
            .get(ref: "1", json: false, maxChars: ClipboardCLIArguments.defaultMaxChars, from: 0, original: true)
        )
    }

    func testCLIGetReturnsOriginalOrResultWithHint() {
        var settings = ClipboardSettings()
        settings.enabled = true
        let context = ClipboardCLIFormatter.Context(
            settings: settings, directory: URL(fileURLWithPath: "/tmp"), fullText: { $0.text }, now: now
        )
        let dictation = entry("d", "Klar, bis morgen.", ago: 1, mode: "Slack", original: "jo klar")

        XCTAssertEqual(ClipboardCLIFormatter.summary(dictation, number: 1, context: context)["hasOriginal"] as? Bool, true)

        let result = ClipboardCLIFormatter.detail(dictation, number: 1, json: false, context: context)
        XCTAssertEqual(result.stdout, "Klar, bis morgen.")
        XCTAssertTrue(result.note?.contains("--original") == true)

        let original = ClipboardCLIFormatter.detail(dictation, number: 1, json: false, context: context, original: true)
        XCTAssertEqual(original.stdout, "jo klar")

        let plain = entry("p", "nur kopiert", ago: 1)
        XCTAssertNil(ClipboardCLIFormatter.summary(plain, number: 2, context: context)["hasOriginal"])
        let fallback = ClipboardCLIFormatter.detail(plain, number: 2, json: false, context: context, original: true)
        XCTAssertEqual(fallback.stdout, "nur kopiert")
        XCTAssertTrue(fallback.note?.contains("Kein Roh-Transkript") == true)
    }

    // MARK: Schrift der Vorschau

    func testPreviewUsesMonospaceOnlyForCodeLikeText() {
        XCTAssertFalse(ClipboardPreviewStyle.prefersMonospace("Klar, ich schaue mir den PR heute Abend an."))
        XCTAssertFalse(ClipboardPreviewStyle.prefersMonospace("https://github.com/rankm8/whisperm8/pull/42"))
        XCTAssertFalse(ClipboardPreviewStyle.prefersMonospace("Erste Zeile\nZweite Zeile\nDritte Zeile"))
        XCTAssertTrue(ClipboardPreviewStyle.prefersMonospace("TypeError: x\n    at renderList (app.js:128:22)\n    at App (app.js:40:9)"))
        XCTAssertTrue(ClipboardPreviewStyle.prefersMonospace("func paste(_ entry: ClipboardEntry) { }"))
        XCTAssertTrue(ClipboardPreviewStyle.prefersMonospace("~/repos/whisperm8/WhisperM8"))
        XCTAssertTrue(ClipboardPreviewStyle.prefersMonospace("$ swift test --filter Clipboard"))
        XCTAssertFalse(ClipboardPreviewStyle.prefersMonospace(""))
    }

    // MARK: Große Bildansicht

    private func imageEntry(_ id: String, ago: TimeInterval) -> ClipboardEntry {
        var entry = entry(id, "", ago: ago)
        entry.kind = .image
        entry.text = nil
        entry.preview = "Image 10 × 10"
        entry.imageFile = "\(id).png"
        return entry
    }

    func testZoomOnlyForImagesAndEscapeGoesBackFirst() {
        let model = makeModel([imageEntry("img", ago: 1), entry("txt", "Text", ago: 2)])
        var closed = 0
        model.actions.close = { closed += 1 }

        model.select("txt")
        model.handle(.toggleZoom)
        XCTAssertFalse(model.isZoomed)

        model.select("img")
        model.handle(.toggleZoom)
        XCTAssertTrue(model.isZoomed)

        model.handle(.close)
        XCTAssertFalse(model.isZoomed)
        XCTAssertEqual(closed, 0)
        model.handle(.close)
        XCTAssertEqual(closed, 1)
    }

    func testZoomClosesWhenSelectionMovesToTextAndEnterPastesTheImage() {
        let model = makeModel([imageEntry("img", ago: 1), entry("txt", "Text", ago: 2)])
        var pasted: [String] = []
        model.actions.paste = { entry, _ in pasted.append(entry.id) }

        model.select("img")
        model.openZoom()
        model.handle(.paste)
        XCTAssertEqual(pasted, ["img"])

        model.handle(.moveDown)
        XCTAssertEqual(model.selectedID, "txt")
        XCTAssertFalse(model.isZoomed)
    }

    func testCommandYTogglesZoomAndResetClosesIt() {
        XCTAssertEqual(ClipboardKeyCommand.resolve(keyCode: 16, characters: "y", modifiers: .command), .toggleZoom)
        let model = makeModel([imageEntry("img", ago: 1)])
        model.openZoom()
        XCTAssertTrue(model.isZoomed)
        model.reset()
        XCTAssertFalse(model.isZoomed)
    }
}

