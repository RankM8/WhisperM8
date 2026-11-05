import AppKit
import KeyboardShortcuts
import XCTest
@testable import WhisperM8

/// Review-Befunde zur Schnellaktion: Ersetzen samt Zurücklegen der
/// Zwischenablage (eigenes Pasteboard, Fake-Einfügen), Standard-Kurzbefehl,
/// Umfang „Nur Diktat“, Modifier vor Cmd+C und die Kennzeichnung im Verlauf.
@MainActor
final class QuickActionReplacerTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("quick-action-replacer-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("alte Kopie", forType: .string)
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        pasteboard = nil
        super.tearDown()
    }

    /// Echter `PasteService` mit Fake-Umgebung: Cmd+V liest (wie eine App)
    /// die Zwischenablage, kein Tastendruck geht ans System.
    private func makeReplacer(
        pasteSucceeds: Bool = true,
        onPaste: @escaping () -> Void = {},
        currentSelection: @escaping @MainActor (NSRunningApplication?) async -> String? = { _ in nil }
    ) -> (QuickActionReplacer, pasted: () -> [String]) {
        var pastedTexts: [String] = []
        let board = pasteboard!
        let environment = PasteServiceEnvironment(
            hasAccessibilityPermission: { true },
            requestAccessibilityPermission: {},
            isFrontmost: { _ in true },
            activate: { _ in },
            postPasteKeyEvent: {
                guard pasteSucceeds else { return false }
                pastedTexts.append(board.string(forType: .string) ?? "")
                onPaste()
                return true
            },
            pasteboard: board,
            activationTimeout: 0.1
        )
        let replacer = QuickActionReplacer(
            pasteService: PasteService(environment: environment),
            pasteboard: board,
            restoreDelay: .milliseconds(20),
            confirmTimeout: .milliseconds(150),
            confirmStep: .milliseconds(10),
            currentSelection: currentSelection
        )
        return (replacer, { pastedTexts })
    }

    func testRestoresOldClipboardWhenResultIsSavedInHistory() async {
        let (replacer, pasted) = makeReplacer()
        let result = await replacer.replaceSelection(with: "Ergebnis", in: .current, restore: .ifResultSaved(true))
        XCTAssertEqual(result, .pasted)
        XCTAssertEqual(pasted(), ["Ergebnis"])
        XCTAssertEqual(pasteboard.string(forType: .string), "alte Kopie")
    }

    func testKeepsResultWhenItWouldOtherwiseBeLost() async {
        let (replacer, _) = makeReplacer()
        let result = await replacer.replaceSelection(with: "Ergebnis", in: .current, restore: .ifResultSaved(false))
        XCTAssertEqual(result, .pastedResultKept)
        XCTAssertEqual(pasteboard.string(forType: .string), "Ergebnis", "Verlauf aus: das Ergebnis bleibt greifbar")
    }

    func testRestoresOnlyAfterTheSelectionChanged() async {
        var reads = 0
        let (replacer, _) = makeReplacer(currentSelection: { _ in
            reads += 1
            // Die App braucht etwas, bis sie Cmd+V verarbeitet hat.
            return reads < 3 ? "ein fehler" : ""
        })
        let result = await replacer.replaceSelection(with: "Ein Fehler.", in: .current, restore: .afterConfirmation(original: "ein fehler"))
        XCTAssertEqual(result, .pasted)
        XCTAssertGreaterThanOrEqual(reads, 3)
        XCTAssertEqual(pasteboard.string(forType: .string), "alte Kopie")
    }

    func testUnconfirmedPasteKeepsResult() async {
        let (replacer, _) = makeReplacer(currentSelection: { _ in "ein fehler" })
        let result = await replacer.replaceSelection(with: "Ein Fehler.", in: .current, restore: .afterConfirmation(original: "ein fehler"))
        XCTAssertEqual(result, .pastedResultKept, "spät lesende App bekäme sonst die alte Kopie")
        XCTAssertEqual(pasteboard.string(forType: .string), "Ein Fehler.")
    }

    func testUnreadableSelectionCountsAsUnconfirmed() async {
        let (replacer, _) = makeReplacer(currentSelection: { _ in nil })
        let result = await replacer.replaceSelection(with: "Ein Fehler.", in: .current, restore: .afterConfirmation(original: "x"))
        XCTAssertEqual(result, .pastedResultKept)
    }

    func testDoesNotRestoreWhenSomeoneElseCopiedMeanwhile() async {
        let board = pasteboard!
        let (replacer, _) = makeReplacer(currentSelection: { _ in
            board.clearContents()
            board.setString("neue Kopie des Nutzers", forType: .string)
            return ""
        })
        let result = await replacer.replaceSelection(with: "Ergebnis", in: .current, restore: .afterConfirmation(original: "x"))
        XCTAssertEqual(result, .pasted)
        XCTAssertEqual(pasteboard.string(forType: .string), "neue Kopie des Nutzers")
    }

    func testNeverRestoresAPassword() async {
        let item = NSPasteboardItem()
        item.setString("geheim", forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pasteboard.clearContents()
        pasteboard.writeObjects([item])

        let (replacer, _) = makeReplacer()
        let result = await replacer.replaceSelection(with: "Ergebnis", in: .current, restore: .ifResultSaved(true))
        XCTAssertEqual(result, .pasted)
        XCTAssertEqual(pasteboard.string(forType: .string), "Ergebnis", "das Passwort kommt nicht zurück")
    }

    func testTooLargeSnapshotIsNotRestored() async {
        pasteboard.clearContents()
        pasteboard.setData(Data(count: 9 * 1024 * 1024), forType: NSPasteboard.PasteboardType("public.data"))

        let (replacer, _) = makeReplacer()
        let result = await replacer.replaceSelection(with: "Ergebnis", in: .current, restore: .ifResultSaved(true))
        XCTAssertEqual(result, .pasted)
        XCTAssertEqual(pasteboard.string(forType: .string), "Ergebnis")
    }

    func testFailedPasteReportsNotPasted() async {
        let (replacer, pasted) = makeReplacer(pasteSucceeds: false)
        let result = await replacer.replaceSelection(with: "Ergebnis", in: .current, restore: .ifResultSaved(true))
        XCTAssertEqual(result, .notPasted)
        XCTAssertTrue(pasted().isEmpty)
    }

    func testMissingTargetAppReportsNotPasted() async {
        let (replacer, _) = makeReplacer()
        let result = await replacer.replaceSelection(with: "Ergebnis", in: nil, restore: .ifResultSaved(true))
        XCTAssertEqual(result, .notPasted)
    }
}

