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
        // L1/R1 getippt folgen der Liste links, nicht den Tabs (die Tastatur
        // bleibt bei den Tabs). Gehalten sind sie Ebenen, kein Durchlaufen.
        case .tap(.l1): return .adjacentChat(step: -1)
        case .tap(.r1): return .adjacentChat(step: 1)
        // Dreieck: Leerzeichen (Runde 3; „nächster wartender Chat“ entfällt).
        // Nur bei Claude und Codex, in Shells „geht nicht“.
        case .press(.triangle): return writingKeysAllowed(state) ? .chatKey(.space) : writingKeyRejected(state)
        // Der Ausführer entscheidet: Kachel groß oder zurück zum Raster.
        case .press(.l3): return .toggleMaximize
        case .press(.create): return .newChat
        case .press(.options): return .menuToggle
        // R3 tippen startet einen gestoppten Chat. Auf einem lebenden nichts,
        // auch keine Vibration: beim Scrollen drückt man ihn leicht aus
        // Versehen. R3 halten leert die ganze Eingabe (nicht in Rückfragen;
        // in Shells nur an der Eingabezeile, nie in nano, vim und Co.).
        case .tap(.r3): return state.acceptsKeys ? nil : .chatResume
        case .holdBegan(.r3):
            if clearAllowed(state) { return .chatClearInput }
            return writingKeysAllowed(state) ? nil : writingKeyRejected(state)
        case let .holdPending(.r3, duration): return clearAllowed(state) ? .holdProgress(.r3, duration: duration) : nil
        case .holdCancelled(.r3): return clearAllowed(state) ? .holdProgressCancelled(.r3) : nil
        case .press(.touchpad): return .clipboardToggle
        case .press(.r2): return .dictationToggle
        // L2 gehalten ist die Ebene „Wohin“ (Insel, Runde 4).
        case .tap(.l2): return .lastChat
        case let .scroll(lines): return .scroll(lines: lines)

        // Steuerkreuz: in jedem lebenden Chat Pfeiltasten ins Terminal
        // (Entscheidung 12.11.2026). Nur so kommt man in Claude in
        // Subagenten-, Workflow- und Aufgabenansichten, in Rückfragen, die
        // nicht als „wartet“ gemeldet werden, und durch Listen der CLI. In
        // der App navigiert der linke Stick. Rechts übernimmt den grauen
        // Vorschlag. Ausnahme: links im vermutlich leeren Claude-Feld
        // („geht nicht“, siehe `leftArrowAllowed`). Ohne lebendes Terminal
        // (beendeter Chat, Verlauf) wie der Stick.
        case let .move(direction, .dpad, isRepeat):
            if arrowsAllowed(state) {
                if direction == .left, !leftArrowAllowed(state) { return isRepeat ? nil : .rejected }
                return .chatKey(ControllerChatKey(direction))
            }
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
    static func writingKeyRejected(_ state: ControllerChatState) -> ControllerAction? {
        state.acceptsKeys ? .rejected : nil
    }

    /// Ganze Eingabe leeren: Claude oder Codex, keine Rückfrage — dort wählt
    /// man aus, und Leeren könnte die Auswahl zerstören. Shell nur an ihrer
    /// Eingabezeile; sonst bliebe nach `chats send` der Entwurfs-Verdacht
    /// stehen (E2E-Befund 12.11.2026).
    static func clearAllowed(_ state: ControllerChatState) -> Bool {
        if state.profile == .shell { return state.acceptsKeys && state.shellAtPrompt }
        return writingKeysAllowed(state) && state.status != .awaitingInput
    }

    /// Pfeiltasten ins Terminal: in jedem lebenden Chat, gleich welches
    /// Programm (Claude, Codex, Shell). Bis 12.11.2026 nur bei offener
    /// Auswahl und in Codex; das sperrte Ansichten, die Claude ohne
    /// „wartet“ zeigt (Subagenten, Workflows).
    static func arrowsAllowed(_ state: ControllerChatState) -> Bool {
        state.acceptsKeys
    }

    /// Links bei Claude nur, wo es sicher nicht das leere Eingabefeld trifft:
    /// in einer Rückfrage, in einer offenen Auswahl des Menüs oder wenn
    /// irgendetwas im Feld steht (getippt, diktiert, Rückleger, mit ↑
    /// zurückgeholt, mit → übernommen; seit 12.11.2026 weniger streng). Im leeren Feld schickt ← die ganze Sitzung in
    /// Claudes Agent-Ansicht — so gingen am 12.11.2026 zwei Sitzungen
    /// verloren. Dieselbe Regel prüft `TerminalControlKey.controllerAllows`.
    ///
    /// Runde 5 (R2): Eine erkannte Ansicht fängt ← selbst ab. Sonst entscheidet
    /// der Bildschirm, wenn das Feld ablesbar ist — gesperrt wird nur, wenn es
    /// sichtbar leer ist; ist es nicht eindeutig, gilt die Schätzung.
    static func leftArrowAllowed(_ state: ControllerChatState) -> Bool {
        guard state.profile == .claude else { return true }
        if state.status == .awaitingInput || choiceListActive(state) { return true }
        return ControllerScreenReading.fieldMayHaveText(
            screen: ControllerScreenSnapshot(openView: state.openView, promptField: state.promptField),
            tracker: state.draftSuspected || state.fieldMayHaveText)
    }

    /// In einer erkannten Claude-Ansicht (`/tasks`, `/workflows`, Transkript,
    /// Zurückspulen, Auswahl in der Fußzeile) fängt die Ansicht Escape selbst
    /// ab: schließen statt abbrechen (Runde 5, R2).
    static func viewOpen(_ state: ControllerChatState) -> Bool {
        state.acceptsKeys && state.profile == .claude && state.openView != nil
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
    /// Zustand unklar: bei Claude immer, wenn sein Eingabefeld sichtbar ist
    /// (`claudePromptVisible`). Sonst nur, wenn kurz vorher per Controller
    /// getippt, gelöscht oder diktiert (bei Codex: ein Pfeil gedrückt; bei
    /// Claude bis 5 s nach einem scharfen Pfeil, `recentArrowNavigation`) und
    /// seither nichts abgeschickt wurde, oder wenn eine Auswahl des Menüs offen
    /// ist: Zwischen dem Erscheinen eines Freigabe-Dialogs und dem Status
    /// „wartet“ liegt eine Lücke, in der Enter sonst die Vorauswahl bestätigte.
    static func confirmAllowed(_ state: ControllerChatState) -> Bool {
        guard state.acceptsKeys else { return false }
        switch state.status {
        case .awaitingInput:
            if let seconds = state.secondsSinceAwaitingBegan, seconds < confirmLockAfterQuestion { return false }
            return true
        case .idle:
            return true
        case .working, .unknown:
            return claudePromptVisible(state) || state.recentDraftInput || choiceListActive(state)
                || state.recentArrowNavigation
        case .ended:
            return false
        }
    }

    /// Claudes Eingabefeld steht beim Druck sichtbar unten am Bildschirm
    /// (Entscheidung 13.11.2026). Ein Freigabe-Dialog ersetzt das Feld; steht
    /// es da, ist also keiner offen, und Enter schickt den Text ab (oder reiht
    /// ihn ein), öffnet den gewählten Eintrag der Fußzeile oder tut im leeren
    /// Feld nichts. So wirkt Kreuz auch auf Text von Tastatur und Hotkey-Diktat
    /// und auf den ersten ▼ in die Fußzeile, den der Pfeil selbst noch nicht
    /// scharf machen konnte (Claude zeichnet erst danach neu).
    ///
    /// Gelesen wird beim Druck selbst (Schnappschuss je Geste). Nicht
    /// ablesbar (hochgescrollt, Feld nicht erkannt, Codex, Shell) heißt
    /// `nil`, dann gilt die vorsichtige Regel. Steht unter dem Feld ein
    /// Dialog-Hinweis, gilt es nicht als Feld (`ControllerScreenReading`).
    ///
    /// Steht laut Tracker nur ein alter Prompt im Feld (mit ↑ zurückgeholt
    /// oder zurückgelegt), gilt ebenfalls die vorsichtige Regel: Sonst
    /// schickte ↑ + Kreuz den letzten Prompt erneut ab (Runde 5; R1 + Kreuz
    /// sperrt dort genauso). In der Fußzeilen-Auswahl öffnet Enter den
    /// Agenten, das Feld bleibt unberührt.
    static func claudePromptVisible(_ state: ControllerChatState) -> Bool {
        guard state.profile == .claude, state.promptField != nil else { return false }
        // Mit sichtbarem Feld kann nur die Fußzeilen-Auswahl erkannt sein;
        // jede andere Ansicht ersetzt das Feld.
        switch state.openView {
        case .footerSelection: return true
        case nil: return !state.onlyRecalledPrompt
        default: return false
        }
    }

    /// Escape (tippen) nur, wenn der Chat ruht oder fragt und nicht gerade
    /// etwas gesendet wurde. Ein zweites Escape innerhalb 1 s wird
    /// verschluckt, sonst öffnet Claude das Zurückspulen. Eine offene Auswahl
    /// des Menüs schließt Escape auch direkt nach dem Befehl, der sie geöffnet
    /// hat (der zählt als „gerade gesendet“).
    ///
    /// In einer erkannten Ansicht auch bei „arbeitet“ und gerade gesendet,
    /// mit nur 0,3 s Sperre statt 1 s (Runde 5, R2): Escape schließt dort die
    /// Ansicht; ein zweites, bevor sie zu ist, träfe den Hauptchat.
    static func escapeAllowed(_ state: ControllerChatState) -> Bool {
        if viewOpen(state) { return !state.escapeSentJustNow }
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
