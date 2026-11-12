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
    case space, previousNextChat, filter, move, arrows, scroll, clearInputHold, acceptSuggestion
    case backspace, newChat, clipboard, maximize, menu
    case lastChat, pickAndDictate
    // Ebenen der Insel (Runde 4)
    case layersHold, deleteToLineStart, newline
    case continueWork, cycleMode, commands, switchAccount
    case whereToHold, nextWaiting
    case open, select, paste, pin, deleteHold, close, closeHold
    case startChat, correctAndPaste, clipboardFilter, zoomImage, clearHistory
    case resume, pauseHold, bringToFront
    // Touchpad als Maus
    case pointer, clipboardWithL2
}

struct ControllerLegendEntry: Equatable, Sendable {
    /// Alternativen („Stick oder Steuerkreuz“), bei `isCombination` eine Folge
    /// („L2 halten, dann R2“).
    var inputs: [ControllerLegendInput]
    var label: ControllerLegendLabel
    var isCombination: Bool = false
    /// Nur bei `lastChat` in der Legende: wohin L2 zurückführt.
    var backTarget: ControllerBackTarget? = nil
}

struct ControllerLegendSection: Equatable, Sendable {
    enum Kind: String, Sendable {
        /// L1, R1 und L2 gehalten: die drei Ebenen der Insel.
        case core, extra, layers
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

    /// - Parameter touchpadPointer: Touchpad als Maus ist an; der Verlauf
    ///   liegt dann auf L2 + Touchpad.
    static func entries(for context: ControllerContext, touchpadPointer: Bool = false) -> [ControllerLegendEntry] {
        candidates(for: context, touchpadPointer: touchpadPointer)
            .filter { candidate in
                candidate.probes.contains { probe in
                    guard let action = ControllerBindingResolver.action(for: probe, in: context) else { return false }
                    return action != .rejected
                }
            }
            .map(\.entry)
    }

    /// Belegung für die Einstellungsseite, getrennt nach Kern, Zusatz und den
    /// drei Ebenen der Insel. Mit dem Touchpad als Maus steht beim Touchpad
    /// der Zeiger; L2 + Touchpad (Verlauf) gilt immer und steht bei den Ebenen.
    static func allBindings(touchpadPointer: Bool = false) -> [ControllerLegendSection] {
        var sections = standardBindings()
        guard touchpadPointer else { return sections }
        for index in sections.indices where sections[index].kind == .extra {
            if let position = sections[index].entries.firstIndex(of: entry(.button(.touchpad), .clipboard)) {
                sections[index].entries[position] = entry(.button(.touchpad), .pointer)
            }
        }
        return sections
    }

    private static func standardBindings() -> [ControllerLegendSection] {
        [
            ControllerLegendSection(kind: .core, entries: [
                entry(.leftStick, .move),
                entry(.button(.cross), .confirm),
                entry(.button(.circle), .back),
                entry(.button(.circle), .interruptHold),
                entry(.button(.r2), .dictate),
                entry(.button(.triangle), .space),
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
                entry(.button(.r3), .clearInputHold),
                entry(.button(.dpadRight), .acceptSuggestion),
                entry(.button(.l2), .lastChat),
                entry(.bumpers, .pauseHold),
            ]),
            ControllerLegendSection(kind: .layers, entries: [
                combination(.l1, .square, .deleteToLineStart),
                combination(.l1, .triangle, .newline),
                combination(.r1, .cross, .continueWork),
                combination(.r1, .triangle, .cycleMode),
                combination(.r1, .square, .commands),
                combination(.r1, .circle, .switchAccount),
                entry(.button(.l2), .whereToHold),
                combination(.l2, .triangle, .nextWaiting),
                combination(.l2, .touchpad, .clipboardWithL2),
                combination(.l2, .r2, .pickAndDictate),
            ]),
        ]
    }

    private static func combination(
        _ layerKey: ControllerButton, _ button: ControllerButton, _ label: ControllerLegendLabel
    ) -> ControllerLegendEntry {
        ControllerLegendEntry(inputs: [.button(layerKey), .button(button)], label: label, isCombination: true)
    }

    /// Gesten, für die ein Eintrag steht. Eine Kombination mit einer
    /// Ebenen-Taste vorn steht für die zweite Taste in dieser Ebene.
    static func probes(for entry: ControllerLegendEntry) -> [ControllerGesture] {
        if entry.isCombination, case let .button(key)? = entry.inputs.first, let layer = ControllerLayer(key: key) {
            return entry.inputs.dropFirst().flatMap(gestures(for:)).map { .inLayer(layer, $0) }
        }
        return entry.inputs.flatMap(gestures(for:))
    }

