import Foundation

/// Die gesamte Belegung als pure Funktion: (Geste, Zusammenhang) → Aktion
/// (Plan Abschnitt 2). `nil` heißt „keine Wirkung“.
///
/// Grundsätze, die hier überall gelten:
/// - Wiederholungen des linken Sticks bewegen nur Markierungen in Listen
///   (Liste links, Menü, Verlauf, Chat-Auswahl), nie Kacheln oder Bereiche:
///   ein Druck, ein Schritt.
/// - Halte-Fortschritt (`holdProgress`) erscheint nur, wo das Halten im
///   Zusammenhang eine Wirkung hätte.
/// - Der Pause-Akkord L1 + R1 gilt überall außer während der Aufnahme und in
///   der Chat-Auswahl, und nicht außerhalb der App ohne Hintergrund-Empfang.
enum ControllerBindingResolver {
    /// Steht für das Paar L1 + R1 in `holdProgress`.
    static let chordProgressButton: ControllerButton = .l1

    static func action(for gesture: ControllerGesture, in context: ControllerContext) -> ControllerAction? {
        if let chordAction = chordAction(for: gesture, in: context) {
            return chordAction
        }
        switch context {
        case .paused:
            return nil
        case let .outsideApp(backgroundEnabled):
            return backgroundEnabled ? outsideApp(gesture) : nil
        case let .recording(phase, targetIsChat):
            return recording(gesture, phase: phase, targetIsChat: targetIsChat)
        case .quickAction:
            return quickAction(gesture)
        case .clipboardPanel:
            return clipboardPanel(gesture)
        case .menu:
            return menu(gesture)
        case .chatPicker:
            return chatPicker(gesture)
        case .modal:
            return bridge(gesture)
        case .otherWindow:
            return otherWindow(gesture)
        case .noWindow:
            return noWindow(gesture)
        case .list:
            return list(gesture)
        case let .chat(state):
            return chat(gesture, state: state)
        }
    }

    // MARK: - Pause-Akkord

    static func chordAllowed(in context: ControllerContext) -> Bool {
        switch context {
        case .recording, .chatPicker, .outsideApp(backgroundEnabled: false):
            return false
        default:
            return true
        }
    }

    private static func chordAction(for gesture: ControllerGesture, in context: ControllerContext) -> ControllerAction? {
        guard chordAllowed(in: context) else { return nil }
        switch gesture {
        case .chordCompleted: return .pauseToggle
        case let .chordPending(duration): return .holdProgress(chordProgressButton, duration: duration)
        case .chordCancelled: return .holdProgressCancelled(chordProgressButton)
        default: return nil
        }
    }

    // MARK: - Außerhalb der App und ohne Agent-Chats-Fenster

    private static func outsideApp(_ gesture: ControllerGesture) -> ControllerAction? {
        switch gesture {
        case .press(.r2): return .dictationToggle
        case .press(.touchpad): return .clipboardToggle
        case .press(.triangle): return .bringAppToFront
        default: return nil
        }
    }

    private static func noWindow(_ gesture: ControllerGesture) -> ControllerAction? {
        switch gesture {
        case .press(.r2): return .dictationToggle
        case .press(.touchpad): return .clipboardToggle
        case .press(.triangle): return .bringAppToFront
        default: return nil
        }
    }

    /// Ein anderes WhisperM8-Fenster (etwa die Einstellungen): Tastatur-Brücke,
    /// dazu Diktat, Verlauf und Dreieck (holt das Agent-Chats-Fenster nach vorn).
    private static func otherWindow(_ gesture: ControllerGesture) -> ControllerAction? {
        switch gesture {
        case .press(.triangle): return .nextWaitingChat
        case .press(.touchpad): return .clipboardToggle
        default: return bridge(gesture)
        }
    }

    /// Tastatur-Brücke für Dialoge und andere Fenster (Plan 3.6). R2 diktiert
    /// in das Feld mit dem Fokus.
    private static func bridge(_ gesture: ControllerGesture) -> ControllerAction? {
        switch gesture {
        case let .move(direction, .dpad, _): return .bridgeKey(ControllerBridgeKey(direction))
        case .press(.cross): return .bridgeKey(.returnKey)
        case .tap(.circle): return .bridgeKey(.escape)
        case .press(.l1): return .bridgeKey(.backTab)
        case .press(.r1): return .bridgeKey(.tab)
        case .press(.r2): return .dictationToggle
        default: return nil
        }
    }

