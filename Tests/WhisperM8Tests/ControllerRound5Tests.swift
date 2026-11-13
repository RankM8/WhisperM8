import Foundation
import XCTest
@testable import WhisperM8

/// Runde 5: Ansichten am Bildschirm (R2), L1 mit Wortsprung, Zeilen,
/// Einfügen, Escape und Rückgängig, R1 + L3, „Jetzt senden“ und L2 + Viereck.
final class ControllerRound5BindingTests: XCTestCase {
    private func state(
        _ status: ControllerChatState.Status = .idle, profile: ControllerChatState.Profile = .claude,
        view: ControllerOpenView? = nil, field: ControllerPromptField? = nil
    ) -> ControllerChatState {
        var state = ControllerChatState(status: status, profile: profile)
        state.openView = view
        state.promptField = field
        return state
    }

    private func layer(_ layer: ControllerLayer, _ inner: ControllerGesture, _ state: ControllerChatState) -> ControllerAction? {
        ControllerBindingResolver.action(for: .inLayer(layer, inner), in: .chat(state))
    }

    // MARK: R2

    func testCircleClosesARecognizedViewEvenWhileWorking() {
        var working = state(.working, view: .tasks)
        working.escapeSentRecently = true
        working.recentlySubmitted = true
        XCTAssertEqual(ControllerBindingResolver.action(for: .tap(.circle), in: .chat(working)), .chatKey(.escape))
        XCTAssertNil(ControllerBindingResolver.action(for: .tap(.circle), in: .chat(state(.working))))
        // Codex hat diese Ansichten nicht.
        XCTAssertNil(ControllerBindingResolver.action(
            for: .tap(.circle), in: .chat(state(.working, profile: .codex, view: .tasks))))
    }

    func testLeftArrowFollowsTheVisibleField() {
        let empty = ControllerPromptField(rows: 1, cursorRow: 0, cursorAtStart: true, isEmpty: true)
        let text = ControllerPromptField(rows: 1, cursorRow: 0, cursorAtStart: false, isEmpty: false)
        let left = ControllerGesture.move(.left, source: .dpad, isRepeat: false)
        var guessed = state(field: empty)
        guessed.fieldMayHaveText = true
        XCTAssertEqual(ControllerBindingResolver.action(for: left, in: .chat(guessed)), .rejected, "sichtbar leer sperrt")
        XCTAssertEqual(ControllerBindingResolver.action(for: left, in: .chat(state(field: text))), .chatKey(.left))
        XCTAssertEqual(ControllerBindingResolver.action(for: left, in: .chat(state(view: .transcript))), .chatKey(.left))
        XCTAssertEqual(ControllerBindingResolver.action(for: left, in: .chat(state())), .rejected, "nicht ablesbar, Tracker leer")
    }

    // MARK: L1

    func testWritingLayerWordAndLineMoves() {
        let multi = ControllerPromptField(rows: 3, cursorRow: 1, cursorAtStart: false, isEmpty: false)
        let top = ControllerPromptField(rows: 3, cursorRow: 0, cursorAtStart: false, isEmpty: false)
        let single = ControllerPromptField(rows: 1, cursorRow: 0, cursorAtStart: false, isEmpty: false)
        func move(_ direction: ControllerDirection, repeat isRepeat: Bool = false) -> ControllerGesture {
            .move(direction, source: .dpad, isRepeat: isRepeat)
        }
        XCTAssertEqual(layer(.writing, move(.left), state(.working)), .chatKey(.wordLeft))
        XCTAssertEqual(layer(.writing, move(.right, repeat: true), state(profile: .codex)), .chatKey(.wordRight))
        XCTAssertEqual(layer(.writing, move(.up), state(field: multi)), .chatKey(.up))
        XCTAssertEqual(layer(.writing, move(.down), state(field: multi)), .chatKey(.down))
        XCTAssertEqual(layer(.writing, move(.up), state(field: top)), .rejected, "erste Zeile: Verlauf")
        XCTAssertEqual(layer(.writing, move(.down), state(field: top)), .chatKey(.down))
        XCTAssertEqual(layer(.writing, move(.up), state(field: single)), .rejected)
        XCTAssertEqual(layer(.writing, move(.up), state()), .rejected, "nicht ablesbar")
        XCTAssertNil(layer(.writing, move(.up, repeat: true), state()), "Wiederholung vibriert nicht")
        XCTAssertEqual(layer(.writing, move(.left), state(profile: .shell)), .rejected)
        XCTAssertEqual(layer(.writing, move(.left), state(.awaitingInput)), .rejected)
    }

