import AppKit
import XCTest
@testable import WhisperM8

/// Befunde aus dem Review vom 05.11.2026: große Bildansicht bleibt beim
/// gezeigten Bild, Speichergrenzen, Diktat beim Verschmelzen, Maskierung.
@MainActor
final class ClipboardReviewFixTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 50_000)

    private func text(_ id: String, _ value: String, ago: TimeInterval, mode: String? = nil) -> ClipboardEntry {
        let date = now.addingTimeInterval(-ago)
        var entry = ClipboardEntry(
            id: id, kind: .text, createdAt: date, lastCopiedAt: date, copyCount: 1, isPinned: false,
            sourceBundleID: nil, sourceName: nil, contentHash: ClipboardEntry.hash(text: value),
            preview: ClipboardEntry.makePreview(from: value), text: value
        )
        entry.dictationMode = mode
        return entry
    }

    private func image(_ id: String, ago: TimeInterval, bytes: Int = 1000, pinned: Bool = false) -> ClipboardEntry {
        let date = now.addingTimeInterval(-ago)
        var entry = ClipboardEntry(
            id: id, kind: .image, createdAt: date, lastCopiedAt: date, copyCount: 1, isPinned: pinned,
            sourceBundleID: nil, sourceName: nil, contentHash: id, preview: "Image \(id)"
        )
        entry.imageFile = "\(id).png"
        entry.blobBytes = bytes
        return entry
    }

    private func makeModel(_ entries: [ClipboardEntry], loaded: [String: NSImage] = [:]) -> ClipboardHistoryViewModel {
        let model = ClipboardHistoryViewModel(
            loaders: .init(fullText: { $0.text }, image: { entry, _ in loaded[entry.id] }, appIcon: { _ in nil }),
            now: { self.now }
        )
        model.setEntries(entries)
        return model
    }

    private func pixel() -> NSImage { NSImage(size: NSSize(width: 4, height: 4)) }

    // MARK: 1. Große Bildansicht

    func testSearchChangeWhileZoomedFollowsSelectionAndPastesWhatIsShown() async throws {
        let first = pixel(), second = pixel()
        let model = makeModel([image("a", ago: 1), image("b", ago: 2)], loaded: ["a": first, "b": second])
        var pasted: [String] = []
        model.actions.paste = { entry, _ in pasted.append(entry.id) }
        model.isPresented = true

        model.select("a")
        model.openZoom()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(model.zoomImageForSelection === first)

        // Suche trifft nur noch „b“: Auswahl springt, die große Ansicht zieht mit.
        model.query = "image b"
        XCTAssertEqual(model.selectedID, "b")
        XCTAssertTrue(model.isZoomed)
        XCTAssertFalse(model.zoomImageForSelection === first, "das alte Bild darf nicht stehen bleiben")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(model.zoomImageForSelection === second)

        model.handle(.paste)
        XCTAssertEqual(pasted, ["b"])
    }

    func testZoomClosesWhenFilterEmptiesTheList() {
        let model = makeModel([image("a", ago: 1)])
        model.select("a")
        model.openZoom()
        model.filter = .dictations
        XCTAssertFalse(model.isZoomed)
        XCTAssertNil(model.selectedID)
    }

    func testZoomClosesWhenTheZoomedEntryDisappears() {
        let model = makeModel([image("a", ago: 1), text("t", "Text", ago: 2)])
        model.select("a")
        model.openZoom()
        model.setEntries([text("t", "Text", ago: 2)])
        XCTAssertEqual(model.selectedID, "t")
        XCTAssertFalse(model.isZoomed)
    }

    func testKeysWhileZoomedNeverReachTheSearchField() {
        func zoomed(_ code: UInt16, _ chars: String?, _ mods: NSEvent.ModifierFlags = []) -> ClipboardKeyCommand? {
            ClipboardKeyCommand.resolveWhileZoomed(keyCode: code, characters: chars, modifiers: mods)
        }
        XCTAssertEqual(zoomed(49, " "), .toggleZoom, "Leertaste schließt")
        XCTAssertNil(zoomed(0, "a"), "Buchstaben werden geschluckt")
        XCTAssertNil(zoomed(2, "d", .command), "⌘D tauscht die Liste unter dem Bild nicht")
        XCTAssertEqual(zoomed(36, "\r"), .paste)
        XCTAssertEqual(zoomed(53, nil), .close)
        XCTAssertEqual(zoomed(125, nil), .moveDown)
        XCTAssertEqual(zoomed(16, "y", .command), .toggleZoom)
    }

    // MARK: 2. Speichergrenzen

    func testPreviewImagesAreCappedAndFreedWhenTheWindowCloses() {
        let model = makeModel([image("a", ago: 1)])
        model.isPresented = true
        for index in 0..<(ClipboardHistoryViewModel.previewImageCacheLimit + 5) {
            model.rememberPreviewImage(pixel(), for: "id\(index)")
        }
        XCTAssertEqual(model.cachedPreviewImageCount, ClipboardHistoryViewModel.previewImageCacheLimit)
        model.isPresented = false
        XCTAssertEqual(model.cachedPreviewImageCount, 0)
    }

    func testTrimDropsOldestUnpinnedWhenTheByteBudgetIsExceeded() {
        let entries = [
            image("new", ago: 1, bytes: 400),
            image("mid", ago: 2, bytes: 400),
            image("pin", ago: 3, bytes: 5_000, pinned: true),
            image("old", ago: 4, bytes: 400),
        ]
        let result = ClipboardHistoryCore.trim(entries, maxUnpinned: 200, maxUnpinnedBytes: 900)
        XCTAssertEqual(Set(result.kept.map(\.id)), ["new", "mid", "pin"])
        XCTAssertEqual(result.removed.map(\.id), ["old"])

        // Der neueste bleibt, auch wenn er allein zu groß ist.
        let huge = ClipboardHistoryCore.trim([image("big", ago: 1, bytes: 10_000)], maxUnpinned: 200, maxUnpinnedBytes: 900)
        XCTAssertEqual(huge.kept.map(\.id), ["big"])
    }

    func testStoreRecordsBlobBytesOfImages() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-bytes-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 6, pixelsHigh: 6, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let store = ClipboardHistoryStore(directory: directory, debounceSeconds: 0.01)
        store.add(ClipboardCapture(imageData: png, imageIsPNG: true), maxItems: 50)
        store.waitUntilIdle()
        XCTAssertEqual(store.snapshot().first?.blobBytes, png.count)
    }

    // MARK: 3. Diktat und frühere Kopie

    func testDictationOfAnAlreadyCopiedTextKeepsTheDictationData() {
        let copied = text("old", "Klar, bis morgen.", ago: 100)
        var dictated = text("new", "Klar, bis morgen.", ago: 0, mode: "Slack")
        dictated.dictationOriginal = "jo klar bis morgen"
        let result = ClipboardHistoryCore.insert(dictated, into: [copied])
        XCTAssertTrue(result.merged)
        XCTAssertEqual(result.entries.first?.id, "old")
        XCTAssertEqual(result.entries.first?.dictationMode, "Slack")
        XCTAssertEqual(result.entries.first?.dictationOriginal, "jo klar bis morgen")

        // Wird ein Diktat später normal kopiert, bleibt es ein Diktat.
        let again = ClipboardHistoryCore.insert(text("copy", "Klar, bis morgen.", ago: 0), into: result.entries)
        XCTAssertEqual(again.entries.first?.dictationMode, "Slack")
    }

    // MARK: 4./5. Maskierung

    func testSpokenGermanSecretsAreMasked() {
        let cases = [
            "das Passwort ist Sommer2024",
            "Mein Kennwort lautet hallo-welt-77",
            "meine PIN ist 4711",
            "the password is hunter22",
            "Passwort: Geheim123",
        ]
        for input in cases {
            let result = ClipboardSecretMasker.mask(input)
            XCTAssertTrue(result.text.contains("[REDACTED:"), input)
            XCTAssertFalse(result.text.contains("Sommer2024") || result.text.contains("4711") || result.text.contains("hunter22"), input)
        }
        XCTAssertEqual(ClipboardSecretMasker.mask("Das Meeting ist morgen um zehn.").maskedCount, 0)
    }

    func testOriginalTranscriptIsMaskedForAgentsAndSearchDoesNotLeakIt() {
        var settings = ClipboardSettings()
        settings.enabled = true
        let context = ClipboardCLIFormatter.Context(
            settings: settings, directory: URL(fileURLWithPath: "/tmp"), fullText: { $0.text }, now: now
        )
        var dictation = text("d", "Ich schicke dir die Zugangsdaten gleich.", ago: 1, mode: "Slack")
        dictation.dictationOriginal = "schick ihm das passwort ist Sommer2024 aber sag es keinem"
        let output = ClipboardCLIFormatter.detail(dictation, number: 1, json: false, context: context, original: true)
        XCTAssertFalse(output.stdout.contains("Sommer2024"))
        XCTAssertTrue(output.stdout.contains("[REDACTED:"))

        let env = ClipboardCLIEnvironment(
            settings: { settings }, directory: URL(fileURLWithPath: "/tmp"), loadEntries: { [dictation] },
            fullText: { $0.text }, now: { self.now }, copyViaApp: { _ in .copied(kind: "text") }
        )
        let found = ClipboardCLIRunner.execute(.search(query: "Sommer2024", limit: 20, json: false), environment: env)
        XCTAssertFalse(found.stdout.contains("Sommer2024"))
        XCTAssertTrue(found.stdout.contains("keine Einträge"), found.stdout)
    }

    func testListPreviewIsMaskedBeforeItIsCut() {
        var settings = ClipboardSettings()
        settings.enabled = true
        // Der Schlüssel beginnt kurz vor Zeichen 240 und wäre in der gekürzten
        // Vorschau nur noch halb da, also für die Maskierung unkenntlich.
        let filler = String(repeating: "x ", count: 112)
        let secret = "sk-proj-" + String(repeating: "A1b2C3d4", count: 6)
        let entry = text("k", filler + secret, ago: 1)
        let context = ClipboardCLIFormatter.Context(
            settings: settings, directory: URL(fileURLWithPath: "/tmp"), fullText: { $0.text }, now: now
        )
        let preview = ClipboardCLIFormatter.maskedPreview(entry, context)
        XCTAssertFalse(preview.contains("sk-proj-A1b2"), preview)
        XCTAssertTrue(preview.contains("[REDACTED"), preview)
    }

    // MARK: Diktat plus Zwischenablage

    func testDictationWriteAndRecordGiveExactlyOneEntry() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-once-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardHistoryStore(directory: directory, debounceSeconds: 0.01)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("whisperm8-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        var settings = ClipboardSettings()
        settings.enabled = true
        let monitor = ClipboardMonitor(
            store: store, pasteboard: pasteboard, interval: 60, readTimeout: 2,
            settings: { settings }, frontmostApp: { (nil, nil) }
        )

        // So schreibt das Diktat (PasteService.copyToClipboard) …
        let service = PasteService(environment: PasteServiceEnvironment(pasteboard: pasteboard))
        service.copyToClipboard("Klar, bis morgen.")
        monitor.tick()
        await monitor.waitForReads()
        // … und so landet es über den Diktat-Weg im Verlauf.
        let capture = try XCTUnwrap(ClipboardHistoryCore.dictationCapture(
            text: "Klar, bis morgen.", original: "jo klar", modeName: "Slack",
            targetBundleID: nil, targetName: nil, settings: settings
        ))
        store.add(capture, maxItems: 50)
        store.waitUntilIdle()

        XCTAssertEqual(store.snapshot().count, 1)
        XCTAssertEqual(store.snapshot().first?.dictationMode, "Slack")
    }

    // MARK: Notch

    func testTurnOffFromTheListSetsTheUserSwitch() {
        let name = "notch-turnoff-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let prefs = AppPreferences(defaults: defaults)
        let controller = NotchStatusController(
            statusStore: AgentSessionRuntimeStatusStore(), activityStore: AgentSessionActivityStore(),
            workspaceProvider: { AgentWorkspace(projects: [], sessions: []) }, prefs: prefs
        )
        XCTAssertTrue(NotchConfig.current(prefs).isActive)
        controller.turnOff()
        XCTAssertFalse(prefs.isNotchStatusEnabled)
        XCTAssertFalse(NotchConfig.current(prefs).isActive)
    }
}
