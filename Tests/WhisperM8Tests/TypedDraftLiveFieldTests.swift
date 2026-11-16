import XCTest
@testable import WhisperM8

/// WM8-123, Punkt 1: Ein getippter, nicht abgeschickter Entwurf geht nicht mit
/// einer Meldung hinaus, auch wenn der Chat von selbst einen Turn begonnen hat
/// (der die Tasten-Schätzung für Getipptes löscht) und das Terminal
/// hochgescrollt ist. Die Sendeprüfung liest das Feld dafür vom lebendigen
/// Bildschirm. Gelockert wird nichts: Ein leeres Feld gibt weiter nur frei,
/// wenn die Ansicht unten steht.
@MainActor
final class TypedDraftLiveFieldTests: XCTestCase {
    private var f: QueueFlowFixture!
    private var controller: AgentTerminalController { f.controller }

    private let rule = String(repeating: "─", count: 80)
    private let (dim, reset, save, restore) = ("\u{1b}[2m", "\u{1b}[0m", "\u{1b}[s", "\u{1b}[u")

    override func setUpWithError() throws {
        f = try QueueFlowFixture()
    }

    override func tearDown() {
        f?.tearDown()
    }

    /// Feld mit Text, Cursor dahinter, darunter `below`.
    private func field(_ text: String, below: [String] = []) -> String {
        "\(rule)\r\n❯ \(text)\(save)\r\n\(rule)" + below.map { "\r\n" + $0 }.joined() + restore
    }

    // MARK: Getippter Entwurf sperrt, auch hochgescrollt

    func testTypedDraftHoldsTheQueueAfterAnOwnTurnEvenScrolledUp() {
        // Die Schätzung kennt nach dem eigenen Turn keinen Entwurf mehr.
        f.draw(bottom: field("das ist erst ein halber Sa"))
        f.ownTurn()
        XCTAssertFalse(controller.composerDraft.mayHaveUnsentInput)
        XCTAssertEqual(f.queueDecision(), .draftPending, "unten: der Bildschirm sieht den Text")

        f.scrollUp()
        XCTAssertTrue(controller.isScrolledBack)
        XCTAssertNil(controller.controllerScreenSnapshot(), "der Controller-Leser bleibt hochgescrollt blind")
        let reading = controller.composerFieldForSendCheck()
        XCTAssertFalse(reading.atBottom)
        XCTAssertEqual(reading.field?.hasText, true, "vom lebendigen Bildschirm gelesen")
        XCTAssertEqual(f.queueDecision(), .draftPending)

        // Gegenprobe: mit der alten Lesart (hochgescrollt nichts) ginge sie raus.
        XCTAssertEqual(AgentPromptQueueDelivery.gateDecision(
            draft: controller.composerDraft, reading: .unreadable, profile: .claudeCodeChat,
            runtime: .idle, lifecycle: f.coordinator.lifecycleState(for: f.sessionID), inputPending: false), .deliver)
    }

    /// `chats send` liest dasselbe Feld: Sichtbarer Text sperrt auch hochgescrollt.
    func testSendSeesTheTypedDraftScrolledUp() {
        f.draw(bottom: field("noch nicht fertig"))
        f.scrollUp()
        let reading = controller.composerFieldForSendCheck()
        XCTAssertTrue(PromptSubmitCheck.visibleDraft(field: reading.field, profile: .claudeCodeChat,
                                                     clearsBeforeSubmit: false))
    }

    /// Enter in einer Vervollständigung (@-Datei, Slash-Menü) schickt nichts ab.
    /// Die Schätzung hält es für Absenden; der Text steht aber noch da und sperrt.
    func testEnterThatOnlyPicksACompletionDoesNotRelease() {
        for (text, list) in [
            ("schau dir @Sources/Ma", ["  Sources/Main.swift", "  Sources/Model.swift"]),
            ("/cle", ["  /clear              Clear conversation history", "  /cost                Show cost"]),
        ] {
            f.draw(bottom: field(text, below: list), spare: 2 + list.count)
            f.ownTurn()   // Schätzung leer, wie nach dem Enter
            XCTAssertEqual(f.queueDecision(), .draftPending, text)
            f.scrollUp()
            XCTAssertEqual(f.queueDecision(), .draftPending, "\(text), hochgescrollt")
            f.scrollToBottom()
        }
    }