    func testWritingLayerPasteEscapeAndUndo() {
        XCTAssertEqual(layer(.writing, .press(.cross), state(.working)), .pasteNewest)
        XCTAssertEqual(layer(.writing, .press(.cross), state(.awaitingInput)), .rejected)
        var recentEscape = state(.working)
        recentEscape.escapeSentRecently = true
        XCTAssertEqual(layer(.writing, .press(.circle), recentEscape), .chatKey(.escape), "genau ein Escape, ohne Sperre")
        XCTAssertEqual(layer(.writing, .press(.circle), state(profile: .shell)), .rejected)
        XCTAssertEqual(layer(.writing, .press(.l3), state(.working)), .chatKey(.undo))
        XCTAssertEqual(layer(.writing, .press(.l3), state(profile: .codex)), .rejected, "Codex hat kein Undo")
        XCTAssertEqual(layer(.writing, .press(.l3), state(.awaitingInput)), .rejected)
    }

    // MARK: R1, L2

    func testQuickDrawL3TogglesTranscriptOnlyInClaude() {
        XCTAssertEqual(layer(.quickDraw, .press(.l3), state(.working)), .chatKey(.toggleTranscript))
        XCTAssertEqual(layer(.quickDraw, .press(.l3), state(profile: .codex)), .rejected)
    }

    func testWhereToSquareReopens() {
        XCTAssertEqual(layer(.whereTo, .press(.square), state()), .islandReopenClosed)
    }

    // MARK: R1 + Kreuz

    func testCrossActionTable() {
        func cross(_ profile: ControllerChatState.Profile = .claude, busy: Bool = false, dialog: Bool = false,
                   view: Bool = false, text: Bool = false, queued: Int = 0) -> ControllerQuickDrawCross? {
            ControllerQuickDrawSlots.crossAction(
                profile: profile, busy: busy, dialogOpen: dialog, viewOpen: view, fieldHasText: text, queuedOwnPrompts: queued)
        }
        // Claude
        XCTAssertEqual(cross(busy: true, text: true), .sendNow)
        XCTAssertEqual(cross(busy: true, queued: 1), .sendNow)
        XCTAssertEqual(cross(text: true), .send)
        XCTAssertEqual(cross(), .continueWork)
        XCTAssertNil(cross(busy: true), "leer und nichts wartet: geht nicht")
        XCTAssertNil(cross(busy: true, dialog: true, text: true), "nie in einer Rückfrage")
        XCTAssertNil(cross(view: true, text: true), "nie bei offener Ansicht")
        // Codex
        XCTAssertNil(cross(.codex, busy: true, text: true), "Codex meldet nie „wartet“: Enter könnte freigeben")
        XCTAssertEqual(cross(.codex, text: true), .send)
        XCTAssertEqual(cross(.codex), .continueWork)
        XCTAssertNil(cross(.codex, busy: true))
        // Shell: wie bisher
        XCTAssertEqual(cross(.shell, busy: true, text: true), .continueWork)
    }

    func testRecalledPromptIsNotSentAgain() {
        XCTAssertNil(ControllerQuickDrawSlots.crossAction(
            profile: .claude, busy: false, dialogOpen: false, viewOpen: false,
            fieldHasText: true, queuedOwnPrompts: 0, onlyRecalledPrompt: true))
        XCTAssertNil(ControllerQuickDrawSlots.crossAction(
            profile: .claude, busy: true, dialogOpen: false, viewOpen: false,
            fieldHasText: true, queuedOwnPrompts: 1, onlyRecalledPrompt: true))
        XCTAssertNil(ControllerQuickDrawSlots.crossAction(
            profile: .codex, busy: false, dialogOpen: false, viewOpen: false,
            fieldHasText: true, queuedOwnPrompts: 0, onlyRecalledPrompt: true), "Codex: mit ↑ zurückgeholt")
        // Sichtbar leer: der Rückleger-Verdacht ist veraltet, „Weiter“ geht.
        XCTAssertEqual(ControllerQuickDrawSlots.crossAction(
            profile: .claude, busy: false, dialogOpen: false, viewOpen: false,
            fieldHasText: false, queuedOwnPrompts: 0, onlyRecalledPrompt: true), .continueWork)
    }

    func testSecondEscapeInAViewWaitsBriefly() {
        var view = state(.working, view: .tasks)
        view.escapeSentJustNow = true
        XCTAssertNil(ControllerBindingResolver.action(for: .tap(.circle), in: .chat(view)))
        view.escapeSentJustNow = false
        view.escapeSentRecently = true
        XCTAssertEqual(ControllerBindingResolver.action(for: .tap(.circle), in: .chat(view)), .chatKey(.escape))
    }

    func testPasteInShellOnlyAtThePrompt() {
        XCTAssertEqual(layer(.writing, .press(.cross), state(profile: .shell)), .rejected, "nano, vim …")
        var prompt = state(profile: .shell)
        prompt.shellAtPrompt = true
        XCTAssertEqual(layer(.writing, .press(.cross), prompt), .pasteNewest)
    }

