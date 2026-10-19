import Foundation

/// Darf ein programmatischer Prompt (`chats send`, Folgeauftrag) jetzt in die
/// TUI? Pur, damit die Fälle ohne laufende App testbar sind.
///
/// - Entwurf im Eingabefeld: Der Paste hinge den Auftrag an den halb getippten
///   Text des Users und schickte beides ab — der Entwurf wäre verloren
///   (LR-CLI-002). `send` lehnt ab (Ausweg `enqueue` oder `--force`), die Queue
///   wartet aufs nächste Turn-Ende.
/// - `launching`: Die TUI ist noch nicht bereit; ein Folgeauftrag ging dort
///   still verloren und stand trotzdem auf „zugestellt“ (LR-CLI-003).
enum PromptDeliveryGate {
    enum Decision: Equatable {
        case deliver
        case draftPending
        case notReady
        case busy(String)
    }

    static func forQueue(
        runtime: AgentSessionRuntimeStatus?,
        lifecycle: AgentSessionLifecycleState?,
        mayHaveUnsentInput: Bool
    ) -> Decision {
        if case .launching = lifecycle { return .notReady }
        if let runtime, runtime != .idle { return .busy(runtime.rawValue) }
        if mayHaveUnsentInput { return .draftPending }
        return .deliver
    }

    static func sendBlockedByDraft(mayHaveUnsentInput: Bool, force: Bool) -> Bool {
        mayHaveUnsentInput && !force
    }

    static let draftMessage = "Im Eingabefeld des Ziel-Chats steht ein nicht abgeschickter Entwurf — "
        + "der Prompt würde daran angehängt und beides abgeschickt. Ausweg: `whisperm8 chats enqueue` "
        + "(wird nach dem nächsten Turn zugestellt) oder bewusst `--force`."
}