// MARK: - Standard-Kurzbefehl, Umfang, Konflikte

@MainActor
final class QuickActionHotkeyReviewTests: XCTestCase {
    private let shiftCmdK = QuickActionShortcuts.correctDefault
    private let ctrlOptR = KeyboardShortcuts.Shortcut(.r, modifiers: [.control, .option])

    private func isolatedDefaults() -> (UserDefaults, String) {
        let suite = "QuickActionDefaultTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    func testCorrectDefaultIsStoredAsOffWhenTheKeyIsAlreadyTaken() {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = QuickActionShortcuts.storageKey(for: OutputMode.correctID)

        // Aufnahme-Hotkey liegt schon auf ⇧⌘K: „aus“ speichern, wie die Bibliothek es tut.
        QuickActionShortcuts.resolveCorrectDefault(
            modes: OutputMode.builtInModes, defaults: defaults,
            lookup: { $0 == .toggleRecording ? QuickActionShortcuts.correctDefault : nil }
        )
        XCTAssertEqual(defaults.object(forKey: key) as? Bool, false)
    }

    func testCorrectDefaultStaysWhenFreeOrAlreadyChosen() {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = QuickActionShortcuts.storageKey(for: OutputMode.correctID)

        QuickActionShortcuts.resolveCorrectDefault(modes: OutputMode.builtInModes, defaults: defaults, lookup: { _ in nil })
        XCTAssertNil(defaults.object(forKey: key), "frei: der Standard der Bibliothek greift")

        defaults.set("gewählt", forKey: key)
        QuickActionShortcuts.resolveCorrectDefault(
            modes: OutputMode.builtInModes, defaults: defaults,
            lookup: { $0 == .toggleRecording ? QuickActionShortcuts.correctDefault : nil }
        )
        XCTAssertEqual(defaults.string(forKey: key), "gewählt", "die Wahl des Nutzers bleibt, auch bei Konflikt")
    }

