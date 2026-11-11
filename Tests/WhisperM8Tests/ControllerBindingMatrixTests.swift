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
        .cross, .triangle, .l1, .r1, .r2, .l3, .r3, .create, .options, .touchpad,
    ]
    private static let holdButtons: [(ControllerButton, TimeInterval)] = [(.l2, 0.3), (.circle, 0.4), (.square, 0.6)]

    static let allGestures: [ControllerGesture] = {
        var gestures: [ControllerGesture] = immediateButtons.map { .press($0) }
        for (button, duration) in holdButtons {
            gestures += [
                .tap(button), .holdPending(button, duration: duration),
                .holdBegan(button), .holdEnded(button), .holdCancelled(button),
            ]
        }
        gestures += [.chordPending(duration: 1), .chordCompleted, .chordCancelled]
        for direction in ControllerDirection.allCases {
            for source in ControllerMoveSource.allCases {
                for isRepeat in [false, true] {
                    gestures.append(.move(direction, source: source, isRepeat: isRepeat))
                }
            }
        }
        gestures += [.scroll(lines: 3), .scroll(lines: -3)]
        return gestures
    }()

    // MARK: - Bausteine der Tabellen

    private static let pauseChord: Table = [
        .chordPending(duration: 1): .holdProgress(.l1, duration: 1),
        .chordCompleted: .pauseToggle,
        .chordCancelled: .holdProgressCancelled(.l1),
    ]

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

    /// Navigation im Chat, die auch bei beendetem Chat bleibt.
    private static let chatNavigation: Table = {
        var table: Table = [
            .press(.l1): .tab(step: -1),
            .press(.r1): .tab(step: 1),
            .press(.triangle): .nextWaitingChat,
            .press(.l3): .toggleMaximize,
            .press(.create): .newChat,
            .press(.options): .menuToggle,
            .press(.touchpad): .clipboardToggle,
            .press(.r2): .dictationToggle,
            .tap(.l2): .lastChat,
            .holdBegan(.l2): .pickerBegin,
            .holdPending(.l2, duration: 0.3): .holdProgress(.l2, duration: 0.3),
            .holdCancelled(.l2): .holdProgressCancelled(.l2),
            .scroll(lines: 3): .scroll(lines: 3),
            .scroll(lines: -3): .scroll(lines: -3),
        ]
        for direction in ControllerDirection.allCases {
            table[.move(direction, source: .leftStick, isRepeat: false)] = .moveInContent(direction)
        }
        return merge(table, pauseChord)
    }()

    private static let chatArrows = dpad { .chatKey(ControllerChatKey($0)) }

    private static let bridge: Table = merge(dpad { .bridgeKey(ControllerBridgeKey($0)) }, [
        .press(.cross): .bridgeKey(.returnKey),
        .tap(.circle): .bridgeKey(.escape),
        .press(.l1): .bridgeKey(.backTab),
        .press(.r1): .bridgeKey(.tab),
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
        ("Aufnahme in Chat", .recording(phase: .recording, targetIsChat: true), [
            .press(.r2): .dictationToggle,
            .press(.cross): .dictationStopAndSubmit,
            .tap(.circle): .dictationCancel,
            .move(.left, source: .dpad, isRepeat: false): .outputMode(step: -1),
            .move(.right, source: .dpad, isRepeat: false): .outputMode(step: 1),
        ]),
        ("Aufnahme in App", .recording(phase: .recording, targetIsChat: false), [
            .press(.r2): .dictationToggle,
            .tap(.circle): .dictationCancel,
            .move(.left, source: .dpad, isRepeat: false): .outputMode(step: -1),
            .move(.right, source: .dpad, isRepeat: false): .outputMode(step: 1),
        ]),
        ("Transkription", .recording(phase: .transcribing, targetIsChat: true), [.tap(.circle): .dictationCancel]),
        ("Nacharbeit", .recording(phase: .postProcessing, targetIsChat: false), [.tap(.circle): .dictationCancel]),
        ("Schnellaktion", .quickAction, merge([
            .tap(.circle): .dictationCancel,
            .press(.r2): .rejected,
        ], pauseChord)),
        ("Verlauf", .clipboardPanel, merge(moves(.up, .clipboard(.up)), moves(.down, .clipboard(.down)), [
            .press(.cross): .clipboard(.paste),
            .tap(.circle): .clipboard(.close),
            .press(.triangle): .clipboard(.pin),
            .press(.touchpad): .clipboardToggle,
            .holdPending(.square, duration: 0.6): .holdProgress(.square, duration: 0.6),
            .holdBegan(.square): .clipboard(.delete),
            .holdCancelled(.square): .holdProgressCancelled(.square),
        ], pauseChord)),
        ("Menü", .menu(dialogOpen: false), merge(moves(.up, .menuMove(step: -1)), moves(.down, .menuMove(step: 1)), [
            .press(.cross): .menuActivate,
            .tap(.circle): .menuToggle,
            .press(.options): .menuToggle,
        ], pauseChord)),
        ("Chat-Auswahl", .chatPicker, merge(
            moves(.up, .pickerMove(.up)), moves(.down, .pickerMove(.down)),
            moves(.left, .pickerMove(.left)), moves(.right, .pickerMove(.right)), [
                .holdEnded(.l2): .pickerCommit,
                .holdCancelled(.l2): .pickerCancel,
                .tap(.circle): .pickerCancel,
                .press(.r2): .pickerCommitAndDictate,
            ])),
        ("Dialog", .modal, bridge),
        ("anderes Fenster", .otherWindow, merge(bridge, [
            .press(.triangle): .nextWaitingChat,
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
            .press(.l1): .listFilter(step: -1),
            .press(.r1): .listFilter(step: 1),
            .press(.create): .newChat,
            .press(.triangle): .nextWaitingChat,
            .press(.r2): .dictationToggle,
            .press(.touchpad): .clipboardToggle,
            .press(.options): .menuToggle,
        ], pauseChord)),
        ("Chat ruht mit Entwurf", chatState(.idle) { $0.draftSuspected = true }, merge(chatNavigation, chatArrows, [
            .press(.cross): .chatKey(.enter),
            .tap(.circle): .chatKey(.escape),
            .tap(.square): .chatClearComposer,
        ])),
        ("Chat ruht, Codex", .chat(ControllerChatState(status: .idle, profile: .codex, draftSuspected: true)),
         merge(chatNavigation, chatArrows, [
             .press(.cross): .chatKey(.enter),
             .tap(.circle): .chatKey(.escape),
         ])),
        ("Chat arbeitet", chatState(.working), merge(chatNavigation, chatArrows, [
            .press(.cross): .chatKey(.enter),
            .holdBegan(.circle): .chatInterrupt,
            .holdPending(.circle, duration: 0.4): .holdProgress(.circle, duration: 0.4),
            .holdCancelled(.circle): .holdProgressCancelled(.circle),
        ])),
        ("Chat gerade gesendet", chatState(.idle) { $0.recentlySubmitted = true }, merge(chatNavigation, chatArrows, [
            .press(.cross): .chatKey(.enter),
            .holdBegan(.circle): .chatInterrupt,
            .holdPending(.circle, duration: 0.4): .holdProgress(.circle, duration: 0.4),
            .holdCancelled(.circle): .holdProgressCancelled(.circle),
        ])),
        ("Rückfrage alt", chatState(.awaitingInput) { $0.secondsSinceAwaitingBegan = 2 },
         merge(chatNavigation, chatArrows, [
             .press(.cross): .chatKey(.enter),
             .tap(.circle): .chatKey(.escape),
         ])),
        ("Rückfrage neu", chatState(.awaitingInput) { $0.secondsSinceAwaitingBegan = 0.1 },
         merge(chatNavigation, chatArrows, [.tap(.circle): .chatKey(.escape)])),
        ("Chat beendet", chatState(.ended) { $0.draftSuspected = true }, chatNavigation),
        ("nur Verlauf", chatState(.working) { $0.hasTerminal = false }, chatNavigation),
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
                    ControllerBindingResolver.action(for: gesture, in: context), table[gesture],
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
            case .chatPicker: seen.insert("chatPicker")
            case .modal: seen.insert("modal")
            case .list: seen.insert("list")
            case .chat: seen.insert("chat")
            case .otherWindow: seen.insert("otherWindow")
            case .noWindow: seen.insert("noWindow")
            }
        }
        XCTAssertEqual(seen.count, 12)
    }
}
