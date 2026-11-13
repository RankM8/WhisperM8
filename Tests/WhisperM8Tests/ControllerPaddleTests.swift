import XCTest
@testable import WhisperM8

/// Paddles im Kern (Plan `controller-xbox-paddles.md`, Schritt 3): Bits,
/// Belegung, Erkenner und die Matrix Belegung × Zusammenhang.
final class ControllerPaddleTests: XCTestCase {
    // MARK: - Bits

    func testBitsMapToPositions() {
        XCTAssertEqual(XboxPaddleBits.paddles(in: 0x1), [.upperRight])
        XCTAssertEqual(XboxPaddleBits.paddles(in: 0x2), [.lowerRight])
        XCTAssertEqual(XboxPaddleBits.paddles(in: 0x4), [.upperLeft])
        XCTAssertEqual(XboxPaddleBits.paddles(in: 0x8), [.lowerLeft])
        XCTAssertEqual(XboxPaddleBits.paddles(in: 0x0), [])
        XCTAssertEqual(XboxPaddleBits.paddles(in: 0xF).count, 4)
        // Jede Lage genau einmal in der Tabelle.
        XCTAssertEqual(Set(XboxPaddleBits.table.map(\.paddle)), Set(ControllerPaddle.allCases))
    }

    func testMaskChangesReleaseBeforePress() {
        let changes = XboxPaddleBits.changes(from: 0x4, to: 0x2)
        XCTAssertEqual(changes.map(\.paddle), [.upperLeft, .lowerRight])
        XCTAssertEqual(changes.map(\.pressed), [false, true])
        let both = XboxPaddleBits.changes(from: 0, to: 0x3)
        XCTAssertEqual(Set(both.map(\.paddle)), [.upperRight, .lowerRight])
        XCTAssertTrue(both.allSatisfy(\.pressed))
        XCTAssertTrue(XboxPaddleBits.changes(from: 0x5, to: 0x5).isEmpty)
    }

    func testEliteNumbering() {
        XCTAssertEqual(ControllerPaddle.upperRight.eliteNumber, 1)
        XCTAssertEqual(ControllerPaddle.lowerRight.eliteNumber, 2)
        XCTAssertEqual(ControllerPaddle.upperLeft.eliteNumber, 3)
        XCTAssertEqual(ControllerPaddle.lowerLeft.eliteNumber, 4)
        for paddle in ControllerPaddle.allCases {
            XCTAssertEqual(ControllerPaddle(button: paddle.button), paddle)
        }
        XCTAssertNil(ControllerPaddle(button: .cross))
    }

    // MARK: - Belegung

    func testStandardBindings() {
        let standard = ControllerPaddleBindings.standard
        XCTAssertEqual(standard[.upperLeft], .nextWaiting)
        XCTAssertEqual(standard[.lowerLeft], .answer)
        XCTAssertEqual(standard[.upperRight], .sendNow)
        XCTAssertEqual(standard[.lowerRight], .cycleMode)
    }

    func testUnknownStoredValuesFallBackToTheStandard() {
        let stored: [ControllerPaddle: String] = [.upperLeft: "pause", .lowerLeft: "somethingNew", .upperRight: "none"]
        let bindings = ControllerPaddleBindings(rawValues: { stored[$0] })
        XCTAssertEqual(bindings[.upperLeft], .pause)
        XCTAssertEqual(bindings[.lowerLeft], .answer)
        XCTAssertEqual(bindings[.upperRight], ControllerPaddleBinding.none)
        XCTAssertEqual(bindings[.lowerRight], .cycleMode)
    }

    // MARK: - Erkenner

    func testPaddleIsAnImmediatePressWithoutHold() {
        var recognizer = ControllerGestureRecognizer()
        XCTAssertEqual(recognizer.handle(.button(.paddleUpperLeft, pressed: true), at: 0), [.press(.paddleUpperLeft)])
        XCTAssertNil(recognizer.nextDeadline)
        XCTAssertEqual(recognizer.tick(at: 2), [])
        XCTAssertEqual(recognizer.handle(.button(.paddleUpperLeft, pressed: false), at: 2), [])
        XCTAssertTrue(recognizer.isIdle)
    }

    func testPaddleInALayerUsesTheLayer() {
        var recognizer = ControllerGestureRecognizer()
        _ = recognizer.handle(.button(.l1, pressed: true), at: 0)
        XCTAssertEqual(recognizer.handle(.button(.paddleLowerRight, pressed: true), at: 0.05),
                       [.inLayer(.writing, .press(.paddleLowerRight))])
        _ = recognizer.handle(.button(.paddleLowerRight, pressed: false), at: 0.1)
        // Kein Tippen mehr: Die Ebene gilt als benutzt.
        XCTAssertEqual(recognizer.handle(.button(.l1, pressed: false), at: 0.2), [.layerEnded(.writing)])
    }

    // MARK: - Matrix

    private let idleClaude = ControllerChatState(status: .idle, profile: .claude)