    /// Die Bibliothek liest nur `.standard`. Ein eindeutiger Name prüft, dass
    /// sie das gespeicherte `false` als „aus“ nimmt und ihren Standard dann
    /// nicht schreibt (ohne dabei einen Hotkey anzumelden).
    func testLibraryHonoursStoredOff() {
        let raw = "quickActionTest-\(UUID().uuidString)"
        let key = "KeyboardShortcuts_" + raw
        UserDefaults.standard.set(false, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let name = KeyboardShortcuts.Name(raw, default: KeyboardShortcuts.Shortcut(.f19, modifiers: [.command, .option, .control, .shift]))
        XCTAssertNil(KeyboardShortcuts.getShortcut(for: name))
        XCTAssertEqual(UserDefaults.standard.object(forKey: key) as? Bool, false)
    }

    func testQuickActionUsingFindsTheModeForFixedRecorders() {
        let modes = OutputMode.builtInModes
        let lookup: (KeyboardShortcuts.Name) -> KeyboardShortcuts.Shortcut? = { name in
            name.rawValue == "quickAction.\(OutputMode.correctID)" ? self.shiftCmdK : nil
        }
        let correct = modes.first { $0.id == OutputMode.correctID }!.displayName
        XCTAssertEqual(QuickActionShortcuts.quickActionUsing(shiftCmdK, modes: modes, lookup: lookup), correct)
        XCTAssertNil(QuickActionShortcuts.quickActionUsing(ctrlOptR, modes: modes, lookup: lookup))
        XCTAssertNil(QuickActionShortcuts.quickActionUsing(nil, modes: modes, lookup: lookup))
        XCTAssertNil(QuickActionShortcuts.quickActionUsing(shiftCmdK, excluding: OutputMode.correctID, modes: modes, lookup: lookup))
        XCTAssertNil(
            SettingsKeyRecorderRow.quickActionConflict(for: shiftCmdK, name: QuickActionShortcuts.lookupName(for: OutputMode.rephraseID)),
            "Schnellaktionen prüfen sich im eigenen Abschnitt"
        )
    }

    func testSuspendSkipsEmptyAndSharedWithFixedShortcuts() {
        let modes = OutputMode.builtInModes.filter { [OutputMode.emailID, OutputMode.rephraseID, OutputMode.correctID].contains($0.id) }
        let names = QuickActionShortcuts.namesToSuspend(modes: modes) { name in
            switch name.rawValue {
            case "quickAction.\(OutputMode.correctID)": return self.shiftCmdK
            case "quickAction.\(OutputMode.rephraseID)": return self.ctrlOptR
            case KeyboardShortcuts.Name.toggleRecording.rawValue: return self.ctrlOptR
            default: return nil
            }
        }
        XCTAssertEqual(names.map(\.rawValue), ["quickAction.\(OutputMode.correctID)"],
                       "Besser formulieren teilt sich die Taste mit der Aufnahme, E-Mail hat keinen")
    }

    func testDictationOnlyUnregistersAndSwitchingBackRegistersAgain() {
        // Ohne Korrigieren: dessen Name mit Standard schriebe in die echten Defaults.
        let modes = OutputMode.builtInModes.filter { [OutputMode.emailID, OutputMode.rephraseID].contains($0.id) }
        var available = false
        var handlers: [String] = []
        var calls: [(names: [String], enabled: Bool)] = []
        let hotkeys = QuickActionHotkeys(hooks: .init(
            modes: { modes },
            isAvailable: { available },
            addHandler: { name, _ in handlers.append(name.rawValue) },
            setEnabled: { names, enabled in calls.append((names.map(\.rawValue), enabled)) },
            lookup: { name in name.rawValue.hasPrefix(QuickActionShortcuts.namePrefix) ? self.ctrlOptR : nil },
            resolveDefault: { _ in }
        ))

        hotkeys.start { _ in }
        XCTAssertEqual(Set(handlers), Set(modes.map { "quickAction.\($0.id)" }), "Handler gibt es immer, gespeichert bleibt alles")
        XCTAssertEqual(calls.last?.enabled, false, "„Nur Diktat“: ⇧⌘K und Co. gehören wieder den anderen Apps")
        XCTAssertEqual(calls.last?.names.count, 2)

        // Irgendeine andere Einstellung ändert sich: nichts tun (R6).
        let before = calls.count
        hotkeys.applyScope()
        hotkeys.applyScope()
        XCTAssertEqual(calls.count, before, "ohne Wechsel des Umfangs keine Arbeit auf Main")

        // Frisch aufgenommener Kurzbefehl: nur dieser wird wieder abgemeldet.
        let rephrase = QuickActionShortcuts.lookupName(for: OutputMode.rephraseID)
        hotkeys.shortcutDidChange(rephrase)
        XCTAssertEqual(calls.count, before + 1)
        XCTAssertEqual(calls.last?.names, [rephrase.rawValue])
        XCTAssertEqual(calls.last?.enabled, false)
        hotkeys.shortcutDidChange(.toggleRecording)
        hotkeys.shortcutDidChange(nil)
        XCTAssertEqual(calls.count, before + 1, "andere Kurzbefehle gehen die Schnellaktion nichts an")

        available = true
        hotkeys.applyScope()
        XCTAssertEqual(calls.last?.enabled, true)
        let afterEnable = calls.count
        hotkeys.applyScope()
        XCTAssertEqual(calls.count, afterEnable, "mit Nacharbeit kostet eine Defaults-Änderung nichts")
        hotkeys.shortcutDidChange(QuickActionShortcuts.lookupName(for: OutputMode.rephraseID))
        XCTAssertEqual(calls.count, afterEnable, "mit Nacharbeit bleibt ein neuer Kurzbefehl angemeldet")
    }
}

// MARK: - Prüfung vor dem Einfügen: unklar ist nicht „geändert“ (R8)

final class QuickActionTargetCheckTests: XCTestCase {
    private let writable = CapturedSelection(text: "ein fehler", writability: .writable)

