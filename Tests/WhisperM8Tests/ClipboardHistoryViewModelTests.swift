import AppKit
import XCTest
@testable import WhisperM8

/// Fenster-Logik ohne Fenster: Reihenfolge, Nummern, Suche, Auswahl, sowie
/// der Control-Socket-Handler `clipboard.copy` und die Einstellungs-Helfer.
@MainActor
final class ClipboardHistoryViewModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 50_000)

    private func entry(_ id: String, _ text: String, ago: TimeInterval, pinned: Bool = false) -> ClipboardEntry {
        let date = now.addingTimeInterval(-ago)
        return ClipboardEntry(
            id: id, kind: .text, createdAt: date, lastCopiedAt: date, copyCount: 1, isPinned: pinned,
            sourceBundleID: nil, sourceName: nil, contentHash: ClipboardEntry.hash(text: text),
            preview: ClipboardEntry.makePreview(from: text), text: text
        )
    }

    private func makeModel(_ entries: [ClipboardEntry]) -> (ClipboardHistoryViewModel, Pasted) {
        let model = ClipboardHistoryViewModel(
            loaders: .init(fullText: { $0.text }, image: { _, _ in nil }, appIcon: { _ in nil }), now: { self.now }
        )
        let pasted = Pasted()
        model.actions.paste = { entry, plain in pasted.calls.append((entry.id, plain)) }
        model.setEntries(entries)
        return (model, pasted)
    }

    private final class Pasted { var calls: [(String, Bool)] = [] }

    private var sample: [ClipboardEntry] {
        [
            entry("a", "alpha neu", ago: 10),
            entry("b", "beta", ago: 20),
            entry("p", "gepinnt alpha", ago: 500, pinned: true),
            entry("c", "gamma alpha", ago: 30),
        ]
    }

    func testWithoutSearchPinnedComeFirstAndNumbersFollowTheList() {
        let (model, pasted) = makeModel(sample)
        XCTAssertEqual(model.visible.map(\.id), ["p", "a", "b", "c"])
        XCTAssertTrue(model.showsPinnedGroup)
        model.handle(.quickSelect(2))
        XCTAssertEqual(pasted.calls.first?.0, "a")
    }

    func testSearchOrderIsTheShownOrderForArrowsAndQuickSelect() {
        let (model, pasted) = makeModel(sample)
        model.query = "alpha"
        XCTAssertFalse(model.showsPinnedGroup, "bei der Suche zählt die Trefferreihenfolge")
        let shown = model.visible.map(\.id)
        XCTAssertEqual(Set(shown), ["a", "p", "c"])
        XCTAssertEqual(model.selectedID, shown.first)
        model.handle(.moveDown)
        XCTAssertEqual(model.selectedID, shown[1])
        model.handle(.quickSelect(3))
        XCTAssertEqual(pasted.calls.last?.0, shown[2])
        model.handle(.quickSelect(9))
        XCTAssertEqual(pasted.calls.count, 1, "keine Nummer 9: nichts passiert")
    }

    func testEnterAndOptionEnterPasteTheSelection() {
        let (model, pasted) = makeModel(sample)
        model.select("b")
        model.handle(.paste)
        model.handle(.pastePlain)
        XCTAssertEqual(pasted.calls.map(\.0), ["b", "b"])
        XCTAssertEqual(pasted.calls.map(\.1), [false, true])
    }

    func testDeleteMovesSelectionToNeighbour() {
        let (model, _) = makeModel(sample)
        var deleted: [String] = []
        model.actions.delete = { deleted.append($0.id) }
        model.select("a")
        model.handle(.delete)
        XCTAssertEqual(deleted, ["a"])
        XCTAssertEqual(model.selectedID, "b")
    }

    func testSearchUsesTheStoreIndexForTextOutsideTheEntry() {
        var long = entry("long", "Anfang", ago: 5)
        long.text = nil
        long.textFile = "long.txt"
        var index = ClipboardSearchIndex()
        index.set(long, fullText: "Anfang ... ganz unten: Segmentation fault")
        let model = ClipboardHistoryViewModel(
            loaders: .init(fullText: { _ in nil }, image: { _, _ in nil }, appIcon: { _ in nil }), now: { self.now }
        )
        model.setEntries([long, entry("x", "anderes", ago: 1)], search: index)
        model.query = "segmentation"
        XCTAssertEqual(model.visible.map(\.id), ["long"])
    }

    func testResetClearsQueryAndSelectsFirst() {
        let (model, _) = makeModel(sample)
        model.query = "beta"
        model.reset()
        XCTAssertEqual(model.query, "")
        XCTAssertEqual(model.selectedID, "p")
    }

    // MARK: clipboard.copy (Control-Socket)

    func testClipboardCopyHonoursSwitchesAndResolvesReferences() async {
        let entries = sample
        var copied: [String] = []
        func run(_ ref: String, settings: ClipboardSettings, ok: Bool = true) async -> ChatsControlResponse {
            await AgentControlRequestHandler.clipboardCopy(
                ref: ref, requestID: "r1", settings: settings,
                entries: { entries },
                copy: { entry in copied.append(entry.id); return ok }
            )
        }
        let off = await run("1", settings: ClipboardSettings(enabled: false))
        XCTAssertEqual(off.error?.code, ChatsControlErrorCode.unsupported.rawValue)

        var blocked = ClipboardSettings(enabled: true)
        blocked.agentAccess = false
        let denied = await run("1", settings: blocked)
        XCTAssertEqual(denied.error?.message, ClipboardSettings.agentAccessDeniedMessage)

        let missing = await run("42", settings: ClipboardSettings(enabled: true))
        XCTAssertEqual(missing.error?.code, ChatsControlErrorCode.notFound.rawValue)

        let failed = await run("1", settings: ClipboardSettings(enabled: true), ok: false)
        XCTAssertEqual(failed.error?.code, ChatsControlErrorCode.conflict.rawValue)

        let done = await run("1", settings: ClipboardSettings(enabled: true))
        XCTAssertTrue(done.ok)
        XCTAssertEqual(done.result?["copied"]?.stringValue, "a", "Nummer 1 ist der neueste Eintrag")
        XCTAssertEqual(copied, ["a", "a"])
    }

    // MARK: Einstellungen

    func testExcludedAppsSplitIntoBuiltInAndCustom() {
        let apps = ClipboardSettings.defaultExcludedApps + ["com.example.secret"]
        let groups = ClipboardSettings.partitionExcluded(apps)
        XCTAssertEqual(groups.builtIn, ClipboardSettings.defaultExcludedApps)
        XCTAssertEqual(groups.custom, ["com.example.secret"])
        XCTAssertEqual(ClipboardSettings.displayName(for: "com.bitwarden.desktop"), "Bitwarden")
        XCTAssertEqual(ClipboardSettings.displayName(for: "com.example.secret"), "com.example.secret")
        for bundleID in ClipboardSettings.defaultExcludedApps {
            XCTAssertNotNil(ClipboardSettings.defaultExcludedAppNames[bundleID], "Name fehlt für \(bundleID)")
        }
    }

    func testExcludedSummaryNamesTheFirstFew() {
        let summary = ClipboardSettingsPage.summary(of: ["com.1password.1password", "com.bitwarden.desktop"])
        XCTAssertEqual(summary, "1Password, Bitwarden")
        XCTAssertEqual(ClipboardSettingsPage.summary(of: ClipboardSettings.defaultExcludedApps),
                       "1Password, Bitwarden, Keychain Access and 8 more")
    }
}
