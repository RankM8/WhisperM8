import Foundation
import XCTest
@testable import WhisperM8

/// Belegung der drei Ebenen (Runde 4, Controller-Insel), Zeile für Zeile der
/// bestätigten Tabelle, dazu die Zusammenhänge, in denen L1/R1/L2 heute etwas
/// anderes tun.
final class ControllerBindingResolverLayerTests: XCTestCase {
    private func action(_ gesture: ControllerGesture, _ context: ControllerContext) -> ControllerAction? {
        ControllerBindingResolver.action(for: gesture, in: context)
    }

    private func chat(
        _ status: ControllerChatState.Status, profile: ControllerChatState.Profile = .claude,
        _ configure: (inout ControllerChatState) -> Void = { _ in }
    ) -> ControllerContext {
        var state = ControllerChatState(status: status, profile: profile)
        configure(&state)
        return .chat(state)
    }

    // MARK: - Tippen

    func testTapsKeepTheirOldMeaning() {
        for context in [chat(.idle), chat(.working) { $0.gridActive = true }, chat(.ended)] {
            XCTAssertEqual(action(.tap(.l1), context), .adjacentChat(step: -1))
            XCTAssertEqual(action(.tap(.r1), context), .adjacentChat(step: 1))
            XCTAssertEqual(action(.tap(.l2), context), .lastChat)
        }
        // Druck allein zeigt keinen Halte-Ring: Die Insel kommt nach 0,3 s.
        for key in [ControllerButton.l1, .r1, .l2] {
            XCTAssertNil(action(.holdPending(key, duration: 0.3), chat(.idle)), "\(key)")
        }
    }

    // MARK: - L1 Schreiben

    func testWritingLayerInClaudeAndCodex() {
        for profile in [ControllerChatState.Profile.claude, .codex] {
            for status in [ControllerChatState.Status.idle, .working, .unknown] {
                let context = chat(status, profile: profile)
                XCTAssertEqual(action(.layerBegan(.writing), context), .islandShow(.writing))
                XCTAssertEqual(action(.inLayer(.writing, .press(.square)), context), .chatKey(.deleteToLineStart))
                XCTAssertEqual(action(.inLayer(.writing, .holdRepeat(.square)), context), .chatKey(.deleteToLineStart),
                               "gehalten Zeile für Zeile")
                XCTAssertEqual(action(.inLayer(.writing, .press(.triangle)), context), .chatKey(.newline))
                // Runde 5: Kreuz fügt ein, Kreis schickt genau ein Escape.
                XCTAssertEqual(action(.inLayer(.writing, .press(.cross)), context), .pasteNewest)
                XCTAssertEqual(action(.inLayer(.writing, .press(.circle)), context), .chatKey(.escape))
                XCTAssertEqual(action(.inLayer(.writing, .press(.r2)), context), .dictationToggle)
                XCTAssertEqual(action(.layerEnded(.writing), context), .islandClose)
            }
        }
    }

    func testWritingLayerRefusesShellQuestionAndEndedChat() {
        let shell = chat(.idle, profile: .shell)
        XCTAssertEqual(action(.inLayer(.writing, .press(.square)), shell), .rejected)
        XCTAssertEqual(action(.inLayer(.writing, .press(.triangle)), shell), .rejected)
        XCTAssertNil(action(.inLayer(.writing, .holdRepeat(.square)), shell), "nicht bei jeder Wiederholung vibrieren")
        XCTAssertEqual(action(.layerBegan(.writing), shell), .islandShow(.writing), "die Insel sagt, warum")

        let question = chat(.awaitingInput) { $0.secondsSinceAwaitingBegan = 5 }
        XCTAssertEqual(action(.inLayer(.writing, .press(.square)), question), .rejected)
        XCTAssertEqual(action(.inLayer(.writing, .press(.triangle)), question), .rejected)

        let ended = chat(.ended)
        XCTAssertNil(action(.inLayer(.writing, .press(.square)), ended))
        XCTAssertNil(action(.inLayer(.writing, .press(.triangle)), ended))
    }

