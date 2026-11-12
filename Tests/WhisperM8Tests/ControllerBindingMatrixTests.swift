import Foundation
import XCTest
@testable import WhisperM8

/// Matrix-Test der Belegung: Jede Geste in jedem (repräsentativen)
/// Zusammenhang hat einen festgelegten Ausgang. Die Tabellen unten nennen alle
/// Gesten mit Wirkung; jede andere Geste muss `nil` liefern. Wer die Belegung
/// ändert, muss diese Tabelle bewusst mitändern.
final class ControllerBindingMatrixTests: XCTestCase {
    typealias Table = [ControllerGesture: ControllerAction]

    // MARK: - Alle Gesten

    private static let immediateButtons: [ControllerButton] = [
        .cross, .triangle, .r2, .l3, .create, .options, .touchpad,
    ]
    private static let holdButtons: [(ControllerButton, TimeInterval)] = [
        (.circle, 0.4), (.square, 0.6), (.r3, 0.6),
    ]
    /// Tasten, die in einer Ebene ankommen können (beim Drücken).
    private static let layerPressButtons: [ControllerButton] = [
        .cross, .circle, .square, .triangle, .r2, .r3, .l3, .create, .options, .touchpad, .l1, .r1, .l2,
    ]

    static let allGestures: [ControllerGesture] = {
        var gestures: [ControllerGesture] = immediateButtons.map { .press($0) }
        for (button, duration) in holdButtons {
            gestures += [
                .tap(button), .holdPending(button, duration: duration),
                .holdBegan(button), .holdRepeat(button), .holdRepeatLong(button), .holdEnded(button),
                .holdCancelled(button),
            ]
        }
        gestures += [.chordPending(duration: 1), .chordCompleted, .chordCancelled]
        var moves: [ControllerGesture] = []
        for direction in ControllerDirection.allCases {
            for source in ControllerMoveSource.allCases {
                for isRepeat in [false, true] {
                    moves.append(.move(direction, source: source, isRepeat: isRepeat))
                }
            }
        }
        gestures += moves
        gestures += [.scroll(lines: 3), .scroll(lines: -3)]
        // Runde 4: Ebenen-Tasten und was in einer Ebene ankommt.
        for key in [ControllerButton.l1, .r1, .l2] {
            gestures += [.tap(key), .holdPending(key, duration: 0.3)]
        }
        for layer in ControllerLayer.allCases {
            gestures += [.layerBegan(layer), .layerEnded(layer), .layerCancelled(layer)]
            let inner = layerPressButtons.map { ControllerGesture.press($0) } + [.holdRepeat(.square)] + moves
            gestures += inner.map { .inLayer(layer, $0) }
        }
        return gestures
    }()

    /// Ausgang außerhalb der ausdrücklichen Tabelle: Außerhalb eines Chats
    /// wirken die Tasten einer Ebene wie ohne Ebene, und das Ende einer Ebene
    /// schließt die Insel (außer in der Pause). Im Chat steht alles in der
    /// Tabelle.
    static func expected(_ gesture: ControllerGesture, in context: ControllerContext, table: Table) -> ControllerAction? {
        if let action = table[gesture] { return action }
        if case .chat = context { return nil }
        if case .paused = context { return nil }
        switch gesture {
        case .layerEnded(.whereTo): return .islandRelease
        case .layerEnded, .layerCancelled: return .islandClose
        case let .inLayer(_, inner): return expected(inner, in: context, table: table)
        default: return nil
        }
    }

    // MARK: - Bausteine der Tabellen

    private static let pauseChord: Table = [
        .chordPending(duration: 1): .holdProgress(.l1, duration: 1),
        .chordCompleted: .pauseToggle,
        .chordCancelled: .holdProgressCancelled(.l1),
    ]

