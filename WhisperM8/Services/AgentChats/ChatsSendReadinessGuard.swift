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

    /// Meldung, wenn der Chat am Nutzungslimit steht (WM8-69); `nil` sonst.
    /// Die Warteschlange stellt erst nach dem Limit zu. Slash-Befehle
    /// (`/login`, `/model`, `/rate-limit-options`) lässt der Sende-Pfad durch:
    /// sie sind der Ausweg aus dem Limit.
    static func usageLimitMessage(_ limit: AgentUsageLimit?, now: Date = Date()) -> String? {
        guard let limit, limit.isActive(at: now) else { return nil }
        let until = limit.resetsAt.map { " bis \(ChatsUsageLimitFormat.clock($0, now: now))" } ?? ""
        if limit.autoContinues == true {
            return "Konto am Nutzungslimit\(until); Claude macht dann von selbst weiter. Ein Prompt jetzt würde "
                + "verbraucht und das automatische Weitermachen abbrechen. Nutze `chats enqueue` (stellt nach dem "
                + "fortgesetzten Turn zu) oder wechsle das Konto."
        }
        return "Konto am Nutzungslimit\(until) — der Prompt würde verbraucht, ohne dass der Chat arbeitet. "
            + "Nutze `chats enqueue` (stellt nach dem Limit zu) oder wechsle das Konto."
    }

    /// Hinweis bei einem Limit an einem anderen Chat desselben Kontos, das
    /// nicht sperren darf (Guthaben für ein Modell, unbekannte Art, ohne Ende).
    static func creditsWarning(_ limit: AgentUsageLimit) -> String {
        if limit.kind == "model_requires_usage_credits" {
            return "Achtung: Ein anderer Chat dieses Kontos hat das Guthaben-Limit für sein Modell erreicht. "
                + "Nutzt dieser Chat dasselbe Modell, arbeitet er nicht und der Prompt ist verbraucht."
        }
        return "Achtung: Ein anderer Chat dieses Kontos steht am Nutzungslimit (\(limit.kind)). "
            + "Gilt es auch hier, arbeitet dieser Chat nicht und der Prompt ist verbraucht."
    }

    /// Eintrag für `sessions.live` (aus dem Request-Handler ausgelagert).
    /// `usageLimitResetsAt` nur bei aktivem Limit (WM8-69).
    static func liveEntry(session: AgentChatSession, isRunning: Bool,
                          runtime: AgentSessionRuntimeStatus?, hasStarted: Bool = false,
                          pid: Int32? = nil, now: Date = Date()) -> [String: Any] {
        var entry: [String: Any] = [
            "sessionID": session.id.uuidString,
            "runtimeStatus": runtime?.rawValue ?? "unknown",
            "isAttachedPTY": isRunning,
            "hasStarted": hasStarted,
            "canSend": isRunning,
            "canInterrupt": isRunning && runtime == .working,
            "pid": AgentControlRequestHandler.livePID(pid),
        ]
        if let limit = session.activeUsageLimit(at: now) {
            entry["usageLimit"] = limit.kind
            if let resetsAt = limit.resetsAt { entry["usageLimitResetsAt"] = ChatsOutput.iso(resetsAt) }
        }
        return entry
    }

    /// Fehlermeldung mit dem sicheren Ausweg. `enqueue` ist hier die richtige
    /// Antwort, weil die Warteschlange erst bei bestätigtem Turn-Ende zustellt
    /// und höchstens einmal liefert.
    static func message(for decision: Decision, adopted: Bool = false) -> String? {
        guard case .notReady(let since) = decision else { return nil }
        if adopted {
            // WM8-97: nach einem Neustart übernommen, Status noch ohne Beleg.
            return "Chat wurde beim Neustart übernommen und hat sich noch nicht gemeldet — ein Prompt könnte "
                + "in laufende Arbeit oder eine offene Frage geraten. Nutze `chats enqueue` (stellt zu, sobald der "
                + "Chat bereit ist) oder warte, bis er sich meldet (höchstens zwei Minuten)."
        }
        let age = since.map { " (seit \($0) s)" } ?? ""
        return "Chat startet noch\(age) — ein Prompt würde jetzt in einer noch nicht "
            + "bereiten TUI landen und verloren gehen oder doppelt ankommen. "
            + "Nutze `chats enqueue` (stellt sicher zu, höchstens einmal) oder warte die Bereitschaft ab."
    }
}
