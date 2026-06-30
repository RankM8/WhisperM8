import Foundation
import XCTest
@testable import WhisperM8

/// Deckt die interaktive Screenshot-Aufnahme (`screencapture -i`) ab. Der
/// Subprocess selbst ist nicht unit-testbar — getestet wird die Logik um den
/// injizierbaren `interactiveScreenshotRunner` herum (Erfolg → Attachment,
/// Abbruch/leere Datei → nil, deaktiviert → throws).
@MainActor
final class VisualContextScreenshotTests: XCTestCase {

    /// Threadsicherer Halter, damit der `@Sendable`-Runner die beobachtete URL
    /// zurueckreichen kann, ohne eine mutable Var ueber die Concurrency-Grenze
    /// zu capturen (Swift-6-clean).
    private final class URLBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: URL?
        func set(_ url: URL) { lock.withLock { value = url } }
        var url: URL? { lock.withLock { value } }
    }

    func testInteractiveCaptureReturnsAttachmentWhenRunnerWritesFile() async throws {
        let service = VisualContextCaptureService()
        let box = URLBox()
        service.interactiveScreenshotRunner = { url in
            box.set(url)
            // Dummy-Bytes reichen — der Service prueft nur Existenz + Groesse > 0.
            try? Data([0x89, 0x50, 0x4E, 0x47]).write(to: url)
            return true
        }

        let attachment = try await service.captureInteractiveScreenshot(sourceApp: nil)

        let unwrapped = try XCTUnwrap(attachment, "Erfolgreiche Aufnahme muss ein Attachment liefern")
        XCTAssertEqual(unwrapped.kind, .screenshot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unwrapped.fileURL.path))
        XCTAssertEqual(unwrapped.thumbnailURL, unwrapped.fileURL)
        XCTAssertEqual(unwrapped.sourceAppName, "Screenshot")
        XCTAssertEqual(box.url, unwrapped.fileURL, "Runner muss in genau die Ziel-Datei schreiben")

        try? FileManager.default.removeItem(at: unwrapped.fileURL)
    }

    func testInteractiveCaptureReturnsNilOnCancel() async throws {
        let service = VisualContextCaptureService()
        let box = URLBox()
        service.interactiveScreenshotRunner = { url in
            box.set(url)
            return false  // ESC / Abbruch — keine Datei geschrieben.
        }

        let attachment = try await service.captureInteractiveScreenshot(sourceApp: nil)

        XCTAssertNil(attachment, "Abbruch darf kein Attachment liefern")
        if let observed = box.url {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: observed.path),
                "Abbruch darf keine Datei hinterlassen"
            )
        }
    }

    func testInteractiveCaptureReturnsNilWhenRunnerWritesEmptyFile() async throws {
        let service = VisualContextCaptureService()
        let box = URLBox()
        service.interactiveScreenshotRunner = { url in
            box.set(url)
            try? Data().write(to: url)  // 0 Bytes — z. B. Auswahl ohne Inhalt.
            return true
        }

        let attachment = try await service.captureInteractiveScreenshot(sourceApp: nil)

        XCTAssertNil(attachment, "Leere Datei (0 Bytes) zaehlt als Abbruch")
        if let observed = box.url {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: observed.path),
                "Leere Datei muss aufgeraeumt werden"
            )
        }
    }

    func testInteractiveCaptureThrowsWhenVisualContextDisabled() async {
        let previous = AppPreferences.shared.isVisualContextCaptureEnabled
        AppPreferences.shared.isVisualContextCaptureEnabled = false
        defer { AppPreferences.shared.isVisualContextCaptureEnabled = previous }

        let service = VisualContextCaptureService()
        service.interactiveScreenshotRunner = { _ in
            XCTFail("Runner darf bei deaktiviertem Visual-Context nicht laufen")
            return false
        }

        do {
            _ = try await service.captureInteractiveScreenshot(sourceApp: nil)
            XCTFail("Expected VisualContextCaptureError.disabled")
        } catch let error as VisualContextCaptureError {
            XCTAssertEqual(error, .disabled)
        } catch {
            XCTFail("Unerwarteter Fehler: \(error)")
        }
    }
}