    // MARK: Was Claude selbst zeichnet, sperrt nicht (Jarvis' Wunsch 1)

    /// Nach einem Turn: grauer Vorschlag im leeren Feld, Hinweiszeilen
    /// darunter, vorgemerkte Nachricht darüber. Nichts davon ist Text des Users.
    func testClaudesOwnDrawingIsNotADraft() {
        let queued = "\(dim)  ⎿ Queued: Weiter mit WM8-12\(reset)"
        let suggestion = "\(rule)\r\n\(dim)❯ \(reset)\(save)\(dim)Variante A für WM8-71, bau weiter\(reset)\r\n\(rule)"
            + "\r\n\(dim)  ? for shortcuts\(reset)\r\n\(dim)  · 1 shell\(reset)\(restore)"
        f.draw(bottom: queued + "\r\n" + suggestion, spare: 5)
        f.ownTurn()
        let atBottom = controller.composerFieldForSendCheck()
        XCTAssertNotNil(atBottom.field, "das Feld wird erkannt")
        XCTAssertEqual(atBottom.field?.hasText, false)
        XCTAssertEqual(f.queueDecision(), .deliver)
        f.scrollUp()
        XCTAssertEqual(controller.composerFieldForSendCheck().field?.hasText, false)
        XCTAssertEqual(f.queueDecision(), .deliver, "hochgescrollt ebenso: keine Sperre durch Claudes Zeichnung")
    }

    /// „[Pasted text #1 +40 lines]“ im Feld ist eingefügter, nicht
    /// abgeschickter Text des Users: Er sperrt (wie seit WM8-64).
    func testPastedTextPlaceholderInTheFieldIsADraft() {
        f.draw(bottom: field("[Pasted text #1 +40 lines]"))
        f.scrollUp()
        XCTAssertEqual(f.queueDecision(), .draftPending)
    }

    // MARK: Kein Feld erkennbar: nie frei, wenn die Schätzung etwas sieht (Jarvis' Wunsch 2)

    func testNoRecognizableFieldFallsBackToTheEstimate() {
        // Dialog unten statt des Felds.
        let dialog = "\(rule)\r\n Do you want to proceed?\r\n ❯ 1. Yes\r\n   2. No\r\n\(rule)"
        f.draw(bottom: dialog, spare: 4)
        controller.noteComposerTextInserted()
        XCTAssertNil(controller.composerFieldForSendCheck().field)
        XCTAssertEqual(f.queueDecision(), .draftPending)
        f.scrollUp()
        XCTAssertNil(controller.composerFieldForSendCheck().field)
        XCTAssertEqual(f.queueDecision(), .draftPending)

        // Vollbild (zweiter Puffer) ohne Feld.
        f.scrollToBottom()
        controller.terminal.feed(text: "\u{1b}[?1049h\u{1b}[HAgents\r\n  Explore\r\n  Plan")
        XCTAssertNil(controller.composerFieldForSendCheck().field)
        XCTAssertEqual(f.queueDecision(), .draftPending)
    }

    /// Dieselbe Regel pur, für jede Lesart ohne Feld und beide Arten Entwurf.
    func testUnreadableNeverReleasesAnEstimatedDraft() {
        var typed = TerminalComposerDraftTracker()
        typed.recordTerminalKey(keyCode: 0, modifiers: [], status: .idle, restoresPromptOnInterrupt: true, now: Date())
        var inserted = TerminalComposerDraftTracker()
        inserted.recordTextInserted()
        for draft in [typed, inserted] {
            for reading in [ComposerFieldReading.unreadable, ComposerFieldReading(field: nil, atBottom: true)] {
                XCTAssertEqual(AgentPromptQueueDelivery.gateDecision(
                    draft: draft, reading: reading, profile: .claudeCodeChat,
                    runtime: .idle, lifecycle: .ready, inputPending: false), .draftPending)
            }
            XCTAssertTrue(PromptDeliveryGate.sendBlockedByDraft(
                mayHaveUnsentInput: draft.mayHaveUnsentInput, force: false,
                fieldVisiblyEmpty: PromptSubmitCheck.fieldVisiblyEmpty(
                    field: ComposerFieldReading.unreadable.fieldForRelease, profile: .claudeCodeChat)))
        }
    }

