import Foundation

// Belegung im Zusammenhang `chat` (Plan, „Im Inhalt“ und „Kreuz, Kreis und
// Viereck im Chat“).

extension ControllerBindingResolver {
    /// Kreuz ist nach einer neuen Rückfrage so lange ohne Wirkung, damit ein
    /// Reflex-Druck keine Freigabe erteilt.
    static let confirmLockAfterQuestion: TimeInterval = 0.5

    static func chat(_ gesture: ControllerGesture, state: ControllerChatState) -> ControllerAction? {
        switch gesture {
        // Navigation: wirkt auch bei beendetem Chat oder reinem Verlauf.
        case let .move(direction, .leftStick, isRepeat):
            return navigate(direction, isRepeat: isRepeat, gridActive: state.gridActive)
        // L1/R1 folgen der Liste links, nicht den Tabs (die Tastatur bleibt bei den Tabs).
        case .press(.l1): return .adjacentChat(step: -1)
        case .press(.r1): return .adjacentChat(step: 1)
        // Dreieck: Leerzeichen (Runde 3; „nächster wartender Chat“ entfällt).
        // Nur bei Claude und Codex, in Shells „geht nicht“.
        case .press(.triangle): return writingKeysAllowed(state) ? .chatKey(.space) : writingKeyRejected(state)
        // Der Ausführer entscheidet: Kachel groß oder zurück zum Raster.
        case .press(.l3): return .toggleMaximize
        case .press(.create): return .newChat
        case .press(.options): return .menuToggle
        // R3 tippen startet einen gestoppten Chat. Auf einem lebenden nichts,
        // auch keine Vibration: beim Scrollen drückt man ihn leicht aus
        // Versehen. R3 halten leert die ganze Eingabe (nicht in Rückfragen,
        // nicht in Shells).
        case .tap(.r3): return state.acceptsKeys ? nil : .chatResume
        case .holdBegan(.r3):
            if clearAllowed(state) { return .chatClearInput }
            return writingKeysAllowed(state) ? nil : writingKeyRejected(state)
        case let .holdPending(.r3, duration): return clearAllowed(state) ? .holdProgress(.r3, duration: duration) : nil
        case .holdCancelled(.r3): return clearAllowed(state) ? .holdProgressCancelled(.r3) : nil
        case .press(.touchpad): return .clipboardToggle
        case .press(.r2): return .dictationToggle
        case .tap(.l2): return .lastChat
        // Im Raster öffnet L2 halten die Workspace-Auswahl (Runde 3), in der
        // Einzelansicht die Chat-Auswahl. Die Tastatur (Ctrl+Tab) bleibt bei den Chats.
        case .holdBegan(.l2): return state.gridActive ? .workspacePickerBegin : .pickerBegin
        case let .holdPending(.l2, duration): return .holdProgress(.l2, duration: duration)
        case .holdCancelled(.l2): return .holdProgressCancelled(.l2)
        case let .scroll(lines): return .scroll(lines: lines)

        // Steuerkreuz: Pfeile ins Terminal nur, wo eine Auswahl offen ist
        // (`arrowsAllowed`). Sonst richten sie Schaden an — links im leeren
        // Eingabefeld schickt Claude in den Hintergrund, hoch holt den letzten
        // Prompt zurück (Kreuz schickte ihn erneut), in einer Shell den
        // letzten Befehl. Dann wirkt das Steuerkreuz wie der linke Stick.
        // Bewusst nicht am Entwurfs-Verdacht festgemacht: Die Rücktaste setzt
        // ihn nie zurück.
        case let .move(direction, .dpad, isRepeat):
            if arrowsAllowed(state) { return .chatKey(ControllerChatKey(direction)) }
            return navigate(direction, isRepeat: isRepeat, gridActive: state.gridActive)

        // Tasten ins Terminal: nur bei lebendem Chat.
        case .press(.cross):
            // Gestoppter Chat: Kreuz startet ihn wieder (wie „Starten“ im Kopf).
            guard state.acceptsKeys else { return .chatResume }
            return confirmAllowed(state) ? .chatKey(.enter) : nil
        case .tap(.circle):
            return escapeAllowed(state) ? .chatKey(.escape) : nil
        case .holdBegan(.circle):
            return interruptAllowed(state) ? .chatInterrupt : nil
        case let .holdPending(.circle, duration):
            return interruptAllowed(state) ? .holdProgress(.circle, duration: duration) : nil
        case .holdCancelled(.circle):
            return interruptAllowed(state) ? .holdProgressCancelled(.circle) : nil
        // Rücktaste: tippen löscht ein Zeichen, halten löscht weiter wie eine
        // gehaltene Taste, nach 1 s ganze Wörter (wie beim iPhone). Harmlos in
        // jedem lebenden Zustand, auch in Shells — dort wie die echte
        // Rücktaste. Ganze Wörter (Ctrl+W) nur bei Claude und Codex: In nano
        // heißt Ctrl+W „Suchen“, in emacs „Ausschneiden“; Shells löschen
        // gehalten weiter Zeichen.
        case .tap(.square), .holdBegan(.square), .holdRepeat(.square):
            return state.acceptsKeys ? .chatKey(.backspace) : nil
        case .holdRepeatLong(.square):
            guard state.acceptsKeys else { return nil }
            return writingKeysAllowed(state) ? .chatKey(.deleteWord) : .chatKey(.backspace)

        default:
            return nil
        }
    }

    /// Schreibtasten (Leerzeichen, Wort löschen, Eingabe leeren) nur in den
    /// Eingabefeldern von Claude und Codex. In einer Shell läuft oft ein
    /// Programm mit eigener Belegung: nano fügt mit Ctrl+U ein, vim und emacs
    /// deuten Ctrl+W und Ctrl+E anders.
    static func writingKeysAllowed(_ state: ControllerChatState) -> Bool {
        state.acceptsKeys && (state.profile == .claude || state.profile == .codex)
    }