    /// Außerhalb der App mit „Bei Eingabe nach vorn holen“: Tasten beim
    /// Drücken, Sticks und Steuerkreuz beim ersten Ausschlag, L1/R1/L2 erst
    /// beim Tippen. Wiederholungen und das Halten danach nicht.
    private static let wakeTable: Table = {
        var table: Table = [:]
        for button in immediateButtons where button != .r2 && button != .touchpad {
            table[.press(button)] = .bringAppToFront
        }
        // Tasten, die nur in einer Ebene als Druck ankommen (Kreis, L1 …).
        let layerOnly = Set(layerPressButtons).subtracting(immediateButtons)
        for layer in ControllerLayer.allCases {
            for button in layerOnly {
                table[.inLayer(layer, .press(button))] = .bringAppToFront
            }
        }
        for (button, duration) in holdButtons {
            table[.holdPending(button, duration: duration)] = .bringAppToFront
        }
        for key in [ControllerButton.l1, .r1, .l2] {
            table[.tap(key)] = .bringAppToFront
        }
        for direction in ControllerDirection.allCases {
            for source in ControllerMoveSource.allCases {
                table[.move(direction, source: source, isRepeat: false)] = .bringAppToFront
            }
        }
        table[.scroll(lines: 3)] = .bringAppToFront
        table[.scroll(lines: -3)] = .bringAppToFront
        return table
    }()

    /// Alle Bewegungen in `direction` aus beiden Quellen, mit und ohne Wiederholung.
    private static func moves(_ direction: ControllerDirection, _ action: ControllerAction) -> Table {
        var table: Table = [:]
        for source in ControllerMoveSource.allCases {
            for isRepeat in [false, true] {
                table[.move(direction, source: source, isRepeat: isRepeat)] = action
            }
        }
        return table
    }

    private static func dpad(_ map: (ControllerDirection) -> ControllerAction) -> Table {
        var table: Table = [:]
        for direction in ControllerDirection.allCases {
            for isRepeat in [false, true] {
                table[.move(direction, source: .dpad, isRepeat: isRepeat)] = map(direction)
            }
        }
        return table
    }

    private static func merge(_ tables: Table...) -> Table {
        tables.reduce(into: Table()) { result, table in
            result.merge(table) { _, _ in fatalError("doppelte Geste in der Tabelle") }
        }
    }

    /// Navigation im Chat, die auch bei beendetem Chat bleibt. Einzelansicht:
    /// Stick hoch/runter springt mit der Markierung in die Liste, ein Schritt
    /// (Runde 3; Wiederholungen kommen dann im Zusammenhang `list` an).
    private static let chatNavigation: Table = {
        var table: Table = [
            .tap(.l1): .adjacentChat(step: -1),
            .tap(.r1): .adjacentChat(step: 1),
            .press(.l3): .toggleMaximize,
            .press(.create): .newChat,
            .press(.options): .menuToggle,
            .press(.touchpad): .clipboardToggle,
            .press(.r2): .dictationToggle,
            .tap(.l2): .lastChat,
            .scroll(lines: 3): .scroll(lines: 3),
            .scroll(lines: -3): .scroll(lines: -3),
        ]
        table[.move(.up, source: .leftStick, isRepeat: false)] = .enterList(step: -1)
        table[.move(.down, source: .leftStick, isRepeat: false)] = .enterList(step: 1)
        table[.move(.left, source: .leftStick, isRepeat: false)] = .moveInContent(.left)
        // Rechts hat in der Einzelansicht keine Wirkung (Review-Befund 1).
        return merge(table, pauseChord, layers)
    }()

