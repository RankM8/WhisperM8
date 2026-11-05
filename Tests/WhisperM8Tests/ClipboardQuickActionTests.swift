import AppKit
import XCTest
@testable import WhisperM8

/// Zwischenablage-Fenster und Schnellaktion „Korrigieren“: Kopfzeile, Knopf
/// je Eintrag und ⌘↩, ohne Fenster.
@MainActor
final class ClipboardQuickActionTests: XCTestCase {
    private final class Calls {
        var corrected: [String] = []
        var selectionRuns = 0
    }

    private func entry(_ id: String, kind: ClipboardEntry.Kind = .text) -> ClipboardEntry {
        let date = Date(timeIntervalSince1970: 1_000)
        var entry = ClipboardEntry(
            id: id, kind: .text, createdAt: date, lastCopiedAt: date, copyCount: 1, isPinned: false,
            sourceBundleID: nil, sourceName: nil, contentHash: ClipboardEntry.hash(text: id),
            preview: id, text: id
        )
        entry.kind = kind
        return entry
    }

    private func makeModel(_ entries: [ClipboardEntry], available: Bool = true) -> (ClipboardHistoryViewModel, Calls) {
        let model = ClipboardHistoryViewModel(loaders: .init(fullText: { $0.text }, image: { _, _ in nil }, appIcon: { _ in nil }))
        let calls = Calls()
        model.actions.correctAndPaste = { calls.corrected.append($0.id) }
        model.actions.correctSelection = { calls.selectionRuns += 1 }
        model.quickActionsAvailable = available
        model.setEntries(entries)
        return (model, calls)
    }

    func testCommandReturnCorrectsAndPastesTheSelectedTextEntry() {
        let (model, calls) = makeModel([entry("a"), entry("b")])
        model.handle(.correctAndPaste)
        XCTAssertEqual(calls.corrected, ["a"])
    }

    func testImagesAndFilesCannotBeCorrected() {
        let (model, calls) = makeModel([entry("bild", kind: .image), entry("datei", kind: .files)])
        XCTAssertFalse(model.canCorrect(model.visible[0]))
        XCTAssertFalse(model.canCorrect(model.visible[1]))
        model.handle(.correctAndPaste)
        XCTAssertTrue(calls.corrected.isEmpty)
    }

    func testNothingWhenQuickActionsAreOff() {
        let (model, calls) = makeModel([entry("a")], available: false)
        XCTAssertFalse(model.canCorrect(model.visible[0]))
        model.selectionProbe = .selected(preview: "x")
        XCTAssertFalse(model.showsSelectionHeader, "Umfang „Nur Diktat“: keine Kopfzeile")
        model.handle(.correctAndPaste)
        XCTAssertTrue(calls.corrected.isEmpty)
    }

    func testSelectionHeaderFollowsTheProbe() {
        let (model, _) = makeModel([entry("a")])
        XCTAssertFalse(model.showsSelectionHeader, "noch nicht geprüft")
        model.selectionProbe = .none
        XCTAssertFalse(model.showsSelectionHeader, "App meldet: nichts markiert")
        model.selectionProbe = .selected(preview: "Hallo")
        XCTAssertTrue(model.showsSelectionHeader)
        model.selectionProbe = .unknown
        XCTAssertTrue(model.showsSelectionHeader, "unklare Lage: Kopfzeile ohne Vorschau")
        model.reset()
        XCTAssertNil(model.selectionProbe, "jedes Öffnen prüft neu")
    }

    func testCommandReturnKeys() {
        XCTAssertEqual(ClipboardKeyCommand.resolve(keyCode: 36, characters: "\r", modifiers: .command), .correctAndPaste)
        XCTAssertEqual(ClipboardKeyCommand.resolve(keyCode: 76, characters: "\r", modifiers: .command), .correctAndPaste)
        XCTAssertEqual(ClipboardKeyCommand.resolve(keyCode: 36, characters: "\r", modifiers: []), .paste)
        XCTAssertNil(ClipboardKeyCommand.resolve(keyCode: 36, characters: "\r", modifiers: [.command, .shift]))
    }
}