    /// „Geht nicht“ für eine Schreibtaste in einem lebenden Chat ohne
    /// Eingabefeld (Shell); bei beendetem Chat still.
    private static func writingKeyRejected(_ state: ControllerChatState) -> ControllerAction? {
        state.acceptsKeys ? .rejected : nil
    }

    /// Ganze Eingabe leeren: Claude oder Codex, keine Rückfrage — dort wählt
    /// man aus, und Leeren könnte die Auswahl zerstören.
    static func clearAllowed(_ state: ControllerChatState) -> Bool {
        writingKeysAllowed(state) && state.status != .awaitingInput
    }

    /// Pfeiltasten ins Terminal eines lebenden Chats:
    /// - bei offener Rückfrage;
    /// - solange eine Auswahlliste offen ist, die das Controller-Menü geöffnet
    ///   hat (`/model`, `/config`, „/“ …) — der Chat ruht dabei;
    /// - bei Codex immer. Codex meldet nie „wartet“ (keine Hooks), und seine
    ///   Freigaben erscheinen, während das Transkript „arbeitet“ sagt (letzter
    ///   Eintrag ist der Tool-Aufruf; nach 2 min ohne Schreiben „ruht“). Eine
    ///   Erkennung gibt es nicht, also bleibt nur: immer. Links im leeren Feld
    ///   schickt Codex nicht in den Hintergrund, das ist Claude-eigen; hoch
    ///   holt den letzten Prompt, sichtbar im Feld.
    /// Bei Claude bleibt das Steuerkreuz sonst Navigation.
    static func arrowsAllowed(_ state: ControllerChatState) -> Bool {
        guard state.acceptsKeys else { return false }
        return state.status == .awaitingInput || choiceListActive(state) || state.profile == .codex
    }

    /// Merker „Auswahl offen“ in der Belegung: bei Claude nur, solange der
    /// Chat ruht. Arbeitet er (auch ein Turn, den Claude selbst beginnt),
    /// gingen Pfeile und Kreuz sonst in den arbeitenden Chat, und Kreuz
    /// bestätigte in der Lücke vor „wartet“ einen Freigabe-Dialog.
    static func choiceListActive(_ state: ControllerChatState) -> Bool {
        guard state.choiceListOpen else { return false }
        return state.profile != .claude || state.status == .idle
    }

    /// Enter: im Ruhezustand immer, in einer Rückfrage nach den ersten 0,5 s
    /// (unbekannter Beginn gilt als alt). Arbeitet der Chat oder ist sein
    /// Zustand unklar, nur wenn kurz vorher per Controller getippt, gelöscht
    /// oder diktiert (bei Codex: ein Pfeil gedrückt) und seither nichts
    /// abgeschickt wurde, oder wenn eine Auswahl des Menüs offen ist: Zwischen
    /// dem Erscheinen eines Freigabe-Dialogs und dem Status „wartet“ liegt eine
    /// Lücke, in der Enter sonst die Vorauswahl bestätigte.
    static func confirmAllowed(_ state: ControllerChatState) -> Bool {
        guard state.acceptsKeys else { return false }
        switch state.status {
        case .awaitingInput:
            if let seconds = state.secondsSinceAwaitingBegan, seconds < confirmLockAfterQuestion { return false }
            return true
        case .idle:
            return true
        case .working, .unknown:
            return state.recentDraftInput || choiceListActive(state)
        case .ended:
            return false
        }
    }

    /// Escape (tippen) nur, wenn der Chat ruht oder fragt und nicht gerade
    /// etwas gesendet wurde. Ein zweites Escape innerhalb 1 s wird
    /// verschluckt, sonst öffnet Claude das Zurückspulen. Eine offene Auswahl
    /// des Menüs schließt Escape auch direkt nach dem Befehl, der sie geöffnet
    /// hat (der zählt als „gerade gesendet“).
    static func escapeAllowed(_ state: ControllerChatState) -> Bool {
        guard state.acceptsKeys, !state.escapeSentRecently else { return false }
        guard state.status == .idle || state.status == .awaitingInput else { return false }
        return !state.recentlySubmitted || choiceListActive(state)
    }

    /// Unterbrechen (Kreis halten) nur, wenn der Chat arbeitet, sein Zustand
    /// unklar ist oder gerade gesendet wurde. Auch hier kein zweites Escape
    /// innerhalb 1 s.
    static func interruptAllowed(_ state: ControllerChatState) -> Bool {
        guard state.acceptsKeys, !state.escapeSentRecently else { return false }
        return state.status == .working || state.status == .unknown || state.recentlySubmitted
    }

    /// Linker Stick (und Steuerkreuz außerhalb von Rückfragen) im Inhalt. Im
    /// Raster bewegt er den Kachel-Fokus (ein Druck, ein Schritt). In der
    /// Einzelansicht springen hoch und runter mit der Markierung in die Liste
    /// links — Start beim aktuellen Chat, sofort ein Schritt in die gedrückte
    /// Richtung; der offene Chat bleibt (Runde 3). Hält man weiter, kommen die
    /// Wiederholungen schon im Zusammenhang `list` an und bewegen dort die
    /// Markierung. Links führt in die Liste, rechts hat dort keine Wirkung.
    static func navigate(_ direction: ControllerDirection, isRepeat: Bool, gridActive: Bool) -> ControllerAction? {
        guard !isRepeat else { return nil }
        if !gridActive {
            switch direction {
            case .up: return .enterList(step: -1)
            case .down: return .enterList(step: 1)
            case .left: break
            case .right: return nil
            }
        }
        return .moveInContent(direction)
    }
}
