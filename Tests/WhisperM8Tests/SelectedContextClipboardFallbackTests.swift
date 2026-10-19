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

    /// Aktivieren und Cmd+C laufen auf dem Main Thread: HIToolbox (Tastaturlayout
    /// für Cmd+C) bricht die App abseits davon ab — so stürzte jeder Diktatstart ab.
    func testActivateAndCopyRunOnMainThreadAfterSnapshot() async {
        let pasteboard = makePasteboard("meine Zwischenablage")
        var copyOnMain: Bool?
        var activateOnMain: Bool?
        let service = SelectedContextService(
            pasteboard: pasteboard,
            copyPoster: { [self] in
                copyOnMain = Thread.isMainThread
                write("markierter Text", to: pasteboard)
            },
            activator: { _ in }
        )

        _ = await service.captureViaClipboard(
            bundleIdentifier: "com.apple.Notes",
            activate: { activateOnMain = Thread.isMainThread }
        )

        XCTAssertEqual(activateOnMain, true)
        XCTAssertEqual(copyOnMain, true)
    }

    /// Review W2b: Manche Apps erhöhen den Zähler beim Kopieren um mehr als 1
    /// (clearContents + mehrere Writes). Das ist ihre Kopie — die Nutzerkopie
    /// im Snapshot kommt zurück, statt verloren zu gehen.
    func testMultiWriteCopyStillRestoresUserClipboard() async {
        let pasteboard = makePasteboard("meine Zwischenablage")
        let service = SelectedContextService(
            pasteboard: pasteboard,
            copyPoster: { [self] in
                write("Zwischenstand", to: pasteboard)
                write("markierter Text", to: pasteboard)
            },
            activator: { _ in }
        )

        let text = await service.captureViaClipboard(bundleIdentifier: "com.microsoft.Word", activate: {})

        XCTAssertEqual(text, "markierter Text")
        XCTAssertEqual(pasteboard.string(forType: .string), "meine Zwischenablage")
    }

    /// Review W2b zu LR-DIK-023: Liegt schon ein Passwort in der Zwischenablage,
    /// läuft der Fallback gar nicht — sonst wäre es durch die Auswahl ersetzt.
    func testConfidentialClipboardSkipsFallback() async {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("wm8-fallback-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString("geheim", forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pasteboard.writeObjects([item])
        var posted = false
        let service = SelectedContextService(pasteboard: pasteboard, copyPoster: { posted = true }, activator: { _ in })

        let text = await service.captureViaClipboard(bundleIdentifier: "com.apple.Notes", activate: {})

        XCTAssertNil(text)
        XCTAssertFalse(posted, "kein Cmd+C über einem Passwort")
        XCTAssertEqual(pasteboard.string(forType: .string), "geheim")
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