    func testQuickDrawSlotsShowCrossTitleAndState() {
        var setup = ControllerMenuSetup()
        setup.acceptsInput = true
        setup.profile = .claude
        setup.chatBusy = true
        setup.quickCross = nil
        let blocked = ControllerQuickDrawSlots(setup: setup)
        XCTAssertFalse(blocked.enabled.contains(.continueWork))
        XCTAssertEqual(blocked.note, .busy)
        setup.quickCross = .sendNow
        let sendNow = ControllerQuickDrawSlots(setup: setup)
        XCTAssertTrue(sendNow.enabled.contains(.continueWork))
        XCTAssertEqual(sendNow.cross, .sendNow)
        XCTAssertNil(sendNow.note)
        setup.chatBusy = false
        setup.quickCross = .send
        XCTAssertTrue(ControllerQuickDrawSlots(setup: setup).enabled.contains(.continueWork))
    }

    func testFieldHasTextIgnoresOpenViews() {
        XCTAssertFalse(ControllerScreenReading.fieldHasText(screen: ControllerScreenSnapshot(openView: .tasks), tracker: false))
        XCTAssertTrue(ControllerScreenReading.fieldHasText(screen: nil, tracker: true))
    }

    // MARK: Insel L1

    func testWritingSlots() {
        let clip = ControllerClipPreview(id: "1", kind: .image, preview: "", imageWidth: 10, imageHeight: 5)
        let claude = ControllerWritingSlots(state: state(.working), clip: clip)
        XCTAssertTrue(claude.canMoveWord)
        XCTAssertTrue(claude.canPaste)
        XCTAssertTrue(claude.canUndo)
        XCTAssertEqual(claude.note, .escapeInterrupts)
        let shell = ControllerWritingSlots(state: state(profile: .shell), clip: clip)
        XCTAssertFalse(shell.canPaste, "Bild nicht in der Shell")
        XCTAssertEqual(shell.note, .shell)
        let codex = ControllerWritingSlots(state: state(profile: .codex), clip: nil)
        XCTAssertFalse(codex.canUndo)
        XCTAssertFalse(codex.canPaste)
        XCTAssertNil(ControllerWritingSlots(state: state(.working, view: .tasks), clip: nil).note)
    }

    // MARK: Kreuz bei sichtbarem Eingabefeld (Entscheidung 13.11.2026)

    /// Jedes Feld des Zustands kommt unverändert durch `ControllerContext.chat`
    /// (Weitergabe-Test; neue Felder hier mit einem Nicht-Standardwert ergänzen).
    func testChatStateSurvivesTheContextEnum() {
        var full = ControllerChatState(status: .working, profile: .claude)
        full.draftSuspected = true
        full.fieldMayHaveText = true
        full.recentlySubmitted = true
        full.secondsSinceAwaitingBegan = 1.5
        full.escapeSentRecently = true
        full.escapeSentJustNow = true
        full.recentDraftInput = true
        full.recentArrowNavigation = true
        full.choiceListOpen = true
        full.onlyRecalledPrompt = true
        full.gridActive = true
        full.shellAtPrompt = true
        full.backTarget = ControllerBackTarget(kind: .chat, title: "Chat", id: UUID())
        full.openView = .footerSelection
        full.promptField = ControllerPromptField(rows: 2, cursorRow: 1, cursorAtStart: false, isEmpty: false)
        guard case let .chat(inner) = ControllerContext.chat(full) else { return XCTFail("chat erwartet") }
        XCTAssertEqual(inner, full)
        XCTAssertTrue(inner.onlyRecalledPrompt)
    }

