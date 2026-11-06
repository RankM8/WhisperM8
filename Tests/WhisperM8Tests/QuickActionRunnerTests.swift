import AppKit
import KeyboardShortcuts
import XCTest
@testable import WhisperM8

/// Schnellaktion ohne Diktat: Markierung lesen, umarbeiten, ersetzen. Alle
/// Systemzugriffe sind Spies; geprüft wird der Ablauf.
@MainActor
final class QuickActionRunnerTests: XCTestCase {
    // MARK: Spies

    private final class SpyPresenter: QuickActionPresenting {
        var workingLabels: [String] = []
        var hints: [String] = []
        var hideCount = 0
        var onCancel: (() -> Void)?

        func showQuickActionWorking(label: String, onCancel: @escaping () -> Void) {
            workingLabels.append(label)
            self.onCancel = onCancel
        }

        func showQuickActionHint(_ text: String, duration: TimeInterval) { hints.append(text) }
        func hideQuickAction() { hideCount += 1 }
    }

    private final class SpyCancelKey: CleanUpCancelKeyGrabbing {
        private(set) var isActive = false
        private(set) var activations = 0
        private var handler: (@MainActor () -> Void)?

        func activate(handler: @escaping @MainActor () -> Void) {
            activations += 1
            isActive = true
            self.handler = handler
        }

        func deactivate() {
            isActive = false
            handler = nil
        }

        @MainActor func pressEscape() { handler?() }
    }

    /// Hält fest, was der Runner an die Umgebung gegeben hat.
    private final class Log {
        var captureCalls = 0
        var reworkInputs: [(text: String, modeID: String)] = []
        var replaced: [String] = []
        var copied: [String] = []
        var history: [(result: String, original: String)] = []
        var notices: [String] = []
        var busySignals = 0
        var engineCancels = 0
        var seenSource: PostProcessingInputSource?
        var seenOwner: CodexRunOwner?
        var sawCancelToken = false
        var permissionRequests = 0
        /// War Esc noch angemeldet, als eingefügt wurde?
        var cancelKeyActiveWhilePasting: Bool?
        var restoreRules: [QuickActionRestoreRule] = []
        var targetChecks: [CapturedSelection?] = []
    }

    private let correctMode = OutputMode.builtInModes.first { $0.id == OutputMode.correctID }!
    private let rawMode = OutputMode.builtInModes.first { $0.id == OutputMode.rawID }!

    private func makeRunner(
        log: Log,
        presenter: SpyPresenter? = nil,
        cancelKey: SpyCancelKey? = nil,
        selection: CapturedSelection? = CapturedSelection(text: "Das ist ein fehler.", writability: .writable),
        rework: @escaping @MainActor (String, OutputMode) async throws -> PostProcessingRun = { _, _ in PostProcessingRun(text: "Das ist ein Fehler.") },
        replaceSucceeds: Bool = true,
        pasteResult: QuickActionPasteResult? = nil,
        targetUnchanged: Bool = true,
        historySaved: Bool = true,
        postProcessingAvailable: Bool = true,
        accessibilityGranted: Bool = true,
        dictationBusy: Bool = false
    ) -> QuickActionRunner {
        let modes = [correctMode, rawMode]
        let key = cancelKey ?? SpyCancelKey()
        let environment = QuickActionEnvironment(
            frontmostApp: { nil },
            modeResolver: { id in modes.first { $0.id == id } },
            isPostProcessingAvailable: { postProcessingAvailable },
            hasAccessibilityPermission: { accessibilityGranted },
            requestAccessibilityPermission: { log.permissionRequests += 1 },
            captureSelection: { _ in
                log.captureCalls += 1
                return selection
            },
            rework: { text, mode in
                log.reworkInputs.append((text, mode.id))
                log.seenSource = PostProcessingInputSource.current
                log.seenOwner = CodexRunOwner.current
                log.sawCancelToken = PostProcessingCancelToken.current != nil
                return try await rework(text, mode)
            },
            isTargetUnchanged: { original, _ in
                log.targetChecks.append(original)
                return targetUnchanged
            },
            replaceSelection: { text, _, rule in
                log.cancelKeyActiveWhilePasting = key.isActive
                log.replaced.append(text)
                log.restoreRules.append(rule)
                return pasteResult ?? (replaceSucceeds ? .pasted : .notPasted)
            },
            copyToClipboard: { log.copied.append($0) },
            recordHistory: { result, original, _, _ in
                log.history.append((result, original))
                return historySaved
            },
            postNotice: { title, _ in log.notices.append(title) },
            busySignal: { log.busySignals += 1 },
            cancelEngines: { log.engineCancels += 1 }
        )
        return QuickActionRunner(
            environment: environment,
            presenter: presenter ?? SpyPresenter(),
            cancelKey: key,
            isDictationBusy: { dictationBusy }
        )
    }

