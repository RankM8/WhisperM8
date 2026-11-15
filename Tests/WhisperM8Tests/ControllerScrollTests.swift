import Foundation
import XCTest
@testable import WhisperM8

/// WM8-116: schnelleres Scrollen beim Halten, bildschirmweise blättern mit
/// R1 + rechtem Stick, Kreis springt im hochgescrollten Chat ans Ende.
final class ControllerScrollRecognizerTests: XCTestCase {
    private var recognizer = ControllerGestureRecognizer()

    override func setUp() {
        super.setUp()
        recognizer = ControllerGestureRecognizer()
    }

    private func right(_ y: Float, at time: TimeInterval) -> [ControllerGesture] {
        recognizer.handle(.stick(.right, x: 0, y: y), at: time)
    }

    private func down(_ button: ControllerButton, at time: TimeInterval) -> [ControllerGesture] {
        recognizer.handle(.button(button, pressed: true), at: time)
    }

    private func up(_ button: ControllerButton, at time: TimeInterval) -> [ControllerGesture] {
        recognizer.handle(.button(button, pressed: false), at: time)
    }

    /// Zeilen und Gesten im Fenster [from, to), so wie die Pumpe tickt: immer
    /// zur nächsten Frist.
    private func run(from: TimeInterval, to: TimeInterval) -> (lines: Int, gestures: Int, pages: [Int]) {
        var lines = 0, gestures = 0, pages: [Int] = []
        var time = from
        var guardCount = 0
        while let deadline = recognizer.nextDeadline, deadline < to - 1e-6, guardCount < 10_000 {
            time = max(time, deadline)
            for gesture in recognizer.tick(at: time) {
                switch gesture {
                case let .scroll(count):
                    lines += count
                    gestures += 1
                case let .inLayer(_, .scrollPage(step)):
                    pages.append(step)
                default:
                    XCTFail("unerwartet: \(gesture)")
                }
            }
            guardCount += 1
        }
        return (lines, gestures, pages)
    }

    // MARK: - Tempo beim Halten

    func testBoostFactorRampsFromHalfASecondToTwoSeconds() {
        let config = ControllerGestureRecognizer.Config()
        XCTAssertEqual(ControllerGestureRecognizer.boostFactor(after: 0, config: config), 1)
        XCTAssertEqual(ControllerGestureRecognizer.boostFactor(after: 0.5, config: config), 1)
        XCTAssertEqual(ControllerGestureRecognizer.boostFactor(after: 1.25, config: config), 5.5, accuracy: 1e-9)
        XCTAssertEqual(ControllerGestureRecognizer.boostFactor(after: 2, config: config), 10, accuracy: 1e-9)
        XCTAssertEqual(ControllerGestureRecognizer.boostFactor(after: 9, config: config), 10)
    }

    /// Die geschlossene Fläche stimmt mit der aufsummierten überein.
    func testBoostIntegralMatchesNumericSum() {
        let config = ControllerGestureRecognizer.Config()
        for end in [0.3, 0.5, 1.0, 1.7, 2.0, 3.5] {
            var numeric = 0.0
            let step = 1e-4
            var t = 0.0
            while t < end - 1e-12 {
                numeric += ControllerGestureRecognizer.boostFactor(after: t + step / 2, config: config) * step
                t += step
            }
            XCTAssertEqual(ControllerGestureRecognizer.boostIntegral(upTo: end, config: config), numeric,
                           accuracy: 1e-3, "bis \(end) s")
        }
    }

    func testHoldingAtTheStopGetsTenTimesFaster() {
        _ = right(-1, at: 0)
        let first = run(from: 0, to: 0.5)
        XCTAssertEqual(first.lines, 15, accuracy: 1, "die ersten 0,5 s wie bisher: 30 Zeilen/s")
        let ramp = run(from: 0.5, to: 2)
        // 1,5 s mit im Mittel 5,5-fachem Tempo: 30 × 5,5 × 1,5 ≈ 248.
        XCTAssertEqual(ramp.lines, 248, accuracy: 3)
        let top = run(from: 2, to: 3)
        XCTAssertEqual(top.lines, 300, accuracy: 3, "nach 2 s rund das Zehnfache")
        XCTAssertGreaterThan(top.lines, 0)
    }

