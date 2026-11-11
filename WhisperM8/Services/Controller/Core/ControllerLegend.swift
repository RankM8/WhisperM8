import Foundation

/// Eine Eingabe, wie die Legende sie zeigt.
enum ControllerLegendInput: Hashable, Sendable {
    case button(ControllerButton)
    case leftStick
    case rightStick
    case dpad
    /// L1 und R1 als Paar.
    case bumpers
}

/// Fachliche Bezeichnung eines Legenden-Eintrags. Die sichtbaren Texte
/// (englisch, mit deutscher Übersetzung) entstehen erst in der UI.
enum ControllerLegendLabel: String, CaseIterable, Sendable {
    case send, confirm, back, reject, cancel, interruptHold
    case dictate, stopDictation, stopAndSend, discard, outputMode
    case nextWaiting, tabs, filter, move, arrows, scroll
    case clearInput, newChat, clipboard, maximize, menu
    case lastChat, pickChatHold, pickAndDictate, switchOnRelease
    case open, select, paste, pin, deleteHold, close
    case resume, pauseHold, bringToFront
}

struct ControllerLegendEntry: Equatable, Sendable {
    /// Alternativen („Stick oder Steuerkreuz“), bei `isCombination` eine Folge
    /// („L2 halten, dann R2“).
    var inputs: [ControllerLegendInput]
    var label: ControllerLegendLabel
    var isCombination: Bool = false
}

struct ControllerLegendSection: Equatable, Sendable {
    enum Kind: String, Sendable {
        case core, extra
    }

    var kind: Kind
    var entries: [ControllerLegendEntry]
}

/// Liefert die Legende am unteren Fensterrand und die Belegung für die
/// Einstellungsseite (Plan 3.1).
///
/// Jeder Kandidat nennt die Gesten, für die er steht. Gezeigt wird er nur,
/// wenn der `ControllerBindingResolver` im selben Zusammenhang für eine davon
/// eine Aktion liefert. So kann die Legende keine Taste ohne Wirkung zeigen,
/// etwa Viereck ohne erkannten Entwurf oder Kreuz bei beendetem Chat.
enum ControllerLegend {
    struct Candidate {
        var entry: ControllerLegendEntry
        var probes: [ControllerGesture]
    }

    static func entries(for context: ControllerContext) -> [ControllerLegendEntry] {
        candidates(for: context)
            .filter { candidate in
                candidate.probes.contains { ControllerBindingResolver.action(for: $0, in: context) != nil }
            }
            .map(\.entry)
    }

    /// Belegung für die Einstellungsseite, getrennt nach Kern und Zusatz.
    static func allBindings() -> [ControllerLegendSection] {
        [
            ControllerLegendSection(kind: .core, entries: [
                entry(.leftStick, .move),
                entry(.button(.cross), .confirm),
                entry(.button(.circle), .back),
                entry(.button(.circle), .interruptHold),
                entry(.button(.r2), .dictate),
                entry(.button(.triangle), .nextWaiting),
                entry(.bumpers, .tabs),
                entry(.dpad, .arrows),
                entry(.rightStick, .scroll),
            ]),
            ControllerLegendSection(kind: .extra, entries: [
                entry(.button(.square), .clearInput),
                entry(.button(.create), .newChat),
                entry(.button(.touchpad), .clipboard),
                entry(.button(.l3), .maximize),
                entry(.button(.options), .menu),
                entry(.button(.l2), .lastChat),
                entry(.button(.l2), .pickChatHold),
                ControllerLegendEntry(inputs: [.button(.l2), .button(.r2)], label: .pickAndDictate, isCombination: true),
                entry(.bumpers, .pauseHold),
            ]),
        ]
    }

    /// Alle Gesten, die zu einer Eingabe gehören können. Grundlage für Tests,
    /// die Legende und Belegung gegeneinander prüfen.
    static func gestures(for input: ControllerLegendInput) -> [ControllerGesture] {
        switch input {
        case let .button(button):
            return [
                .press(button), .tap(button), .holdPending(button, duration: 1),
                .holdBegan(button), .holdEnded(button), .holdCancelled(button),
            ]
        case .leftStick:
            return ControllerDirection.allCases.flatMap { direction in
                [false, true].map { ControllerGesture.move(direction, source: .leftStick, isRepeat: $0) }
            }
        case .dpad:
            return ControllerDirection.allCases.flatMap { direction in
                [false, true].map { ControllerGesture.move(direction, source: .dpad, isRepeat: $0) }
            }
        case .rightStick:
            return [.scroll(lines: 1), .scroll(lines: -1)]
        case .bumpers:
            return [.press(.l1), .press(.r1), .chordPending(duration: 1), .chordCompleted, .chordCancelled]
        }
    }

    // MARK: - Kandidaten je Zusammenhang