    func testCrossWhileWorkingFollowsTheVisiblePromptField() {
        let empty = ControllerPromptField(rows: 1, cursorRow: 0, cursorAtStart: true, isEmpty: true)
        let text = ControllerPromptField(rows: 1, cursorRow: 0, cursorAtStart: false, isEmpty: false)
        func cross(_ state: ControllerChatState) -> ControllerAction? {
            ControllerBindingResolver.action(for: .press(.cross), in: .chat(state))
        }
        XCTAssertEqual(cross(state(.working, field: empty)), .chatKey(.enter), "leeres Feld: Enter tut dort nichts")
        XCTAssertEqual(cross(state(.working, field: text)), .chatKey(.enter), "Text von Tastatur oder Hotkey-Diktat")
        XCTAssertEqual(cross(state(.unknown, field: text)), .chatKey(.enter))
        XCTAssertEqual(cross(state(.working, view: .footerSelection, field: empty)), .chatKey(.enter), "Subagent in der Fußzeile")
        // Nur ein mit ↑ zurückgeholter Prompt: nicht erneut abschicken —
        // außer in der Fußzeilen-Auswahl, dort öffnet Enter den Agenten.
        var recalled = state(.working, field: text)
        recalled.onlyRecalledPrompt = true
        XCTAssertNil(cross(recalled))
        recalled.openView = .footerSelection
        XCTAssertEqual(cross(recalled), .chatKey(.enter))
        // Nicht ablesbar oder kein Feld (Dialog, Ansicht, hochgescrollt): alte Regel.
        XCTAssertNil(cross(state(.working)))
        XCTAssertNil(cross(state(.working, view: .transcript)))
        var armed = state(.working)
        armed.recentDraftInput = true
        XCTAssertEqual(cross(armed), .chatKey(.enter), "alte Regel gilt weiter")
        // Eine Ansicht, die das Feld ersetzt, schließt die Regel aus — auch
        // wenn ein Feld gemeldet würde.
        XCTAssertNil(cross(state(.working, view: .tasks, field: empty)))
        // Nur Claude: Codex zeigt Freigaben ohne „wartet“, Shells haben kein Feld.
        XCTAssertNil(cross(state(.working, profile: .codex, field: text)))
        XCTAssertNil(cross(state(.working, profile: .shell, field: text)))
        // Rückfragen unverändert: 0,5 s Sperre, auch mit gemeldetem Feld.
        var question = state(.awaitingInput, field: text)
        question.secondsSinceAwaitingBegan = 0.1
        XCTAssertNil(cross(question))
        question.secondsSinceAwaitingBegan = 2
        XCTAssertEqual(cross(question), .chatKey(.enter))
        // Escape bleibt bei „arbeitet“ ohne Ansicht gesperrt.
        XCTAssertNil(ControllerBindingResolver.action(for: .tap(.circle), in: .chat(state(.working, field: text))))
    }
}

/// Warteschlange im Transcript (`queue-operation`, Claude Code 2.1.322).
final class ClaudeQueueScanTests: XCTestCase {
    private func line(_ operation: String, _ content: String? = nil) -> String {
        var object: [String: Any] = ["type": "queue-operation", "operation": operation,
                                     "timestamp": "2026-11-12T10:00:00.000Z", "sessionId": "s"]
        if let content { object["content"] = content }
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    func testOwnPromptWaitsUntilRemoved() {
        let tail = [line("enqueue", "bitte auch die Tests"), "{\"type\":\"assistant\"}"].joined(separator: "\n")
        XCTAssertEqual(ClaudeQueueScan.pendingOwnPrompts(inTail: tail), 1)
        let absorbed = tail + "\n" + line("remove", "bitte auch die Tests")
        XCTAssertEqual(ClaudeQueueScan.pendingOwnPrompts(inTail: absorbed), 0)
    }

    func testNotificationsDoNotCount() {
        let tail = [line("enqueue", "<task-notification><task-id>a</task-id></task-notification>"),
                    line("enqueue")].joined(separator: "\n")
        XCTAssertEqual(ClaudeQueueScan.pendingOwnPrompts(inTail: tail), 0)
    }

    func testDequeueTakesTheFirstAndPopAllClears() {
        let tail = [line("enqueue", "eins"), line("enqueue", "zwei"), line("dequeue")].joined(separator: "\n")
        XCTAssertEqual(ClaudeQueueScan.pendingOwnPrompts(inTail: tail), 1)
        XCTAssertEqual(ClaudeQueueScan.pendingOwnPrompts(inTail: tail + "\n" + line("popAll", "zwei")), 0)
    }

    func testCutFirstLineAndOtherLinesAreIgnored() {
        let tail = "ation\",\"operation\":\"enqueue\",\"content\":\"x\"}\n" + line("enqueue", "drei")
        XCTAssertEqual(ClaudeQueueScan.pendingOwnPrompts(inTail: tail), 1)
        XCTAssertEqual(ClaudeQueueScan.pendingOwnPrompts(inTail: "{\"type\":\"user\"}"), 0)
    }
}

/// Ausführer: Einfügen, Jetzt senden, Wiederöffnen.
@MainActor
final class ControllerRound5DispatcherTests: XCTestCase {
    private var window: ControllerWindowFake!
    private var center: AgentChatsCommandCenter!
    private var terminals: ControllerTerminalSpy!
    private var island: ControllerIslandSpy!
    private var dictation: ControllerDictationSpy!
    private var dispatcher: ControllerActionDispatcher!
    private var haptics: [ControllerHapticPattern] = []
    private var chat = UUID()
    private let now = Date(timeIntervalSince1970: 1_000)