    /// Bündelung: auch bei 300 Zeilen/s höchstens 60 Gesten je Sekunde.
    func testFastScrollingIsBundled() {
        _ = right(-1, at: 0)
        _ = run(from: 0, to: 2)
        let top = run(from: 2, to: 3)
        XCTAssertLessThanOrEqual(top.gestures, 61)
        XCTAssertGreaterThanOrEqual(top.gestures, 55, "weiter flüssig, etwa eine Geste je Bild")
    }

    /// Am Grundtempo (bis 30 Zeilen/s) bleibt jede Zeile eine eigene Geste.
    func testSlowScrollingStaysLineByLine() {
        _ = right(-0.85, at: 0)
        let result = run(from: 0, to: 3)
        XCTAssertEqual(result.lines, result.gestures)
    }

    func testPartialDeflectionNeverSpeedsUp() {
        _ = right(-0.85, at: 0)
        let early = run(from: 0, to: 1)
        _ = run(from: 1, to: 2)
        let late = run(from: 2, to: 3)
        XCTAssertEqual(early.lines, late.lines, accuracy: 1, "wenig Ausschlag scrollt fein wie bisher")
        XCTAssertLessThanOrEqual(late.lines, 30)
    }

    func testReleasingResetsTheBoost() {
        _ = right(-1, at: 0)
        _ = run(from: 0, to: 2.5)
        _ = right(0, at: 2.5)
        XCTAssertTrue(recognizer.isIdle)
        _ = right(-1, at: 2.6)
        XCTAssertEqual(run(from: 2.6, to: 3.1).lines, 15, accuracy: 1, "nach dem Loslassen wieder von vorn")
    }

    func testDirectionChangeResetsTheBoost() {
        _ = right(-1, at: 0)
        _ = run(from: 0, to: 2.5)
        // Umschlagen ohne Halt in der Mitte (ein schneller Daumen).
        _ = right(1, at: 2.5)
        let result = run(from: 2.5, to: 3.0)
        XCTAssertEqual(result.lines, -15, accuracy: 1, "nach oben, wieder mit Grundtempo")
    }

    /// Hysterese: Gibt der Daumen am Anschlag etwas nach (0,8), bleibt das
    /// Tempo; erst unter 0,7 fällt der Anstieg weg.
    func testBoostSurvivesSmallWobbleButNotHalfDeflection() {
        _ = right(-1, at: 0)
        _ = run(from: 0, to: 2.5)
        _ = right(-0.8, at: 2.5)
        let wobble = run(from: 2.5, to: 3.0)
        // Grundtempo bei 0,8 rund 17 Zeilen/s, mal 10: etwa 85 in 0,5 s.
        XCTAssertGreaterThan(wobble.lines, 60, "0,8 hält den Anstieg")
        _ = right(-0.6, at: 3.0)
        let slow = run(from: 3.0, to: 3.5)
        XCTAssertLessThan(slow.lines, 15, "0,6 ist wieder fein")
        // Wieder an den Anschlag: Der Anstieg beginnt von vorn.
        _ = right(-1, at: 3.5)
        XCTAssertEqual(run(from: 3.5, to: 4.0).lines, 15, accuracy: 1)
    }

    // MARK: - Blättern mit R1

    func testR1AndRightStickPagesInsteadOfScrolling() {
        _ = down(.r1, at: 0)
        XCTAssertEqual(right(-1, at: 0.05), [.inLayer(.quickDraw, .scrollPage(step: 1))],
                       "ein Stoß, sofort ein Bildschirm")
        // Bis zur ersten Wiederholung kein Scrollen; die Insel-Schwelle kommt dazwischen.
        XCTAssertEqual(recognizer.tick(at: 0.3), [.layerBegan(.quickDraw)])
        XCTAssertEqual(recognizer.tick(at: 0.55), [.inLayer(.quickDraw, .scrollPage(step: 1))])
        XCTAssertEqual(recognizer.tick(at: 0.85), [.inLayer(.quickDraw, .scrollPage(step: 1))])
        _ = right(0, at: 0.9)
        XCTAssertNil(recognizer.nextDeadline.flatMap { $0 < 10 ? $0 : nil })
        XCTAssertEqual(right(0.9, at: 1.0), [.inLayer(.quickDraw, .scrollPage(step: -1))], "hoch heißt zurück")
        _ = right(0, at: 1.1)
        // Blättern ist eine Kombination: Loslassen von R1 löst nichts aus.
        XCTAssertEqual(up(.r1, at: 1.2), [.layerEnded(.quickDraw)])
        XCTAssertTrue(recognizer.isIdle)
    }