    static func candidates(for context: ControllerContext) -> [Candidate] {
        switch context {
        case .paused:
            return [candidate(.bumpers, .resume, [.chordCompleted])]
        case .outsideApp, .noWindow:
            return [
                candidate(.button(.r2), .dictate, [.press(.r2)]),
                candidate(.button(.triangle), .bringToFront, [.press(.triangle)]),
                candidate(.button(.touchpad), .clipboard, [.press(.touchpad)]),
            ]
        case .recording(.recording, _):
            return [
                candidate(.button(.r2), .stopDictation, [.press(.r2)]),
                candidate(.button(.cross), .stopAndSend, [.press(.cross)]),
                candidate(.button(.circle), .discard, [.tap(.circle)]),
                candidate(.dpad, .outputMode, [
                    .move(.left, source: .dpad, isRepeat: false),
                    .move(.right, source: .dpad, isRepeat: false),
                ]),
            ]
        case .recording, .quickAction:
            return [candidate(.button(.circle), .cancel, [.tap(.circle)])]
        case .clipboardPanel:
            return [
                ControllerLegend.Candidate(
                    entry: ControllerLegendEntry(inputs: [.leftStick, .dpad], label: .move),
                    probes: verticalMoves
                ),
                candidate(.button(.cross), .paste, [.press(.cross)]),
                candidate(.button(.triangle), .pin, [.press(.triangle)]),
                candidate(.button(.square), .deleteHold, [.holdBegan(.square)]),
                candidate(.button(.circle), .close, [.tap(.circle)]),
            ]
        case .menu:
            return [
                ControllerLegend.Candidate(
                    entry: ControllerLegendEntry(inputs: [.leftStick, .dpad], label: .move),
                    probes: verticalMoves
                ),
                candidate(.button(.cross), .select, [.press(.cross)]),
                candidate(.button(.circle), .close, [.tap(.circle)]),
            ]
        case .chatPicker:
            return [
                ControllerLegend.Candidate(
                    entry: ControllerLegendEntry(inputs: [.leftStick, .dpad], label: .move),
                    probes: gestures(for: .leftStick) + gestures(for: .dpad)
                ),
                candidate(.button(.l2), .switchOnRelease, [.holdEnded(.l2)]),
                candidate(.button(.r2), .pickAndDictate, [.press(.r2)]),
                candidate(.button(.circle), .cancel, [.tap(.circle)]),
            ]
        case .modal, .otherWindow:
            return [
                candidate(.dpad, .arrows, gestures(for: .dpad)),
                candidate(.button(.cross), .confirm, [.press(.cross)]),
                candidate(.button(.circle), .back, [.tap(.circle)]),
                candidate(.button(.triangle), .nextWaiting, [.press(.triangle)]),
                candidate(.button(.r2), .dictate, [.press(.r2)]),
            ]
        case .list:
            return [
                ControllerLegend.Candidate(
                    entry: ControllerLegendEntry(inputs: [.leftStick, .dpad], label: .move),
                    probes: verticalMoves
                ),
                candidate(.button(.cross), .open, [.press(.cross)]),
                candidate(.button(.circle), .back, [.tap(.circle)]),
                candidate(.bumpers, .filter, [.press(.l1), .press(.r1)]),
                candidate(.button(.create), .newChat, [.press(.create)]),
                candidate(.button(.triangle), .nextWaiting, [.press(.triangle)]),
                candidate(.button(.r2), .dictate, [.press(.r2)]),
            ]
        case let .chat(state):
            return chatCandidates(state)
        }
    }

    private static func chatCandidates(_ state: ControllerChatState) -> [Candidate] {
        let awaiting = state.status == .awaitingInput
        return [
            candidate(.leftStick, .move, ControllerDirection.allCases.map {
                .move($0, source: .leftStick, isRepeat: false)
            }),
            candidate(.button(.cross), awaiting ? .confirm : .send, [.press(.cross)]),
            candidate(.button(.circle), awaiting ? .reject : .back, [.tap(.circle)]),
            candidate(.button(.circle), .interruptHold, [.holdBegan(.circle)]),
            candidate(.button(.square), .clearInput, [.tap(.square)]),
            candidate(.button(.r2), .dictate, [.press(.r2)]),
            candidate(.button(.triangle), .nextWaiting, [.press(.triangle)]),
            candidate(.bumpers, .tabs, [.press(.l1), .press(.r1)]),
            candidate(.dpad, .arrows, gestures(for: .dpad)),
            candidate(.rightStick, .scroll, gestures(for: .rightStick)),
        ]
    }

    private static let verticalMoves: [ControllerGesture] = ControllerMoveSource.allCases.flatMap { source in
        [ControllerGesture.move(.up, source: source, isRepeat: false),
         .move(.down, source: source, isRepeat: false)]
    }

    private static func candidate(
        _ input: ControllerLegendInput, _ label: ControllerLegendLabel, _ probes: [ControllerGesture]
    ) -> Candidate {
        Candidate(entry: entry(input, label), probes: probes)
    }

    private static func entry(_ input: ControllerLegendInput, _ label: ControllerLegendLabel) -> ControllerLegendEntry {
        ControllerLegendEntry(inputs: [input], label: label)
    }
}