    private func resolve(
        _ binding: ControllerPaddleBinding, in context: ControllerContext, inLayer: Bool = false
    ) -> ControllerAction? {
        var bindings = ControllerPaddleBindings.standard
        bindings[.upperLeft] = binding
        let press = ControllerGesture.press(.paddleUpperLeft)
        return ControllerBindingResolver.action(
            for: inLayer ? .inLayer(.quickDraw, press) : press, in: context, paddles: bindings)
    }

    func testChatGetsEveryBinding() {
        let chat = ControllerContext.chat(idleClaude)
        XCTAssertEqual(resolve(.nextWaiting, in: chat), .nextWaitingChat)
        XCTAssertEqual(resolve(.answer, in: chat), .answerNextWaiting)
        XCTAssertEqual(resolve(.sendNow, in: chat), .sendNowOrContinue)
        XCTAssertEqual(resolve(.cycleMode, in: chat), .cycleMode)
        XCTAssertEqual(resolve(.lastChat, in: chat), .lastChat)
        XCTAssertEqual(resolve(.pasteNewest, in: chat), .pasteNewest)
        XCTAssertEqual(resolve(.undo, in: chat), .chatKey(.undo))
        XCTAssertEqual(resolve(.clipboardHistory, in: chat), .clipboardToggle)
        XCTAssertEqual(resolve(.pause, in: chat), .pauseToggle)
        XCTAssertEqual(resolve(.claudeWorkflows, in: chat), .slashCommand("/workflows"))
        XCTAssertEqual(resolve(.claudeTasks, in: chat), .slashCommand("/tasks"))
        XCTAssertNil(resolve(.none, in: chat))
    }

    func testChatChecksUndoAndPasteRules() {
        let codex = ControllerContext.chat(ControllerChatState(status: .idle, profile: .codex))
        XCTAssertEqual(resolve(.undo, in: codex), .rejected)
        let question = ControllerContext.chat(ControllerChatState(status: .awaitingInput, profile: .claude))
        XCTAssertEqual(resolve(.pasteNewest, in: question), .rejected)
    }

    func testListRejectsChatInput() {
        for binding in [ControllerPaddleBinding.sendNow, .cycleMode, .pasteNewest, .undo, .claudeWorkflows, .claudeTasks] {
            XCTAssertEqual(resolve(binding, in: .list), .rejected, "\(binding)")
        }
        XCTAssertEqual(resolve(.nextWaiting, in: .list), .nextWaitingChat)
        XCTAssertEqual(resolve(.answer, in: .list), .answerNextWaiting)
        XCTAssertEqual(resolve(.lastChat, in: .list), .lastChat)
        XCTAssertEqual(resolve(.clipboardHistory, in: .list), .clipboardToggle)
        XCTAssertEqual(resolve(.pause, in: .list), .pauseToggle)
    }

    func testOtherContexts() {
        let clipboard = ControllerContext.clipboardPanel(ControllerClipboardState())
        XCTAssertEqual(resolve(.clipboardHistory, in: clipboard), .clipboardToggle)
        XCTAssertEqual(resolve(.pause, in: clipboard), .pauseToggle)
        XCTAssertEqual(resolve(.nextWaiting, in: clipboard), .rejected)
        for context in [ControllerContext.menu(dialogOpen: false), .modal, .otherWindow] {
            XCTAssertEqual(resolve(.pause, in: context), .pauseToggle, "\(context)")
            XCTAssertEqual(resolve(.sendNow, in: context), .rejected, "\(context)")
        }
        // Aufnahme und Schnellaktion: nichts, auch keine Vibration.
        for context in [ControllerContext.recording(phase: .recording, targetIsChat: true), .quickAction] {
            XCTAssertNil(resolve(.pause, in: context))
            XCTAssertNil(resolve(.sendNow, in: context))
        }
        // Pause: nur Pause, sonst bliebe man gefangen.
        XCTAssertEqual(resolve(.pause, in: .paused), .pauseToggle)
        XCTAssertNil(resolve(.nextWaiting, in: .paused))
    }

    func testOutsideTheAppOnlyPauseWhereTheChordWorks() {
        let background = ControllerContext.outsideApp(backgroundEnabled: true, wakeOnInput: true)
        XCTAssertEqual(resolve(.pause, in: background), .pauseToggle)
        XCTAssertNil(resolve(.nextWaiting, in: background), "Paddles wecken nicht")
        XCTAssertNil(resolve(.pause, in: .outsideApp(backgroundEnabled: false)))
        XCTAssertEqual(resolve(.pause, in: .noWindow), .pauseToggle)
        XCTAssertNil(resolve(.answer, in: .noWindow))
        XCTAssertFalse(ControllerBindingResolver.wakes(.press(.paddleUpperLeft)))
    }

    func testNothingInALayer() {
        XCTAssertNil(resolve(.sendNow, in: .chat(idleClaude), inLayer: true))
        XCTAssertNil(resolve(.pause, in: .list, inLayer: true))
    }

    func testDebugScriptKnowsPaddles() throws {
        let steps = try ControllerDebugScript.parse("down:paddleUpperLeft,up:paddleUpperLeft")
        XCTAssertEqual(steps.first, .event(.button(.paddleUpperLeft, pressed: true)))
    }
}