    /// Auch ein schnelles R1 + Stoß (unter 0,3 s) ist kein Tippen mehr.
    func testQuickPageIsNoTap() {
        _ = down(.r1, at: 0)
        _ = right(-1, at: 0.05)
        _ = right(0, at: 0.1)
        XCTAssertEqual(up(.r1, at: 0.15), [.layerEnded(.quickDraw)], "kein Chatwechsel")
    }

    func testReleasingR1StopsPagingUntilTheStickReturns() {
        _ = down(.r1, at: 0)
        _ = right(-1, at: 0.05)
        XCTAssertEqual(up(.r1, at: 0.2), [.layerEnded(.quickDraw)])
        // Der Stick ist noch ausgelenkt: weder Blättern noch Scrollen.
        XCTAssertEqual(right(-1, at: 0.3), [])
        let after = run(from: 0.3, to: 1.5)
        XCTAssertEqual(after.lines, 0)
        XCTAssertEqual(after.pages, [])
        XCTAssertFalse(recognizer.isIdle)
        _ = right(0, at: 1.5)
        XCTAssertTrue(recognizer.isIdle)
        // Danach scrollt er wieder fließend.
        _ = right(-1, at: 1.6)
        XCTAssertEqual(recognizer.tick(at: 1.6), [.scroll(lines: 1)])
    }

    /// Ein Scrollen, das vor R1 begann, läuft weiter, bis der Stick in die
    /// Mitte zurückkehrt; R1 zählt dann nicht als Tippen.
    func testScrollStartedBeforeR1KeepsScrolling() {
        _ = right(-1, at: 0)
        XCTAssertEqual(recognizer.tick(at: 0), [.scroll(lines: 1)])
        _ = down(.r1, at: 0.1)
        XCTAssertEqual(right(-1, at: 0.15), [])
        XCTAssertGreaterThan(run(from: 0.15, to: 0.25).lines, 0)
        _ = right(0, at: 0.25)
        XCTAssertEqual(up(.r1, at: 0.28), [.layerEnded(.quickDraw)])
    }

    /// Unter L1 und L2 scrollt der Stick weiter fließend.
    func testOtherLayersStillScroll() {
        for key in [ControllerButton.l1, .l2] {
            recognizer = ControllerGestureRecognizer()
            _ = down(key, at: 0)
            XCTAssertEqual(right(-1, at: 0.05), [], "\(key)")
            XCTAssertEqual(recognizer.tick(at: 0.05), [.scroll(lines: 1)], "\(key)")
        }
    }

    /// Pause-Akkord (L1 + R1) beendet das Blättern.
    func testPauseChordEndsPaging() {
        _ = down(.r1, at: 0)
        _ = right(-1, at: 0.05)
        _ = down(.l1, at: 0.1)
        let after = run(from: 0.1, to: 0.9)
        XCTAssertEqual(after.pages, [])
    }

    /// Unter der Schwelle (zwischen Totzone und 0,6) blättert nichts, und
    /// erst wieder nach dem Unterschreiten von 0,4 gibt es einen neuen Stoß.
    func testPagingHasThresholdAndHysteresis() {
        _ = down(.r1, at: 0)
        XCTAssertEqual(right(-0.5, at: 0.05), [])
        XCTAssertEqual(right(-0.7, at: 0.1), [.inLayer(.quickDraw, .scrollPage(step: 1))])
        XCTAssertEqual(right(-0.45, at: 0.15), [], "über 0,4 bleibt es derselbe Stoß")
        XCTAssertEqual(right(-0.3, at: 0.2), [])
        XCTAssertEqual(right(-0.7, at: 0.25), [.inLayer(.quickDraw, .scrollPage(step: 1))], "neuer Stoß")
    }

