import Foundation
import XCTest
@testable import WhisperM8

// MARK: - OutputModeStore-Cache (P5 Schritt 2)

final class OutputModeStoreCacheTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        OutputModeStore._resetCacheForTesting()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OutputModeStoreCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        OutputModeStore._resetCacheForTesting()
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    private func writeModesFile(at url: URL, customName: String) throws {
        var custom = OutputModeStore().createCustomMode()
        custom.name = customName
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode([custom]).write(to: url, options: .atomic)
    }

    func testSecondAccessWithoutFileChangeSkipsDiskRead() throws {
        let fileURL = tempDirectory.appendingPathComponent("OutputModes.json")
        try writeModesFile(at: fileURL, customName: "Erster Stand")

        var loadCount = 0
        let store = OutputModeStore(fileURL: fileURL, loader: { url in
            loadCount += 1
            return try Data(contentsOf: url)
        })

        XCTAssertTrue(store.modes.contains { $0.name == "Erster Stand" })
        _ = store.modes
        _ = store.enabledModes

        XCTAssertEqual(loadCount, 1, "Unveränderte Datei darf nur einmal gelesen werden")
    }

    func testExternalFileChangeTriggersReload() throws {
        let fileURL = tempDirectory.appendingPathComponent("OutputModes.json")
        try writeModesFile(at: fileURL, customName: "Erster Stand")

        var loadCount = 0
        let store = OutputModeStore(fileURL: fileURL, loader: { url in
            loadCount += 1
            return try Data(contentsOf: url)
        })
        _ = store.modes
        XCTAssertEqual(loadCount, 1)

        // Externen Schreiber simulieren — mtime explizit verschieben, damit
        // der Test nicht an der Dateisystem-Zeitauflösung hängt.
        try writeModesFile(at: fileURL, customName: "Zweiter Stand")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)],
            ofItemAtPath: fileURL.path
        )

        XCTAssertTrue(store.modes.contains { $0.name == "Zweiter Stand" })
        XCTAssertEqual(loadCount, 2, "Geänderte Datei muss neu gelesen werden")
    }

    func testSaveModesUpdatesCacheAndPostsNotification() throws {
        let fileURL = tempDirectory.appendingPathComponent("OutputModes.json")
        var loadCount = 0
        let store = OutputModeStore(fileURL: fileURL, loader: { url in
            loadCount += 1
            return try Data(contentsOf: url)
        })

        let notificationExpectation = XCTNSNotificationExpectation(
            name: OutputModeStore.modesDidChangeNotification
        )

        var custom = store.createCustomMode()
        custom.name = "Gespeichert"
        try store.saveModes([custom])

        wait(for: [notificationExpectation], timeout: 1.0)
        XCTAssertTrue(store.modes.contains { $0.name == "Gespeichert" })
        XCTAssertEqual(loadCount, 0, "saveModes aktualisiert den Cache direkt — kein Disk-Read nötig")
    }
}

// MARK: - CodexStatusCache (P5 Schritt 4)

final class CodexStatusCacheTests: XCTestCase {
    private final class Clock {
        var current = Date(timeIntervalSince1970: 1_000)
        func advance(by interval: TimeInterval) {
            current = current.addingTimeInterval(interval)
        }
    }

    func testSignedInIsCachedForFullTTL() {
        let clock = Clock()
        var probeCount = 0
        let cache = CodexStatusCache(ttl: 300, negativeTTL: 5, now: { clock.current }, probe: {
            probeCount += 1
            return .signedIn
        })

        XCTAssertEqual(cache.status(), .signedIn)
        clock.advance(by: 250)
        XCTAssertEqual(cache.status(), .signedIn)
        XCTAssertEqual(probeCount, 1, "Innerhalb der TTL darf nur einmal geprobt werden")

        clock.advance(by: 100)
        XCTAssertEqual(cache.status(), .signedIn)
        XCTAssertEqual(probeCount, 2, "Nach TTL-Ablauf muss frisch geprobt werden")
    }

    func testNegativeStatusOnlyCachedForMiniTTL() {
        let clock = Clock()
        var probeCount = 0
        let cache = CodexStatusCache(ttl: 300, negativeTTL: 5, now: { clock.current }, probe: {
            probeCount += 1
            return .notSignedIn
        })

        XCTAssertEqual(cache.status(), .notSignedIn)
        clock.advance(by: 2)
        XCTAssertEqual(cache.status(), .notSignedIn)
        XCTAssertEqual(probeCount, 1)

        // Negativ-Status nur Mini-TTL: ein frisch abgeschlossener Login darf
        // nicht 5 Minuten lang ignoriert werden.
        clock.advance(by: 4)
        XCTAssertEqual(cache.status(), .notSignedIn)
        XCTAssertEqual(probeCount, 2)
    }