    // MARK: Ablauf

    func testReplacesSelectionWithReworkedText() async {
        let log = Log()
        let presenter = SpyPresenter()
        let key = SpyCancelKey()
        let runner = makeRunner(log: log, presenter: presenter, cancelKey: key)

        let outcome = await runner.run(modeID: OutputMode.correctID)

        XCTAssertEqual(outcome, .replaced)
        XCTAssertEqual(log.reworkInputs.map(\.text), ["Das ist ein fehler."])
        XCTAssertEqual(log.replaced, ["Das ist ein Fehler."])
        XCTAssertTrue(log.copied.isEmpty, "Erfolg legt nichts zusätzlich in die Zwischenablage")
        XCTAssertEqual(log.history.first?.original, "Das ist ein fehler.")
        XCTAssertEqual(presenter.workingLabels.count, 1, "Overlay zeigt die Arbeit statt einer Aufnahme")
        XCTAssertGreaterThan(presenter.hideCount, 0)
        XCTAssertEqual(key.activations, 1, "ESC ist während der Nacharbeit angemeldet")
        XCTAssertFalse(key.isActive, "und danach wieder frei")
        XCTAssertFalse(runner.isRunning)
    }

    func testEscapeIsReleasedBeforePasting() async {
        let log = Log()
        _ = await makeRunner(log: log).run(modeID: OutputMode.correctID)
        XCTAssertEqual(log.cancelKeyActiveWhilePasting, false, "Esc gehört beim Einfügen wieder allen Apps")
    }

    func testMissingAccessibilityAsksForPermissionInsteadOfSayingSelectFirst() async {
        let log = Log()
        let presenter = SpyPresenter()
        let outcome = await makeRunner(log: log, presenter: presenter, accessibilityGranted: false)
            .run(modeID: OutputMode.correctID)

        XCTAssertEqual(outcome, .unavailable)
        XCTAssertEqual(log.permissionRequests, 1)
        XCTAssertEqual(log.captureCalls, 0)
        XCTAssertEqual(presenter.hints, [String(localized: "Allow Accessibility for WhisperM8 first")])
    }

    func testReworkRunsUnderSelectionSourceOwnerAndCancelToken() async {
        let log = Log()
        _ = await makeRunner(log: log).run(modeID: OutputMode.correctID)

        XCTAssertEqual(log.seenSource, .selection, "Prompt erfährt, dass es markierter Text ist")
        XCTAssertEqual(log.seenOwner, .quickAction, "Abbruch trifft nur die Schnellaktion")
        XCTAssertTrue(log.sawCancelToken)
        XCTAssertEqual(PostProcessingInputSource.current, .dictation, "Task-Local gilt nur im Lauf")
    }

    func testNoSelectionShowsHintAndDoesNotRework() async {
        let log = Log()
        let presenter = SpyPresenter()
        let outcome = await makeRunner(log: log, presenter: presenter, selection: nil).run(modeID: OutputMode.correctID)

        XCTAssertEqual(outcome, .noSelection)
        XCTAssertEqual(presenter.hints.count, 1)
        XCTAssertTrue(presenter.workingLabels.isEmpty)
        XCTAssertTrue(log.reworkInputs.isEmpty)
        XCTAssertTrue(log.replaced.isEmpty && log.copied.isEmpty)
    }

    func testReadOnlyFieldPutsResultOnClipboardWithHint() async {
        let log = Log()
        let presenter = SpyPresenter()
        let runner = makeRunner(
            log: log, presenter: presenter,
            selection: CapturedSelection(text: "web text", writability: .readOnly),
            rework: { _, _ in PostProcessingRun(text: "Web text.") }
        )

        let outcome = await runner.run(modeID: OutputMode.correctID)

        XCTAssertEqual(outcome, .copiedToClipboard)
        XCTAssertTrue(log.replaced.isEmpty, "Kein Cmd+V in ein nicht beschreibbares Feld")
        XCTAssertEqual(log.copied, ["Web text."])
        XCTAssertEqual(presenter.hints.count, 1)
        XCTAssertEqual(log.history.count, 1)
    }