    /// R3, das beim Blättern mitgedrückt wird, verfällt wie beim Scrollen.
    func testR3WhilePagingAfterR1Release() {
        _ = down(.r1, at: 0)
        _ = right(-1, at: 0.05)
        _ = up(.r1, at: 0.1)
        XCTAssertEqual(down(.r3, at: 0.15), [], "Stick noch ausgelenkt: R3 zählt nicht")
    }

    func testPageLinesKeepOverlap() {
        XCTAssertEqual(ControllerScrollPaging.lines(step: 1, rows: 40), 37)
        XCTAssertEqual(ControllerScrollPaging.lines(step: -1, rows: 40), -37)
        XCTAssertEqual(ControllerScrollPaging.lines(step: 1, rows: 3), 1, "flache Kachel: mindestens eine Zeile")
    }
}

/// Belegung und Legende für WM8-116.
final class ControllerScrollBindingTests: XCTestCase {
    private func chat(
        _ status: ControllerChatState.Status, profile: ControllerChatState.Profile = .claude,
        scrolledBack: Bool = true, _ configure: (inout ControllerChatState) -> Void = { _ in }
    ) -> ControllerContext {
        var state = ControllerChatState(status: status, profile: profile)
        state.scrolledBack = scrolledBack
        configure(&state)
        return .chat(state)
    }

    /// In keinem Zustand geht hochgescrollt ein Escape raus, auch nicht dort,
    /// wo es vorher durfte; stattdessen ans Ende.
    func testCircleJumpsToEndInEveryStateWhenScrolledBack() {
        for status in ControllerChatState.Status.allCases {
            for profile in ControllerChatState.Profile.allCases {
                for recent in [false, true] {
                    let context = chat(status, profile: profile) {
                        $0.recentlySubmitted = recent
                        $0.escapeSentRecently = recent
                        $0.choiceListOpen = true
                    }
                    XCTAssertEqual(ControllerBindingResolver.action(for: .tap(.circle), in: context), .scrollToBottom,
                                   "\(status) \(profile) \(recent)")
                }
            }
        }
    }

    /// Am Ende ist Kreis wieder, was er war.
    func testCircleAtTheEndIsEscapeAsBefore() {
        XCTAssertEqual(ControllerBindingResolver.action(for: .tap(.circle), in: chat(.idle, scrolledBack: false)),
                       .chatKey(.escape))
        XCTAssertNil(ControllerBindingResolver.action(for: .tap(.circle), in: chat(.working, scrolledBack: false)))
    }

    /// Kreis halten unterbricht weiter, auch hochgescrollt.
    func testHoldingCircleStillInterrupts() {
        let context = chat(.working)
        XCTAssertEqual(ControllerBindingResolver.action(for: .holdBegan(.circle), in: context), .chatInterrupt)
        XCTAssertEqual(ControllerBindingResolver.action(for: .holdPending(.circle, duration: 0.4), in: context),
                       .holdProgress(.circle, duration: 0.4))
        XCTAssertNil(ControllerBindingResolver.action(for: .holdBegan(.circle), in: chat(.idle)))
    }

    /// L1 + Kreis bleibt „genau ein Escape“, auch hochgescrollt — das ist der
    /// bewusste Weg, wenn man wirklich Escape will.
    func testL1CircleStaysExactlyOneEscape() {
        XCTAssertEqual(ControllerBindingResolver.action(for: .inLayer(.writing, .press(.circle)), in: chat(.working)),
                       .chatKey(.escape))
    }

    func testR1PagesInChatAndDuringDictation() {
        let page = ControllerGesture.inLayer(.quickDraw, .scrollPage(step: 1))
        XCTAssertEqual(ControllerBindingResolver.action(for: page, in: chat(.idle)), .scrollPage(step: 1))
        XCTAssertEqual(ControllerBindingResolver.action(for: page, in: chat(.ended)), .scrollPage(step: 1))
        for phase in ControllerRecordingPhase.allCases {
            XCTAssertEqual(ControllerBindingResolver.action(
                for: page, in: .recording(phase: phase, targetIsChat: true)), .scrollPage(step: 1), "\(phase)")
            XCTAssertEqual(ControllerBindingResolver.action(
                for: page, in: .recording(phase: phase, targetIsChat: true,
                                          navigation: .init(area: .content, gridActive: true))),
                .scrollPage(step: 1), "\(phase) gebunden")
        }
        XCTAssertNil(ControllerBindingResolver.action(for: page, in: .list), "in der Liste nichts")
        XCTAssertNil(ControllerBindingResolver.action(for: page, in: .menu(dialogOpen: false)))
    }

