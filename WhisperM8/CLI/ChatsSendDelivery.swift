import Foundation

// MARK: - chats send: vormerken und Start bestätigen (WM8-70)

/// Was `chats send` mit `--queue-if-busy` oder `--wait-started` am Ende
/// sagt: gestartet, vorgemerkt oder nicht angekommen, mit Grund.
enum ChatsSendOutcome: Equatable {
    /// Zugestellt; ohne `--wait-started` wird nicht weiter geprüft.
    case delivered
    /// Zugestellt und der Chat arbeitet (nach `waited` Sekunden).
    case started(waited: TimeInterval)
    /// Der Chat war beschäftigt: in die Warteschlange gelegt.
    case queued(position: Int, status: String)
    /// Zugestellt, aber der Chat hat nicht angefangen.
    case notStarted(Reason)

    enum Reason: Equatable {
        /// Konto am Nutzungslimit; `until` = Ende laut Claude.
        case usageLimit(until: Date?)
        /// Der Chat wartet auf eine Antwort (Rückfrage, Freigabe).
        case awaitingInput
        case stopped
        case errored
        /// Frist abgelaufen, der Chat steht weiter auf `status`.
        case timeout(seconds: TimeInterval, status: String?)
        /// Die App war während des Wartens nicht mehr erreichbar.
        case appUnreachable
    }

    var keyword: String {
        switch self {
        case .delivered: return "delivered"
        case .started: return "started"
        case .queued: return "queued"
        case .notStarted: return "notStarted"
        }
    }

    var exitCode: Int32 {
        switch self {
        case .delivered, .started, .queued: return ChatsCLIExit.ok
        case .notStarted(.timeout): return ChatsCLIExit.timeout
        case .notStarted(.appUnreachable): return ChatsCLIExit.appUnreachable
        case .notStarted: return ChatsCLIExit.conflict
        }
    }

    /// Deutsche Zeile für den Menschen.
    func line(title: String, characters: Int) -> String {
        switch self {
        case .delivered:
            return "✓ zugestellt an \(title) (\(characters) Zeichen)"
        case .started(let waited):
            return "✓ gestartet: \(title) arbeitet (nach \(Int(waited.rounded())) s)"
        case .queued(let position, let status):
            return "✓ vorgemerkt als Nr. \(position) bei \(title) (Chat ist \(status); Zustellung beim nächsten Turn-Ende)"
        case .notStarted(let reason):
            return "✗ nicht angekommen: \(title) — \(Self.reasonText(reason))"
        }
    }

    static func reasonText(_ reason: Reason) -> String {
        switch reason {
        case .usageLimit(let until):
            return "Konto am Nutzungslimit" + (until.map { " bis \(ChatsUsageLimitFormat.clock($0))" } ?? "")
                + ". Nachricht nicht zugestellt; später senden, vormerken oder Konto wechseln."
        case .awaitingInput:
            return "der Chat wartet auf eine Antwort (Rückfrage oder Freigabe) und hat nicht angefangen."
        case .stopped:
            return "der Chat ist beendet."
        case .errored:
            return "der Chat steht im Fehlerzustand."
        case .timeout(let seconds, let status):
            return "nach \(Int(seconds)) s noch nicht gestartet (Status: \(status ?? "unbekannt"))."
        case .appUnreachable:
            return "die App ist nicht mehr erreichbar, Start nicht bestätigt."
        }
    }

    var reasonCode: String? {
        guard case .notStarted(let reason) = self else { return nil }
        switch reason {
        case .usageLimit: return "usageLimit"
        case .awaitingInput: return "awaitingInput"
        case .stopped: return "stopped"
        case .errored: return "errored"
        case .timeout: return "timeout"
        case .appUnreachable: return "appUnreachable"
        }
    }
}

/// Pur: nach dem Zustellen — arbeitet der Chat, wartet man weiter, oder ist
/// klar, dass er nicht anfängt? Grundlage ist der Status der App, nicht ein
/// wachsender Verlauf: Codex schreibt beim Antworten minutenlang nichts.
enum ChatsSendStartDecider {
    enum Step: Equatable {
        case started
        case keepWaiting
        case stop(ChatsSendOutcome.Reason)
    }