    func testUnknownWritabilityStillPastes() async {
        let log = Log()
        let outcome = await makeRunner(
            log: log,
            selection: CapturedSelection(text: "a", writability: .unknown),
            rework: { _, _ in PostProcessingRun(text: "A.") }
        ).run(modeID: OutputMode.correctID)

        XCTAssertEqual(outcome, .replaced)
        XCTAssertEqual(log.replaced, ["A."])
    }

    func testFailedPasteFallsBackToClipboardWithNotice() async {
        let log = Log()
        let outcome = await makeRunner(log: log, replaceSucceeds: false).run(modeID: OutputMode.correctID)

        XCTAssertEqual(outcome, .copiedToClipboard)
        XCTAssertEqual(log.copied, ["Das ist ein Fehler."])
        XCTAssertEqual(log.notices.count, 1)
    }

    func testEscapeCancelsAndLeavesEverythingAsItWas() async {
        let log = Log()
        let key = SpyCancelKey()
        let presenter = SpyPresenter()
        var hiddenRightAfterEscape = false
        let runner = makeRunner(log: log, presenter: presenter, cancelKey: key, rework: { _, _ in
            // ESC kommt, während die Nacharbeit läuft; der Weg meldet den Abbruch.
            key.pressEscape()
            hiddenRightAfterEscape = presenter.hideCount > 0
            try PostProcessingCancelToken.checkCurrent()
            return PostProcessingRun(text: "nie")
        })

        let outcome = await runner.run(modeID: OutputMode.correctID)

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertTrue(hiddenRightAfterEscape, "Overlay geht sofort weg, nicht erst nach dem Prozessende")
        XCTAssertEqual(log.engineCancels, 1, "laufender Codex-/Backend-Lauf wird beendet")
        XCTAssertTrue(log.replaced.isEmpty && log.copied.isEmpty && log.history.isEmpty)
        XCTAssertTrue(log.notices.isEmpty, "Abbruch ist kein Fehler")
        XCTAssertGreaterThan(presenter.hideCount, 0)
        XCTAssertFalse(key.isActive)
    }

    /// ✕ nach dem Ende der Nacharbeit (nichts mehr abzubrechen) schließt die
    /// Pill trotzdem, statt sie tot stehen zu lassen.
    func testCancelWithoutRunningActionStillHidesPill() {
        let log = Log()
        let presenter = SpyPresenter()
        let runner = makeRunner(log: log, presenter: presenter)

        runner.cancel()

        XCTAssertEqual(presenter.hideCount, 1)
        XCTAssertEqual(log.engineCancels, 0, "Ohne Lauf wird nichts abgebrochen")
    }

    func testCancelViaOverlayWinsEvenIfEngineStillDelivers() async {
        let log = Log()
        let presenter = SpyPresenter()
        let runner = makeRunner(log: log, presenter: presenter, rework: { _, _ in
            presenter.onCancel?()
            return PostProcessingRun(text: "kam trotzdem")
        })

        let outcome = await runner.run(modeID: OutputMode.correctID)

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertTrue(log.replaced.isEmpty && log.copied.isEmpty)
    }

    func testFailureReportsAndReplacesNothing() async {
        let log = Log()
        let runner = makeRunner(log: log, rework: { _, _ in
            throw PostProcessingError.bothEnginesFailed(backend: "down", codex: "not logged in")
        })

        let outcome = await runner.run(modeID: OutputMode.correctID)

        guard case .failed = outcome else { return XCTFail("erwartet .failed, war \(outcome)") }
        XCTAssertEqual(log.notices.count, 1)
        XCTAssertTrue(log.replaced.isEmpty && log.copied.isEmpty)
    }

    func testUnchangedResultIsNotPasted() async {
        let log = Log()
        let presenter = SpyPresenter()
        let outcome = await makeRunner(
            log: log, presenter: presenter,
            rework: { text, _ in PostProcessingRun(text: text) }
        ).run(modeID: OutputMode.correctID)

        XCTAssertEqual(outcome, .unchanged)
        XCTAssertTrue(log.replaced.isEmpty)
        XCTAssertEqual(presenter.hints.count, 1)
    }