    /// Ebenen im Chat (Runde 4), soweit sie nicht vom Zustand abhängen. Die
    /// Schreib-Tasten der L1-Ebene stehen in `clearInput` bzw. bei Shell und
    /// Rückfrage in `writingRejected`.
    private static let layers: Table = {
        var table: Table = [
            .inLayer(.writing, .press(.r2)): .dictationToggle,
            .inLayer(.quickDraw, .press(.cross)): .quickDraw(.continueWork),
            .inLayer(.quickDraw, .press(.triangle)): .quickDraw(.cycleMode),
            .inLayer(.quickDraw, .press(.square)): .quickDraw(.commands),
            .inLayer(.quickDraw, .press(.circle)): .quickDraw(.switchAccount),
            .inLayer(.quickDraw, .press(.r2)): .dictationToggle,
            .inLayer(.whereTo, .press(.cross)): .islandCommit,
            .inLayer(.whereTo, .press(.circle)): .islandCancel,
            .inLayer(.whereTo, .press(.triangle)): .islandNextWaiting,
            .inLayer(.whereTo, .press(.r2)): .islandCommitAndDictate,
            // Touchpad als Maus: L2 + Touchpad ist der Weg zum Verlauf.
            .inLayer(.whereTo, .press(.touchpad)): .clipboardToggle,
            .inLayer(.whereTo, .move(.left, source: .leftStick, isRepeat: false)): .islandTab(step: -1),
            .inLayer(.whereTo, .move(.left, source: .dpad, isRepeat: false)): .islandTab(step: -1),
            .inLayer(.whereTo, .move(.right, source: .leftStick, isRepeat: false)): .islandTab(step: 1),
            .inLayer(.whereTo, .move(.right, source: .dpad, isRepeat: false)): .islandTab(step: 1),
        ]
        for layer in ControllerLayer.allCases {
            table[.layerBegan(layer)] = .islandShow(layer)
            table[.layerEnded(layer)] = layer == .whereTo ? .islandRelease : .islandClose
            table[.layerCancelled(layer)] = .islandClose
        }
        for (gesture, action) in moves(.up, .islandMove(step: -1)).merging(moves(.down, .islandMove(step: 1)), uniquingKeysWith: { a, _ in a }) {
            table[.inLayer(.whereTo, gesture)] = action
        }
        return table
    }()

    /// L1-Ebene, wo Schreiben nicht geht (Shell, Rückfrage): „geht nicht“.
    private static let writingRejected: Table = [
        .inLayer(.writing, .press(.square)): .rejected,
        .inLayer(.writing, .press(.triangle)): .rejected,
    ]

    /// Im Raster bewegt der Stick den Kachel-Fokus, ein Druck ein Schritt.
    private static let gridNavigation: Table = {
        var table = chatNavigation
        for direction in ControllerDirection.allCases {
            table[.move(direction, source: .leftStick, isRepeat: false)] = .moveInContent(direction)
            table[.move(direction, source: .leftStick, isRepeat: true)] = nil
        }
        return table
    }()

    /// Schreibtasten in jedem lebenden Chat: Viereck als Rücktaste (Runde 2),
    /// lange gehalten ganze Wörter, Dreieck als Leerzeichen (Runde 3).
    private static let backspace: Table = [
        .tap(.square): .chatKey(.backspace),
        .holdBegan(.square): .chatKey(.backspace),
        .holdRepeat(.square): .chatKey(.backspace),
        .holdRepeatLong(.square): .chatKey(.deleteWord),
        .press(.triangle): .chatKey(.space),
    ]

    /// R3 halten leert die Eingabe — lebender Chat ohne Rückfrage (Runde 3).
    /// Dieselben Schutzregeln gelten für die L1-Ebene: bis Zeilenanfang
    /// löschen (gehalten wiederholt) und Zeilenumbruch.
    private static let clearInput: Table = [
        .holdPending(.r3, duration: 0.6): .holdProgress(.r3, duration: 0.6),
        .holdBegan(.r3): .chatClearInput,
        .holdCancelled(.r3): .holdProgressCancelled(.r3),
        .inLayer(.writing, .press(.square)): .chatKey(.deleteToLineStart),
        .inLayer(.writing, .holdRepeat(.square)): .chatKey(.deleteToLineStart),
        .inLayer(.writing, .press(.triangle)): .chatKey(.newline),
    ]

    /// Verlauf ohne Menü und Rückfrage: was in jedem Zustand gilt.
    private static let clipboardBase: Table = merge(moves(.up, .clipboard(.up)), moves(.down, .clipboard(.down)), [
        .press(.cross): .clipboard(.paste),
        .tap(.circle): .clipboard(.close),
        .press(.touchpad): .clipboardToggle,
        .press(.options): .clipboard(.menuToggle),
        .press(.r2): .rejected,
        .holdPending(.square, duration: 0.6): .holdProgress(.square, duration: 0.6),
        .holdBegan(.square): .clipboard(.delete),
        .holdCancelled(.square): .holdProgressCancelled(.square),
    ], pauseChord)

