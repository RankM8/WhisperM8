import Foundation
import XCTest
@testable import WhisperM8

/// Einzelne Regeln der Belegung (Plan Abschnitt 2). Die vollständige Tabelle
/// steht in `ControllerBindingMatrixTests`.
final class ControllerBindingResolverTests: XCTestCase {
    private func action(_ gesture: ControllerGesture, _ context: ControllerContext) -> ControllerAction? {
        ControllerBindingResolver.action(for: gesture, in: context)
    }

    private func chat(
        _ status: ControllerChatState.Status,
        profile: ControllerChatState.Profile = .claude,
        configure: (inout ControllerChatState) -> Void = { _ in }
    ) -> ControllerContext {
        var state = ControllerChatState(status: status, profile: profile)
        configure(&state)
        return .chat(state)
    }

    // MARK: - Tabelle „Kreuz, Kreis und Viereck im Chat“

    func testCrossSendsEnterInEveryLiveState() {
        for status in [ControllerChatState.Status.idle, .awaitingInput, .working, .unknown] {
            XCTAssertEqual(action(.press(.cross), chat(status)), .chatKey(.enter), "\(status)")
        }
        XCTAssertEqual(action(.press(.cross), chat(.idle) { $0.recentlySubmitted = true }), .chatKey(.enter))
        XCTAssertNil(action(.press(.cross), chat(.ended)))
    }

    func testCrossIsLockedRightAfterNewQuestion() {
        XCTAssertNil(action(.press(.cross), chat(.awaitingInput) { $0.secondsSinceAwaitingBegan = 0.2 }))
        XCTAssertNil(action(.press(.cross), chat(.awaitingInput) { $0.secondsSinceAwaitingBegan = 0.49 }))
        XCTAssertEqual(action(.press(.cross), chat(.awaitingInput) { $0.secondsSinceAwaitingBegan = 0.5 }),
                       .chatKey(.enter))
        // Die Sperre gilt nur für Rückfragen.
        XCTAssertEqual(action(.press(.cross), chat(.idle) { $0.secondsSinceAwaitingBegan = 0.1 }),
                       .chatKey(.enter))
    }

    func testCircleTapEscapesOnlyWhenIdleOrAsking() {
        XCTAssertEqual(action(.tap(.circle), chat(.idle)), .chatKey(.escape))
        XCTAssertEqual(action(.tap(.circle), chat(.awaitingInput)), .chatKey(.escape))
        XCTAssertNil(action(.tap(.circle), chat(.working)))
        XCTAssertNil(action(.tap(.circle), chat(.unknown)))
        XCTAssertNil(action(.tap(.circle), chat(.idle) { $0.recentlySubmitted = true }))
        XCTAssertNil(action(.tap(.circle), chat(.ended)))
    }

    func testSecondEscapeWithinOneSecondIsSwallowed() {
        XCTAssertNil(action(.tap(.circle), chat(.idle) { $0.escapeSentRecently = true }))
        XCTAssertNil(action(.tap(.circle), chat(.awaitingInput) { $0.escapeSentRecently = true }))
        XCTAssertNil(action(.holdBegan(.circle), chat(.working) { $0.escapeSentRecently = true }))
    }

    func testCircleHoldInterruptsOnlyWorkingUnknownOrJustSent() {
        XCTAssertEqual(action(.holdBegan(.circle), chat(.working)), .chatInterrupt)
        XCTAssertEqual(action(.holdBegan(.circle), chat(.unknown)), .chatInterrupt)
        XCTAssertEqual(action(.holdBegan(.circle), chat(.idle) { $0.recentlySubmitted = true }), .chatInterrupt)
        XCTAssertNil(action(.holdBegan(.circle), chat(.idle)))
        XCTAssertNil(action(.holdBegan(.circle), chat(.awaitingInput)))
        XCTAssertNil(action(.holdBegan(.circle), chat(.ended)))
        XCTAssertNil(action(.holdEnded(.circle), chat(.working)), "Loslassen danach bleibt ohne Wirkung")
    }

    func testCircleHoldProgressOnlyWhereHoldingHasAnEffect() {
        XCTAssertEqual(action(.holdPending(.circle, duration: 0.4), chat(.working)),
                       .holdProgress(.circle, duration: 0.4))
        XCTAssertEqual(action(.holdCancelled(.circle), chat(.working)), .holdProgressCancelled(.circle))
        XCTAssertNil(action(.holdPending(.circle, duration: 0.4), chat(.idle)))
        XCTAssertNil(action(.holdCancelled(.circle), chat(.idle)))
    }

