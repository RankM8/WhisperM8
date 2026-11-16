import Foundation

/// Wohin ein Diktat geht: wie bisher ins vordere Programm oder direkt in das
/// Terminal eines bestimmten Agent-Chats.
enum DictationDeliveryTarget: Equatable {
    case frontApp
    case agentChat(sessionID: UUID)
    /// Board-Chat im Ticket-Modus (WM8-113): ein Diktat, das ins vordere
    /// Programm gesprochen und dorthin umgelenkt wurde. Geht nie mit Senden
    /// hinaus und nie in eine offene Frage; dieselben Regeln wie „→ Jarvis“.
    case boardChat(sessionID: UUID)

    /// Chat, in den das Diktat geht; `nil` = vorderes Programm.
    var sessionID: UUID? {
        switch self {
        case .frontApp: return nil
        case .agentChat(let id), .boardChat(let id): return id
        }
    }

    /// Ein umgelenktes Diktat wird nie abgeschickt.
    var neverSubmits: Bool {
        if case .boardChat = self { return true }
        return false
    }
}

/// Ziel plus „danach senden“. Das Ziel merkt sich der Coordinator beim Start
/// der Aufnahme, `submit` wird erst beim angenommenen Stopp festgelegt.
struct DictationDelivery: Equatable {
    var target: DictationDeliveryTarget = .frontApp
    var submit: Bool = false

    static let frontApp = DictationDelivery()

    /// Was beim Stopp gilt: Ein umgelenktes Diktat geht nie mit Senden hinaus,
    /// auch wenn der Stopp „senden“ verlangt (Kreuz am Controller).
    static func atStop(target: DictationDeliveryTarget, submit: Bool) -> DictationDelivery {
        DictationDelivery(target: target, submit: submit && !target.neverSubmits)
    }
}

/// Zustand des Ziel-Chats im Moment der Zustellung.
enum DictationChatState: Equatable {
    /// Läuft und nimmt Text an.
    case ready
    /// Der Agent wartet auf eine Antwort oder Freigabe.
    case awaitingInput
    /// Claudes Frage-Dialog mit freiem Textfeld ist offen, doppelt erkannt
    /// (`ClaudeQuestionTextGate`): Text darf als Einfüge-Block hinein.
    case questionAcceptsText
    /// Die TUI fährt noch hoch.
    case starting
    /// Konto am Nutzungslimit (WM8-69): Text würde verbraucht, ohne dass der
    /// Chat arbeitet, und bräche Claudes automatisches Weitermachen ab.
    case usageLimited
    /// Kein laufendes Terminal.
    case notRunning
}

/// Warum der Text nur in der Zwischenablage gelandet ist.
enum DictationClipboardReason: Equatable {
    case decisionPending
    case chatStarting
    case chatUsageLimited
    case chatNotRunning
    case writeFailed
}

enum DictationDeliveryDecision: Equatable {
    /// Der bisherige Weg (Zwischenablage, optional Auto-Paste).
    case frontApp
    case writeToChat(sessionID: UUID, submit: Bool)
    /// In Claudes offene Frage, ins freie Textfeld, nie mit Enter.
    case writeToQuestion(sessionID: UUID)
    case clipboardOnly(DictationClipboardReason)
    /// Nichts zu liefern (leerer Text an einen Chat).
    case nothing
}

/// Entscheidet rein aus Ziel, Text und Chat-Zustand, was mit dem fertigen
/// Diktat passiert. Kein App-Zustand, damit jede Regel ohne laufende App
/// prüfbar bleibt.
enum DictationDeliveryRouter {
    static func decide(
        delivery: DictationDelivery,
        text: String,
        chatState: (UUID) -> DictationChatState,
        approvalPending: (UUID) -> Bool = { _ in false }
    ) -> DictationDeliveryDecision {
        switch delivery.target {
        case .boardChat(let sessionID):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .nothing }
            // Dieselbe Prüfung wie „→ Jarvis“: auch Claudes Frage mit Textfeld
            // und eine Freigabe laut Sendeweg der CLI zählen als „wartet“.
            switch BoardChatInputRules.refusal(state: chatState(sessionID), approvalPending: approvalPending(sessionID)) {
            case nil: return .writeToChat(sessionID: sessionID, submit: false)
            case .awaitingInput: return .clipboardOnly(.decisionPending)
            case .starting: return .clipboardOnly(.chatStarting)
            case .usageLimited: return .clipboardOnly(.chatUsageLimited)
            case .notRunning, .noBoardChat: return .clipboardOnly(.chatNotRunning)
            }
        case .frontApp:
            // Der Weg ins vordere Programm bleibt, wie er ist, auch bei leerem Text.
            return .frontApp
        case .agentChat(let sessionID):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .nothing
            }
            switch chatState(sessionID) {
            case .ready:
                return .writeToChat(sessionID: sessionID, submit: delivery.submit)
            case .questionAcceptsText:
                // Nur das Textfeld einer erkannten Frage; das Senden übernimmt
                // immer der Nutzer (bei Mehrfachauswahl nähme Enter den Haken
                // wieder weg).
                return .writeToQuestion(sessionID: sessionID)
            case .awaitingInput:
                // Freigabe, Plan oder nicht sicher erkannt: Nie Text hinein,
                // er könnte dort als Antwort gelten.
                return .clipboardOnly(.decisionPending)
            case .starting:
                return .clipboardOnly(.chatStarting)
            case .usageLimited:
                return .clipboardOnly(.chatUsageLimited)
            case .notRunning:
                return .clipboardOnly(.chatNotRunning)
            }
        }
    }
}
