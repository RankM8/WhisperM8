import XCTest
@testable import WhisperM8

/// WM8-66: Diktat und Einfügen in Claudes offene Frage (AskUserQuestion) —
/// nur bei doppelter Erkennung (Werkzeug und Bildschirm), nie in eine Freigabe.
/// Die Bildschirmzeilen stammen aus Claude Code 2.1.325 (Wegwerf-Sitzung in
/// tmux, 14.11.2026).
final class ClaudeQuestionTextTests: XCTestCase {
    // MARK: Bildschirm

    private static let singleQuestion = [
        "────────────────────────────────────────",
        " ☐ Farbe",
        "Welche Farbe?",
        "❯ 1. Rot",
        "     Rot",
        "  2. Gruen",
        "     Gruen",
        "  3. Type something.",
        "────────────────────────────────────────",
        "  4. Chat about this",
        "Enter to select · ↑/↓ to navigate · Esc to cancel",
    ]

    private static let multiSelect = [
        "←  ☒ Farbe  ☐ Tiere  ✔ Submit  →",
        "Welche Tiere?",
        "❯ 1. [ ] Hund",
        "  2. [ ] Katze",
        "  4. [✔] Papagei",
        "     Submit",
        "────────────────────────────────────────",
        "  5. Chat about this",
        "Enter to select · Tab/Arrow keys to navigate · ctrl+g to edit in Vim · Esc to cancel",
    ]

    private static let permission = [
        " Bash command",
        " rm freigabe-test.txt",
        " Permission rule Bash(rm:*) requires confirmation for this command.",
        " Do you want to proceed?",
        " ❯ 1. Yes",
        "   2. No",
        " Esc to cancel · Tab to amend",
    ]

    func testQuestionDialogIsRecognizedWithOneOrSeveralQuestions() {
        XCTAssertTrue(ControllerScreenReading.isQuestionDialog(Self.singleQuestion))
        XCTAssertTrue(ControllerScreenReading.isQuestionDialog(Self.multiSelect))
    }

    func testPermissionIsNeverAQuestion() {
        XCTAssertFalse(ControllerScreenReading.isQuestionDialog(Self.permission))
        // Auch wenn darunter zufällig die Hinweiszeile einer Frage stünde.
        XCTAssertFalse(ControllerScreenReading.isQuestionDialog(
            Self.permission + ["Enter to select · ↑/↓ to navigate · Esc to cancel"]))
    }

    /// Freigaben anderer Werkzeuge (Bearbeiten, Abrufen, Plan) — nachgebaut,
    /// nicht gemessen; auch mit einer Hinweiszeile wie bei der Frage gelten sie nie.
    func testOtherApprovalsAreNeverAQuestion() {
        let footer = "Enter to select · ↑/↓ to navigate · Esc to cancel"
        let edit = [
            " Edit file", " Do you want to make this edit to Foo.swift?",
            " ❯ 1. Yes", "   2. Yes, allow all edits during this session (shift+tab)", "   3. No", footer,
        ]
        let fetch = [
            " Fetch", " Do you want to allow Claude to fetch this content?",
            " ❯ 1. Yes", "   2. Yes, and don't ask again for example.com", "   3. No", footer,
        ]
        let plan = [
            " Ready to code?", " Would you like to proceed?",
            " ❯ 1. Yes, and auto-accept edits", "   2. Yes, and manually approve edits", "   3. No, keep planning", footer,
        ]
        for screen in [edit, fetch, plan] {
            XCTAssertFalse(ControllerScreenReading.isQuestionDialog(screen), screen[1])
        }
    }

    /// Ohne festen Anker („Chat about this“ oder Kästchen-Kopf) keine Frage.
    func testWithoutAnchorItIsNoQuestion() {
        let unanchored = Self.singleQuestion.filter { !$0.contains("Chat about this") && !$0.contains("☐") }
        XCTAssertFalse(ControllerScreenReading.isQuestionDialog(unanchored))
    }

    func testWithoutHintLineOrOptionsItIsNoQuestion() {
        XCTAssertFalse(ControllerScreenReading.isQuestionDialog(Array(Self.singleQuestion.dropLast())))
        XCTAssertFalse(ControllerScreenReading.isQuestionDialog([
            "Ich frage mich: Enter to select · ↑/↓ to navigate",
        ]), "Ohne nummerierte Optionen ist es Ausgabe, kein Dialog")
    }

    func testReadSetsQuestionDialogOnlyForClaude() {
        let lines = Self.singleQuestion.map(ControllerScreenLine.plain)
        XCTAssertTrue(ControllerScreenReading.read(lines: lines, cursor: nil, detectViews: true).questionDialog)
        XCTAssertFalse(ControllerScreenReading.read(lines: lines, cursor: nil, detectViews: false).questionDialog)
        let permission = Self.permission.map(ControllerScreenLine.plain)
        XCTAssertFalse(ControllerScreenReading.read(lines: permission, cursor: nil, detectViews: true).questionDialog)
    }

