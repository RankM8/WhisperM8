import Foundation

// Belegung der Ebenen (Runde 4, Controller-Insel): L1 „Schreiben“, R1
// „Schnellbefehle“, L2 „Wohin“. Getippt bleiben die drei Tasten, was sie
// waren (`ControllerBindingResolver+Chat.swift`).

extension ControllerBindingResolver {
    /// Gesten, die eine Ebene betreffen. Die Ebenen gelten nur im Chat (auch
    /// im Raster, dort für den Chat der fokussierten Kachel). In jedem anderen
    /// Zusammenhang — Liste, Verlauf, Menü, Dialog, Aufnahme — wirken die
    /// Tasten darin wie ohne Ebene. Das Ende einer Ebene schließt die Insel
    /// überall (außer in der Pause, die sie ohnehin schließt): Sie könnte
    /// offen sein, während der Zusammenhang wechselt.
    static func layerAction(for gesture: ControllerGesture, in context: ControllerContext) -> ControllerAction? {
        if case .paused = context { return nil }
        switch gesture {
        case let .layerEnded(layer): return layer == .whereTo ? .islandRelease : .islandClose
        case .layerCancelled: return .islandClose
        default: break
        }
        guard case let .chat(state) = context else {
            if case let .inLayer(_, inner) = gesture { return action(for: inner, in: context) }
            return nil
        }
        switch gesture {
        case let .layerBegan(layer): return .islandShow(layer)
        case let .inLayer(layer, inner):
            // Scrollen läuft nie über eine Ebene (der rechte Stick ist frei).
            switch layer {
            case .writing: return writingLayer(inner, state: state)
            case .quickDraw: return quickDrawLayer(inner, state: state)
            case .whereTo: return whereToLayer(inner)
            }
        default: return nil
        }
    }

    /// Bis Zeilenanfang löschen und Zeilenumbruch: dieselben Schutzregeln wie
    /// „Eingabe leeren“ — nur Claude und Codex (in einer Shell deutet ein
    /// Programm Ctrl+U und Ctrl+J womöglich anders), nicht in einer
    /// Rückfrage (dort wählt man aus).
    static func layerWritingAllowed(_ state: ControllerChatState) -> Bool {
        clearAllowed(state)
    }

    /// L1 gehalten. Viereck löscht sofort bis zum Zeilenanfang und gehalten
    /// Zeile für Zeile; Dreieck setzt einen Zeilenumbruch. R2 diktiert wie
    /// ohne Ebene. Runde 5: ◀ ▶ springen wortweise, ▲ ▼ zeilenweise im
    /// mehrzeiligen Entwurf, Kreuz fügt den neuesten Eintrag der
    /// Zwischenablage ein, Kreis schickt genau ein Escape, L3 macht rückgängig.
    private static func writingLayer(_ gesture: ControllerGesture, state: ControllerChatState) -> ControllerAction? {
        let allowed = layerWritingAllowed(state)
        switch gesture {
        case .press(.square): return allowed ? .chatKey(.deleteToLineStart) : layerWritingRejected(state)
        case .holdRepeat(.square): return allowed ? .chatKey(.deleteToLineStart) : nil
        case .press(.triangle): return allowed ? .chatKey(.newline) : layerWritingRejected(state)
        case .press(.r2): return .dictationToggle
        case let .move(direction, .dpad, isRepeat):
            switch direction {
            case .left, .right:
                guard allowed else { return isRepeat ? nil : layerWritingRejected(state) }
                return .chatKey(direction == .left ? .wordLeft : .wordRight)
            case .up, .down:
                guard allowed, lineMoveAllowed(direction, state: state) else {
                    return isRepeat ? nil : layerWritingRejected(state)
                }
                return .chatKey(direction == .up ? .up : .down)
            }
        case .press(.cross): return pasteAllowed(state) ? .pasteNewest : layerWritingRejected(state)
        case .press(.circle): return escapeOnceAllowed(state) ? .chatKey(.escape) : layerWritingRejected(state)
        case .press(.l3): return undoAllowed(state) ? .chatKey(.undo) : layerWritingRejected(state)
        default: return nil
        }
    }