    func testEmptyResultIsAFailureNotAnEmptyReplacement() async {
        let log = Log()
        let outcome = await makeRunner(log: log, rework: { _, _ in PostProcessingRun(text: "  \n") })
            .run(modeID: OutputMode.correctID)

        guard case .failed = outcome else { return XCTFail("erwartet .failed, war \(outcome)") }
        XCTAssertTrue(log.replaced.isEmpty, "Die Markierung darf nie durch Leere ersetzt werden")
    }

    func testBusyDictationBlocksWithSignal() async {
        let log = Log()
        let outcome = await makeRunner(log: log, dictationBusy: true).run(modeID: OutputMode.correctID)

        XCTAssertEqual(outcome, .busy)
        XCTAssertEqual(log.busySignals, 1)
        XCTAssertEqual(log.captureCalls, 0, "kein Cmd+C, solange ein Diktat läuft")
    }

    func testModeWithoutPostProcessingIsUnavailable() async {
        let log = Log()
        let outcome = await makeRunner(log: log).run(modeID: OutputMode.rawID)
        XCTAssertEqual(outcome, .unavailable)
        XCTAssertEqual(log.captureCalls, 0)
    }

    func testDictationOnlyScopeShowsHint() async {
        let log = Log()
        let presenter = SpyPresenter()
        let outcome = await makeRunner(log: log, presenter: presenter, postProcessingAvailable: false)
            .run(modeID: OutputMode.correctID)
        XCTAssertEqual(outcome, .unavailable)
        XCTAssertEqual(presenter.hints.count, 1)
        XCTAssertEqual(log.captureCalls, 0)
    }

    func testCorrectModeGetsCorrectingLabel() {
        XCTAssertEqual(QuickActionRunner.workingLabel(for: correctMode), String(localized: "Correcting…"))
        var renamed = correctMode
        renamed.name = "Tippfehler weg"
        renamed.kind = .custom
        XCTAssertEqual(QuickActionRunner.workingLabel(for: renamed), "Tippfehler weg…")
    }

    // MARK: Textregeln

    func testReplacementKeepsOuterWhitespaceOfSelection() {
        XCTAssertEqual(
            QuickActionText.replacement(for: "  ein absatz\n\n", modelOutput: "Ein Absatz.\n"),
            "  Ein Absatz.\n\n"
        )
        XCTAssertEqual(QuickActionText.replacement(for: "wort", modelOutput: "  Wort "), "Wort")
        XCTAssertEqual(QuickActionText.replacement(for: "x\n", modelOutput: " \n "), "")
    }

    func testWritabilityRule() {
        XCTAssertEqual(SelectionWritability.resolve(hasFocusedElement: false, selectedTextSettable: false, valueSettable: false), .unknown)
        XCTAssertEqual(SelectionWritability.resolve(hasFocusedElement: true, selectedTextSettable: true, valueSettable: false), .writable)
        XCTAssertEqual(SelectionWritability.resolve(hasFocusedElement: true, selectedTextSettable: false, valueSettable: true), .writable)
        XCTAssertEqual(SelectionWritability.resolve(hasFocusedElement: true, selectedTextSettable: false, valueSettable: false), .readOnly)
    }
}

/// Neue Modi, Prompt-Hinweis und Kurzbefehl-Regeln.
@MainActor
final class QuickActionModesTests: XCTestCase {
    func testNewBuiltInModesExistWithTemplatesAndRunOverGPTBackend() throws {
        for id in [OutputMode.correctID, OutputMode.rephraseID] {
            let mode = try XCTUnwrap(OutputMode.builtInModes.first { $0.id == id })
            XCTAssertTrue(mode.usesPostProcessing)
            XCTAssertTrue(mode.isEnabled, "steht auch beim Diktat zur Wahl")
            XCTAssertEqual(mode.contextPolicy, .auto, "Markierung kommt beim Diktat als Text mit")
            XCTAssertFalse(mode.pasteVisualAttachments)
            XCTAssertTrue(PostProcessingEngineRouter.isBackendEligible(mode), "kein Projektzugriff, also GPT-Backend mit Codex-Rückfall")
            let template = try XCTUnwrap(PostProcessingTemplate.builtInTemplate(id: mode.templateID))
            XCTAssertTrue(template.instruction.contains("{selectedContext}"))
            XCTAssertTrue(template.instruction.contains("{rawTranscript}"))
        }
    }

