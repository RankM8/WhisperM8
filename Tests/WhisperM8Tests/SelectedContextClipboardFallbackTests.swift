import AppKit
import XCTest
@testable import WhisperM8

/// LR-DIK-016 / LR-DIK-027: Clipboard-Fallback mit Eigentümerschaft, Größenlimit und
/// Editor-Ausnahme. Privates Pasteboard, keine echten Tastendrücke.
@MainActor
final class SelectedContextClipboardFallbackTests: XCTestCase {
    private func makePasteboard(_ text: String) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("wm8-fallback-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return pasteboard
    }

    private func write(_ text: String, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func testHappyPathReturnsSelectionAndRestoresUserClipboard() async {
        let pasteboard = makePasteboard("meine Zwischenablage")
        let service = SelectedContextService(
            pasteboard: pasteboard,
            copyPoster: { [self] in write("markierter Text", to: pasteboard) },
            activator: { _ in }
        )

        let text = await service.captureViaClipboard(bundleIdentifier: "com.apple.Notes", activate: {})

        XCTAssertEqual(text, "markierter Text")
        XCTAssertEqual(pasteboard.string(forType: .string), "meine Zwischenablage")
        XCTAssertEqual(service.outcome.resyncChangeCount, pasteboard.changeCount)
    }

    func testForeignCopyDuringCaptureIsNeitherImportedNorOverwritten() async {
        let pasteboard = makePasteboard("alt")
        let service = SelectedContextService(
            pasteboard: pasteboard,
            copyPoster: { [self] in
                write("Ziel-App-Kopie", to: pasteboard)
                write("echte Nutzerkopie", to: pasteboard)   // fremde Kopie im Fenster
            },
            activator: { _ in }
        )

        let text = await service.captureViaClipboard(bundleIdentifier: "com.apple.Notes", activate: {})

        XCTAssertNil(text, "fremde Kopie darf nicht als markierter Kontext gelten")
        XCTAssertEqual(pasteboard.string(forType: .string), "echte Nutzerkopie", "kein Restore über die Nutzerkopie")
        XCTAssertNil(service.outcome.resyncChangeCount, "Monitor darf die Nutzerkopie noch importieren")
    }

    func testCopyLineEditorSkipsFallbackEntirely() async {
        let pasteboard = makePasteboard("alt")
        var posted = false
        let service = SelectedContextService(
            pasteboard: pasteboard,
            copyPoster: { posted = true },
            activator: { _ in }
        )

        for bundleID in ["com.microsoft.VSCode", "com.jetbrains.intellij", "dev.zed.Zed"] {
            let text = await service.captureViaClipboard(bundleIdentifier: bundleID, activate: {})
            XCTAssertNil(text)
        }
        XCTAssertFalse(posted, "kein Cmd+C in Editoren, die ohne Auswahl die Zeile kopieren")
        XCTAssertEqual(pasteboard.string(forType: .string), "alt")
    }

    func testOversizedClipboardIsLeftAlone() async {
        let pasteboard = makePasteboard(String(repeating: "x", count: 4096))
        var posted = false
        let service = SelectedContextService(
            pasteboard: pasteboard,
            copyPoster: { posted = true },
            activator: { _ in },
            maxSnapshotBytes: 1024
        )

        let text = await service.captureViaClipboard(bundleIdentifier: "com.apple.Notes", activate: {})

        XCTAssertNil(text)
        XCTAssertFalse(posted, "zu großer Inhalt: Fallback entfällt, nichts wird angefasst")
        XCTAssertEqual(pasteboard.string(forType: .string)?.count, 4096)
    }

    func testPasswordManagerContentIsStillNotImportedFromFallback() async {
        let pasteboard = makePasteboard("alt")
        let service = SelectedContextService(
            pasteboard: pasteboard,
            copyPoster: {
                let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
                pasteboard.declareTypes([.string, concealed], owner: nil)
                pasteboard.setString("geheim", forType: .string)
                pasteboard.setData(Data([1]), forType: concealed)
            },
            activator: { _ in }
        )

        let text = await service.captureViaClipboard(bundleIdentifier: "com.apple.Notes", activate: {})

        XCTAssertNil(text)
    }
}
