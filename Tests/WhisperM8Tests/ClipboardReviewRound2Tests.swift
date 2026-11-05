import AppKit
import XCTest
@testable import WhisperM8

/// Zweite Review-Runde (05.11.2026): CLI-Suche, Text mit Bild, Duplikate mit
/// neuer Formatierung, Anzahl in den Einstellungen, Vorschau bei geschlossenem
/// Fenster, Herkunft bei Kopien aus dem Verlaufsfenster.
@MainActor
final class ClipboardReviewRound2Tests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-round2-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func pngData() -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        return rep.representation(using: .png, properties: [:])!
    }

    private func textEntry(_ id: String, _ value: String, at seconds: TimeInterval) -> ClipboardEntry {
        let date = Date(timeIntervalSince1970: seconds)
        return ClipboardEntry(
            id: id, kind: .text, createdAt: date, lastCopiedAt: date, copyCount: 1, isPinned: false,
            sourceBundleID: nil, sourceName: nil, contentHash: ClipboardEntry.hash(text: value),
            preview: ClipboardEntry.makePreview(from: value), text: value
        )
    }

    // MARK: 2. CLI-Suche

    func testSecretRuleStillMasksKeysWithPrefixes() {
        let prefix = String(repeating: "service_", count: 7) // 56 Zeichen vor dem Schlüsselwort
        let masked = ClipboardSecretMasker.mask("config \(prefix)password: Sommer2024x").text
        XCTAssertFalse(masked.contains("Sommer2024x"))
        XCTAssertTrue(masked.contains("[REDACTED:"))
        XCTAssertFalse(ClipboardSecretMasker.mask("db_password=Sommer2024y").text.contains("Sommer2024y"))
        // Sehr langer Präfix in einer .env-Zeile: fängt `env-secret`.
        let long = String(repeating: "SERVICE_", count: 12)
        XCTAssertFalse(ClipboardSecretMasker.mask("\(long)PASSWORD=Sommer2024z").text.contains("Sommer2024z"))
    }

    func testSecretRuleIsNotQuadraticOnLongIdentifierChains() {
        let chain = String(repeating: "ab_cd-", count: 40_000) // 240.000 Zeichen ohne Schlüsselwort
        let start = Date()
        _ = ClipboardSecretMasker.mask(chain)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2, "Maskieren einer langen Kette darf nicht quadratisch laufen")
    }

    func testWordBoundaryExcerptCutsAtSeparatorsAndKeepsShortTexts() {
        XCTAssertEqual(ClipboardSearchIndex.wordBoundaryExcerpt("kurz", head: 10, tail: 10), "kurz")
        let text = "aaaa bbbbbbbb cccc dddddddd eeee"
        let cut = ClipboardSearchIndex.wordBoundaryExcerpt(text, head: 8, tail: 8)
        // Kopf endet vor „bbbbbbbb“, Ende beginnt nach „dddddddd“: kein halbes Wort.
        XCTAssertEqual(cut, "aaaa \n eeee")
    }

    func testWordBoundaryExcerptFallsBackToHardCutWithoutSeparators() {
        let blob = String(repeating: "Ab1", count: 2000)
        let cut = ClipboardSearchIndex.wordBoundaryExcerpt(blob, head: 3000, tail: 2000, searchWindow: 100)
        XCTAssertEqual(cut.utf8.count, 3000 + 1 + 2000)
    }

    func testCLISearchOnlyReadsHeadAndTailOfLongTexts() {
        let filler = String(repeating: "x ", count: 400_000) // 800 KB
        let long = "anfangswort " + filler + "mittelwort " + filler + " endwort"
        let entry = textEntry("long0001", long, at: 10)
        let env = ClipboardCLIEnvironment(
            settings: { ClipboardSettings(enabled: true) }, directory: directory, loadEntries: { [entry] },
            fullText: { $0.text }, now: { Date(timeIntervalSince1970: 20) }, copyViaApp: { _ in .copied(kind: "text") }
        )
        func hits(_ query: String) -> Bool {
            ClipboardCLIRunner.execute(.search(query: query, limit: 5, json: true), environment: env).stdout.contains("long0001")
        }
        XCTAssertTrue(hits("anfangswort"))
        XCTAssertTrue(hits("endwort"))
        XCTAssertFalse(hits("mittelwort"), "Wie im Fenster zählen bei langen Texten nur Anfang und Ende")
    }

    // MARK: 6. Text plus Bild

    func testTextWithImageKeepsTheImageInTheArchive() throws {
        let png = pngData()
        let archive = ClipboardArchive(items: [[
            ClipboardRepresentation(type: "public.utf8-plain-text", data: Data("Bild.png".utf8)),
            ClipboardRepresentation(type: "public.png", data: png),
        ]])
        let store = ClipboardHistoryStore(directory: directory, debounceSeconds: 0.01)
        store.add(ClipboardCapture(
            types: ["public.utf8-plain-text", "public.png"], text: "Bild.png",
            imageData: png, imageIsPNG: true, archive: archive
        ), maxItems: 50)
        let entry = try XCTUnwrap(store.snapshot().first)
        XCTAssertEqual(entry.kind, .text)
        XCTAssertNotNil(entry.archiveFile, "Ohne Archiv ginge das Bild beim Einfügen verloren")

        guard case .items(let items) = ClipboardRestore.payload(for: entry, plain: false, directory: directory) else {
            return XCTFail("Kein Inhalt zum Einfügen")
        }
        XCTAssertTrue(items.first?.contains { $0.type == "public.png" } ?? false)
    }

    func testPlainTextWithoutImageNeedsNoArchive() {
        let archive = ClipboardArchive(items: [[
            ClipboardRepresentation(type: "public.utf8-plain-text", data: Data("x".utf8)),
            ClipboardRepresentation(type: "public.rtf", data: Data("r".utf8)),
        ]])
        XCTAssertFalse(ClipboardHistoryStore.needsArchive(archive))
        XCTAssertFalse(ClipboardHistoryStore.needsArchive(archive, keepsImage: true))
    }

    // MARK: 7. Duplikat mit neuer Formatierung

    func testDuplicateTakesTheFormattingOfTheNewestCopy() {
        var old = textEntry("old", "Summe 1.200", at: 10)
        old.rtfFile = "old.rtf"
        old.isPinned = true
        var fresh = textEntry("new", "Summe 1.200", at: 20)
        fresh.archiveFile = "new.pasteboard"
        fresh.blobBytes = 42

        let result = ClipboardHistoryCore.insert(fresh, into: [old])
        XCTAssertTrue(result.merged)
        let merged = result.entries[0]
        XCTAssertEqual(merged.id, "old")
        XCTAssertTrue(merged.isPinned)
        XCTAssertNil(merged.rtfFile)
        XCTAssertEqual(merged.archiveFile, "new.pasteboard")
        XCTAssertEqual(merged.blobBytes, 42)
        XCTAssertEqual(result.discardedBlobs, ["old.rtf"])
    }

    func testDuplicateAsPlainTextDropsTheOldFormattingOnDisk() throws {
        // Langer Abstand: Der Index wird nur durch `flush` geschrieben.
        let store = ClipboardHistoryStore(directory: directory, debounceSeconds: 60)
        store.add(ClipboardCapture(text: "Zelle", rtf: Data("{\\rtf1 Zelle}".utf8), date: Date(timeIntervalSince1970: 1)), maxItems: 50)
        store.flush()
        let first = try XCTUnwrap(store.snapshot().first)
        let rtf = try XCTUnwrap(first.rtfFile)
        let rtfURL = directory.appendingPathComponent(rtf)
        store.add(ClipboardCapture(text: "Zelle", date: Date(timeIntervalSince1970: 2)), maxItems: 50)
        let merged = try XCTUnwrap(store.snapshot().first)
        XCTAssertEqual(merged.id, first.id)
        XCTAssertNil(merged.rtfFile)

        // Solange der Index auf der Platte die alte Datei nennt, bleibt sie
        // (CLI liest ihn; nach einem Absturz lädt die App genau ihn).
        XCTAssertEqual(ClipboardHistoryStore.loadIndex(directory: directory).first?.rtfFile, rtf)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rtfURL.path))

        store.flush()
        XCTAssertNil(ClipboardHistoryStore.loadIndex(directory: directory).first?.rtfFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rtfURL.path))
    }

    /// Absturz zwischen Zusammenführen und Schreiben: Der alte Index samt
    /// seinen Dateien ist beim nächsten Start vollständig da.
    func testCrashBeforeIndexWriteKeepsTheOldEntryComplete() throws {
        let long = String(repeating: "Logzeile mit Inhalt\n", count: 2000) // > 16.000 Zeichen: Datei
        let store = ClipboardHistoryStore(directory: directory, debounceSeconds: 60)
        store.add(ClipboardCapture(text: long, date: Date(timeIntervalSince1970: 1)), maxItems: 50)
        store.flush()
        store.add(ClipboardCapture(text: long, date: Date(timeIntervalSince1970: 2)), maxItems: 50)
        store.waitUntilIdle()

        // Neuer Store = Neustart nach Absturz (kein flush).
        let restarted = ClipboardHistoryStore(directory: directory, debounceSeconds: 60)
        let entry = try XCTUnwrap(restarted.snapshot().first)
        XCTAssertEqual(restarted.fullText(of: entry), long)
    }

    // MARK: 8. Anzahl in den Einstellungen

    func testStoredEntryCountReadsTheDiskIndexWithoutLoadingTheHistory() async {
        let writer = ClipboardHistoryStore(directory: directory, debounceSeconds: 0.01)
        writer.add(ClipboardCapture(text: "eins", date: Date(timeIntervalSince1970: 1)), maxItems: 50)
        writer.add(ClipboardCapture(text: "zwei", date: Date(timeIntervalSince1970: 2)), maxItems: 50)
        writer.flush()

        let controller = ClipboardHistoryController(store: ClipboardHistoryStore(directory: directory, debounceSeconds: 0.01))
        let count = await controller.storedEntryCount()
        XCTAssertEqual(count, 2)
        XCTAssertTrue(controller.entries.isEmpty, "Bei abgeschaltetem Verlauf wird nichts in den Speicher geladen")
    }

    func testStoredEntryCountWaitsForTheLoadWhenObserving() async {
        let writer = ClipboardHistoryStore(directory: directory, debounceSeconds: 0.01)
        writer.add(ClipboardCapture(text: "eins", date: Date(timeIntervalSince1970: 1)), maxItems: 50)
        writer.flush()

        let controller = ClipboardHistoryController(store: ClipboardHistoryStore(directory: directory, debounceSeconds: 0.01))
        controller.ensureLoaded()
        let count = await controller.storedEntryCount()
        XCTAssertEqual(count, 1, "Direkt nach dem Laden ist der Stand auf dem Main Thread noch leer")
    }

    // MARK: 11. Vorschau bei geschlossenem Fenster

    func testLongTextPreviewIsNotReadWhileTheWindowIsClosed() async throws {
        var long = textEntry("long", "Anfang", at: 10)
        long.text = nil
        long.textFile = "long.txt"
        let counter = ReadCounter()
        var reads: Int { counter.value }
        let model = ClipboardHistoryViewModel(
            loaders: .init(fullText: { entry in
                if entry.textFile != nil { counter.increment(); return "voller Text" }
                return entry.text
            }, image: { _, _ in nil }, appIcon: { _ in nil }),
            now: { Date(timeIntervalSince1970: 100) }
        )
        model.setEntries([long])
        let before = reads // Suchindex ohne Store liest einmal
        model.setEntries([long, textEntry("b", "neu", at: 5)])
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(reads, before + 1, "Nur der Suchindex liest, die Vorschau nicht")

        let indexReads = reads
        model.isPresented = true
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(reads, indexReads + 1)
        XCTAssertEqual(model.previewText, "voller Text")
    }

    // MARK: 12. Herkunft bei Kopien aus dem Verlaufsfenster

    func testCopyWhileOwnWindowIsOpenCountsAsWhisperM8() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("whisperm8-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let store = ClipboardHistoryStore(directory: directory, debounceSeconds: 0.01)
        let monitor = ClipboardMonitor(
            store: store, pasteboard: pasteboard, interval: 0.5,
            settings: { ClipboardSettings(enabled: true) },
            // Die App davor ist ausgeschlossen (Passwort-Manager).
            frontmostApp: { ("com.1password.1password", "1Password") }
        )
        var panelCopied: Int?
        monitor.ownWindowSource = { count in count == panelCopied ? ("com.whisperm8.app", "WhisperM8") : nil }
        monitor.start(); monitor.stop()

        // Das Fenster kopiert selbst (⌘C in der Vorschau).
        pasteboard.clearContents()
        pasteboard.setString("aus der Vorschau", forType: .string)
        panelCopied = pasteboard.changeCount
        monitor.tick()
        await monitor.waitForReads()
        store.waitUntilIdle()
        let stored = try XCTUnwrap(store.snapshot().first)
        XCTAssertEqual(stored.sourceName, "WhisperM8")
        XCTAssertEqual(stored.sourceBundleID, "com.whisperm8.app")

        // Fenster noch offen, aber eine andere App schreibt (Hintergrund,
        // Universal Clipboard): vordere App zählt, hier ausgeschlossen, also nichts.
        pasteboard.clearContents()
        pasteboard.setString("Einmal-Code 123456", forType: .string)
        monitor.tick()
        await monitor.waitForReads()
        store.waitUntilIdle()
        XCTAssertEqual(store.snapshot().count, 1)
    }
}

private final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