    func testWritingSlotsFollowTheSameRules() {
        let claude = ControllerWritingSlots(state: ControllerChatState(status: .idle, profile: .claude))
        XCTAssertTrue(claude.canDeleteLine)
        XCTAssertTrue(claude.canInsertNewline)
        XCTAssertNil(claude.note)
        XCTAssertEqual(ControllerWritingSlots(state: ControllerChatState(status: .idle, profile: .shell)).note, .shell)
        XCTAssertEqual(ControllerWritingSlots(state: ControllerChatState(status: .awaitingInput, profile: .codex)).note,
                       .question)
        let ended = ControllerWritingSlots(state: ControllerChatState(status: .ended, profile: .claude))
        XCTAssertFalse(ended.canDeleteLine)
        XCTAssertNil(ended.note)
        XCTAssertFalse(ControllerWritingSlots(state: nil).canInsertNewline)
    }

    // MARK: - R1 Schnellbefehle

    func testQuickDrawDiamond() {
        let context = chat(.idle)
        XCTAssertEqual(action(.layerBegan(.quickDraw), context), .islandShow(.quickDraw))
        XCTAssertEqual(action(.inLayer(.quickDraw, .press(.cross)), context), .quickDraw(.continueWork))
        XCTAssertEqual(action(.inLayer(.quickDraw, .press(.triangle)), context), .quickDraw(.cycleMode))
        XCTAssertEqual(action(.inLayer(.quickDraw, .press(.square)), context), .quickDraw(.commands))
        XCTAssertEqual(action(.inLayer(.quickDraw, .press(.circle)), context), .quickDraw(.switchAccount))
        XCTAssertEqual(action(.inLayer(.quickDraw, .press(.r2)), context), .dictationToggle)
        XCTAssertNil(action(.inLayer(.quickDraw, .move(.down, source: .leftStick, isRepeat: false)), context))
        XCTAssertEqual(action(.layerEnded(.quickDraw), context), .islandClose)
        // Raute in der Lage der Tasten.
        XCTAssertEqual(ControllerQuickDrawSlots.items, [.cycleMode, .commands, .switchAccount, .continueWork])
        for item in ControllerQuickDrawSlots.items {
            XCTAssertEqual(ControllerQuickDrawSlots.button(for: item).flatMap(ControllerQuickDrawSlots.item(for:)), item)
        }
    }

    /// Dieselben Schutzregeln wie das Menü: Bei offener Rückfrage ist alles
    /// aus, was in den Chat schreibt; Konto wechseln geht weiter.
    func testQuickDrawSlotsUseMenuRules() {
        let session = UUID()
        var chatInfo = ControllerChatActionInfo(title: "A")
        chatInfo.accounts = [
            ControllerAccountChoice(kind: .claude, name: "main", label: "main", isCurrent: true, isLoggedIn: true),
            ControllerAccountChoice(kind: .claude, name: "work", label: "work", isCurrent: false, isLoggedIn: true),
        ]
        var setup = ControllerMenuSetup(
            acceptsInput: true, profile: .claude, sessionID: session, target: .chat(session), chat: chatInfo)
        XCTAssertEqual(ControllerQuickDrawSlots(setup: setup).enabled,
                       [.continueWork, .cycleMode, .commands, .switchAccount])
        setup.dialogOpen = true
        let question = ControllerQuickDrawSlots(setup: setup)
        XCTAssertEqual(question.enabled, [.switchAccount])
        XCTAssertTrue(question.dialogOpen)
        setup.dialogOpen = false
        setup.acceptsInput = false
        XCTAssertEqual(ControllerQuickDrawSlots(setup: setup).enabled, [.switchAccount], "Shell oder gestoppt")
    }

    // MARK: - L2 Wohin