    // MARK: - Diktat und Schnellaktion

    private static func recording(
        _ gesture: ControllerGesture, phase: ControllerRecordingPhase, targetIsChat: Bool
    ) -> ControllerAction? {
        guard phase == .recording else {
            // Transkription oder Nacharbeit: nur abbrechen.
            return gesture == .tap(.circle) ? .dictationCancel : nil
        }
        switch gesture {
        case .press(.r2): return .dictationToggle
        case .press(.cross): return targetIsChat ? .dictationStopAndSubmit : nil
        case .tap(.circle): return .dictationCancel
        // Ein Druck, ein Schritt: der Modus soll nicht durchrauschen.
        case .move(.left, .dpad, false): return .outputMode(step: -1)
        case .move(.right, .dpad, false): return .outputMode(step: 1)
        default: return nil
        }
    }

    private static func quickAction(_ gesture: ControllerGesture) -> ControllerAction? {
        switch gesture {
        case .tap(.circle): return .dictationCancel
        case .press(.r2): return .rejected
        default: return nil
        }
    }

    // MARK: - Zwischenablage-Verlauf, Menü, Chat-Auswahl

    /// Löschen braucht Halten (Plan: „Viereck halten (0,6 s) löscht“). Dafür
    /// ist Viereck im Erkenner eine Tippen-oder-Halten-Taste; hier löst erst
    /// `.holdBegan(.square)` das Löschen aus, getippt passiert nichts.
    private static func clipboardPanel(_ gesture: ControllerGesture) -> ControllerAction? {
        switch gesture {
        case .move(.up, _, _): return .clipboard(.up)
        case .move(.down, _, _): return .clipboard(.down)
        case .press(.cross): return .clipboard(.paste)
        case .tap(.circle): return .clipboard(.close)
        case .press(.triangle): return .clipboard(.pin)
        case .press(.touchpad): return .clipboardToggle
        case let .holdPending(.square, duration): return .holdProgress(.square, duration: duration)
        case .holdBegan(.square): return .clipboard(.delete)
        case .holdCancelled(.square): return .holdProgressCancelled(.square)
        default: return nil
        }
    }

    private static func menu(_ gesture: ControllerGesture) -> ControllerAction? {
        switch gesture {
        case .move(.up, _, _): return .menuMove(step: -1)
        case .move(.down, _, _): return .menuMove(step: 1)
        case .press(.cross): return .menuActivate
        case .tap(.circle), .press(.options): return .menuToggle
        default: return nil
        }
    }

    /// `.holdCancelled(.l2)` kommt hier nur aus `reset` (Trennung, Ruhezustand):
    /// Die Auswahl schließt dann ohne Wechsel.
    private static func chatPicker(_ gesture: ControllerGesture) -> ControllerAction? {
        switch gesture {
        case let .move(direction, _, _): return .pickerMove(direction)
        case .holdEnded(.l2): return .pickerCommit
        case .holdCancelled(.l2): return .pickerCancel
        case .tap(.circle): return .pickerCancel
        case .press(.r2): return .pickerCommitAndDictate
        default: return nil
        }
    }

    // MARK: - Liste links

    private static func list(_ gesture: ControllerGesture) -> ControllerAction? {
        switch gesture {
        case .move(.up, _, _): return .listMove(step: -1)
        case .move(.down, _, _): return .listMove(step: 1)
        case .move(.right, _, false): return .leaveList
        case .tap(.circle): return .leaveList
        case .press(.cross): return .listActivate
        case .press(.l1): return .listFilter(step: -1)
        case .press(.r1): return .listFilter(step: 1)
        case .press(.create): return .newChat
        case .press(.triangle): return .nextWaitingChat
        case .press(.r2): return .dictationToggle
        case .press(.touchpad): return .clipboardToggle
        case .press(.options): return .menuToggle
        default: return nil
        }
    }
}