    private static let scrollWhileRecording: Table = [
        .scroll(lines: 3): .scroll(lines: 3),
        .scroll(lines: -3): .scroll(lines: -3),
    ]

    private static let chatArrows = dpad { .chatKey(ControllerChatKey($0)) }

    /// Shell (Review nach Runde 3, Befund 4): Rücktaste bleibt, auch gehalten —
    /// dort aber nur Zeichen, kein Ctrl+W. Leerzeichen und Leeren „geht nicht“.
    private static let shellKeys: Table = [
        .tap(.square): .chatKey(.backspace),
        .holdBegan(.square): .chatKey(.backspace),
        .holdRepeat(.square): .chatKey(.backspace),
        .holdRepeatLong(.square): .chatKey(.backspace),
        .press(.triangle): .rejected,
        .holdBegan(.r3): .rejected,
        .inLayer(.writing, .press(.square)): .rejected,
        .inLayer(.writing, .press(.triangle)): .rejected,
    ]

    /// Steuerkreuz außerhalb einer Rückfrage (Review-Befund 1): wie der linke
    /// Stick, ohne Wiederholung; rechts ohne Wirkung.
    private static let dpadNavigation: Table = [
        .move(.up, source: .dpad, isRepeat: false): .enterList(step: -1),
        .move(.down, source: .dpad, isRepeat: false): .enterList(step: 1),
        .move(.left, source: .dpad, isRepeat: false): .moveInContent(.left),
    ]

    /// Lebender Claude-Chat: rechts übernimmt den grauen Vorschlag (Pfeil
    /// rechts, auch gehalten), sonst wie `dpadNavigation`.
    private static let claudeDpadNavigation: Table = merge(dpadNavigation, [
        .move(.right, source: .dpad, isRepeat: false): .chatKey(.right),
        .move(.right, source: .dpad, isRepeat: true): .chatKey(.right),
    ])

    /// Im Raster von Kachel zu Kachel.
    private static let gridDpadNavigation: Table = Dictionary(uniqueKeysWithValues: ControllerDirection.allCases.map {
        (ControllerGesture.move($0, source: .dpad, isRepeat: false), ControllerAction.moveInContent($0))
    })

    /// Raster mit Claude-Chat: rechts übernimmt den Vorschlag, die übrigen
    /// Richtungen wechseln die Kachel (der Stick wechselt auch nach rechts).
    private static let claudeGridDpadNavigation: Table = {
        var table = gridDpadNavigation
        table[.move(.right, source: .dpad, isRepeat: false)] = .chatKey(.right)
        table[.move(.right, source: .dpad, isRepeat: true)] = .chatKey(.right)
        return table
    }()

    private static let bridge: Table = merge(dpad { .bridgeKey(ControllerBridgeKey($0)) }, [
        .press(.cross): .bridgeKey(.returnKey),
        .tap(.circle): .bridgeKey(.escape),
        .tap(.l1): .bridgeKey(.backTab),
        .tap(.r1): .bridgeKey(.tab),
        .press(.r2): .dictationToggle,
    ], pauseChord)

    private static func chatState(
        _ status: ControllerChatState.Status, _ configure: (inout ControllerChatState) -> Void = { _ in }
    ) -> ControllerContext {
        var state = ControllerChatState(status: status, profile: .claude)
        configure(&state)
        return .chat(state)
    }

    // MARK: - Die Tabelle