    func testWhereToLayer() {
        for context in [chat(.idle), chat(.awaitingInput) { $0.gridActive = true }, chat(.ended)] {
            XCTAssertEqual(action(.layerBegan(.whereTo), context), .islandShow(.whereTo))
            XCTAssertEqual(action(.inLayer(.whereTo, .move(.up, source: .leftStick, isRepeat: false)), context),
                           .islandMove(step: -1))
            XCTAssertEqual(action(.inLayer(.whereTo, .move(.down, source: .dpad, isRepeat: true)), context),
                           .islandMove(step: 1), "Wiederholung beim Halten")
            XCTAssertEqual(action(.inLayer(.whereTo, .move(.left, source: .dpad, isRepeat: false)), context),
                           .islandTab(step: -1))
            XCTAssertEqual(action(.inLayer(.whereTo, .move(.right, source: .leftStick, isRepeat: false)), context),
                           .islandTab(step: 1))
            XCTAssertNil(action(.inLayer(.whereTo, .move(.right, source: .leftStick, isRepeat: true)), context))
            XCTAssertEqual(action(.inLayer(.whereTo, .press(.cross)), context), .islandCommit)
            XCTAssertEqual(action(.inLayer(.whereTo, .press(.circle)), context), .islandCancel)
            XCTAssertEqual(action(.inLayer(.whereTo, .press(.triangle)), context), .islandNextWaiting)
            XCTAssertEqual(action(.inLayer(.whereTo, .press(.r2)), context), .islandCommitAndDictate)
            XCTAssertEqual(action(.inLayer(.whereTo, .press(.touchpad)), context), .clipboardToggle,
                           "L2 + Touchpad: Verlauf (Touchpad als Maus)")
            XCTAssertEqual(action(.inLayer(.whereTo, .press(.square)), context), .islandReopenClosed, "Runde 5")
            XCTAssertNil(action(.inLayer(.whereTo, .press(.l1)), context), "kein Pause-Akkord unter L2")
            XCTAssertEqual(action(.layerEnded(.whereTo), context), .islandRelease)
            XCTAssertEqual(action(.layerCancelled(.whereTo), context), .islandClose)
        }
    }

    // MARK: - Andere Zusammenhänge

    /// Ebenen gibt es nur im Chat. Liste, Verlauf, Dialog, Menü und Aufnahme
    /// behalten ihre Belegung; die Tasten in einer Ebene wirken dort wie ohne.
    func testLayersOnlyInChat() {
        XCTAssertNil(action(.layerBegan(.writing), .list))
        XCTAssertEqual(action(.inLayer(.writing, .press(.cross)), .list), .listActivate)
        XCTAssertEqual(action(.tap(.l1), .list), .listFilter(step: -1))

        let clipboard = ControllerContext.clipboardPanel(ControllerClipboardState())
        XCTAssertNil(action(.layerBegan(.quickDraw), clipboard))
        XCTAssertEqual(action(.tap(.r1), clipboard), .clipboard(.filterDictations))
        XCTAssertEqual(action(.inLayer(.writing, .press(.cross)), clipboard), .clipboard(.paste))

        XCTAssertEqual(action(.tap(.l1), .modal), .bridgeKey(.backTab), "Brücke: Shift+Tab")
        XCTAssertEqual(action(.tap(.r1), .otherWindow), .bridgeKey(.tab))
        XCTAssertEqual(action(.inLayer(.writing, .press(.cross)), .modal), .bridgeKey(.returnKey))

        XCTAssertEqual(action(.inLayer(.quickDraw, .press(.cross)), .menu(dialogOpen: false)), .menuActivate,
                       "„›“ hat das Menü geöffnet: R1 darf noch gehalten sein")
        XCTAssertEqual(action(.layerEnded(.quickDraw), .menu(dialogOpen: false)), .islandClose)

        let recording = ControllerContext.recording(phase: .recording, targetIsChat: true)
        XCTAssertNil(action(.layerBegan(.writing), recording))
        XCTAssertEqual(action(.inLayer(.writing, .press(.r2)), recording), .dictationToggle)
        XCTAssertNil(action(.tap(.l1), recording))
        XCTAssertEqual(action(.layerEnded(.whereTo), recording), .islandRelease, "eine offene Insel schließt immer")
    }

    /// Pause-Akkord: Das Ende der Ebene schließt nur die Insel.
    func testChordEndsTheLayerWithoutAction() {
        XCTAssertEqual(action(.layerCancelled(.writing), chat(.idle)), .islandClose)
        XCTAssertEqual(action(.chordCompleted, chat(.idle)), .pauseToggle)
    }
}