    func testDictationWithSelectionPassesSelectionAsTextAndSpeechAsInstruction() throws {
        let template = try XCTUnwrap(PostProcessingTemplate.builtInTemplate(id: PostProcessingTemplate.correctID))
        let rendered = template.render(
            rawTranscript: "und etwas förmlicher",
            language: "de",
            selectedContext: SelectedContext(text: "hey, kanst du das machen", sourceAppName: "Mail", sourceBundleIdentifier: nil)
        )
        XCTAssertTrue(rendered.contains("Selected text:\nhey, kanst du das machen"))
        XCTAssertTrue(rendered.contains("Transcript:\nund etwas förmlicher"))
    }

    func testPromptMentionsSelectionOnlyForQuickAction() {
        let mode = OutputMode.builtInModes.first { $0.id == OutputMode.correctID }!
        let template = PostProcessingTemplate.builtInTemplate(id: mode.templateID)!
        let builder = PromptPackageBuilder()

        let dictation = builder.build(rawText: "x", mode: mode, template: template, language: "", contextBundle: .empty)
        XCTAssertFalse(dictation.prompt.contains("## Input Source"))

        let selection = PostProcessingInputSource.$current.withValue(.selection) {
            builder.build(rawText: "x", mode: mode, template: template, language: "", contextBundle: .empty)
        }
        XCTAssertTrue(selection.prompt.contains("## Input Source"))
        XCTAssertTrue(selection.prompt.contains("replaces the selection"))
    }

    func testRouterFallsBackToCodexForQuickActionToo() async throws {
        struct Failing: PostProcessing {
            func process(rawText: String, mode: OutputMode, language: String, contextBundle: TranscriptContextBundle) async throws -> String {
                throw URLError(.cannotConnectToHost)
            }
        }
        let router = PostProcessingEngineRouter(
            backend: Failing(),
            codex: MockPostProcessor(output: "Korrigiert."),
            isBackendPreferred: { true }
        )
        let mode = OutputMode.builtInModes.first { $0.id == OutputMode.correctID }!
        let run = try await PostProcessingInputSource.$current.withValue(.selection) {
            try await PostProcessingService(processor: router)
                .processRun(rawText: "korigiert", mode: mode, language: "", contextBundle: .empty)
        }
        XCTAssertEqual(run.text, "Korrigiert.")
        XCTAssertEqual(run.engine, .codexCLI)
        XCTAssertNotNil(run.fallbackReason)
    }

    func testDashesFromTheSelectionSurviveButModelDashesAreStillRemoved() async throws {
        let mode = OutputMode.builtInModes.first { $0.id == OutputMode.correctID }!
        let service = PostProcessingService(processor: MockPostProcessor(output: "Ja — genau so."))

        let kept = try await PostProcessingInputSource.$current.withValue(.selection) {
            try await service.processRun(rawText: "ja — genau so", mode: mode, language: "", contextBundle: .empty)
        }
        XCTAssertEqual(kept.text, "Ja — genau so.", "Striche des Nutzers bleiben")

        let filtered = try await PostProcessingInputSource.$current.withValue(.selection) {
            try await service.processRun(rawText: "ja genau so", mode: mode, language: "", contextBundle: .empty)
        }
        XCTAssertFalse(filtered.text.contains("—"), "neue Striche vom Modell fliegen raus")

        let dictation = try await service.processRun(rawText: "ja — genau so", mode: mode, language: "", contextBundle: .empty)
        XCTAssertFalse(dictation.text.contains("—"), "beim Diktat gilt der Filter wie bisher")
    }

    func testShortcutsAreOnlyOfferedForPostProcessingModes() {
        XCTAssertNil(QuickActionShortcuts.suggestion(for: OutputMode.correctID), "Korrigieren hat den Standard, keinen Vorschlag-Knopf")
        XCTAssertNotNil(QuickActionShortcuts.suggestion(for: OutputMode.rephraseID))
        XCTAssertNil(QuickActionShortcuts.suggestion(for: OutputMode.emailID))
        XCTAssertNotEqual(QuickActionShortcuts.suggestion(for: OutputMode.rephraseID), QuickActionShortcuts.correctDefault)
        let eligible = QuickActionShortcuts.eligibleModes(OutputMode.builtInModes).map(\.id)
        XCTAssertFalse(eligible.contains(OutputMode.rawID))
        XCTAssertTrue(eligible.contains(OutputMode.emailID), "auch bestehende Modi bekommen einen Kurzbefehl")
        XCTAssertEqual(QuickActionShortcuts.name(for: "x").rawValue, "quickAction.x")
    }