    /// ▲ ▼ unter L1 nur im sichtbar mehrzeiligen Entwurf und nur, wenn der
    /// Cursor nicht schon in der ersten (▲) bzw. letzten (▼) Zeile steht: Dort
    /// holte Claude den Verlauf ins Feld, und Kreuz schickte ihn ab. Ist das
    /// Feld oder die Cursorzeile nicht ablesbar, geht es nicht.
    static func lineMoveAllowed(_ direction: ControllerDirection, state: ControllerChatState) -> Bool {
        guard let field = state.promptField, field.rows >= 2, let row = field.cursorRow else { return false }
        switch direction {
        case .up: return row > 0
        case .down: return row < field.rows - 1
        case .left, .right: return false
        }
    }

    /// Einfügen (L1 + Kreuz): in jedem lebenden Chat außer bei offener
    /// Rückfrage, auch in Shells (dort wie ⌘V, nur Text). Ob es ein Bild ist,
    /// prüft der Ausführer.
    static func pasteAllowed(_ state: ControllerChatState) -> Bool {
        state.acceptsKeys && state.status != .awaitingInput
            && (state.profile == .claude || state.profile == .codex || state.profile == .shell)
    }

    /// Genau ein Escape (L1 + Kreis), unabhängig vom Status und ohne die
    /// 1-s-Sperre — ausdrücklich gewollt. Nur Claude und Codex (L1-Regel).
    static func escapeOnceAllowed(_ state: ControllerChatState) -> Bool {
        writingKeysAllowed(state)
    }

    /// Rückgängig (L1 + L3): nur Claude (Ctrl+_), nicht in einer Rückfrage.
    /// Codex hat im Standard-Editor kein Undo.
    static func undoAllowed(_ state: ControllerChatState) -> Bool {
        state.acceptsKeys && state.profile == .claude && state.status != .awaitingInput
    }

    /// Ausführliches Transkript (R1 + L3): nur Claude (Ctrl+O).
    static func transcriptToggleAllowed(_ state: ControllerChatState) -> Bool {
        state.acceptsKeys && state.profile == .claude
    }

    /// „Geht nicht“ in einem lebenden Chat (Shell, Rückfrage); bei beendetem still.
    private static func layerWritingRejected(_ state: ControllerChatState) -> ControllerAction? {
        state.acceptsKeys ? .rejected : nil
    }

    /// R1 gehalten: die Raute. Ob ein Eintrag geht, entscheidet der Ausführer
    /// mit denselben Regeln wie das Options-Menü (`ControllerMenuModel.isEnabled`).
    private static func quickDrawLayer(_ gesture: ControllerGesture, state: ControllerChatState) -> ControllerAction? {
        if gesture == .press(.r2) { return .dictationToggle }
        if gesture == .press(.l3) {
            return transcriptToggleAllowed(state) ? .chatKey(.toggleTranscript) : layerWritingRejected(state)
        }
        guard case let .press(button) = gesture, let item = ControllerQuickDrawSlots.item(for: button) else {
            return nil
        }
        return .quickDraw(item)
    }

    /// L2 gehalten: Stick oder Steuerkreuz hoch/runter öffnen die Liste und
    /// bewegen die Markierung (mit Wiederholung), links/rechts wechseln den
    /// Reiter (ein Druck, ein Schritt). Kreuz wechselt, Kreis bricht ab,
    /// Dreieck springt zum nächsten wartenden Chat, R2 wechselt und diktiert.
    /// Das Touchpad öffnet den Zwischenablage-Verlauf — überall, auch wenn die
    /// Insel offen ist (außerhalb des Chats kommt das schon über die Tasten
    /// ohne Ebene).
    private static func whereToLayer(_ gesture: ControllerGesture) -> ControllerAction? {
        switch gesture {
        case .move(.up, _, _): return .islandMove(step: -1)
        case .move(.down, _, _): return .islandMove(step: 1)
        case .move(.left, _, false): return .islandTab(step: -1)
        case .move(.right, _, false): return .islandTab(step: 1)
        case .press(.cross): return .islandCommit
        case .press(.circle): return .islandCancel
        case .press(.triangle): return .islandNextWaiting
        case .press(.square): return .islandReopenClosed
        case .press(.r2): return .islandCommitAndDictate
        case .press(.touchpad): return .clipboardToggle
        default: return nil
        }
    }
}