    static let expectations: [(name: String, context: ControllerContext, table: Table)] = [
        ("paused", .paused, pauseChord),
        ("outsideApp an", .outsideApp(backgroundEnabled: true), merge([
            .press(.r2): .dictationToggle,
            .press(.touchpad): .clipboardToggle,
            .press(.triangle): .bringAppToFront,
        ], pauseChord)),
        ("outsideApp aus", .outsideApp(backgroundEnabled: false), [:]),
        ("outsideApp aufwecken", .outsideApp(backgroundEnabled: true, wakeOnInput: true), merge([
            .press(.r2): .dictationToggle,
            .press(.touchpad): .clipboardToggle,
        ], wakeTable, pauseChord)),
        ("Aufnahme in Chat", .recording(phase: .recording, targetIsChat: true), merge([
            .press(.r2): .dictationToggle,
            .press(.cross): .dictationStopAndSubmit,
            .tap(.circle): .dictationCancel,
            .move(.left, source: .dpad, isRepeat: false): .outputMode(step: -1),
            .move(.right, source: .dpad, isRepeat: false): .outputMode(step: 1),
            .move(.up, source: .dpad, isRepeat: false): .outputMode(step: -1),
            .move(.up, source: .dpad, isRepeat: true): .outputMode(step: -1),
            .move(.down, source: .dpad, isRepeat: false): .outputMode(step: 1),
            .move(.down, source: .dpad, isRepeat: true): .outputMode(step: 1),
        ], scrollWhileRecording)),
        ("Aufnahme in App", .recording(phase: .recording, targetIsChat: false), merge([
            .press(.r2): .dictationToggle,
            .tap(.circle): .dictationCancel,
            .move(.left, source: .dpad, isRepeat: false): .outputMode(step: -1),
            .move(.right, source: .dpad, isRepeat: false): .outputMode(step: 1),
            .move(.up, source: .dpad, isRepeat: false): .outputMode(step: -1),
            .move(.up, source: .dpad, isRepeat: true): .outputMode(step: -1),
            .move(.down, source: .dpad, isRepeat: false): .outputMode(step: 1),
            .move(.down, source: .dpad, isRepeat: true): .outputMode(step: 1),
        ], scrollWhileRecording)),
        ("Transkription", .recording(phase: .transcribing, targetIsChat: true),
         merge([.tap(.circle): .dictationCancel], scrollWhileRecording)),
        ("Nacharbeit", .recording(phase: .postProcessing, targetIsChat: false),
         merge([.tap(.circle): .dictationCancel], scrollWhileRecording)),
        ("Schnellaktion", .quickAction, merge([
            .tap(.circle): .dictationCancel,
            .press(.r2): .rejected,
        ], pauseChord)),
        ("Verlauf", .clipboardPanel(ControllerClipboardState()), merge(clipboardBase, [
            .press(.triangle): .rejected,
            .press(.l3): .rejected,
            .tap(.l1): .clipboard(.filterAll),
            .tap(.r1): .clipboard(.filterDictations),
        ])),
        ("Verlauf, Bild mit Korrektur", .clipboardPanel(ControllerClipboardState(canCorrect: true, selectedIsImage: true)),
         merge(clipboardBase, [
             .press(.triangle): .clipboard(.correctAndPaste),
             .press(.l3): .clipboard(.zoom),
             .tap(.l1): .clipboard(.filterAll),
             .tap(.r1): .clipboard(.filterDictations),
         ])),
        ("Verlauf, große Bildansicht",
         .clipboardPanel(ControllerClipboardState(isZoomed: true, selectedIsImage: true)), merge(clipboardBase, [
             .press(.triangle): .rejected,
             .press(.l3): .clipboard(.zoom),
         ])),
        ("Verlauf, Rückfrage Leeren", .clipboardPanel(ControllerClipboardState(isConfirmingClear: true)), merge([
            .press(.cross): .clipboard(.confirmClear),
            .tap(.circle): .clipboard(.close),
            .press(.touchpad): .clipboardToggle,
        ], pauseChord)),
        ("Verlauf, Menü", .clipboardPanel(ControllerClipboardState(menuOpen: true)),
         merge(moves(.up, .clipboard(.menuUp)), moves(.down, .clipboard(.menuDown)), [
             .press(.cross): .clipboard(.menuActivate),
             .tap(.circle): .clipboard(.menuToggle),
             .press(.options): .clipboard(.menuToggle),
             .press(.touchpad): .clipboardToggle,
         ], pauseChord)),
        ("Menü", .menu(dialogOpen: false), merge(moves(.up, .menuMove(step: -1)), moves(.down, .menuMove(step: 1)), [
            .press(.cross): .menuActivate,
            .tap(.circle): .menuBack,
            .press(.options): .menuToggle,
        ], pauseChord)),
        ("Dialog", .modal, merge(bridge, [
            .move(.up, source: .leftStick, isRepeat: false): .bridgeKey(.up),
            .move(.up, source: .leftStick, isRepeat: true): .bridgeKey(.up),
            .move(.down, source: .leftStick, isRepeat: false): .bridgeKey(.down),
            .move(.down, source: .leftStick, isRepeat: true): .bridgeKey(.down),
        ])),
        ("anderes Fenster", .otherWindow, merge(bridge, [
            .press(.triangle): .bringAppToFront,
            .press(.touchpad): .clipboardToggle,
        ])),
        ("kein Fenster", .noWindow, merge([
            .press(.triangle): .bringAppToFront,
            .press(.r2): .dictationToggle,
            .press(.touchpad): .clipboardToggle,
        ], pauseChord)),
        ("Liste", .list, merge(moves(.up, .listMove(step: -1)), moves(.down, .listMove(step: 1)), [
            .move(.right, source: .leftStick, isRepeat: false): .leaveList,
            .move(.right, source: .dpad, isRepeat: false): .leaveList,
            .tap(.circle): .leaveList,
            .press(.cross): .listActivate,
            .tap(.l1): .listFilter(step: -1),
            .tap(.r1): .listFilter(step: 1),
            .holdPending(.square, duration: 0.6): .holdProgress(.square, duration: 0.6),
            .holdBegan(.square): .listCloseRow,
            .holdCancelled(.square): .holdProgressCancelled(.square),
            .tap(.r3): .listStartRow,
            .press(.create): .newChat,
            .press(.r2): .dictationToggle,
            .press(.touchpad): .clipboardToggle,
            .press(.options): .menuToggle,
        ], pauseChord)),
        ("Chat ruht mit Entwurf", chatState(.idle) { $0.draftSuspected = true }, merge(chatNavigation, claudeDpadNavigation, backspace, clearInput, [
            .press(.cross): .chatKey(.enter),
            .tap(.circle): .chatKey(.escape),
        ])),
        // Befund 1b nach Runde 3: Codex meldet keine Rückfragen — Pfeile immer.
        ("Chat ruht, Codex", .chat(ControllerChatState(status: .idle, profile: .codex, draftSuspected: true)),
         merge(chatNavigation, chatArrows, backspace, clearInput, [
             .press(.cross): .chatKey(.enter),
             .tap(.circle): .chatKey(.escape),
         ])),
        ("Codex arbeitet", .chat(ControllerChatState(status: .working, profile: .codex)),
         merge(chatNavigation, chatArrows, backspace, clearInput, [
             .holdBegan(.circle): .chatInterrupt,
             .holdPending(.circle, duration: 0.4): .holdProgress(.circle, duration: 0.4),
             .holdCancelled(.circle): .holdProgressCancelled(.circle),
         ])),
        ("Codex arbeitet, Pfeil per Controller",
         .chat(ControllerChatState(status: .working, profile: .codex, recentDraftInput: true)),
         merge(chatNavigation, chatArrows, backspace, clearInput, [
             .press(.cross): .chatKey(.enter),
             .holdBegan(.circle): .chatInterrupt,
             .holdPending(.circle, duration: 0.4): .holdProgress(.circle, duration: 0.4),
             .holdCancelled(.circle): .holdProgressCancelled(.circle),
         ])),
        // Befund 1a: Liste aus dem Menü offen (Chat ruht, gerade gesendet).
        ("Claude, Auswahl offen", chatState(.idle) { $0.choiceListOpen = true; $0.recentlySubmitted = true },
         merge(chatNavigation, chatArrows, backspace, clearInput, [
             .press(.cross): .chatKey(.enter),
             .tap(.circle): .chatKey(.escape),
             .holdBegan(.circle): .chatInterrupt,
             .holdPending(.circle, duration: 0.4): .holdProgress(.circle, duration: 0.4),
             .holdCancelled(.circle): .holdProgressCancelled(.circle),
         ])),
        ("Shell ruht", .chat(ControllerChatState(status: .idle, profile: .shell)),
         merge(chatNavigation, dpadNavigation, shellKeys, [
             .press(.cross): .chatKey(.enter),
             .tap(.circle): .chatKey(.escape),
         ])),
        ("Raster, Chat ruht", chatState(.idle) { $0.gridActive = true }, merge(gridNavigation, claudeGridDpadNavigation, backspace, clearInput, [
            .press(.cross): .chatKey(.enter),
            .tap(.circle): .chatKey(.escape),
        ])),
        // Review-Befund 3: Kreuz nur nach einer frischen Eingabe per Controller.
        ("Chat arbeitet", chatState(.working), merge(chatNavigation, claudeDpadNavigation, backspace, clearInput, [
            .holdBegan(.circle): .chatInterrupt,
            .holdPending(.circle, duration: 0.4): .holdProgress(.circle, duration: 0.4),
            .holdCancelled(.circle): .holdProgressCancelled(.circle),
        ])),
        ("Chat arbeitet, Entwurf per Controller", chatState(.working) { $0.recentDraftInput = true },
         merge(chatNavigation, claudeDpadNavigation, backspace, clearInput, [
            .press(.cross): .chatKey(.enter),
            .holdBegan(.circle): .chatInterrupt,
            .holdPending(.circle, duration: 0.4): .holdProgress(.circle, duration: 0.4),
            .holdCancelled(.circle): .holdProgressCancelled(.circle),
        ])),
        ("Chat gerade gesendet", chatState(.idle) { $0.recentlySubmitted = true }, merge(chatNavigation, claudeDpadNavigation, backspace, clearInput, [
            .press(.cross): .chatKey(.enter),
            .holdBegan(.circle): .chatInterrupt,
            .holdPending(.circle, duration: 0.4): .holdProgress(.circle, duration: 0.4),
            .holdCancelled(.circle): .holdProgressCancelled(.circle),
        ])),
        ("Rückfrage alt", chatState(.awaitingInput) { $0.secondsSinceAwaitingBegan = 2 },
         merge(chatNavigation, chatArrows, backspace, writingRejected, [
             .press(.cross): .chatKey(.enter),
             .tap(.circle): .chatKey(.escape),
         ])),
        ("Rückfrage neu", chatState(.awaitingInput) { $0.secondsSinceAwaitingBegan = 0.1 },
         merge(chatNavigation, chatArrows, backspace, writingRejected, [.tap(.circle): .chatKey(.escape)])),
        ("Chat beendet", chatState(.ended) { $0.draftSuspected = true },
         merge(chatNavigation, dpadNavigation, [.press(.cross): .chatResume, .tap(.r3): .chatResume])),
        ("nur Verlauf", chatState(.working) { $0.hasTerminal = false },
         merge(chatNavigation, dpadNavigation, [.press(.cross): .chatResume, .tap(.r3): .chatResume])),
    ]