    func testSquareClearsOnlyClaudeIdleDraft() {
        let draft: (inout ControllerChatState) -> Void = { $0.draftSuspected = true }
        XCTAssertEqual(action(.tap(.square), chat(.idle, configure: draft)), .chatClearComposer)
        XCTAssertNil(action(.tap(.square), chat(.idle)), "ohne Entwurf")
        XCTAssertNil(action(.tap(.square), chat(.idle, profile: .codex, configure: draft)))
        XCTAssertNil(action(.tap(.square), chat(.working, configure: draft)))
        XCTAssertNil(action(.tap(.square), chat(.awaitingInput, configure: draft)))
        XCTAssertNil(action(.tap(.square), chat(.idle) { $0.draftSuspected = true; $0.recentlySubmitted = true }))
        XCTAssertNil(action(.tap(.square), chat(.ended, configure: draft)))
        XCTAssertNil(action(.holdBegan(.square), chat(.idle, configure: draft)), "Halten löscht nur im Verlauf")
    }

    // MARK: - Beendeter Chat und reiner Verlauf

    func testEndedChatKeepsNavigationButNoTerminalKeys() {
        for context in [chat(.ended), chat(.idle) { $0.hasTerminal = false }] {
            XCTAssertNil(action(.press(.cross), context))
            XCTAssertNil(action(.tap(.circle), context))
            XCTAssertNil(action(.holdBegan(.circle), context))
            XCTAssertNil(action(.move(.up, source: .dpad, isRepeat: false), context))
            XCTAssertEqual(action(.move(.left, source: .leftStick, isRepeat: false), context), .moveInContent(.left))
            XCTAssertEqual(action(.press(.triangle), context), .nextWaitingChat)
            XCTAssertEqual(action(.press(.r1), context), .tab(step: 1))
            XCTAssertEqual(action(.tap(.l2), context), .lastChat)
            XCTAssertEqual(action(.press(.touchpad), context), .clipboardToggle)
            XCTAssertEqual(action(.press(.options), context), .menuToggle)
            XCTAssertEqual(action(.press(.create), context), .newChat)
            XCTAssertEqual(action(.scroll(lines: 3), context), .scroll(lines: 3))
        }
    }

    // MARK: - Chat-Navigation

    func testChatNavigation() {
        let context = chat(.working)
        XCTAssertEqual(action(.move(.right, source: .leftStick, isRepeat: false), context), .moveInContent(.right))
        XCTAssertNil(action(.move(.right, source: .leftStick, isRepeat: true), context), "ein Druck, ein Schritt")
        XCTAssertEqual(action(.move(.down, source: .dpad, isRepeat: true), context), .chatKey(.down))
        XCTAssertEqual(action(.press(.l1), context), .tab(step: -1))
        XCTAssertEqual(action(.press(.l3), context), .toggleMaximize)
        XCTAssertEqual(action(.press(.l3), chat(.working) { $0.gridActive = true }), .toggleMaximize)
        XCTAssertEqual(action(.holdBegan(.l2), context), .pickerBegin)
        XCTAssertNil(action(.holdEnded(.l2), context))
        XCTAssertEqual(action(.press(.r2), context), .dictationToggle)
        XCTAssertEqual(action(.scroll(lines: -2), context), .scroll(lines: -2))
        XCTAssertNil(action(.press(.r3), context))
    }

    // MARK: - Diktat

    func testNothingElseWorksWhileRecording() {
        let toChat = ControllerContext.recording(phase: .recording, targetIsChat: true)
        let toApp = ControllerContext.recording(phase: .recording, targetIsChat: false)
        XCTAssertEqual(action(.press(.r2), toChat), .dictationToggle)
        XCTAssertEqual(action(.press(.cross), toChat), .dictationStopAndSubmit)
        XCTAssertNil(action(.press(.cross), toApp), "Return geht nie an fremde Programme")
        XCTAssertEqual(action(.tap(.circle), toApp), .dictationCancel)
        XCTAssertEqual(action(.move(.left, source: .dpad, isRepeat: false), toChat), .outputMode(step: -1))
        XCTAssertEqual(action(.move(.right, source: .dpad, isRepeat: false), toChat), .outputMode(step: 1))
        XCTAssertNil(action(.move(.right, source: .dpad, isRepeat: true), toChat))
        XCTAssertNil(action(.move(.up, source: .dpad, isRepeat: false), toChat))
        XCTAssertNil(action(.move(.left, source: .leftStick, isRepeat: false), toChat))
        for gesture in [ControllerGesture.press(.triangle), .press(.l1), .press(.touchpad), .press(.options),
                        .tap(.l2), .holdBegan(.l2), .holdBegan(.circle), .scroll(lines: 1), .chordCompleted] {
            XCTAssertNil(action(gesture, toChat), "\(gesture)")
        }
    }