    override func setUp() async throws {
        window = ControllerWindowFake()
        center = AgentChatsCommandCenter(keyWindowID: { [unowned self] in window.id })
        _ = center.register(windowID: window.id, handler: window.handler)
        terminals = ControllerTerminalSpy()
        island = ControllerIslandSpy()
        dictation = ControllerDictationSpy()
        haptics = []
        dispatcher = ControllerActionDispatcher(
            chats: center, terminals: terminals, dictation: dictation,
            environment: ControllerEnvironmentSpy(), ui: ControllerUIModel(), island: island, now: { [now] in now })
        dispatcher.playHaptic = { [unowned self] in haptics.append($0) }
        dispatcher.islandChatRows = { order, current in
            order.map { ControllerIslandChatRow(id: $0, title: "Chat", project: nil, status: .idle, detail: "", isCurrent: $0 == current) }
        }
        chat = UUID()
        window.selected = chat
        window.rows = [AgentChatsListRow(row: .chat(chat))]
        setTerminal(.idle)
    }

    private func setTerminal(_ status: AgentSessionRuntimeStatus?, profile: ControllerChatState.Profile = .claude,
                             draft: Bool = false, draftAt: Date? = nil, queued: Int = 0) {
        var state = ControllerTerminalState(
            isRunning: true, profile: profile, status: status, statusSince: nil,
            draftSuspected: draft, lastEnterAt: nil, lastEscapeAt: nil, lastDraftInputAt: draftAt)
        state.queuedOwnPrompts = queued
        terminals.states[chat] = state
    }

    private func perform(_ action: ControllerAction) {
        dispatcher.perform(action, in: dispatcher.snapshot().chat.map { .chat($0) } ?? .list)
    }

    /// Geste wie der Manager: Zustand beim Druck lesen, auflösen, ausführen.
    private func press(_ gesture: ControllerGesture) {
        let context = ControllerContextResolver.context(for: dispatcher.snapshot())
        if let action = ControllerBindingResolver.action(for: gesture, in: context) {
            dispatcher.perform(action, in: context)
        }
    }

    /// Kreuz bei „arbeitet“ liest den Bildschirm beim Druck, nicht beim Pfeil
    /// davor: Der erste ▼ in die Fußzeile kommt, bevor Claude neu zeichnet.
    func testCrossReadsTheScreenAtPressTime() {
        setTerminal(.working)
        press(.move(.down, source: .dpad, isRepeat: false))
        XCTAssertEqual(terminals.keys, [.down])
        press(.press(.cross))
        XCTAssertEqual(terminals.keys, [.down], "Feld noch nicht ablesbar: alte Regel")

        // Claude hat neu gezeichnet: Feld sichtbar, Agent in der Fußzeile gewählt.
        terminals.states[chat]?.screen = ControllerScreenSnapshot(
            openView: .footerSelection,
            promptField: ControllerPromptField(rows: 1, cursorRow: 0, cursorAtStart: true, isEmpty: true))
        press(.press(.cross))
        XCTAssertEqual(terminals.keys, [.down, .enter])

        // Jetzt ersetzt ein Freigabe-Dialog das Feld, Status noch „arbeitet“.
        terminals.states[chat]?.screen = ControllerScreenSnapshot()
        press(.press(.cross))
        XCTAssertEqual(terminals.keys, [.down, .enter], "ohne sichtbares Feld kein Enter")

        // Feld zeigt nur den mit ↑ zurückgeholten Prompt: nicht erneut abschicken.
        terminals.states[chat]?.screen = ControllerScreenSnapshot(
            promptField: ControllerPromptField(rows: 1, cursorRow: 0, cursorAtStart: false, isEmpty: false))
        terminals.states[chat]?.onlyRecalledPrompt = true
        press(.press(.cross))
        XCTAssertEqual(terminals.keys, [.down, .enter], "zurückgeholter Prompt geht nicht erneut raus")
        terminals.states[chat]?.onlyRecalledPrompt = false
        press(.press(.cross))
        XCTAssertEqual(terminals.keys, [.down, .enter, .enter], "eigener Text im Feld geht raus")
    }

    func testPasteTextGoesInAsBlockWithoutSending() {
        dispatcher.clipboard = ControllerClipboardAccess(
            newest: { ControllerClipPreview(id: "t", kind: .text, preview: "hallo") },
            loadText: { _, completion in completion("hallo welt") })
        perform(.pasteNewest)
        XCTAssertEqual(terminals.texts.map(\.text), ["hallo welt"])
        XCTAssertEqual(terminals.texts.map(\.submit), [false])
    }

    func testPasteImageWritesFirstThenCtrlV() {
        var written = false
        dispatcher.clipboard = ControllerClipboardAccess(
            newest: { ControllerClipPreview(id: "i", kind: .image, preview: "") },
            copyImage: { _, completion in written = true; completion(true) })
        perform(.pasteNewest)
        XCTAssertTrue(written)
        XCTAssertEqual(terminals.keys, [.imagePaste])
    }