    // MARK: Lockerung unverändert

    /// Hochgescrollt gibt ein sichtbar leeres Feld nichts frei, unten schon.
    func testEmptyFieldReleasesOnlyAtTheBottom() {
        f.draw(bottom: field(""))
        controller.noteComposerTextInserted()
        f.scrollUp()
        let scrolled = controller.composerFieldForSendCheck()
        XCTAssertTrue(PromptSubmitCheck.fieldVisiblyEmpty(field: scrolled.field, profile: .claudeCodeChat),
                      "der Leser sieht das leere Feld")
        XCTAssertNil(scrolled.fieldForRelease)
        XCTAssertEqual(f.queueDecision(), .draftPending)
        f.scrollToBottom()
        XCTAssertEqual(f.queueDecision(), .deliver)
    }

    /// Codex wird nicht abgelesen.
    func testCodexIsNotRead() {
        let codex = AgentTerminalController(
            sessionID: UUID(),
            command: AgentLaunchCommand(executablePath: "/bin/sh", arguments: ["-c", "sleep 30"],
                                        workingDirectory: NSTemporaryDirectory(), keyboardProfile: .codexChat),
            onLaunched: {}, onTerminated: { _ in })
        codex.start()
        defer { codex.terminate() }
        XCTAssertEqual(codex.composerFieldForSendCheck(), .unreadable)
    }

    // MARK: Shell-Modus „!“ (Prüferin, Punkt 1)

    /// Abgelesen an Claude Code 2.1.325 (16.11.2026): Im Shell-Modus steht
    /// statt „❯“ ein rosa „!“ vor dem Text, die Linien sind ebenfalls rosa,
    /// darunter „! for shell mode“. Ohne „!“ als Prompt-Zeichen fand der Leser
    /// kein Feld, und ein halber Befehl ging samt Meldung als Shell-Befehl raus.
    private func shellModeField(_ text: String) -> String {
        let pink = "\u{1b}[38;2;253;93;177m", plain = "\u{1b}[39m"
        return "\(pink)\(rule)\(plain)\r\n\(pink)!\(plain)\u{00A0}\(text)\(save)\r\n\(pink)\(rule)\(plain)"
            + "\r\n  \(pink)! for shell mode\(plain)\(restore)"
    }

    func testShellModeFieldIsReadAndHolds() {
        f.draw(bottom: shellModeField("git sta"), spare: 3)
        f.ownTurn()
        let reading = controller.composerFieldForSendCheck()
        XCTAssertNotNil(reading.field, "Feld im Shell-Modus erkannt")
        XCTAssertEqual(reading.field?.hasText, true)
        XCTAssertEqual(f.queueDecision(), .draftPending)
        f.scrollUp()
        XCTAssertEqual(f.queueDecision(), .draftPending, "hochgescrollt ebenso")
    }

    /// Leeres Feld im Shell-Modus: unten frei, wie jedes leere Feld.
    func testEmptyShellModeFieldDoesNotHold() {
        f.draw(bottom: shellModeField(""), spare: 3)
        XCTAssertEqual(controller.composerFieldForSendCheck().field?.hasText, false)
        XCTAssertEqual(f.queueDecision(), .deliver)
    }

    /// „#“ ist in 2.1.325 kein eigener Modus mehr: „❯ #notiz test“ ist ein
    /// normales Feld mit Text.
    func testHashIsOrdinaryText() {
        f.draw(bottom: field("#notiz test"))
        XCTAssertEqual(controller.composerFieldForSendCheck().field?.hasText, true)
        XCTAssertEqual(f.queueDecision(), .draftPending)
    }

