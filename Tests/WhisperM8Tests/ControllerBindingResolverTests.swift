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

    /// Review-Befund 3: Bei Ruhe und Rückfrage wie bisher Enter. Arbeitet der
    /// Chat oder ist sein Zustand unklar, nur nach einer frischen Eingabe per
    /// Controller (getippt, gelöscht, diktiert) — sonst bestätigte Kreuz in
    /// der Lücke vor „wartet“ die Vorauswahl eines Freigabe-Dialogs.
    func testCrossSendsEnterOnlyWhenADraftIsPlausible() {
        for status in [ControllerChatState.Status.idle, .awaitingInput] {
            XCTAssertEqual(action(.press(.cross), chat(status)), .chatKey(.enter), "\(status)")
        }
        XCTAssertEqual(action(.press(.cross), chat(.idle) { $0.recentlySubmitted = true }), .chatKey(.enter))
        for status in [ControllerChatState.Status.working, .unknown] {
            XCTAssertNil(action(.press(.cross), chat(status)), "\(status) ohne Eingabe")
            XCTAssertNil(action(.press(.cross), chat(status) { $0.draftSuspected = true }),
                         "\(status): Entwurfs-Verdacht allein reicht nicht")
            XCTAssertEqual(action(.press(.cross), chat(status) { $0.recentDraftInput = true }), .chatKey(.enter),
                           "\(status) nach Eingabe per Controller")
        }
        XCTAssertEqual(action(.press(.cross), chat(.ended)), .chatResume)
    }

    /// Befund 1 nach Runde 3: Wo das Steuerkreuz Pfeile ins Terminal gibt.
    /// Claude: nur in Rückfragen und in einer Liste, die das Menü geöffnet hat
    /// (sonst Navigation — links schickte Claude im leeren Feld in den
    /// Hintergrund). Codex: in jedem lebenden Zustand, weil es nie „wartet“.
    func testDpadArrowsPerProfileAndState() {
        let left = ControllerGesture.move(.left, source: .dpad, isRepeat: false)
        let up = ControllerGesture.move(.up, source: .dpad, isRepeat: false)
        for status in [ControllerChatState.Status.idle, .working, .unknown] {
            XCTAssertEqual(action(left, chat(status)), .moveInContent(.left), "Claude \(status)")
            XCTAssertEqual(action(up, chat(status)), .enterList(step: -1), "Claude \(status)")
            XCTAssertEqual(action(left, chat(status) { $0.choiceListOpen = true }), .chatKey(.left),
                           "Claude \(status), Auswahl offen")
            XCTAssertEqual(action(left, chat(status, profile: .codex)), .chatKey(.left), "Codex \(status)")
            XCTAssertEqual(action(up, chat(status, profile: .codex)), .chatKey(.up), "Codex \(status)")
            XCTAssertEqual(action(left, chat(status, profile: .shell)), .moveInContent(.left), "Shell \(status)")
        }
        XCTAssertEqual(action(left, chat(.awaitingInput)), .chatKey(.left))
        XCTAssertEqual(action(left, chat(.ended, profile: .codex)), .moveInContent(.left), "beendet: Navigation")
        XCTAssertEqual(action(left, chat(.ended) { $0.choiceListOpen = true }), .moveInContent(.left))
    }

    /// Befund 1a: Mit offener Auswahl des Menüs sendet Kreuz Enter auch bei
    /// arbeitendem Chat, und Kreis schließt die Liste auch direkt nach dem
    /// Befehl, der sie geöffnet hat.
    func testChoiceListAllowsConfirmAndEscape() {
        for status in [ControllerChatState.Status.idle, .working, .unknown] {
            XCTAssertEqual(action(.press(.cross), chat(status) { $0.choiceListOpen = true }), .chatKey(.enter),
                           "\(status)")
        }
        XCTAssertNil(action(.tap(.circle), chat(.idle) { $0.recentlySubmitted = true }))
        XCTAssertEqual(action(.tap(.circle), chat(.idle) { $0.recentlySubmitted = true; $0.choiceListOpen = true }),
                       .chatKey(.escape))
        XCTAssertNil(action(.tap(.circle), chat(.working) { $0.choiceListOpen = true }),
                     "arbeitet: Escape bräche ab, dafür gibt es Kreis halten")
        XCTAssertNil(action(.tap(.circle), chat(.idle) { $0.choiceListOpen = true; $0.escapeSentRecently = true }))
    }

    /// Befund 1b: Codex-Freigaben erscheinen bei „arbeitet“. Kreuz bestätigt
    /// erst nach einer Eingabe per Controller (ein Pfeil zählt dazu).
    func testCodexCrossWhileWorkingNeedsControllerInput() {
        XCTAssertNil(action(.press(.cross), chat(.working, profile: .codex)))
        XCTAssertEqual(action(.press(.cross), chat(.working, profile: .codex) { $0.recentDraftInput = true }),
                       .chatKey(.enter))
        XCTAssertEqual(action(.press(.cross), chat(.idle, profile: .codex)), .chatKey(.enter))
    }

    /// Befund 4: Leerzeichen, Wort löschen und Eingabe leeren nur bei Claude
    /// und Codex; die Rücktaste bleibt in Shells, gehalten nur Zeichen.
    func testWritingKeysOnlyInAgentChats() {
        for profile in [ControllerChatState.Profile.claude, .codex] {
            XCTAssertEqual(action(.press(.triangle), chat(.idle, profile: profile)), .chatKey(.space))
            XCTAssertEqual(action(.holdRepeatLong(.square), chat(.idle, profile: profile)), .chatKey(.deleteWord))
            XCTAssertEqual(action(.holdBegan(.r3), chat(.idle, profile: profile)), .chatClearInput)
        }
        for profile in [ControllerChatState.Profile.shell, .other] {
            XCTAssertEqual(action(.press(.triangle), chat(.idle, profile: profile)), .rejected, "\(profile)")
            XCTAssertEqual(action(.holdBegan(.r3), chat(.idle, profile: profile)), .rejected, "\(profile)")
            XCTAssertNil(action(.holdPending(.r3, duration: 0.6), chat(.idle, profile: profile)), "kein Ring")
            XCTAssertEqual(action(.tap(.square), chat(.idle, profile: profile)), .chatKey(.backspace))
            XCTAssertEqual(action(.holdRepeat(.square), chat(.idle, profile: profile)), .chatKey(.backspace))
            XCTAssertEqual(action(.holdRepeatLong(.square), chat(.idle, profile: profile)), .chatKey(.backspace),
                           "\(profile): gehalten weiter Zeichen statt Ctrl+W")
        }
        XCTAssertNil(action(.press(.triangle), chat(.ended, profile: .shell)), "beendet: still")
        XCTAssertNil(action(.holdBegan(.r3), chat(.awaitingInput)), "Rückfrage: still wie bisher")
    }

    /// Runde 2: Kreuz auf einem gestoppten Chat startet ihn wieder.
    func testCrossStartsStoppedChat() {
        XCTAssertEqual(action(.press(.cross), chat(.ended)), .chatResume)
        XCTAssertEqual(action(.press(.cross), chat(.working) { $0.hasTerminal = false }), .chatResume)
        XCTAssertEqual(action(.press(.cross), chat(.ended) { $0.gridActive = true }), .chatResume)
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

    /// Runde 2: Viereck ist die Rücktaste — tippen ein Zeichen, halten
    /// fortlaufend, in jedem lebenden Zustand und bei jedem Profil. Kein
    /// Ctrl+C mehr (das hätte eine laufende Antwort abgebrochen).
    func testSquareIsBackspaceInEveryLiveState() {
        for status in [ControllerChatState.Status.idle, .awaitingInput, .working, .unknown] {
            for profile in [ControllerChatState.Profile.claude, .codex, .shell] {
                let context = chat(status, profile: profile)
                XCTAssertEqual(action(.tap(.square), context), .chatKey(.backspace), "\(status) \(profile)")
                XCTAssertEqual(action(.holdBegan(.square), context), .chatKey(.backspace))
                XCTAssertEqual(action(.holdRepeat(.square), context), .chatKey(.backspace))
            }
        }
        XCTAssertNil(action(.holdPending(.square, duration: 0.6), chat(.idle)), "kein Ring, wie bei einer Taste")
        XCTAssertNil(action(.holdEnded(.square), chat(.idle)))
        XCTAssertNil(action(.tap(.square), chat(.ended)))
        XCTAssertNil(action(.holdRepeat(.square), chat(.idle) { $0.hasTerminal = false }))
    }

    /// Ende zu Ende: Viereck halten löscht erst Zeichen, nach 1 s ganze
    /// Wörter (wie beim iPhone), und hört beim Loslassen auf.
    func testSquareHoldKeepsDeletingThroughRecognizer() {
        var recognizer = ControllerGestureRecognizer()
        let context = chat(.working)
        var chars = 0, words = 0
        func count(_ gestures: [ControllerGesture]) {
            for action in gestures.compactMap({ action($0, context) }) {
                if action == .chatKey(.backspace) { chars += 1 }
                if action == .chatKey(.deleteWord) { words += 1 }
            }
        }
        count(recognizer.handle(.button(.square, pressed: true), at: 0))
        var time = 0.0
        while time < 2.5 {
            time += 0.005
            count(recognizer.tick(at: time))
        }
        // 0,6 s Schwelle (1 Zeichen), 1 s lang alle 60 ms (~17 Zeichen),
        // danach alle 150 ms ein Wort (~6 in 0,9 s).
        XCTAssertGreaterThan(chars, 14)
        XCTAssertLessThan(chars, 20)
        XCTAssertGreaterThan(words, 4)
        XCTAssertLessThan(words, 8)
        count(recognizer.handle(.button(.square, pressed: false), at: 2.5))
        let afterRelease = chars + words
        count(recognizer.tick(at: 3))
        XCTAssertEqual(chars + words, afterRelease, "nach dem Loslassen nichts mehr")
    }

    // MARK: - Steuerkreuz (Review-Befund 1)

    /// Pfeile gehen nur in einer Rückfrage ins Terminal. In jedem anderen
    /// Zustand wirkt das Steuerkreuz wie der linke Stick — auch bei einem
    /// vermuteten Entwurf.
    func testDpadSendsArrowsOnlyWhileAgentAsks() {
        let asking = chat(.awaitingInput) { $0.secondsSinceAwaitingBegan = 3 }
        for direction in ControllerDirection.allCases {
            for isRepeat in [false, true] {
                XCTAssertEqual(action(.move(direction, source: .dpad, isRepeat: isRepeat), asking),
                               .chatKey(ControllerChatKey(direction)))
            }
        }
        let others: [ControllerContext] = [
            chat(.idle), chat(.idle) { $0.draftSuspected = true }, chat(.working), chat(.unknown), chat(.ended),
            chat(.awaitingInput) { $0.hasTerminal = false },
        ]
        for context in others {
            XCTAssertEqual(action(.move(.up, source: .dpad, isRepeat: false), context), .enterList(step: -1), "\(context)")
            XCTAssertEqual(action(.move(.down, source: .dpad, isRepeat: false), context), .enterList(step: 1), "\(context)")
            XCTAssertEqual(action(.move(.left, source: .dpad, isRepeat: false), context), .moveInContent(.left), "\(context)")
            XCTAssertNil(action(.move(.right, source: .dpad, isRepeat: false), context), "\(context)")
            XCTAssertNil(action(.move(.down, source: .dpad, isRepeat: true), context), "\(context)")
        }
        let grid = chat(.working) { $0.gridActive = true }
        XCTAssertEqual(action(.move(.right, source: .dpad, isRepeat: false), grid), .moveInContent(.right))
        XCTAssertEqual(action(.move(.up, source: .dpad, isRepeat: false), grid), .moveInContent(.up))
        // Während der Aufnahme bleibt das Steuerkreuz der Ausgabemodus.
        XCTAssertEqual(action(.move(.up, source: .dpad, isRepeat: false), .recording(phase: .recording, targetIsChat: true)),
                       .outputMode(step: -1))
    }

    /// Absicherung im Terminal-Weg des Controllers.
    func testTerminalGuardForControllerKeys() {
        func allows(_ key: TerminalControlKey, _ status: AgentSessionRuntimeStatus?,
                    _ profile: TerminalKeyboardProfile = .claudeCodeChat, list: Bool = false) -> Bool {
            TerminalControlKey.controllerAllows(key, status: status, profile: profile, choiceListOpen: list)
        }
        for key in [TerminalControlKey.up, .down, .left, .right] {
            XCTAssertTrue(allows(key, .awaitingInput))
            for status in [AgentSessionRuntimeStatus.idle, .working, .stopped, .errored] {
                XCTAssertFalse(allows(key, status), "\(key) \(status)")
                XCTAssertFalse(allows(key, status, .plainShell), "Shell \(key) \(status)")
                // Befund 1 nach Runde 3: offene Auswahl des Menüs, Codex immer.
                XCTAssertTrue(allows(key, status, list: true), "Auswahl offen \(key) \(status)")
                XCTAssertTrue(allows(key, status, .codexChat), "Codex \(key) \(status)")
            }
            XCTAssertFalse(allows(key, nil))
            XCTAssertTrue(allows(key, nil, .codexChat))
        }
        XCTAssertFalse(allows(.backTab, .awaitingInput))
        XCTAssertTrue(allows(.backTab, .idle))
        XCTAssertTrue(allows(.enter, .working))
        XCTAssertTrue(allows(.backspace, nil))
    }

    // MARK: - Beendeter Chat und reiner Verlauf

    func testEndedChatKeepsNavigationButNoTerminalKeys() {
        for context in [chat(.ended), chat(.idle) { $0.hasTerminal = false }] {
            XCTAssertEqual(action(.press(.cross), context), .chatResume)
            XCTAssertNil(action(.tap(.circle), context))
            XCTAssertNil(action(.holdBegan(.circle), context))
            XCTAssertEqual(action(.move(.up, source: .dpad, isRepeat: false), context), .enterList(step: -1),
                           "Steuerkreuz navigiert wie der Stick, keine Pfeile")
            XCTAssertEqual(action(.move(.left, source: .leftStick, isRepeat: false), context), .moveInContent(.left))
            XCTAssertNil(action(.press(.triangle), context), "kein Leerzeichen in einen gestoppten Chat")
            XCTAssertEqual(action(.press(.r1), context), .adjacentChat(step: 1))
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
        XCTAssertNil(action(.move(.right, source: .leftStick, isRepeat: false), context), "rechts: in der Einzelansicht nichts")
        XCTAssertEqual(action(.move(.right, source: .leftStick, isRepeat: false), chat(.working) { $0.gridActive = true }),
                       .moveInContent(.right))
        XCTAssertNil(action(.move(.right, source: .leftStick, isRepeat: true), context), "ein Druck, ein Schritt")
        XCTAssertNil(action(.move(.down, source: .dpad, isRepeat: true), context), "kein Pfeil, keine Wiederholung")
        XCTAssertEqual(action(.press(.l1), context), .adjacentChat(step: -1), "L1/R1 folgen der Liste links")
        XCTAssertEqual(action(.press(.r1), chat(.idle) { $0.gridActive = true }), .adjacentChat(step: 1), "auch im Raster")
        XCTAssertEqual(action(.press(.l3), context), .toggleMaximize)
        XCTAssertEqual(action(.press(.l3), chat(.working) { $0.gridActive = true }), .toggleMaximize)
        XCTAssertEqual(action(.holdBegan(.l2), context), .pickerBegin)
        XCTAssertNil(action(.holdEnded(.l2), context))
        XCTAssertEqual(action(.press(.r2), context), .dictationToggle)
        XCTAssertEqual(action(.scroll(lines: -2), context), .scroll(lines: -2))
        XCTAssertNil(action(.tap(.r3), context), "R3 auf einem lebenden Chat: nichts, auch keine Vibration")
    }

    /// Runde 2: R3 (getippt) startet einen gestoppten Chat, in der Liste die
    /// markierte Zeile.
    func testR3StartsStoppedChat() {
        XCTAssertEqual(action(.tap(.r3), chat(.ended)), .chatResume)
        XCTAssertEqual(action(.tap(.r3), chat(.idle) { $0.hasTerminal = false }), .chatResume)
        for status in [ControllerChatState.Status.idle, .working, .awaitingInput, .unknown] {
            XCTAssertNil(action(.tap(.r3), chat(status)), "\(status)")
        }
        XCTAssertEqual(action(.tap(.r3), .list), .listStartRow)
        XCTAssertNil(action(.holdBegan(.r3), .list), "in der Liste leert R3 nichts")
    }

    // MARK: - Schreibtasten (Runde 3)

    /// Dreieck = Leerzeichen in jedem lebenden Chat, auch in Rückfragen (wie
    /// die Rücktaste); gestoppt nichts. Kein Wiederholen beim Halten.
    func testTriangleTypesSpaceInEveryLiveChat() {
        for status in [ControllerChatState.Status.idle, .awaitingInput, .working, .unknown] {
            XCTAssertEqual(action(.press(.triangle), chat(status)), .chatKey(.space), "\(status)")
        }
        XCTAssertNil(action(.press(.triangle), chat(.ended)))
        XCTAssertNil(action(.press(.triangle), chat(.idle) { $0.hasTerminal = false }))
        XCTAssertEqual(action(.press(.triangle), .clipboardPanel(ControllerClipboardState(canCorrect: true))),
                       .clipboard(.correctAndPaste), "im Verlauf unverändert")
    }

    /// Viereck lange gehalten löscht ganze Wörter (Ctrl+W).
    func testSquareLongHoldDeletesWords() {
        for status in [ControllerChatState.Status.idle, .awaitingInput, .working] {
            XCTAssertEqual(action(.holdRepeatLong(.square), chat(status)), .chatKey(.deleteWord), "\(status)")
        }
        XCTAssertNil(action(.holdRepeatLong(.square), chat(.ended)))
        XCTAssertNil(action(.holdRepeatLong(.square), .list))
        XCTAssertNil(action(.holdRepeatLong(.square), .clipboardPanel(ControllerClipboardState())))
    }

    /// R3 halten leert die Eingabe — in lebenden Chats, nicht bei einer
    /// Rückfrage (dort wählt man aus), nicht bei gestopptem Chat.
    func testR3HoldClearsInputOutsideQuestions() {
        for status in [ControllerChatState.Status.idle, .working, .unknown] {
            XCTAssertEqual(action(.holdBegan(.r3), chat(status)), .chatClearInput, "\(status)")
            XCTAssertEqual(action(.holdPending(.r3, duration: 0.6), chat(status)), .holdProgress(.r3, duration: 0.6))
            XCTAssertEqual(action(.holdCancelled(.r3), chat(status)), .holdProgressCancelled(.r3))
        }
        for context in [chat(.awaitingInput), chat(.ended), chat(.idle) { $0.hasTerminal = false }] {
            XCTAssertNil(action(.holdBegan(.r3), context), "\(context)")
            XCTAssertNil(action(.holdPending(.r3, duration: 0.6), context), "kein Ring ohne Wirkung")
        }
        XCTAssertNil(action(.holdBegan(.r3), .recording(phase: .recording, targetIsChat: true)))
    }

    /// Runde 2: Viereck halten in der Liste schließt die Zeile wie ihr „−“/„×“.
    func testSquareHoldInListClosesRow() {
        XCTAssertEqual(action(.holdBegan(.square), .list), .listCloseRow)
        XCTAssertEqual(action(.holdPending(.square, duration: 0.6), .list), .holdProgress(.square, duration: 0.6))
        XCTAssertEqual(action(.holdCancelled(.square), .list), .holdProgressCancelled(.square))
        XCTAssertNil(action(.tap(.square), .list), "tippen: nichts")
        XCTAssertNil(action(.holdRepeat(.square), .list), "kein Wiederholen")
    }

    /// Runde 3: In der Einzelansicht springen hoch/runter mit der Markierung
    /// in die Liste (ein Schritt, kein Chat-Wechsel). Wiederholungen kommen
    /// danach im Zusammenhang `list` an; im Chat selbst bleiben sie ohne
    /// Wirkung. Im Raster bleibt es der Kachel-Fokus.
    func testLeftStickUpDownMarksInListInSingleView() {
        let single = chat(.idle)
        XCTAssertEqual(action(.move(.up, source: .leftStick, isRepeat: false), single), .enterList(step: -1))
        XCTAssertEqual(action(.move(.down, source: .leftStick, isRepeat: false), single), .enterList(step: 1))
        XCTAssertNil(action(.move(.down, source: .leftStick, isRepeat: true), single))
        XCTAssertEqual(action(.move(.down, source: .leftStick, isRepeat: true), .list), .listMove(step: 1))
        XCTAssertEqual(action(.move(.down, source: .leftStick, isRepeat: false), chat(.ended)), .enterList(step: 1))
        XCTAssertEqual(action(.press(.l1), single), .adjacentChat(step: -1), "L1/R1 wechseln weiter direkt")
        XCTAssertEqual(action(.move(.left, source: .leftStick, isRepeat: false), single), .moveInContent(.left))
        XCTAssertNil(action(.move(.left, source: .leftStick, isRepeat: true), single))
        XCTAssertEqual(action(.move(.up, source: .dpad, isRepeat: false), single), .enterList(step: -1),
                       "Steuerkreuz außerhalb einer Rückfrage wie der Stick")

        let grid = chat(.idle) { $0.gridActive = true }
        XCTAssertEqual(action(.move(.up, source: .leftStick, isRepeat: false), grid), .moveInContent(.up))
        XCTAssertNil(action(.move(.down, source: .leftStick, isRepeat: true), grid))
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
        XCTAssertNil(action(.move(.left, source: .leftStick, isRepeat: false), toChat))
        for gesture in [ControllerGesture.press(.triangle), .press(.l1), .press(.touchpad), .press(.options),
                        .tap(.l2), .holdBegan(.l2), .holdBegan(.circle), .tap(.square), .chordCompleted] {
            XCTAssertNil(action(gesture, toChat), "\(gesture)")
        }
    }

    /// Runde 3: Während Aufnahme, Transkription, Nacharbeit und Schnellaktion
    /// tut der linke Stick nichts — keine Liste, keine Kachel, keine
    /// Vibration. Der rechte Stick scrollt weiter.
    func testLeftStickRestsWhileDictationRuns() {
        var contexts: [ControllerContext] = [.quickAction]
        for phase in ControllerRecordingPhase.allCases {
            for targetIsChat in [true, false] {
                contexts.append(.recording(phase: phase, targetIsChat: targetIsChat))
            }
        }
        for context in contexts {
            for direction in ControllerDirection.allCases {
                for isRepeat in [false, true] {
                    XCTAssertNil(action(.move(direction, source: .leftStick, isRepeat: isRepeat), context),
                                 "\(context) \(direction)")
                }
            }
        }
        XCTAssertEqual(action(.scroll(lines: 2), .recording(phase: .transcribing, targetIsChat: true)), .scroll(lines: 2))
    }

    /// Runde 2: Steuerkreuz hoch/runter wechselt den Modus ebenfalls, beim
    /// Halten wiederholt; links/rechts bleibt ein Schritt pro Druck.
    func testDpadUpDownStepsOutputModeWhileRecording() {
        let context = ControllerContext.recording(phase: .recording, targetIsChat: false)
        XCTAssertEqual(action(.move(.up, source: .dpad, isRepeat: false), context), .outputMode(step: -1))
        XCTAssertEqual(action(.move(.down, source: .dpad, isRepeat: false), context), .outputMode(step: 1))
        XCTAssertEqual(action(.move(.down, source: .dpad, isRepeat: true), context), .outputMode(step: 1))
        XCTAssertEqual(action(.move(.up, source: .dpad, isRepeat: true), context), .outputMode(step: -1))
        XCTAssertNil(action(.move(.up, source: .leftStick, isRepeat: false), context))
    }

    /// Runde 2: Der rechte Stick scrollt auch während Aufnahme,
    /// Transkription und Nacharbeit.
    func testScrollWorksInEveryRecordingPhase() {
        for phase in ControllerRecordingPhase.allCases {
            for targetIsChat in [true, false] {
                let context = ControllerContext.recording(phase: phase, targetIsChat: targetIsChat)
                XCTAssertEqual(action(.scroll(lines: -2), context), .scroll(lines: -2), "\(phase)")
            }
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
        XCTAssertEqual(action(.press(.triangle), .otherWindow), .bringAppToFront)
        XCTAssertNil(action(.press(.triangle), .modal), "unter einem Dialog nicht wegspringen")
        // Runde 2: Im Dialog (Projekt-Auswahl) bewegt auch der linke Stick
        // hoch/runter, mit Wiederholung; in anderen Fenstern nicht.
        XCTAssertEqual(action(.move(.up, source: .leftStick, isRepeat: false), .modal), .bridgeKey(.up))
        XCTAssertEqual(action(.move(.down, source: .leftStick, isRepeat: true), .modal), .bridgeKey(.down))
        XCTAssertNil(action(.move(.left, source: .leftStick, isRepeat: false), .modal))
        XCTAssertNil(action(.move(.up, source: .leftStick, isRepeat: false), .otherWindow))
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
        XCTAssertNil(action(.press(.triangle), .list), "Runde 3: kein Sprung zum wartenden Chat mehr")
        XCTAssertEqual(action(.press(.r2), .list), .dictationToggle)
        XCTAssertEqual(action(.press(.touchpad), .list), .clipboardToggle)
        XCTAssertEqual(action(.press(.options), .list), .menuToggle)
    }

    func testMenu() {
        let context = ControllerContext.menu(dialogOpen: true)
        XCTAssertEqual(action(.move(.down, source: .dpad, isRepeat: true), context), .menuMove(step: 1))
        XCTAssertEqual(action(.move(.up, source: .leftStick, isRepeat: false), context), .menuMove(step: -1))
        XCTAssertEqual(action(.press(.cross), context), .menuActivate)
        XCTAssertEqual(action(.tap(.circle), context), .menuBack, "Runde 2: Kreis geht eine Ebene zurück")
        XCTAssertEqual(action(.press(.options), context), .menuToggle)
        XCTAssertNil(action(.press(.r2), context))
    }

    func testClipboardPanelDeleteNeedsHolding() {
        let context = ControllerContext.clipboardPanel(ControllerClipboardState())
        XCTAssertEqual(action(.move(.up, source: .leftStick, isRepeat: false), context), .clipboard(.up))
        XCTAssertEqual(action(.move(.down, source: .dpad, isRepeat: true), context), .clipboard(.down))
        XCTAssertEqual(action(.press(.cross), context), .clipboard(.paste))
        XCTAssertEqual(action(.tap(.circle), context), .clipboard(.close))
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
            gestures.compactMap { action($0, .clipboardPanel(ControllerClipboardState())) }
        }
        XCTAssertEqual(actions(recognizer.handle(.button(.square, pressed: true), at: 0)),
                       [.holdProgress(.square, duration: 0.6)])
        XCTAssertEqual(actions(recognizer.handle(.button(.square, pressed: false), at: 0.3)),
                       [.holdProgressCancelled(.square)], "kurz gedrückt löscht nicht")
        _ = recognizer.handle(.button(.square, pressed: true), at: 1)
        XCTAssertEqual(actions(recognizer.tick(at: 1.6)), [.clipboard(.delete)])
        XCTAssertEqual(actions(recognizer.handle(.button(.square, pressed: false), at: 2)), [])
    }

    /// Runde 2: Verlauf vollständig per Controller.
    func testClipboardPanelFullControl() {
        var state = ControllerClipboardState()
        func act(_ gesture: ControllerGesture) -> ControllerAction? { action(gesture, .clipboardPanel(state)) }
        XCTAssertEqual(act(.press(.triangle)), .rejected, "Korrigieren nicht verfügbar")
        XCTAssertEqual(act(.press(.l3)), .rejected, "kein Bild")
        XCTAssertEqual(act(.press(.l1)), .clipboard(.filterAll))
        XCTAssertEqual(act(.press(.r1)), .clipboard(.filterDictations))
        XCTAssertEqual(act(.press(.options)), .clipboard(.menuToggle))
        XCTAssertEqual(act(.press(.r2)), .rejected, "kein Diktat ins nicht aktivierende Fenster")
        state.canCorrect = true
        state.selectedIsImage = true
        XCTAssertEqual(act(.press(.triangle)), .clipboard(.correctAndPaste))
        XCTAssertEqual(act(.press(.l3)), .clipboard(.zoom))

        state.isZoomed = true
        XCTAssertNil(act(.press(.l1)), "Filter in der großen Bildansicht gesperrt (wie ⌘D)")
        XCTAssertNil(act(.press(.r1)))
        XCTAssertEqual(act(.tap(.circle)), .clipboard(.close), "Kreis: zurück aus der Bildansicht")

        state = ControllerClipboardState(isConfirmingClear: true)
        XCTAssertEqual(act(.press(.cross)), .clipboard(.confirmClear))
        XCTAssertEqual(act(.tap(.circle)), .clipboard(.close))
        XCTAssertNil(act(.move(.down, source: .dpad, isRepeat: false)))
        XCTAssertNil(act(.holdBegan(.square)))

        state = ControllerClipboardState(menuOpen: true)
        XCTAssertEqual(act(.move(.up, source: .dpad, isRepeat: false)), .clipboard(.menuUp))
        XCTAssertEqual(act(.move(.down, source: .leftStick, isRepeat: true)), .clipboard(.menuDown))
        XCTAssertEqual(act(.press(.cross)), .clipboard(.menuActivate))
        XCTAssertEqual(act(.tap(.circle)), .clipboard(.menuToggle))
        XCTAssertEqual(act(.press(.options)), .clipboard(.menuToggle))
        XCTAssertEqual(act(.press(.touchpad)), .clipboardToggle)
    }

    /// Runde 3: L2 halten öffnet im Raster die Workspace-Auswahl, in der
    /// Einzelansicht weiter die Chat-Auswahl. Tippen bleibt „letzter Chat“.
    func testL2HoldOpensWorkspacePickerOnlyInGrid() {
        XCTAssertEqual(action(.holdBegan(.l2), chat(.idle) { $0.gridActive = true }), .workspacePickerBegin)
        XCTAssertEqual(action(.holdBegan(.l2), chat(.idle)), .pickerBegin)
        XCTAssertEqual(action(.tap(.l2), chat(.idle) { $0.gridActive = true }), .lastChat)
    }

    func testWorkspacePicker() {
        let context = ControllerContext.workspacePicker
        XCTAssertEqual(action(.move(.up, source: .leftStick, isRepeat: false), context), .workspacePickerMove(step: -1))
        XCTAssertEqual(action(.move(.down, source: .dpad, isRepeat: true), context), .workspacePickerMove(step: 1))
        XCTAssertNil(action(.move(.left, source: .leftStick, isRepeat: false), context))
        XCTAssertEqual(action(.holdEnded(.l2), context), .workspacePickerCommit)
        XCTAssertEqual(action(.press(.cross), context), .workspacePickerCommit)
        XCTAssertEqual(action(.tap(.circle), context), .workspacePickerCancel)
        XCTAssertEqual(action(.holdCancelled(.l2), context), .workspacePickerCancel)
        XCTAssertNil(action(.press(.r2), context), "R2 tut in der Workspace-Auswahl nichts")
        XCTAssertNil(action(.chordCompleted, context), "kein Pause-Akkord bei gehaltenem L2")
    }

    func testChatPicker() {
        XCTAssertEqual(action(.move(.left, source: .leftStick, isRepeat: false), .chatPicker), .pickerMove(.left))
        XCTAssertEqual(action(.move(.down, source: .dpad, isRepeat: true), .chatPicker), .pickerMove(.down))
        XCTAssertEqual(action(.holdEnded(.l2), .chatPicker), .pickerCommit)
        XCTAssertEqual(action(.tap(.circle), .chatPicker), .pickerCancel)
        XCTAssertEqual(action(.press(.r2), .chatPicker), .pickerCommitAndDictate)
        XCTAssertEqual(action(.holdCancelled(.l2), .chatPicker), .pickerCancel, "Zurücksetzen schließt ohne Wechsel")
        // Runde 2: Kreuz wechselt sofort; das spätere Loslassen von L2 trifft
        // dann den Chat und tut dort nichts.
        XCTAssertEqual(action(.press(.cross), .chatPicker), .pickerCommit)
        XCTAssertNil(action(.holdEnded(.l2), chat(.idle)))
        XCTAssertNil(action(.holdEnded(.l2), .list))
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

        for context in [chat(.working), .list, .clipboardPanel(ControllerClipboardState()), .menu(dialogOpen: false), .modal,
                        .otherWindow, .noWindow, .quickAction, .outsideApp(backgroundEnabled: true)] {
            XCTAssertEqual(action(.chordCompleted, context), .pauseToggle, "\(context)")
        }
        XCTAssertNil(action(.chordCompleted, .recording(phase: .recording, targetIsChat: true)))
        XCTAssertNil(action(.chordPending(duration: 1), .recording(phase: .recording, targetIsChat: true)))
        XCTAssertNil(action(.chordCompleted, .chatPicker))
    }
}