    static func evaluate(
        status: AgentSessionRuntimeStatus?,
        limitUntil: Date?,
        now: Date,
        deadline: Date,
        waitedSeconds: TimeInterval,
        limited: Bool = false
    ) -> Step {
        if limited || (limitUntil.map { $0 > now } ?? false) {
            return .stop(.usageLimit(until: limitUntil.flatMap { $0 > now ? $0 : nil }))
        }
        switch status {
        case .working: return .started
        case .stopped: return .stop(.stopped)
        case .errored: return .stop(.errored)
        case .awaitingInput, .idle, nil:
            guard now >= deadline else { return .keepWaiting }
            if status == .awaitingInput { return .stop(.awaitingInput) }
            return .stop(.timeout(seconds: waitedSeconds, status: status?.rawValue))
        }
    }
}

enum ChatsUsageLimitFormat {
    /// „04:20“ heute, sonst „15.11. 04:20“ (Ortszeit).
    static func clock(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "HH:mm" : "dd.MM. HH:mm"
        return formatter.string(from: date)
    }
}

/// Wartet nach dem Zustellen auf den Start (`--wait-started`).
enum ChatsSendStartWaiter {
    static let pollInterval: TimeInterval = 0.5
    /// Nach „arbeitet“ noch so lange auf eine Limit-Zeile achten: Trifft die
    /// Nachricht auf ein noch unbekanntes Limit, steht der Chat 1–2 s auf
    /// „arbeitet“, bevor Claude die Limit-Zeile schreibt (Review M4).
    static let confirmSeconds: TimeInterval = 3

    static func wait(
        targetID: UUID,
        seconds: TimeInterval,
        fetch: () -> ChatsLiveSnapshot? = { ChatsLiveMerge.fetch() },
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        now: () -> Date = { Date() }
    ) -> ChatsSendOutcome {
        let start = now()
        let deadline = start.addingTimeInterval(seconds)
        var startedAt: Date?
        while true {
            guard let snapshot = fetch() else {
                if let startedAt { return .started(waited: startedAt.timeIntervalSince(start)) }
                return .notStarted(.appUnreachable)
            }
            let live = snapshot[targetID]
            let current = now()
            switch ChatsSendStartDecider.evaluate(
                status: live?.runtimeStatus, limitUntil: live?.usageLimitUntil,
                now: current, deadline: deadline, waitedSeconds: current.timeIntervalSince(start),
                limited: live?.usageLimited ?? false
            ) {
            case .stop(.usageLimit(let until)):
                return .notStarted(.usageLimit(until: until))
            case .stop(let reason) where startedAt == nil:
                return .notStarted(reason)
            case .started where startedAt == nil:
                startedAt = current
            default:
                break
            }
            if let startedAt, current.timeIntervalSince(startedAt) >= confirmSeconds {
                return .started(waited: startedAt.timeIntervalSince(start))
            }
            sleep(pollInterval)
        }
    }
}

/// Steht ein Claude-Konto am Nutzungslimit? Belegt durch einen Chat dieses
/// Kontos, dessen letzte Antwort die Limit-Zeile ist (WM8-69). Das Konto als
/// Ganzes kennt die App aus dem Verlauf; die Kontingent-Anzeige wäre ein
/// zweiter, hier nicht nötiger Weg.
enum ChatsAccountUsageLimit {
    static func active(account: String, sessions: [AgentChatSession], now: Date = Date()) -> AgentUsageLimit? {
        let target = AccountMovePlanner.normalize(account) ?? ClaudeAccountProfiles.mainProfileName
        return sessions
            .filter { $0.provider == .claude }
            .filter { (AccountMovePlanner.normalize($0.claudeProfileName) ?? ClaudeAccountProfiles.mainProfileName) == target }
            .compactMap { $0.activeUsageLimit(at: now) }
            .max { ($0.resetsAt ?? .distantFuture) < ($1.resetsAt ?? .distantFuture) }
    }

    static func warning(account: String, limit: AgentUsageLimit, now: Date = Date()) -> String {
        let until = limit.resetsAt.map { " bis \(ChatsUsageLimitFormat.clock($0, now: now))" } ?? ""
        return "⚠︎ Konto \(account) ist am Nutzungslimit\(until) — der neue Chat arbeitet erst danach. "
            + "Anderes Konto: `chats move-account <ref> --to <konto>` oder `chats new … --account <konto>`."
    }
}