    func testPasteImageInShellIsRejected() {
        setTerminal(.idle, profile: .shell)
        dispatcher.clipboard = ControllerClipboardAccess(
            newest: { ControllerClipPreview(id: "i", kind: .image, preview: "") },
            copyImage: { _, completion in completion(true) })
        perform(.pasteNewest)
        XCTAssertTrue(terminals.keys.isEmpty)
        XCTAssertEqual(haptics, [.rejected])
    }

    func testPasteNothingIsRejected() {
        perform(.pasteNewest)
        XCTAssertEqual(haptics, [.rejected])
    }

    func testPasteSkipsWhenTheChatChangedMeanwhile() {
        var pending: (@MainActor (String?) -> Void)?
        dispatcher.clipboard = ControllerClipboardAccess(
            newest: { ControllerClipPreview(id: "t", kind: .text, preview: "x") },
            loadText: { _, completion in pending = completion })
        perform(.pasteNewest)
        window.selected = UUID()
        pending?("x")
        XCTAssertTrue(terminals.texts.isEmpty)
    }

    func testQuickDrawCrossSendsNowWhileWorkingWithQueuedPrompt() {
        setTerminal(.working, queued: 1)
        dispatcher.performQuickDraw(.continueWork)
        XCTAssertEqual(terminals.keys, [.sendNow])
        XCTAssertTrue(terminals.texts.isEmpty, "kein „Weiter“")
    }

    func testQuickDrawCrossWithDraftWhileWorkingSendsNow() {
        setTerminal(.working, draft: true)
        dispatcher.performQuickDraw(.continueWork)
        XCTAssertEqual(terminals.keys, [.sendNow])
    }

    func testQuickDrawCrossWithDraftWhileIdleSendsEnter() {
        setTerminal(.idle, draft: true)
        dispatcher.performQuickDraw(.continueWork)
        XCTAssertEqual(terminals.keys, [.enter])
        XCTAssertTrue(terminals.texts.isEmpty)
    }

    func testQuickDrawCrossInCodexWithText() {
        setTerminal(.working, profile: .codex, draft: true)
        dispatcher.performQuickDraw(.continueWork)
        XCTAssertTrue(terminals.keys.isEmpty, "arbeitet: geht nicht")
        XCTAssertEqual(haptics, [.rejected])
        setTerminal(.idle, profile: .codex, draft: true)
        dispatcher.performQuickDraw(.continueWork)
        XCTAssertEqual(terminals.keys, [.enter])
    }

    func testPasteTextInShellNeedsPromptAndBracketedPaste() {
        dispatcher.clipboard = ControllerClipboardAccess(
            newest: { ControllerClipPreview(id: "t", kind: .text, preview: "ls") },
            loadText: { _, completion in completion("ls -la") })
        var shell = ControllerTerminalState(
            isRunning: true, profile: .shell, status: nil, statusSince: nil, draftSuspected: false,
            lastEnterAt: nil, lastEscapeAt: nil)
        shell.shellAtPrompt = true
        terminals.states[chat] = shell
        perform(.pasteNewest)
        XCTAssertTrue(terminals.texts.isEmpty, "ohne Bracketed Paste nicht")
        shell.bracketedPaste = true
        terminals.states[chat] = shell
        perform(.pasteNewest)
        XCTAssertEqual(terminals.texts.map(\.text), ["ls -la"])
    }

    func testPasteSkipsWhenAQuestionAppearedMeanwhile() {
        var pending: (@MainActor (String?) -> Void)?
        dispatcher.clipboard = ControllerClipboardAccess(
            newest: { ControllerClipPreview(id: "t", kind: .text, preview: "x") },
            loadText: { _, completion in pending = completion })
        perform(.pasteNewest)
        setTerminal(.awaitingInput)
        pending?("x")
        XCTAssertTrue(terminals.texts.isEmpty)
    }

    func testQuickDrawCrossWithEmptyFieldIdleStillContinues() {
        dispatcher.performQuickDraw(.continueWork)
        XCTAssertTrue(terminals.keys.isEmpty)
        XCTAssertEqual(terminals.texts.map(\.submit), [true], "„Weiter“ mit Senden")
    }

    func testQuickDrawCrossWhileWorkingWithoutQueueIsRejected() {
        setTerminal(.working)
        dispatcher.performQuickDraw(.continueWork)
        XCTAssertTrue(terminals.keys.isEmpty)
        XCTAssertEqual(haptics, [.rejected])
    }

    func testReopenClosedChatClosesTheIsland() {
        var reopened = 0
        dispatcher.closedChats = ControllerClosedChatsAccess(nextTitle: { "Alt" }, reopen: { reopened += 1; return true })
        dispatcher.showIsland(.whereTo)
        XCTAssertEqual(dispatcher.islandState?.model.whereTo?.reopenTitle, "Alt")
        perform(.islandReopenClosed)
        XCTAssertEqual(reopened, 1)
        XCTAssertNil(dispatcher.islandState)
    }