    func testTranscribingOnlyAllowsCancel() {
        for phase in [ControllerRecordingPhase.transcribing, .postProcessing] {
            let context = ControllerContext.recording(phase: phase, targetIsChat: true)
            XCTAssertEqual(action(.tap(.circle), context), .dictationCancel)
            XCTAssertNil(action(.press(.r2), context))
            XCTAssertNil(action(.press(.cross), context))
            XCTAssertNil(action(.move(.left, source: .dpad, isRepeat: false), context))
        }
    }

    func testQuickAction() {
        XCTAssertEqual(action(.tap(.circle), .quickAction), .dictationCancel)
        XCTAssertEqual(action(.press(.r2), .quickAction), .rejected)
        XCTAssertNil(action(.press(.cross), .quickAction))
    }

    // MARK: - Außerhalb, Fenster, Dialoge

    func testOutsideApp() {
        let on = ControllerContext.outsideApp(backgroundEnabled: true)
        XCTAssertEqual(action(.press(.r2), on), .dictationToggle)
        XCTAssertEqual(action(.press(.touchpad), on), .clipboardToggle)
        XCTAssertEqual(action(.press(.triangle), on), .bringAppToFront)
        XCTAssertEqual(action(.chordCompleted, on), .pauseToggle)
        XCTAssertNil(action(.press(.cross), on))
        XCTAssertNil(action(.move(.up, source: .dpad, isRepeat: false), on))

        let off = ControllerContext.outsideApp(backgroundEnabled: false)
        for gesture in [ControllerGesture.press(.r2), .press(.touchpad), .press(.triangle), .chordCompleted] {
            XCTAssertNil(action(gesture, off), "\(gesture)")
        }
    }

    func testBridgeInModalAndOtherWindow() {
        for context in [ControllerContext.modal, .otherWindow] {
            XCTAssertEqual(action(.move(.up, source: .dpad, isRepeat: false), context), .bridgeKey(.up))
            XCTAssertEqual(action(.move(.left, source: .dpad, isRepeat: true), context), .bridgeKey(.left))
            XCTAssertEqual(action(.press(.cross), context), .bridgeKey(.returnKey))
            XCTAssertEqual(action(.tap(.circle), context), .bridgeKey(.escape))
            XCTAssertEqual(action(.press(.l1), context), .bridgeKey(.backTab))
            XCTAssertEqual(action(.press(.r1), context), .bridgeKey(.tab))
            XCTAssertEqual(action(.press(.r2), context), .dictationToggle)
        }
        XCTAssertEqual(action(.press(.triangle), .otherWindow), .nextWaitingChat)
        XCTAssertNil(action(.press(.triangle), .modal), "unter einem Dialog nicht wegspringen")
    }

    func testNoWindow() {
        XCTAssertEqual(action(.press(.triangle), .noWindow), .bringAppToFront)
        XCTAssertEqual(action(.press(.r2), .noWindow), .dictationToggle)
        XCTAssertNil(action(.press(.cross), .noWindow))
    }

    // MARK: - Liste, Menü, Verlauf, Chat-Auswahl

    func testList() {
        XCTAssertEqual(action(.move(.down, source: .leftStick, isRepeat: true), .list), .listMove(step: 1))
        XCTAssertEqual(action(.move(.up, source: .dpad, isRepeat: false), .list), .listMove(step: -1))
        XCTAssertEqual(action(.move(.right, source: .leftStick, isRepeat: false), .list), .leaveList)
        XCTAssertNil(action(.move(.right, source: .leftStick, isRepeat: true), .list))
        XCTAssertNil(action(.move(.left, source: .leftStick, isRepeat: false), .list))
        XCTAssertEqual(action(.tap(.circle), .list), .leaveList)
        XCTAssertEqual(action(.press(.cross), .list), .listActivate)
        XCTAssertEqual(action(.press(.l1), .list), .listFilter(step: -1))
        XCTAssertEqual(action(.press(.r1), .list), .listFilter(step: 1))
        XCTAssertEqual(action(.press(.create), .list), .newChat)
        XCTAssertEqual(action(.press(.triangle), .list), .nextWaitingChat)
        XCTAssertEqual(action(.press(.r2), .list), .dictationToggle)
        XCTAssertEqual(action(.press(.touchpad), .list), .clipboardToggle)
        XCTAssertEqual(action(.press(.options), .list), .menuToggle)
    }

