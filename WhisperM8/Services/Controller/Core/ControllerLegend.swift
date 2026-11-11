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
    case send, confirm, back, reject, cancel, interruptHold, start
    case dictate, stopDictation, stopAndSend, discard, outputMode
    case nextWaiting, previousNextChat, filter, move, arrows, scroll
    case backspace, newChat, clipboard, maximize, menu
    case lastChat, pickChatHold, pickAndDictate, switchOnRelease, switchWorkspaceHold
    case open, select, paste, pin, deleteHold, close, closeHold
    case startChat, correctAndPaste, clipboardFilter, zoomImage, clearHistory
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
/// eine Aktion liefert, die etwas tut („geht nicht“ zählt nicht). So kann die Legende keine Taste ohne Wirkung zeigen,
/// etwa Kreuz in den ersten 0,5 s einer Rückfrage oder Viereck bei beendetem Chat.
enum ControllerLegend {
    struct Candidate {
        var entry: ControllerLegendEntry
        var probes: [ControllerGesture]
    }

    static func entries(for context: ControllerContext) -> [ControllerLegendEntry] {
        candidates(for: context)
            .filter { candidate in
                candidate.probes.contains { probe in
                    guard let action = ControllerBindingResolver.action(for: probe, in: context) else { return false }
                    return action != .rejected
                }
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
                entry(.bumpers, .previousNextChat),
                entry(.dpad, .arrows),
                entry(.rightStick, .scroll),
            ]),
            ControllerLegendSection(kind: .extra, entries: [
                entry(.button(.square), .backspace),
                entry(.button(.square), .closeHold),
                entry(.button(.create), .newChat),
                entry(.button(.touchpad), .clipboard),
                entry(.button(.l3), .maximize),
                entry(.button(.options), .menu),
                entry(.button(.r3), .startChat),
                entry(.button(.l2), .lastChat),
                entry(.button(.l2), .pickChatHold),
                entry(.button(.l2), .switchWorkspaceHold),
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
                .holdBegan(button), .holdRepeat(button), .holdEnded(button), .holdCancelled(button),
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
                candidate(.dpad, .outputMode, gestures(for: .dpad)),
                candidate(.rightStick, .scroll, gestures(for: .rightStick)),
            ]
        case .recording:
            return [
                candidate(.button(.circle), .cancel, [.tap(.circle)]),
                candidate(.rightStick, .scroll, gestures(for: .rightStick)),
            ]
        case .quickAction:
            return [candidate(.button(.circle), .cancel, [.tap(.circle)])]
        case let .clipboardPanel(state):
            return clipboardCandidates(state)
        case .menu:
            return [
                ControllerLegend.Candidate(
                    entry: ControllerLegendEntry(inputs: [.leftStick, .dpad], label: .move),
                    probes: verticalMoves
                ),
                candidate(.button(.cross), .select, [.press(.cross)]),
                candidate(.button(.circle), .back, [.tap(.circle)]),
                candidate(.button(.options), .close, [.press(.options)]),
            ]
        case .chatPicker:
            return [
                ControllerLegend.Candidate(
                    entry: ControllerLegendEntry(inputs: [.leftStick, .dpad], label: .move),
                    probes: gestures(for: .leftStick) + gestures(for: .dpad)
                ),
                candidate(.button(.cross), .select, [.press(.cross)]),
                candidate(.button(.l2), .switchOnRelease, [.holdEnded(.l2)]),
                candidate(.button(.r2), .pickAndDictate, [.press(.r2)]),
                candidate(.button(.circle), .cancel, [.tap(.circle)]),
            ]
        case .workspacePicker:
            return [
                ControllerLegend.Candidate(
                    entry: ControllerLegendEntry(inputs: [.leftStick, .dpad], label: .move),
                    probes: verticalMoves
                ),
                candidate(.button(.cross), .select, [.press(.cross)]),
                candidate(.button(.l2), .switchOnRelease, [.holdEnded(.l2)]),
                candidate(.button(.circle), .cancel, [.tap(.circle)]),
            ]
        case .modal:
            return [
                ControllerLegend.Candidate(
                    entry: ControllerLegendEntry(inputs: [.dpad, .leftStick], label: .arrows),
                    probes: gestures(for: .dpad)
                ),
                candidate(.button(.cross), .confirm, [.press(.cross)]),
                candidate(.button(.circle), .back, [.tap(.circle)]),
                candidate(.button(.r2), .dictate, [.press(.r2)]),
            ]
        case .otherWindow:
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
                candidate(.button(.square), .closeHold, [.holdBegan(.square)]),
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
        let crossLabel: ControllerLegendLabel = !state.acceptsKeys ? .start : (awaiting ? .confirm : .send)
        // Im Raster zeigt die Legende die Workspace-Auswahl auf L2. Die
        // Chat-Auswahl der Einzelansicht steht wie bisher nur in der Übersicht
        // der Einstellungen.
        let workspaceHold: [Candidate] = state.gridActive
            ? [candidate(.button(.l2), .switchWorkspaceHold, [.holdBegan(.l2)])] : []
        return [
            candidate(.leftStick, .move, ControllerDirection.allCases.map {
                .move($0, source: .leftStick, isRepeat: false)
            }),
            candidate(.button(.cross), crossLabel, [.press(.cross)]),
            candidate(.button(.circle), awaiting ? .reject : .back, [.tap(.circle)]),
            candidate(.button(.circle), .interruptHold, [.holdBegan(.circle)]),
            candidate(.button(.square), .backspace, [.tap(.square)]),
            candidate(.button(.r2), .dictate, [.press(.r2)]),
            candidate(.button(.triangle), .nextWaiting, [.press(.triangle)]),
            candidate(.bumpers, .previousNextChat, [.press(.l1), .press(.r1)]),
        ] + workspaceHold + [
            candidate(.dpad, .arrows, gestures(for: .dpad)),
            candidate(.rightStick, .scroll, gestures(for: .rightStick)),
            candidate(.button(.r3), .startChat, [.press(.r3)]),
        ]
    }

    /// Verlauf: dieselbe Tabelle liefert die Fußzeile des Verlauf-Fensters,
    /// wenn ein Controller verbunden ist.
    private static func clipboardCandidates(_ state: ControllerClipboardState) -> [Candidate] {
        let move = ControllerLegend.Candidate(
            entry: ControllerLegendEntry(inputs: [.leftStick, .dpad], label: .move),
            probes: verticalMoves
        )
        if state.menuOpen {
            return [
                move,
                candidate(.button(.cross), .select, [.press(.cross)]),
                candidate(.button(.circle), .close, [.tap(.circle)]),
            ]
        }
        if state.isConfirmingClear {
            return [
                candidate(.button(.cross), .clearHistory, [.press(.cross)]),
                candidate(.button(.circle), .cancel, [.tap(.circle)]),
            ]
        }
        return [
            move,
            candidate(.button(.cross), .paste, [.press(.cross)]),
            candidate(.button(.triangle), .correctAndPaste, [.press(.triangle)]),
            candidate(.button(.square), .deleteHold, [.holdBegan(.square)]),
            candidate(.bumpers, .clipboardFilter, [.press(.l1), .press(.r1)]),
            candidate(.button(.l3), .zoomImage, [.press(.l3)]),
            candidate(.button(.options), .menu, [.press(.options)]),
            candidate(.button(.circle), state.isZoomed ? .back : .close, [.tap(.circle)]),
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