    // MARK: Doppelte Erkennung

    private let questionScreen = ControllerScreenSnapshot(questionDialog: true)

    private func activity(_ kind: AwaitingInputKind?, _ detail: AgentSessionActivity.Detail?) -> AgentSessionActivity {
        AgentSessionActivity(detail: detail, awaitingKind: kind)
    }

    func testGateNeedsStatusKindToolAndScreen() {
        let question = activity(.question, .question("Welche Farbe?"))
        XCTAssertTrue(ClaudeQuestionTextGate.acceptsText(status: .awaitingInput, activity: question, screen: questionScreen))

        XCTAssertFalse(ClaudeQuestionTextGate.acceptsText(status: .working, activity: question, screen: questionScreen))
        XCTAssertFalse(ClaudeQuestionTextGate.acceptsText(status: .awaitingInput, activity: question, screen: nil),
                       "Bildschirm nicht ablesbar (hochgescrollt): Zwischenablage")
        XCTAssertFalse(ClaudeQuestionTextGate.acceptsText(
            status: .awaitingInput, activity: question, screen: ControllerScreenSnapshot()))
    }

    /// Claudes Registry meldet „input needed“ auch, wenn ein MCP-Werkzeug
    /// wartet — dann ist die Warte-Art `.question`, das Werkzeug aber keins mit
    /// Textfeld.
    func testQuestionKindWithAnotherToolIsNotEnough() {
        let mcpWaiting = activity(.question, .tool(name: "switch_browser", argument: nil))
        XCTAssertFalse(ClaudeQuestionTextGate.acceptsText(status: .awaitingInput, activity: mcpWaiting, screen: questionScreen))
    }

    func testPermissionAndPlanAreNeverAccepted() {
        for kind in [AwaitingInputKind.permission, .planApproval] {
            let waiting = activity(kind, .question("alte Frage im Tail"))
            XCTAssertFalse(ClaudeQuestionTextGate.acceptsText(status: .awaitingInput, activity: waiting, screen: questionScreen))
        }
        XCTAssertFalse(ClaudeQuestionTextGate.acceptsText(status: .awaitingInput, activity: nil, screen: questionScreen))
    }

    // MARK: Diktat

    func testRouterWritesIntoTheQuestionWithoutEnterEvenIfSubmitWasAsked() {
        let sessionID = UUID()
        for submit in [false, true] {
            let decision = DictationDeliveryRouter.decide(
                delivery: DictationDelivery(target: .agentChat(sessionID: sessionID), submit: submit),
                text: "Lila bitte", chatState: { _ in .questionAcceptsText })
            XCTAssertEqual(decision, .writeToQuestion(sessionID: sessionID))
        }
    }

    func testRouterKeepsEveryOtherOpenQuestionOnTheClipboard() {
        let decision = DictationDeliveryRouter.decide(
            delivery: DictationDelivery(target: .agentChat(sessionID: UUID()), submit: true),
            text: "Ja", chatState: { _ in .awaitingInput })
        XCTAssertEqual(decision, .clipboardOnly(.decisionPending))
    }

    func testEmptyTextIntoQuestionDeliversNothing() {
        let decision = DictationDeliveryRouter.decide(
            delivery: DictationDelivery(target: .agentChat(sessionID: UUID())),
            text: "  \n", chatState: { _ in .questionAcceptsText })
        XCTAssertEqual(decision, .nothing)
    }

    // MARK: Controller (L1 + Kreuz)

    private func chatState(_ status: ControllerChatState.Status, profile: ControllerChatState.Profile = .claude,
                           question: Bool) -> ControllerChatState {
        var state = ControllerChatState(status: status, profile: profile)
        state.questionAcceptsText = question
        return state
    }

    func testPasteIsAllowedInARecognizedQuestionOnly() {
        XCTAssertTrue(ControllerBindingResolver.pasteAllowed(chatState(.awaitingInput, question: true)))
        XCTAssertFalse(ControllerBindingResolver.pasteAllowed(chatState(.awaitingInput, question: false)))
        XCTAssertFalse(ControllerBindingResolver.pasteAllowed(chatState(.awaitingInput, profile: .codex, question: true)))
        XCTAssertFalse(ControllerBindingResolver.pasteAllowed(chatState(.awaitingInput, profile: .shell, question: true)))
        XCTAssertTrue(ControllerBindingResolver.pasteAllowed(chatState(.idle, question: false)), "Bisherige Regel bleibt")
    }

    func testLayerCrossPastesInRecognizedQuestion() {
        let action = ControllerBindingResolver.action(
            for: .inLayer(.writing, .press(.cross)), in: .chat(chatState(.awaitingInput, question: true)))
        XCTAssertEqual(action, .pasteNewest)
        let blocked = ControllerBindingResolver.action(
            for: .inLayer(.writing, .press(.cross)), in: .chat(chatState(.awaitingInput, question: false)))
        XCTAssertNotEqual(blocked, .pasteNewest)
    }
}
