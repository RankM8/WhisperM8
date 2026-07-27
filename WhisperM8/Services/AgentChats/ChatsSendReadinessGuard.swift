import Foundation

/// Schutz gegen den belegten Start-Race von `resume` + sofortigem `send`.
///
/// Reproduziert am 2026-07-26: Nach `resume` meldete `send` `exit=0` und
/// „delivered", während die Transcript-Revision 30 Sekunden unverändert blieb —
/// der Prompt kam nie an. Ursachenkette:
///
/// 1. `AgentSessionLifecycleState.launching` bildet auf `runtimeStatus == .idle`
///    ab (bewusst, damit ein startender Chat in der Sidebar nicht pulsiert).
/// 2. Der Send-Guard erlaubt `idle` per Default.
/// 3. `sendPrompt` schreibt Bracketed-Paste-Bytes blind in die PTY — es gibt
///    keinerlei Rückmeldung, ob die TUI sie verarbeitet hat.
///
/// Ergebnis: Der Paste landete in einer TUI, die noch ihren Verlauf lud, und
/// wurde je nach Timing verworfen oder gepuffert. Beim Retry erschienen dann
/// beide Prompts — ein stiller Doppelauftrag.
///
/// Der Guard schneidet Schritt 2 ab: Im Startfenster wird gar nicht erst
/// geschrieben. Bewusst pur (kein App-Zustand), damit die Entscheidung ohne
/// laufende App prüfbar bleibt.
enum ChatsSendReadinessGuard {
    /// Ergebnis der Bereitschaftsprüfung.
    enum Decision: Equatable {
        /// Schreiben erlaubt.
        case allowed
        /// Chat fährt noch hoch — nicht schreiben.
        case notReady(sinceSec: Int?)
    }

    /// - Parameter lifecycle: Zustand aus dem Koordinator. `nil` = die App
    ///   kennt die Session nicht (extern gestartet) — dann greift wie bisher
    ///   nur der Runtime-Status, wir blockieren nicht zusätzlich.
    /// - Parameter launchedAt: Startzeitpunkt, für die Meldung.
    static func decide(
        lifecycle: AgentSessionLifecycleState?,
        launchedAt: Date? = nil,
        now: Date = Date()
    ) -> Decision {
        guard case .launching = lifecycle else { return .allowed }
        let since = launchedAt.map { Int(max(0, now.timeIntervalSince($0))) }
        return .notReady(sinceSec: since)
    }

    /// Fehlermeldung mit dem sicheren Ausweg. `enqueue` ist hier die richtige
    /// Antwort, weil die Warteschlange erst bei bestätigtem Turn-Ende zustellt
    /// und höchstens einmal liefert.
    static func message(for decision: Decision) -> String? {
        guard case .notReady(let since) = decision else { return nil }
        let age = since.map { " (seit \($0) s)" } ?? ""
        return "Chat startet noch\(age) — ein Prompt würde jetzt in einer noch nicht "
            + "bereiten TUI landen und verloren gehen oder doppelt ankommen. "
            + "Nutze `chats enqueue` (stellt sicher zu, höchstens einmal) oder warte die Bereitschaft ab."
    }
}