    func testReopenWithNothingClosedKeepsTheIsland() {
        dispatcher.showIsland(.whereTo)
        XCTAssertNil(dispatcher.islandState?.model.whereTo?.reopenTitle)
        perform(.islandReopenClosed)
        XCTAssertEqual(haptics, [.rejected])
        XCTAssertNotNil(dispatcher.islandState)
    }

    // MARK: Options-Menü (Punkt 10, R7, Punkt 3)

    func testHeadActionsSendTheirCommand() {
        var info = ControllerChatActionInfo(title: "Chat")
        info.hasProject = true
        info.canRestart = true
        info.hasTab = true
        window.chatInfo = info
        for (item, expected) in [
            (ControllerMenuItem.openProject, AgentChatsCommand.openProjectOfChat(chat)),
            (.revealInFinder, .revealProjectInFinder(chat)),
            (.restart, .restartChat(chat)),
            (.moveToNewWindow, .moveChatToNewWindow(chat)),
        ] {
            perform(.menuToggle)
            dispatcher.ui.menu?.select(item)
            perform(.menuActivate)
            XCTAssertEqual(window.commands.last, expected, "\(item)")
            XCTAssertNil(dispatcher.ui.menu)
        }
    }

    func testRedrawSendsCtrlL() {
        perform(.menuToggle)
        dispatcher.ui.menu?.select(.redraw)
        perform(.menuActivate)
        XCTAssertEqual(terminals.keys, [.redraw])
    }

    func testAddToWorkspaceSubmenu() {
        let target = UUID()
        var info = ControllerChatActionInfo(title: "Chat")
        info.addableWorkspaces = [ControllerWorkspaceChoice(
            id: target, name: "Ops", colorHex: "#fff", chatCount: 0, hasWaitingChat: false, isCurrent: false)]
        window.chatInfo = info
        perform(.menuToggle)
        dispatcher.ui.menu?.select(.addToWorkspace)
        perform(.menuActivate)
        perform(.menuActivate)
        XCTAssertEqual(window.commands.last, .addChatToWorkspace(chat, workspaceID: target))
    }

    func testWorkspaceRenameAndGridCapacity() {
        let workspace = UUID()
        var info = ControllerChatActionInfo(title: "Chat")
        info.shownInWorkspace = ControllerWorkspaceContext(
            id: workspace, name: "Marketing", gridVisible: true, chatIsMember: true, isCurated: true,
            capacities: [
                ControllerCapacityChoice(capacity: 2, label: "1×2", isCurrent: false, needsSelection: true),
                ControllerCapacityChoice(capacity: 4, label: "2×2", isCurrent: true, needsSelection: false),
                ControllerCapacityChoice(capacity: 6, label: "3×2", isCurrent: false, needsSelection: false),
            ])
        window.chatInfo = info
        perform(.menuToggle)
        dispatcher.ui.menu?.select(.renameWorkspace)
        perform(.menuActivate)
        XCTAssertEqual(window.commands.last, .renameWorkspace(workspace))

        // Herausnehmen nennt den Workspace, den das Menü gezeigt hat (Review).
        window.chatInfo?.removableWorkspaceName = "Marketing"
        perform(.menuToggle)
        dispatcher.ui.menu?.select(.removeFromWorkspace)
        perform(.menuActivate)
        XCTAssertEqual(window.commands.last, .removeChatFromWorkspace(chat, workspaceID: workspace))
        XCTAssertNil(dispatcher.ui.menu)

        perform(.menuToggle)
        dispatcher.ui.menu?.select(.gridCapacity)
        perform(.menuActivate)
        // Start auf der aktuellen Stufe: Kreuz dort geht nicht, das Menü bleibt.
        perform(.menuActivate)
        XCTAssertEqual(haptics.last, .rejected)
        XCTAssertNotNil(dispatcher.ui.menu)
        perform(.menuMove(step: 1))
        perform(.menuActivate)
        XCTAssertEqual(window.commands.last, .setWorkspaceCapacity(workspace, capacity: 6))
        XCTAssertNil(dispatcher.ui.menu)
    }

    func testCancelAndUndoAccountSwitch() {
        var info = ControllerChatActionInfo(title: "Chat")
        info.accounts = [ControllerAccountChoice(kind: .claude, name: "main", label: "main", isCurrent: true, isLoggedIn: true)]
        info.pendingAccountSwitchTarget = "work"
        info.canUndoAccountSwitch = true
        window.chatInfo = info
        perform(.menuToggle)
        dispatcher.ui.menu?.select(.switchAccount)
        perform(.menuActivate)
        perform(.menuMove(step: 1))
        perform(.menuActivate)
        XCTAssertEqual(window.commands.last, .cancelAccountSwitch(chat))
        perform(.menuToggle)
        dispatcher.ui.menu?.select(.switchAccount)
        perform(.menuActivate)
        perform(.menuMove(step: 2))
        perform(.menuActivate)
        XCTAssertEqual(window.commands.last, .undoLastAccountSwitch)
    }