    /// Alle Gesten, die zu einer Eingabe gehören können. Grundlage für Tests,
    /// die Legende und Belegung gegeneinander prüfen.
    static func gestures(for input: ControllerLegendInput) -> [ControllerGesture] {
        switch input {
        case let .button(button):
            // Die Richtungen des Steuerkreuzes kommen als Bewegung an.
            if let direction = button.dpadDirection {
                return [false, true].map { ControllerGesture.move(direction, source: .dpad, isRepeat: $0) }
            }
            var gestures: [ControllerGesture] = [
                .press(button), .tap(button), .holdPending(button, duration: 1),
                .holdBegan(button), .holdRepeat(button), .holdRepeatLong(button), .holdEnded(button),
                .holdCancelled(button),
            ]
            if let layer = ControllerLayer(key: button) {
                gestures += [.layerBegan(layer), .layerEnded(layer), .layerCancelled(layer)]
            }
            return gestures
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
            return [.tap(.l1), .tap(.r1), .chordPending(duration: 1), .chordCompleted, .chordCancelled]
        }
    }

    // MARK: - Kandidaten je Zusammenhang

    static func candidates(for context: ControllerContext, touchpadPointer: Bool = false) -> [Candidate] {
        switch context {
        case .paused:
            return [candidate(.bumpers, .resume, [.chordCompleted])]
        case .outsideApp, .noWindow:
            let clipboard = touchpadPointer
                ? Candidate(entry: combination(.l2, .touchpad, .clipboardWithL2),
                            probes: [.inLayer(.whereTo, .press(.touchpad))])
                : candidate(.button(.touchpad), .clipboard, [.press(.touchpad)])
            return [
                candidate(.button(.r2), .dictate, [.press(.r2)]),
                candidate(.button(.triangle), .bringToFront, [.press(.triangle)]),
                clipboard,
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
                candidate(.button(.triangle), .bringToFront, [.press(.triangle)]),
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
                candidate(.bumpers, .filter, [.tap(.l1), .tap(.r1)]),
                candidate(.button(.square), .closeHold, [.holdBegan(.square)]),
                candidate(.button(.create), .newChat, [.press(.create)]),
                candidate(.button(.r2), .dictate, [.press(.r2)]),
            ]
        case let .chat(state):
            return chatCandidates(state)
        }
    }

    private static func chatCandidates(_ state: ControllerChatState) -> [Candidate] {
        let awaiting = state.status == .awaitingInput
        let choosing = awaiting || ControllerBindingResolver.choiceListActive(state)
        let crossLabel: ControllerLegendLabel = !state.acceptsKeys ? .start : (choosing ? .confirm : .send)
        // L1, R1 und L2 gehalten sind die Ebenen der Insel. Die Legende nennt
        // sie in einem Eintrag und schaltet beim Halten nicht um — was die
        // Ebene kann, zeigt die Insel selbst.
        let layers = Candidate(
            entry: ControllerLegendEntry(inputs: [.button(.l1), .button(.r1), .button(.l2)], label: .layersHold),
            probes: ControllerLayer.allCases.map { .layerBegan($0) })
        // Das Steuerkreuz gibt in jedem lebenden Chat Pfeile ins Terminal;
        // ohne Terminal bewegt es wie der Stick.
        let arrows = ControllerBindingResolver.arrowsAllowed(state)
        let moveInputs: [ControllerLegendInput] = arrows ? [.leftStick] : [.leftStick, .dpad]
        // L2 getippt: zurück an den vorigen Ort, mit seinem Namen. Ohne Ziel
        // fehlt der Eintrag (der Druck vibriert dann „geht nicht“).
        let back: [Candidate] = state.backTarget.map { target in
            [Candidate(entry: ControllerLegendEntry(inputs: [.button(.l2)], label: .lastChat, backTarget: target),
                       probes: [.tap(.l2)])]
        } ?? []
        let moveProbes: [ControllerGesture] = moveInputs.flatMap { input in
            ControllerDirection.allCases.map { direction in
                ControllerGesture.move(direction, source: input == .dpad ? .dpad : .leftStick, isRepeat: false)
            }
        }
        let head: [Candidate] = [
            ControllerLegend.Candidate(
                entry: ControllerLegendEntry(inputs: moveInputs, label: .move), probes: moveProbes),
        ] + (arrows ? [candidate(.dpad, .arrows, gestures(for: .dpad))] : []) + [
            candidate(.button(.cross), crossLabel, [.press(.cross)]),
        ]
        let keys: [Candidate] = [
            candidate(.button(.circle), awaiting ? .reject : .back, [.tap(.circle)]),
            candidate(.button(.circle), .interruptHold, [.holdBegan(.circle)]),
            candidate(.button(.square), .backspace, [.tap(.square)]),
            candidate(.button(.triangle), .space, [.press(.triangle)]),
            candidate(.button(.r2), .dictate, [.press(.r2)]),
            candidate(.bumpers, .previousNextChat, [.tap(.l1), .tap(.r1)]),
        ]
        let tail: [Candidate] = [layers] + [
            candidate(.rightStick, .scroll, gestures(for: .rightStick)),
            candidate(.button(.r3), .startChat, [.tap(.r3)]),
            candidate(.button(.r3), .clearInputHold, [.holdBegan(.r3)]),
        ]
        return head + keys + back + tail
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
            candidate(.bumpers, .clipboardFilter, [.tap(.l1), .tap(.r1)]),
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