    func testMenu() {
        let context = ControllerContext.menu(dialogOpen: true)
        XCTAssertEqual(action(.move(.down, source: .dpad, isRepeat: true), context), .menuMove(step: 1))
        XCTAssertEqual(action(.move(.up, source: .leftStick, isRepeat: false), context), .menuMove(step: -1))
        XCTAssertEqual(action(.press(.cross), context), .menuActivate)
        XCTAssertEqual(action(.tap(.circle), context), .menuToggle)
        XCTAssertEqual(action(.press(.options), context), .menuToggle)
        XCTAssertNil(action(.press(.r2), context))
    }

    func testClipboardPanelDeleteNeedsHolding() {
        let context = ControllerContext.clipboardPanel
        XCTAssertEqual(action(.move(.up, source: .leftStick, isRepeat: false), context), .clipboard(.up))
        XCTAssertEqual(action(.move(.down, source: .dpad, isRepeat: true), context), .clipboard(.down))
        XCTAssertEqual(action(.press(.cross), context), .clipboard(.paste))
        XCTAssertEqual(action(.tap(.circle), context), .clipboard(.close))
        XCTAssertEqual(action(.press(.triangle), context), .clipboard(.pin))
        XCTAssertEqual(action(.press(.touchpad), context), .clipboardToggle)
        // Viereck: Tippen tut nichts, Halten zeigt den Fortschritt und löscht nach 0,6 s.
        XCTAssertNil(action(.tap(.square), context))
        XCTAssertEqual(action(.holdPending(.square, duration: 0.6), context), .holdProgress(.square, duration: 0.6))
        XCTAssertEqual(action(.holdCancelled(.square), context), .holdProgressCancelled(.square))
        XCTAssertEqual(action(.holdBegan(.square), context), .clipboard(.delete))
        XCTAssertNil(action(.holdEnded(.square), context))
    }

    /// Ende zu Ende: Erkenner und Belegung zusammen im Verlauf.
    func testClipboardDeleteThroughRecognizer() {
        var recognizer = ControllerGestureRecognizer()
        func actions(_ gestures: [ControllerGesture]) -> [ControllerAction] {
            gestures.compactMap { action($0, .clipboardPanel) }
        }
        XCTAssertEqual(actions(recognizer.handle(.button(.square, pressed: true), at: 0)),
                       [.holdProgress(.square, duration: 0.6)])
        XCTAssertEqual(actions(recognizer.handle(.button(.square, pressed: false), at: 0.3)),
                       [.holdProgressCancelled(.square)], "kurz gedrückt löscht nicht")
        _ = recognizer.handle(.button(.square, pressed: true), at: 1)
        XCTAssertEqual(actions(recognizer.tick(at: 1.6)), [.clipboard(.delete)])
        XCTAssertEqual(actions(recognizer.handle(.button(.square, pressed: false), at: 2)), [])
    }

    func testChatPicker() {
        XCTAssertEqual(action(.move(.left, source: .leftStick, isRepeat: false), .chatPicker), .pickerMove(.left))
        XCTAssertEqual(action(.move(.down, source: .dpad, isRepeat: true), .chatPicker), .pickerMove(.down))
        XCTAssertEqual(action(.holdEnded(.l2), .chatPicker), .pickerCommit)
        XCTAssertEqual(action(.tap(.circle), .chatPicker), .pickerCancel)
        XCTAssertEqual(action(.press(.r2), .chatPicker), .pickerCommitAndDictate)
        XCTAssertEqual(action(.holdCancelled(.l2), .chatPicker), .pickerCancel, "Zurücksetzen schließt ohne Wechsel")
        XCTAssertNil(action(.press(.cross), .chatPicker))
        XCTAssertNil(action(.chordCompleted, .chatPicker))
    }

    // MARK: - Pause

    func testPauseChord() {
        XCTAssertEqual(action(.chordCompleted, .paused), .pauseToggle)
        XCTAssertEqual(action(.chordPending(duration: 1), .paused), .holdProgress(.l1, duration: 1))
        XCTAssertEqual(action(.chordCancelled, .paused), .holdProgressCancelled(.l1))
        XCTAssertNil(action(.press(.cross), .paused))
        XCTAssertNil(action(.press(.r2), .paused))
        XCTAssertNil(action(.press(.l1), .paused))

        for context in [chat(.working), .list, .clipboardPanel, .menu(dialogOpen: false), .modal,
                        .otherWindow, .noWindow, .quickAction, .outsideApp(backgroundEnabled: true)] {
            XCTAssertEqual(action(.chordCompleted, context), .pauseToggle, "\(context)")
        }
        XCTAssertNil(action(.chordCompleted, .recording(phase: .recording, targetIsChat: true)))
        XCTAssertNil(action(.chordPending(duration: 1), .recording(phase: .recording, targetIsChat: true)))
        XCTAssertNil(action(.chordCompleted, .chatPicker))
    }
}