    // MARK: Freigabe hochgescrollt (Prüferin, Punkt 2)

    private var approval: String {
        "\(rule)\r\n Bash command\r\n   rm -rf build\r\n Do you want to proceed?\r\n ❯ 1. Yes\r\n   2. No\r\n"
            + "\(dim) Esc to cancel · Tab to amend\(reset)"
    }

    func testApprovalIsSeenScrolledUp() {
        f.draw(bottom: approval, spare: 7)
        f.scrollUp()
        XCTAssertNil(controller.controllerScreenSnapshot(), "der alte Leser war hier blind")
        let screen = controller.sendCheckScreen().snapshot
        XCTAssertTrue(DelayedEnterGuard.approvalPending(status: .idle, lifecycle: .ready, screen: screen))
        XCTAssertFalse(DelayedEnterGuard.allowsEnter(statusAtPaste: .idle, statusNow: .idle, screen: screen),
                       "verzögertes Enter bleibt zurück")
        // Gegenprobe: ohne Bildschirm sähe nur der Status nichts.
        XCTAssertFalse(DelayedEnterGuard.approvalPending(status: .idle, lifecycle: .ready, screen: nil))
    }

    /// Ein Bildschirm macht die Freigabe-Prüfung nur strenger: Mit sichtbarem
    /// Feld geht das Enter wie ohne Bildschirm.
    func testVisibleFieldDoesNotChangeTheDelayedEnter() {
        f.draw(bottom: field("Weiter mit WM8-12"))
        f.scrollUp()
        let screen = controller.sendCheckScreen().snapshot
        XCTAssertNotNil(screen?.promptField)
        XCTAssertEqual(DelayedEnterGuard.allowsEnter(statusAtPaste: .idle, statusNow: .idle, screen: screen),
                       DelayedEnterGuard.allowsEnter(statusAtPaste: .idle, statusNow: .idle, screen: nil))
    }

    // MARK: Offene Ansicht (Prüferin, Punkt 3)

    func testOpenViewHoldsTheQueue() {
        let views = [
            "\r\n  Background tasks\r\n  ❯ npm test\r\n\(dim)  ↑/↓ to select · Enter to view · x to stop · Esc to close\(reset)",
            "\r\n  Rewind to\r\n  ❯ Weiter mit WM8-12\r\n\(dim)  Enter to continue · Esc to cancel\(reset)",
        ]
        for view in views {
            f.draw(bottom: view, spare: 4)
            f.ownTurn()
            XCTAssertNotNil(controller.composerFieldForSendCheck().openView, view)
            XCTAssertEqual(f.queueDecision(), .viewOpen, view)
            f.scrollUp()
            XCTAssertEqual(f.queueDecision(), .viewOpen, "\(view), hochgescrollt")
            f.scrollToBottom()
        }
        XCTAssertTrue(PromptDeliveryGate.viewOpenMessage.contains("enqueue"))
    }

    // MARK: Zwei Zeilen, Umbruch, Breitenwechsel (Prüferin)