    func testOnlyCorrectHasDefaultShortcut() {
        XCTAssertEqual(
            QuickActionShortcuts.defaultShortcut(for: OutputMode.correctID),
            KeyboardShortcuts.Shortcut(.k, modifiers: [.command, .shift])
        )
        for mode in OutputMode.builtInModes where mode.id != OutputMode.correctID {
            XCTAssertNil(QuickActionShortcuts.defaultShortcut(for: mode.id), "\(mode.id) bleibt ab Werk leer")
        }
        XCTAssertNil(QuickActionShortcuts.defaultShortcut(for: "custom-123"))
    }

    func testCorrectDefaultDoesNotCollideWithAppShortcuts() {
        let fixed: [KeyboardShortcuts.Name] = [.toggleRecording, .clipboardHistory, .toggleNotchStatus]
        for name in fixed {
            XCTAssertNotEqual(name.defaultShortcut, QuickActionShortcuts.correctDefault, name.rawValue)
        }
    }

    func testConflictDetectsOtherModesAndAppShortcuts() {
        let combo = KeyboardShortcuts.Shortcut(.k, modifiers: [.control, .option])
        let modes = OutputMode.builtInModes
        let emailName = QuickActionShortcuts.name(for: OutputMode.emailID)

        let clash = QuickActionShortcuts.conflict(for: combo, excluding: OutputMode.correctID, modes: modes) { name in
            name == emailName ? combo : nil
        }
        XCTAssertEqual(clash, OutputMode.builtInModes.first { $0.id == OutputMode.emailID }!.displayName)

        let own = QuickActionShortcuts.conflict(for: combo, excluding: OutputMode.emailID, modes: modes) { name in
            name == emailName ? combo : nil
        }
        XCTAssertNil(own, "der eigene Kurzbefehl ist kein Konflikt")

        let recording = QuickActionShortcuts.conflict(for: combo, excluding: OutputMode.correctID, modes: modes) { name in
            name == .toggleRecording ? combo : nil
        }
        XCTAssertNotNil(recording)
        XCTAssertNil(QuickActionShortcuts.conflict(for: nil, excluding: OutputMode.correctID, modes: modes))
    }
}

// MARK: - Zwischenablage-Fenster: vorgegebener Text

extension QuickActionRunnerTests {
    func testEntryTextIsCorrectedAndPastedWithoutReadingTheSelection() async {
        let log = Log()
        let runner = makeRunner(log: log, selection: nil)

        let outcome = await runner.run(modeID: OutputMode.correctID, input: .text("Das ist ein fehler."))

        XCTAssertEqual(outcome, .replaced)
        XCTAssertEqual(log.captureCalls, 0, "der Text kommt aus dem Eintrag, keine Markierung lesen")
        XCTAssertEqual(log.reworkInputs.map(\.text), ["Das ist ein fehler."])
        XCTAssertEqual(log.replaced, ["Das ist ein Fehler."])
        XCTAssertEqual(log.history.first?.original, "Das ist ein fehler.")
        XCTAssertEqual(log.seenSource, .selection)
    }

    func testUnchangedEntryIsStillPastedButNotRecordedTwice() async {
        let log = Log()
        let presenter = SpyPresenter()
        let runner = makeRunner(log: log, presenter: presenter, rework: { _, _ in PostProcessingRun(text: "Alles richtig.") })

        let outcome = await runner.run(modeID: OutputMode.correctID, input: .text("Alles richtig."))

        XCTAssertEqual(outcome, .unchanged)
        XCTAssertEqual(log.replaced, ["Alles richtig."], "„Korrigieren & einfügen“ fügt auch einen schon richtigen Text ein")
        XCTAssertTrue(log.history.isEmpty, "der Text steht schon im Verlauf")
        XCTAssertFalse(presenter.hints.contains("Nothing to change"))
    }

    func testBlankEntryDoesNothing() async {
        let log = Log()
        let outcome = await makeRunner(log: log).run(modeID: OutputMode.correctID, input: .text("  \n"))
        XCTAssertEqual(outcome, .noSelection)
        XCTAssertTrue(log.reworkInputs.isEmpty)
    }

