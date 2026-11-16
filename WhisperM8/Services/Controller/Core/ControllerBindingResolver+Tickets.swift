import Foundation

// Belegung im Ticket-Modus (WM8-91, Plan docs/plans/ticket-board-controller.md).
//
// Grundsatz: Hinter den Tickets kommt in keinem Chat etwas an — kein Enter,
// kein Escape, keine Taste, kein Diktat. Der Zusammenhang kennt keinen Chat;
// keine Aktion hier trägt eine Chat-ID oder schreibt in ein Terminal. Das
// prüft `ControllerTicketsSafetyTests` für jede Geste.
//
// Paket 1 (Öffnen und Umschalten): L2 getippt und gehalten wie im Chat
// (Rückweg und „Wohin“ mit dem Reiter „Tickets“), Options, R1 gehalten (nur
// die App-Raute), Create, Touchpad, L1 + R1. R2 tut nichts, mit Rückmeldung
// (Entscheidung E4: kein Diktat ohne sichtbares Ziel). Was das Board selbst
// bedient (Stick, Kreuz, Kreis, L1/R1 …), kommt mit Paket 2; bis dahin führt
// im Board nur ◀ in die Seitenleiste. Dort gelten die Tasten der Liste wie
// bisher, mit sichtbarer Markierung; sie schicken nichts in einen Chat.

extension ControllerBindingResolver {
    static func tickets(_ gesture: ControllerGesture, state: ControllerTicketState) -> ControllerAction? {
        switch gesture {
        case .tap(.l2): return .lastChat
        case .press(.options): return .menuToggle
        case .press(.create): return .newChat
        case .press(.touchpad): return .clipboardToggle
        // E4: Diktat erst mit dem Board-Chat (WM8-113).
        case .press(.r2): return .rejected
        default: break
        }
        // Mit dem Board im Fokus ist keine Markierung der Liste zu sehen: Eine
        // dort stehen gebliebene Zeile darf weder geöffnet, gestartet noch
        // geschlossen werden (Prüfung Paket 1). Nur ◀ führt sichtbar hinein,
        // wie aus einem Chat; die Tasten der Liste gelten mit ihrem Fokus.
        guard state.area == .list else {
            if case .move(.left, _, false) = gesture { return .enterList(step: 0) }
            return nil
        }
        return ticketsListFallback(gesture)
    }

    /// Mit der Liste links im Fokus: nur Gesten, die die Seitenleiste
    /// bedienen. Die Markierung ist zu sehen; Kreuz öffnet den markierten Chat
    /// sichtbar (und verlässt die Tickets).
    private static func ticketsListFallback(_ gesture: ControllerGesture) -> ControllerAction? {
        guard let action = list(gesture) else { return nil }
        switch action {
        case .listMove, .leaveList, .listActivate, .listFilter, .listCloseRow, .holdProgress,
             .holdProgressCancelled, .listStartRow:
            return action
        default:
            return nil
        }
    }

    /// Ebenen im Ticket-Modus: L2 „Wohin“ wie im Chat, R1 nur die App-Raute
    /// (die Chat-Raute bleibt aus, bis es den Board-Chat gibt), L1 „Schreiben“
    /// gibt es nicht. Unter L1 wirken die Tasten wie ohne Ebene.
    static func ticketsLayer(_ gesture: ControllerGesture, state: ControllerTicketState) -> ControllerAction? {
        switch gesture {
        case let .layerBegan(layer): return layer == .writing ? nil : .islandShow(layer)
        case let .inLayer(layer, inner):
            switch layer {
            case .whereTo: return whereToLayer(inner)
            case .writing: return tickets(inner, state: state)
            case .quickDraw:
                if inner == .press(.r2) { return .rejected }
                if case .press(let button) = inner, ControllerQuickDrawSlots.item(for: button) != nil || button == .l3 {
                    return .rejected
                }
                return appDiamond(inner)
            }
        default:
            return nil
        }
    }
}