    func testLegendShowsJumpToEndOnCircle() {
        let entries = ControllerLegend.entries(for: chat(.working))
        XCTAssertTrue(entries.contains { $0.label == .jumpToEnd && $0.inputs == [.button(.circle)] })
        XCTAssertFalse(entries.contains { $0.label == .back })
        let atEnd = ControllerLegend.entries(for: chat(.idle, scrolledBack: false))
        XCTAssertFalse(atEnd.contains { $0.label == .jumpToEnd })
        XCTAssertTrue(atEnd.contains { $0.label == .back })
    }

    func testSettingsListNewBindings() {
        let all = ControllerLegend.allBindings().flatMap(\.entries)
        XCTAssertTrue(all.contains { $0.label == .jumpToEnd })
        let page = all.first { $0.label == .pageScroll }
        XCTAssertEqual(page?.inputs, [.button(.r1), .rightStick])
        // Die Kombination steht für das Blättern unter R1.
        XCTAssertTrue(ControllerLegend.probes(for: page!).contains(.inLayer(.quickDraw, .scrollPage(step: 1))))
    }
}

/// Ausführer für WM8-116.
@MainActor
final class ControllerActionDispatcherScrollTests: XCTestCase {
    private var window: ControllerWindowFake!
    private var center: AgentChatsCommandCenter!
    private var terminals: ControllerTerminalSpy!
    private var ui: ControllerUIModel!
    private var island: ControllerIslandSpy!
    private var dispatcher: ControllerActionDispatcher!

    override func setUp() async throws {
        window = ControllerWindowFake()
        let id = window.id
        center = AgentChatsCommandCenter(keyWindowID: { id })
        _ = center.register(windowID: window.id, handler: window.handler)
        terminals = ControllerTerminalSpy()
        ui = ControllerUIModel()
        island = ControllerIslandSpy()
        dispatcher = ControllerActionDispatcher(
            chats: center, terminals: terminals, dictation: ControllerDictationSpy(),
            environment: ControllerEnvironmentSpy(), ui: ui, island: island)
        guard let selected = window.selected else { return }
        terminals.states[selected] = ControllerTerminalState(
            isRunning: true, profile: .claude, status: .working, draftSuspected: false, scrolledBack: true)
    }

    private var context: ControllerContext {
        ControllerContextResolver.context(for: dispatcher.snapshot())
    }

    func testJumpToEndScrollsAndRefreshesTheLegend() {
        guard case let .chat(before) = context else { return XCTFail("chat erwartet") }
        XCTAssertTrue(before.scrolledBack)
        let action = ControllerBindingResolver.action(for: .tap(.circle), in: context)
        XCTAssertEqual(action, .scrollToBottom)
        dispatcher.perform(.scrollToBottom, in: context)
        XCTAssertEqual(terminals.jumpsToBottom, 1)
        XCTAssertEqual(terminals.keys, [], "kein Escape ans Terminal")
        // Die Legende kennt den neuen Stand sofort, nicht erst bei der nächsten Eingabe.
        guard case let .chat(after) = ui.context else { return XCTFail("chat erwartet") }
        XCTAssertFalse(after.scrolledBack)
    }

    func testPagingScrollsAndKeepsTheIslandClosed() {
        dispatcher.perform(.scrollPage(step: 1), in: context)
        XCTAssertEqual(terminals.pages, [1])
        // Die Halte-Schwelle von R1 kommt erst danach: Die Insel bleibt zu.
        dispatcher.perform(.islandShow(.quickDraw), in: context)
        XCTAssertTrue(island.shown.isEmpty)
        // Loslassen von R1 gibt die Ebene wieder frei.
        dispatcher.perform(.islandClose, in: context)
        dispatcher.perform(.islandShow(.quickDraw), in: context)
        XCTAssertEqual(island.shown.count, 1)
    }
}