    /// Zeilen und Cursor aus `liveBottomLines` passen zusammen: Feld über zwei
    /// Zeilen (Zeilenumbruch im Entwurf und weicher Umbruch langer Zeilen),
    /// hochgescrollt gelesen, auch nach einer schmaleren Ansicht.
    func testTwoRowFieldScrolledUpAndAfterResize() {
        f.draw(bottom: "\(rule)\r\n❯ erste Zeile\r\n  zweite Zeile\(save)\r\n\(rule)\(restore)", spare: 3)
        f.scrollUp()
        var field = controller.composerFieldForSendCheck().field
        XCTAssertEqual(field?.rows, 2)
        XCTAssertEqual(field?.cursorRow, 1, "Cursor in der zweiten Zeile des Felds")
        XCTAssertEqual(field?.hasText, true)

        // Weicher Umbruch: eine Zeile länger als die Breite.
        let long = String(repeating: "lang ", count: 26)   // 130 Zeichen bei 100 Spalten
        f.draw(bottom: "\(String(repeating: "─", count: 100))\r\n❯ \(long)\(save)\r\n"
               + "\(String(repeating: "─", count: 100))\(restore)", spare: 4)
        f.scrollUp()
        field = controller.composerFieldForSendCheck().field
        XCTAssertEqual(field?.rows, 2)
        XCTAssertEqual(field?.cursorRow, 1)
        XCTAssertEqual(field?.hasText, true)
        XCTAssertEqual(f.queueDecision(), .draftPending)

        // Breitenwechsel, bevor Claude neu zeichnet: Der Umbruch verschiebt
        // Zeilen und Cursor; gelesen wird dann Text ohne Cursor oder kein Feld,
        // nie ein leeres Feld.
        controller.terminal.getTerminal().resize(cols: 60, rows: 30)
        let after = controller.composerFieldForSendCheck()
        XCTAssertNotEqual(after.field?.isEmpty, true, String(describing: after.field))
        XCTAssertFalse(PromptSubmitCheck.fieldVisiblyEmpty(field: after.field, profile: .claudeCodeChat))
        controller.noteComposerTextInserted()
        XCTAssertEqual(f.queueDecision(), .draftPending)

        // Claude zeichnet nach dem Breitenwechsel neu: wieder Text mit Cursor.
        let narrow = String(repeating: "─", count: 60)
        f.draw(bottom: "\(narrow)\r\n❯ \(long)\(save)\r\n\(narrow)\(restore)", spare: 5)
        f.scrollUp()
        field = controller.composerFieldForSendCheck().field
        XCTAssertEqual(field?.rows, 3)
        XCTAssertEqual(field?.cursorRow, 2)
        XCTAssertEqual(field?.hasText, true)
    }

    // MARK: Board-Chat (Triage-Sammelauftrag) liest dasselbe Feld

    func testBoardChatFieldVisibilityUsesTheSameReading() {
        func visibility() -> BoardChatFieldVisibility {
            BoardChatFieldVisibility(reading: controller.composerFieldForSendCheck(), profile: .claudeCodeChat,
                                     clearsBeforeSubmit: false)
        }
        f.draw(bottom: field("Triage: WM8-12 schließen"))
        XCTAssertEqual(visibility(), .hasText)
        f.scrollUp()
        XCTAssertEqual(visibility(), .hasText, "Text zählt auch hochgescrollt")
        f.draw(bottom: field(""))
        XCTAssertEqual(visibility(), .empty)
        f.scrollUp()
        XCTAssertEqual(visibility(), .unknown, "hochgescrollt gilt leer nicht")
        XCTAssertFalse(TriageBatchRules.batchEnded(field: visibility(), hasUnsentInput: true))
    }

    // MARK: Ansichten, die nur die Sendeprüfung kennt (abgelesen an 2.1.325)

    /// Agent-Liste: unten ein eigenes Feld mit Platzhalter, das wie ein leeres
    /// Eingabefeld aussieht. Das Enter einer Zustellung startete dort eine
    /// neue Hintergrund-Sitzung.
    func testAgentListHoldsTheQueue() {
        let bottom = "Your conversation moved to the background — enter opens it · esc returns to it · ctrl+c twice quits"
            + "\r\n\r\nNeeds input\r\n\(rule)\r\n\(dim)❯ \(reset)\(save)\(dim)describe a task for a new session\(reset)"
            + "\r\n\(rule)\r\n\(dim)  ⏵⏵ auto mode · enter to return · space to reply · ctrl+x to remove · ? for shortcuts\(reset)"
            + restore
        f.draw(bottom: bottom, spare: 7)
        let reading = controller.composerFieldForSendCheck()
        XCTAssertNotNil(reading.field, "der Leser hält es für das Eingabefeld")
        XCTAssertFalse(PromptSubmitCheck.visibleDraft(field: reading.field, profile: .claudeCodeChat,
                                                      clearsBeforeSubmit: false),
                       "ohne Erkennung sperrte nichts: kein Text im Feld")
        XCTAssertEqual(reading.openView, "agentList")
        XCTAssertEqual(f.queueDecision(), .viewOpen)
        f.scrollUp()
        XCTAssertEqual(f.queueDecision(), .viewOpen)
    }

