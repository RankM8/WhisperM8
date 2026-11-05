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
            replaceSelection: { text, _ in
                log.cancelKeyActiveWhilePasting = key.isActive
                log.replaced.append(text)
                return replaceSucceeds
            },
            copyToClipboard: { log.copied.append($0) },
            recordHistory: { result, original, _, _ in log.history.append((result, original)) },
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
        XCTAssertNotNil(QuickActionShortcuts.suggestion(for: OutputMode.correctID))
        XCTAssertNotNil(QuickActionShortcuts.suggestion(for: OutputMode.rephraseID))
        XCTAssertNil(QuickActionShortcuts.suggestion(for: OutputMode.emailID))
        XCTAssertNotEqual(
            QuickActionShortcuts.suggestion(for: OutputMode.correctID),
            QuickActionShortcuts.suggestion(for: OutputMode.rephraseID)
        )
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
        XCTAssertEqual(QuickActionShortcuts.suggestion(for: OutputMode.correctID), QuickActionShortcuts.correctDefault)
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

    func testCorrectDefaultIsDroppedWhenTheKeyIsAlreadyTaken() {
        let suite = "QuickActionDefaultTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let modes = OutputMode.builtInModes
        var disabled: [String] = []

        // Aufnahme-Hotkey liegt schon auf ⇧⌘K: Standard nicht setzen.
        QuickActionShortcuts.resolveCorrectDefault(
            modes: modes, defaults: defaults,
            lookup: { $0 == .toggleRecording ? QuickActionShortcuts.correctDefault : nil },
            disable: { disabled.append("quickAction.correct") }
        )
        XCTAssertEqual(disabled, ["quickAction.correct"])

        // Frei: nichts tun, der Standard greift.
        disabled.removeAll()
        QuickActionShortcuts.resolveCorrectDefault(modes: modes, defaults: defaults, lookup: { _ in nil }, disable: { disabled.append("quickAction.correct") })
        XCTAssertTrue(disabled.isEmpty)

        // Schon etwas gespeichert: die Wahl des Nutzers bleibt, auch bei Konflikt.
        defaults.set("x", forKey: "KeyboardShortcuts_quickAction.correct")
        QuickActionShortcuts.resolveCorrectDefault(
            modes: modes, defaults: defaults,
            lookup: { $0 == .toggleRecording ? QuickActionShortcuts.correctDefault : nil },
            disable: { disabled.append("quickAction.correct") }
        )
        XCTAssertTrue(disabled.isEmpty)
    }
}
