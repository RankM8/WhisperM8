import Foundation

/// Darf ein programmatischer Prompt (`chats send`, Folgeauftrag) jetzt in die
/// TUI? Pur, damit die Fälle ohne laufende App testbar sind.
///
/// - Entwurf im Eingabefeld: Der Paste hinge den Auftrag an den halb getippten
///   Text des Users und schickte beides ab — der Entwurf wäre verloren
///   (LR-CLI-002). `send` lehnt ab (Ausweg `enqueue` oder `--force`), die Queue
///   wartet aufs nächste Turn-Ende.
///   Mit zählt von der App eingefügter, nicht abgeschickter Text (Diktat ohne
///   Senden, „→ Jarvis“): Den gibt ein Turn-Start nicht frei, nur Enter,
///   Ctrl+C, Absenden oder ein sichtbar leeres Feld (WM8-121).
/// - `launching`: Die TUI ist noch nicht bereit; ein Folgeauftrag ging dort
///   still verloren und stand trotzdem auf „zugestellt“ (LR-CLI-003).
enum PromptDeliveryGate {
    enum Decision: Equatable {
        case deliver
        case draftPending
        case notReady
        case busy(String)
    }

    /// - Parameter inputPending: im Startfenster fehlt Claudes Eingabefeld
    ///   noch (WM8-100); `visibleDraft`: am Bildschirm steht Text im Feld;
    ///   `fieldVisiblyEmpty`: am Bildschirm ist das Feld leer, das schlägt die
    ///   Tasten-Schätzung (WM8-64).
    static func forQueue(
        runtime: AgentSessionRuntimeStatus?,
        lifecycle: AgentSessionLifecycleState?,
        mayHaveUnsentInput: Bool,
        inputPending: Bool = false,
        visibleDraft: Bool = false,
        fieldVisiblyEmpty: Bool = false
    ) -> Decision {
        if case .launching = lifecycle { return .notReady }
        if inputPending { return .notReady }
        if let runtime, runtime != .idle { return .busy(runtime.rawValue) }
        if (mayHaveUnsentInput && !fieldVisiblyEmpty) || visibleDraft { return .draftPending }
        return .deliver
    }

    static func sendBlockedByDraft(mayHaveUnsentInput: Bool, force: Bool, fieldVisiblyEmpty: Bool = false) -> Bool {
        mayHaveUnsentInput && !force && !fieldVisiblyEmpty
    }

    static func draftMessage(insertedText: Bool) -> String {
        insertedText ? insertedTextMessage : draftMessage
    }

    static let insertedTextMessage = "Im Eingabefeld des Ziel-Chats steht Text, den die App eingefügt und noch "
        + "niemand abgeschickt hat (Diktat ohne Senden, „→ Jarvis“, `send --no-submit`). Der Prompt würde daran "
        + "angehängt und beides abgeschickt. Ausweg: `whisperm8 chats enqueue <ref> \"…\"` (wartet, bis der Text "
        + "abgeschickt oder gelöscht ist) oder bewusst `whisperm8 chats send <ref> --force …`."

    static let draftMessage = "Im Eingabefeld des Ziel-Chats steht vermutlich ein nicht abgeschickter Entwurf — "
        + "der Prompt würde daran angehängt und beides abgeschickt. Ausweg: `whisperm8 chats enqueue <ref> \"…\"` "
        + "(wird zugestellt, sobald der Chat fertig ist) oder bewusst `whisperm8 chats send <ref> --force …`."
}