    func testInvalidateForcesReprobe() {
        let clock = Clock()
        var probeCount = 0
        let cache = CodexStatusCache(ttl: 300, negativeTTL: 5, now: { clock.current }, probe: {
            probeCount += 1
            return .signedIn
        })

        _ = cache.status()
        cache.invalidate()
        _ = cache.status()
        XCTAssertEqual(probeCount, 2)
    }

    func testPostProcessorFailsFastWithoutSubprocessWhenNotSignedIn() async {
        let processor = CodexPostProcessor(statusProvider: { .notSignedIn })
        var custom = OutputModeStore().createCustomMode()
        custom.templateID = PostProcessingTemplate.cleanID

        do {
            _ = try await processor.process(
                rawText: "Test",
                mode: custom,
                language: "de",
                contextBundle: .empty
            )
            XCTFail("Muss codexUnavailable werfen")
        } catch let error as PostProcessingError {
            guard case .codexUnavailable = error else {
                XCTFail("Falscher Fehler: \(error)")
                return
            }
        } catch {
            XCTFail("Falscher Fehlertyp: \(error)")
        }
    }
}

// MARK: - ContextCaptureMerge (P5 Schritt 5)

final class ContextCaptureMergeTests: XCTestCase {
    private func makeChatRef() -> AgentChatContextRef {
        AgentChatContextRef(
            sessionID: UUID(),
            provider: .claude,
            projectName: "demo",
            projectPath: "/tmp/demo",
            title: "Demo-Chat",
            externalSessionID: "ext-1"
        )
    }

    private func makeCaptured(_ text: String) -> SelectedContext {
        SelectedContext(text: text, sourceAppName: "TestApp", sourceBundleIdentifier: "com.test.app")
    }

    func testFillsEmptySlots() {
        var bundle = TranscriptContextBundle.empty
        bundle.agentChat = makeChatRef()

        let merged = ContextCaptureMerge.apply(
            captured: makeCaptured("Hallo"),
            tail: "Tail-Inhalt",
            into: bundle,
            userClearedSelectedText: false
        )

        XCTAssertEqual(merged.selectedText.text, "Hallo")
        XCTAssertEqual(merged.agentChatTail, "Tail-Inhalt")
    }

    func testDoesNotOverwriteExistingSelectedText() {
        var bundle = TranscriptContextBundle.empty
        bundle.selectedText = makeCaptured("Vom User kopiert")

        let merged = ContextCaptureMerge.apply(
            captured: makeCaptured("Capture-Ergebnis"),
            tail: nil,
            into: bundle,
            userClearedSelectedText: false
        )

        XCTAssertEqual(merged.selectedText.text, "Vom User kopiert")
    }

    func testUserClearedSuppressesSelectedText() {
        let merged = ContextCaptureMerge.apply(
            captured: makeCaptured("Capture-Ergebnis"),
            tail: nil,
            into: .empty,
            userClearedSelectedText: true
        )

        XCTAssertTrue(merged.selectedText.isEmpty, "User hat geleert — nichts nachreichen")
    }

    func testNoTailWithoutAgentChatRef() {
        // User hat die Agent-Chat-Pill während des Captures entfernt.
        let merged = ContextCaptureMerge.apply(
            captured: .empty,
            tail: "Tail-Inhalt",
            into: .empty,
            userClearedSelectedText: false
        )

        XCTAssertNil(merged.agentChatTail)
    }

    func testIdempotentWhenAppliedTwice() {
        var bundle = TranscriptContextBundle.empty
        bundle.agentChat = makeChatRef()

        let once = ContextCaptureMerge.apply(
            captured: makeCaptured("Hallo"),
            tail: "Tail",
            into: bundle,
            userClearedSelectedText: false
        )
        let twice = ContextCaptureMerge.apply(
            captured: makeCaptured("Anderes"),
            tail: "Anderer Tail",
            into: once,
            userClearedSelectedText: false
        )

        XCTAssertEqual(twice.selectedText.text, "Hallo")
        XCTAssertEqual(twice.agentChatTail, "Tail")
    }
}