    private func check(
        _ original: CapturedSelection?, frontmost: Bool = true, answers: [SelectionReadout]
    ) async -> (unchanged: Bool, timeouts: [Float]) {
        var timeouts: [Float] = []
        var remaining = answers
        let result = await QuickActionTargetCheck.isUnchanged(original: original, frontmostMatches: frontmost) { timeout in
            timeouts.append(timeout)
            return remaining.isEmpty ? .noAnswer : remaining.removeFirst()
        }
        return (result, timeouts)
    }

    func testOtherAppInFrontIsAlwaysAChange() async {
        let result = await check(writable, frontmost: false, answers: [.text("ein fehler")])
        XCTAssertFalse(result.unchanged)
        XCTAssertTrue(result.timeouts.isEmpty)
    }

    func testSameOrDifferentSelection() async {
        let same = await check(writable, answers: [.text("ein fehler")])
        XCTAssertTrue(same.unchanged)
        let other = await check(writable, answers: [.text("anderer Satz")])
        XCTAssertFalse(other.unchanged, "D1: anderer Text markiert")
        let collapsed = await check(writable, answers: [.text("")])
        XCTAssertFalse(collapsed.unchanged, "D1: woanders hingeklickt")
        let noField = await check(writable, answers: [.nothingSelectable])
        XCTAssertFalse(noField.unchanged, "Fokus auf etwas ohne Markierung")
    }