    func testAccountsCarryUsageAndMostFree() {
        var info = ControllerChatActionInfo(title: "Chat")
        info.accounts = [
            ControllerAccountChoice(kind: .claude, name: "main", label: "main", isCurrent: true, isLoggedIn: true),
            ControllerAccountChoice(kind: .claude, name: "a", label: "a", isCurrent: false, isLoggedIn: true),
            ControllerAccountChoice(kind: .claude, name: "b", label: "b", isCurrent: false, isLoggedIn: true),
        ]
        window.chatInfo = info
        var refreshes = 0
        dispatcher.refreshAccountLimits = { refreshes += 1 }
        dispatcher.accountLimit = { _, name in
            switch name {
            case "a": return (fiveHour: 70, week: 20)
            case "b": return (fiveHour: 10, week: 30)
            default: return nil
            }
        }
        perform(.menuToggle)
        let accounts = dispatcher.ui.menu?.setup.chat?.accounts ?? []
        XCTAssertEqual(accounts.first { $0.name == "a" }?.fiveHourUsed, 70)
        XCTAssertEqual(accounts.filter(\.isMostFree).map(\.name), ["b"])
        XCTAssertEqual(refreshes, 0, "nicht schon beim Öffnen des Menüs")
        dispatcher.ui.menu?.select(.switchAccount)
        perform(.menuActivate)
        XCTAssertEqual(refreshes, 1, "passiver Abruf erst mit den Konten")
    }

    // MARK: Während des Diktats (Punkt 9)

    func testNavigationDuringDictationKeepsTheBoundTarget() {
        let other = UUID()
        window.rows = [AgentChatsListRow(row: .chat(chat)), AgentChatsListRow(row: .chat(other))]
        terminals.states[other] = terminals.states[chat]
        dispatcher.titleForSession = { [chat] id in id == chat ? "Ziel" : "Anderer" }
        perform(.dictationToggle)
        XCTAssertEqual(dictation.started, [.agentChat(sessionID: chat)])
        let context = ControllerContextResolver.context(for: dispatcher.snapshot())
        XCTAssertEqual(context, .recording(
            phase: .recording, targetIsChat: true, navigation: .init(area: .content, gridActive: false)))
        // R1 getippt wechselt den Chat …
        let next = ControllerBindingResolver.action(for: .tap(.r1), in: context)
        XCTAssertEqual(next, .adjacentChat(step: 1))
        dispatcher.perform(next!, in: context)
        XCTAssertEqual(window.selected, other)
        // … Legende und Insel nennen weiter das Ziel des Diktats.
        _ = dispatcher.snapshot()
        XCTAssertEqual(dispatcher.ui.targetTitle, "Ziel")
        dispatcher.showIsland(.whereTo)
        XCTAssertEqual(dispatcher.islandState?.model.target.title, "→ Ziel")
        // Kreuz beendet und sendet — an das gebundene Ziel (der Spy kennt es).
        let afterSwitch = ControllerContextResolver.context(for: dispatcher.snapshot())
        XCTAssertEqual(ControllerBindingResolver.action(for: .press(.cross), in: afterSwitch), .dictationStopAndSubmit)
        dispatcher.perform(.dictationStopAndSubmit, in: afterSwitch)
        XCTAssertEqual(dictation.stopped, [true])
    }

    func testFrontAppDictationDoesNotNavigate() {
        dictation.start(target: .frontApp, label: nil)
        let context = ControllerContextResolver.context(for: dispatcher.snapshot())
        XCTAssertEqual(context, .recording(phase: .recording, targetIsChat: false))
        XCTAssertNil(ControllerBindingResolver.action(for: .tap(.r1), in: context))
        XCTAssertNil(ControllerBindingResolver.action(for: .move(.up, source: .leftStick, isRepeat: false), in: context))
        XCTAssertNil(ControllerBindingResolver.action(for: .layerBegan(.whereTo), in: context))
    }

    func testQuickDrawDuringDictationIsGreyedOut() {
        perform(.dictationToggle)
        dispatcher.showIsland(.quickDraw)
        guard case let .quickDraw(slots)? = dispatcher.islandState?.model.content else { return XCTFail("R1 erwartet") }
        XCTAssertTrue(slots.enabled.isEmpty)
        XCTAssertEqual(slots.note, .dictating)
    }
}