    func testFailedEntryPasteLeavesResultOnClipboard() async {
        let log = Log()
        let outcome = await makeRunner(log: log, replaceSucceeds: false)
            .run(modeID: OutputMode.correctID, input: .text("Das ist ein fehler."))
        XCTAssertEqual(outcome, .copiedToClipboard)
        XCTAssertEqual(log.copied, ["Das ist ein Fehler."])
        XCTAssertEqual(log.notices, [String(localized: "Text not inserted")])
    }

    func testEntryFailureUsesEntryWording() async {
        struct Boom: LocalizedError { var errorDescription: String? { "kaputt" } }
        let log = Log()
        _ = await makeRunner(log: log, rework: { _, _ in throw Boom() })
            .run(modeID: OutputMode.correctID, input: .text("Text"))
        XCTAssertEqual(log.notices, [String(localized: "Text not corrected")])
    }

    func testSelectionProbeRule() {
        XCTAssertEqual(SelectionProbe.resolve(hasFocusedElement: false, selectedText: nil), .unknown)
        XCTAssertEqual(SelectionProbe.resolve(hasFocusedElement: true, selectedText: nil), .unknown, "Attribut nicht lesbar (Electron)")
        XCTAssertEqual(SelectionProbe.resolve(hasFocusedElement: true, selectedText: " \n"), .none)
        XCTAssertEqual(SelectionProbe.resolve(hasFocusedElement: true, selectedText: "  Hallo\nWelt "), .selected(preview: "Hallo Welt"))
        let long = String(repeating: "a", count: 1_000)
        guard case .selected(let preview) = SelectionProbe.resolve(hasFocusedElement: true, selectedText: long) else {
            return XCTFail("erwartet: selected")
        }
        XCTAssertEqual(preview.count, SelectionProbe.previewLimit)
        XCTAssertEqual(SelectionProbe.resolve(hasFocusedElement: true, selectedText: nil, role: "AXOutline"), .none, "Finder-Liste: keine Kopfzeile")
        XCTAssertEqual(SelectionProbe.resolve(hasFocusedElement: true, selectedText: nil, role: "AXWebArea"), .unknown)
    }

    func testUnknownProbeNeedsAWorkingCopyFallback() {
        XCTAssertEqual(SelectionProbe.unknown.respectingCopyFallback(true), .unknown)
        XCTAssertEqual(SelectionProbe.unknown.respectingCopyFallback(false), .none, "VS Code, ohne Bedienungshilfen: kein leeres Versprechen")
        XCTAssertEqual(SelectionProbe.selected(preview: "x").respectingCopyFallback(false), .selected(preview: "x"))
    }
}

// MARK: - Review-Befunde (Weiterarbeiten, Rückmeldung, Zurücklegen, Sperre)

extension QuickActionRunnerTests {
    func testChangedTargetPutsResultOnClipboardInsteadOfPasting() async {
        let log = Log()
        let presenter = SpyPresenter()
        let outcome = await makeRunner(log: log, presenter: presenter, targetUnchanged: false)
            .run(modeID: OutputMode.correctID)

        XCTAssertEqual(outcome, .copiedToClipboard)
        XCTAssertTrue(log.replaced.isEmpty, "kein Cmd+V an eine andere Stelle")
        XCTAssertEqual(log.copied, ["Das ist ein Fehler."])
        XCTAssertEqual(presenter.hints, [String(localized: "The selection changed. The result is on the clipboard.")])
        XCTAssertEqual(log.history.count, 1, "das Ergebnis steht trotzdem im Verlauf")
    }

    func testTargetCheckGetsSelectionButNotForEntries() async {
        let log = Log()
        _ = await makeRunner(log: log).run(modeID: OutputMode.correctID)
        _ = await makeRunner(log: log, selection: nil).run(modeID: OutputMode.correctID, input: .text("ein fehler"))

        XCTAssertEqual(log.targetChecks.count, 2)
        XCTAssertEqual(log.targetChecks.first??.text, "Das ist ein fehler.")
        XCTAssertNil(log.targetChecks.last ?? nil, "beim Verlaufseintrag zählt nur die App")
    }