    func testSlowAppIsAskedAgainWithTheLongerTimeout() async {
        let result = await check(writable, answers: [.noAnswer, .text("ein fehler")])
        XCTAssertTrue(result.unchanged)
        XCTAssertEqual(result.timeouts, [QuickActionTargetCheck.firstTimeout, QuickActionTargetCheck.retryTimeout])
    }

    func testNoAnswerTwiceIsUnclearNotChanged() async {
        let result = await check(writable, answers: [.noAnswer, .noAnswer])
        XCTAssertTrue(result.unchanged, "ausgelastete App: einfügen statt die Zwischenablage zu überschreiben")
        XCTAssertEqual(result.timeouts.count, 2)
    }

    func testWithoutAccessibilityTextOnlyTheAppCounts() async {
        let unknown = await check(CapturedSelection(text: "x", writability: .unknown), answers: [.nothingSelectable])
        XCTAssertTrue(unknown.unchanged)
        XCTAssertTrue(unknown.timeouts.isEmpty)
        let entry = await check(nil, answers: [])
        XCTAssertTrue(entry.unchanged)
    }

    func testAXErrorsMapToReadouts() {
        XCTAssertEqual(SelectionReadout(failure: .cannotComplete), .noAnswer, "Zeitlimit")
        XCTAssertEqual(SelectionReadout(failure: .apiDisabled), .noAnswer)
        XCTAssertEqual(SelectionReadout(failure: .attributeUnsupported), .nothingSelectable)
        XCTAssertEqual(SelectionReadout(failure: .noValue), .nothingSelectable)
        XCTAssertNil(SelectionReadout.noAnswer.text)
        XCTAssertEqual(SelectionReadout.text("a").text, "a")
    }
}

// MARK: - Cmd+C erst nach dem Loslassen des Kurzbefehls

@MainActor
final class QuickActionModifierWaitTests: XCTestCase {
    func testWaitsUntilModifiersAreReleased() async {
        var checks = 0
        let service = SelectedContextService(modifierKeysHeld: {
            checks += 1
            return checks < 4
        })
        let released = await service.waitForModifierRelease(timeout: .seconds(2), step: .milliseconds(1))
        XCTAssertTrue(released)
        XCTAssertEqual(checks, 4)
    }

    func testGivesUpAfterTheTimeLimit() async {
        let service = SelectedContextService(modifierKeysHeld: { true })
        let start = ContinuousClock.now
        let released = await service.waitForModifierRelease(timeout: .milliseconds(60), step: .milliseconds(5))
        XCTAssertFalse(released)
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - start, .milliseconds(60))
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1), "hält den Ablauf nicht auf")
    }
}

// MARK: - Schnellaktions-Ergebnisse im Verlauf (kein Diktat)

final class ClipboardQuickActionEntryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-quick-action-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private var enabled: ClipboardSettings {
        var settings = ClipboardSettings()
        settings.enabled = true
        return settings
    }

    private func entry(mode: String?, quickAction: Bool?) -> ClipboardEntry {
        var entry = ClipboardEntry(
            id: UUID().uuidString, kind: .text, createdAt: Date(), lastCopiedAt: Date(), copyCount: 1, isPinned: false,
            sourceBundleID: nil, sourceName: "Mail", contentHash: UUID().uuidString, preview: "Ein Fehler.", text: "Ein Fehler."
        )
        entry.dictationMode = mode
        entry.dictationOriginal = mode == nil ? nil : "ein fehler"
        entry.fromQuickAction = quickAction
        return entry
    }

    func testQuickActionResultIsMarkedAndSurvivesReload() throws {
        let capture = try XCTUnwrap(ClipboardHistoryCore.dictationCapture(
            text: "Ein Fehler.", original: "ein fehler", modeName: "Correct",
            targetBundleID: "com.apple.mail", targetName: "Mail", settings: enabled, fromQuickAction: true
        ))
        XCTAssertTrue(capture.fromQuickAction)

        let store = ClipboardHistoryStore(directory: directory, debounceSeconds: 0.01)
        store.add(capture, maxItems: 50)
        store.add(try XCTUnwrap(ClipboardHistoryCore.dictationCapture(
            text: "Diktiert.", modeName: "Clean", targetBundleID: nil, targetName: nil, settings: enabled
        )), maxItems: 50)
        store.flush()

        let loaded = ClipboardHistoryStore.loadIndex(directory: directory)
        let quick = try XCTUnwrap(loaded.first { $0.preview == "Ein Fehler." })
        XCTAssertTrue(quick.isQuickActionResult)
        XCTAssertFalse(quick.isDictation)
        XCTAssertEqual(quick.dictationOriginal, "ein fehler")
        let dictated = try XCTUnwrap(loaded.first { $0.preview == "Diktiert." })
        XCTAssertTrue(dictated.isDictation)
        XCTAssertNil(dictated.fromQuickAction, "normale Einträge schreiben das Feld gar nicht")
    }

    func testOldIndexWithoutTheFieldStillLoads() throws {
        let json = """
        [{"id":"a","kind":"text","createdAt":0,"lastCopiedAt":0,"copyCount":1,"isPinned":false,
          "contentHash":"h","preview":"alt","text":"alt","dictationMode":"Slack","dictationOriginal":"jo"}]
        """
        let entries = try JSONDecoder().decode([ClipboardEntry].self, from: Data(json.utf8))
        XCTAssertNil(entries.first?.fromQuickAction)
        XCTAssertEqual(entries.first?.isDictation, true, "alte Diktate bleiben Diktate")
    }

    func testDictationFilterLeavesQuickActionsOut() {
        let entries = [entry(mode: "Correct", quickAction: true), entry(mode: "Slack", quickAction: nil), entry(mode: nil, quickAction: nil)]
        let filtered = ClipboardHistoryViewModel.filtered(entries, by: .dictations)
        XCTAssertEqual(filtered.map(\.dictationMode), ["Slack"])
    }

    func testDictatingTheSameTextAgainTurnsItIntoADictation() {
        let quick = entry(mode: "Correct", quickAction: true)
        var dictated = quick
        dictated.id = "neu"
        dictated.dictationMode = "Clean"
        dictated.fromQuickAction = nil
        let merged = ClipboardHistoryCore.insert(dictated, into: [quick])
        XCTAssertTrue(merged.merged)
        XCTAssertEqual(merged.entries.first?.isDictation, true)
    }

    func testCLIShowsQuickActionModeInsteadOfDictationMode() {
        let quick = entry(mode: "Correct", quickAction: true)
        let context = ClipboardCLIFormatter.Context(settings: enabled, directory: directory, fullText: { $0.text }, now: Date())
        let summary = ClipboardCLIFormatter.summary(quick, number: 1, context: context)
        XCTAssertEqual(summary["quickActionMode"] as? String, "Correct")
        XCTAssertNil(summary["dictationMode"], "kein Diktat: Agents sollen es nicht für Gesagtes halten")
        XCTAssertEqual(summary["hasOriginal"] as? Bool, true)
        XCTAssertTrue(ClipboardCLIFormatter.listing([(1, quick)], json: false, context: context).contains("Aktion Correct"))
        let detail = ClipboardCLIFormatter.detail(quick, number: 1, json: false, context: context)
        XCTAssertTrue(detail.note?.contains("Schnellaktion") == true)
    }
}