    /// `/config`: kein Feld unten, das Enter wählte eine Einstellung.
    func testConfigViewHoldsTheQueue() {
        for hint in ["Type to filter · Enter/↓ to select · ↑ to tabs · Esc to clear",
                     "Enter/Space to change · / to search · Esc to close"] {
            let bottom = "  Settings  Status   Config   Usage   Stats\r\n\r\n  ❯ Auto-compact        true\r\n"
                + "    Show tips           true\r\n\r\n\(dim)  \(hint)\(reset)"
            f.draw(bottom: bottom, spare: 6)
            XCTAssertNil(controller.composerFieldForSendCheck().field)
            XCTAssertEqual(controller.composerFieldForSendCheck().openView, "config", hint)
            XCTAssertEqual(f.queueDecision(), .viewOpen, hint)
        }
    }

    /// Verlaufssuche (Ctrl+R): das Feld zeigt einen Treffer.
    func testHistorySearchHoldsTheQueue() {
        f.draw(bottom: field("Weiter mit WM8-12", below: ["  search prompts:   ⏵⏵ auto mode on (shift+tab to cycle)"]),
               spare: 3)
        XCTAssertEqual(controller.composerFieldForSendCheck().openView, "historySearch")
        XCTAssertEqual(f.queueDecision(), .viewOpen)
    }

    /// Die normale Fußzeile ist keine Ansicht.
    func testOrdinaryFooterIsNoView() {
        XCTAssertNil(ComposerFieldReading.viewWithoutUsableField([
            "  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents", "  ? for shortcuts", "  ! for shell mode",
        ]))
        f.draw(bottom: field("", below: ["  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents"]), spare: 3)
        XCTAssertNil(controller.composerFieldForSendCheck().openView)
        XCTAssertEqual(f.queueDecision(), .deliver)
    }

    /// Zitiert ein Chat die Wortlaute der Ansichten in seiner Ausgabe über dem
    /// Feld (etwa aus einem Commit oder einem Prüfurteil), ist das keine
    /// Ansicht: Die Warteschlange stellt zu (Prüferin zu WM8-123).
    func testQuotedViewWordsAboveTheFieldAreNoView() {
        let quoted = [
            "  Fußzeile der Agent-Liste: „enter to return · space to reply · ctrl+x to remove“",
            "  Verlaufssuche: „search prompts:“, Einstellungen: „Enter/Space to change · Esc to close“",
            "  sowie „Type to filter · Enter/↓ to select · ↑ to tabs · Esc to clear“",
        ].joined(separator: "\r\n")
        f.draw(bottom: quoted + "\r\n" + field("", below: ["  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents"]),
               spare: 6)
        XCTAssertNil(controller.composerFieldForSendCheck().openView)
        XCTAssertEqual(f.queueDecision(), .deliver)
        f.scrollUp()
        XCTAssertNil(controller.composerFieldForSendCheck().openView, "hochgescrollt ebenso")
        XCTAssertEqual(f.queueDecision(), .deliver)
    }

    /// Ohne Feld zählen nur die untersten zwei Zeilen: Wortlaute weiter oben
    /// in der Ausgabe machen keine Ansicht.
    func testWithoutFieldOnlyTheLastTwoLinesCount() {
        XCTAssertNil(ComposerFieldReading.viewWithoutUsableField([
            "  Type to filter · Enter/↓ to select · ↑ to tabs · Esc to clear",
            "  noch eine Zeile Ausgabe",
            "  und die letzte Zeile",
        ]))
        XCTAssertEqual(ComposerFieldReading.viewWithoutUsableField([
            "  ❯ Auto-compact        true",
            "  Enter/Space to change · / to search · Esc to close",
        ]), "config")
    }
}