    func testRestoreRuleFollowsWritability() async {
        let writable = Log()
        _ = await makeRunner(log: writable).run(modeID: OutputMode.correctID)
        XCTAssertEqual(writable.restoreRules, [.afterConfirmation(original: "Das ist ein fehler.")])

        let unknownSaved = Log()
        _ = await makeRunner(log: unknownSaved, selection: CapturedSelection(text: "a", writability: .unknown),
                             rework: { _, _ in PostProcessingRun(text: "A.") }).run(modeID: OutputMode.correctID)
        XCTAssertEqual(unknownSaved.restoreRules, [.ifResultSaved(true)])

        let unknownLost = Log()
        _ = await makeRunner(log: unknownLost, selection: CapturedSelection(text: "a", writability: .unknown),
                             rework: { _, _ in PostProcessingRun(text: "A.") }, historySaved: false)
            .run(modeID: OutputMode.correctID)
        XCTAssertEqual(unknownLost.restoreRules, [.ifResultSaved(false)], "Verlauf aus: Ergebnis darf nicht verschwinden")
    }

    func testUnconfirmedPasteTellsThatResultStaysOnClipboard() async {
        let log = Log()
        let presenter = SpyPresenter()
        let outcome = await makeRunner(log: log, presenter: presenter, pasteResult: .pastedResultKept)
            .run(modeID: OutputMode.correctID)
        XCTAssertEqual(outcome, .replaced)
        XCTAssertEqual(presenter.hints, [String(localized: "The result is also on the clipboard.")])
        XCTAssertTrue(log.copied.isEmpty, "liegt schon dort")
    }

    func testFailuresAreShownInTheOverlayToo() async {
        let failed = Log()
        let failedPresenter = SpyPresenter()
        _ = await makeRunner(log: failed, presenter: failedPresenter, rework: { _, _ in
            throw PostProcessingError.bothEnginesFailed(backend: "down", codex: "not logged in")
        }).run(modeID: OutputMode.correctID)
        XCTAssertEqual(failedPresenter.hints, [String(localized: "Selection not changed")], "auch unter Fokus sichtbar")
        XCTAssertEqual(failed.notices.count, 1)

        let empty = Log()
        let emptyPresenter = SpyPresenter()
        _ = await makeRunner(log: empty, presenter: emptyPresenter, rework: { _, _ in PostProcessingRun(text: " ") })
            .run(modeID: OutputMode.correctID)
        XCTAssertEqual(emptyPresenter.hints, [String(localized: "Selection not changed")])

        let notPasted = Log()
        let notPastedPresenter = SpyPresenter()
        _ = await makeRunner(log: notPasted, presenter: notPastedPresenter, replaceSucceeds: false)
            .run(modeID: OutputMode.correctID)
        XCTAssertEqual(notPastedPresenter.hints, [String(localized: "Not inserted. The result is on the clipboard.")])
    }

    func testCancelReleasesTheLockAtOnceAndTheLateRunStaysOutOfTheWay() async {
        let log = Log()
        let presenter = SpyPresenter()
        let key = SpyCancelKey()
        var release: CheckedContinuation<Void, Never>?
        var lockedRightAfterEscape: Bool?
        var firstCall = true
        var runner: QuickActionRunner!
        runner = makeRunner(log: log, presenter: presenter, cancelKey: key, rework: { text, _ in
            if firstCall {
                firstCall = false
                key.pressEscape()
                lockedRightAfterEscape = runner.isRunning
                // Der abgebrochene Weg läuft noch (etwa Codex bis zu 3 s).
                await withCheckedContinuation { release = $0 }
                return PostProcessingRun(text: "spät")
            }
            return PostProcessingRun(text: "Das ist ein Fehler.")
        })

        let first = Task { await runner.run(modeID: OutputMode.correctID) }
        while release == nil { await Task.yield() }
        XCTAssertEqual(lockedRightAfterEscape, false, "Esc gibt die Sperre sofort frei")
        XCTAssertFalse(runner.isRunning)

        // Direkt danach geht die nächste Aktion (oder ein Diktat) durch.
        let presenterHidesBefore = presenter.hideCount
        let second = await runner.run(modeID: OutputMode.correctID)
        XCTAssertEqual(second, .replaced)
        XCTAssertEqual(log.busySignals, 0)

        // Der späte erste Lauf endet jetzt: er ersetzt nichts und fasst
        // weder Overlay noch Esc an.
        key.activate { }
        release?.resume()
        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .cancelled)
        XCTAssertEqual(log.replaced, ["Das ist ein Fehler."], "nur der zweite Lauf fügt ein")
        XCTAssertTrue(key.isActive, "der späte Lauf gibt fremdes Esc nicht frei")
        XCTAssertEqual(presenter.hideCount, presenterHidesBefore + 1, "nur der zweite Lauf blendet aus")
    }
}