    // MARK: - Prüfung

    func testTablesOnlyNameKnownGestures() {
        let known = Set(Self.allGestures)
        for (name, _, table) in Self.expectations {
            for gesture in table.keys {
                XCTAssertTrue(known.contains(gesture), "\(name): \(gesture) fehlt in allGestures")
            }
        }
    }

    func testEveryGestureInEveryContextHasTheExpectedOutcome() {
        for (name, context, table) in Self.expectations {
            for gesture in Self.allGestures {
                XCTAssertEqual(
                    ControllerBindingResolver.action(for: gesture, in: context),
                    Self.expected(gesture, in: context, table: table),
                    "\(name): \(gesture)"
                )
            }
        }
    }

    func testEveryContextCaseIsCovered() {
        var seen = Set<String>()
        for (_, context, _) in Self.expectations {
            switch context {
            case .paused: seen.insert("paused")
            case .outsideApp: seen.insert("outsideApp")
            case .recording: seen.insert("recording")
            case .quickAction: seen.insert("quickAction")
            case .clipboardPanel: seen.insert("clipboardPanel")
            case .menu: seen.insert("menu")
            case .modal: seen.insert("modal")
            case .list: seen.insert("list")
            case .chat: seen.insert("chat")
            case .otherWindow: seen.insert("otherWindow")
            case .noWindow: seen.insert("noWindow")
            }
        }
        XCTAssertEqual(seen.count, 11)
    }
}
