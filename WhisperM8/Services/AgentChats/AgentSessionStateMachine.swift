import Foundation

// MARK: - Lifecycle-Zustand

/// Feingranularer Lebenszyklus einer Agent-Session — die interne Wahrheit des
/// `AgentSessionStatusCoordinator`. Bewusst reicher als der UI-Status
/// (`AgentSessionRuntimeStatus`): „Terminal gestartet, wartet auf ersten
/// Prompt" (`launching`/`ready`) darf in der Sidebar NICHT als Arbeit
/// pulsieren — genau das war der „neuer Chat wirkt aktiv"-Bug.
enum AgentSessionLifecycleState: Equatable {
    /// Session existiert, Prozess nie gestartet.
    case created
    /// PTY/Spawn läuft, noch kein `SessionStart`-Hook gesehen.
    case launching
    /// Claude ist bereit und wartet auf einen Prompt (kein Turn aktiv).
    case ready
    /// Ein Turn läuft (Prompt gesendet, Tools laufen, Antwort streamt).
    case working
    /// Claude wartet auf eine User-Entscheidung (Permission/Frage/Plan).
    case awaitingInput(AwaitingInputKind)
    /// Turn sauber beendet — Anlass für Notification/Ton.
    case turnDone
    /// Prozess beendet (Exit 0).
    case stopped
    /// Prozess beendet (Exit ≠ 0).
    case errored

    /// Mapping auf den bestehenden UI-Status der Sidebar-Indikatoren.
    /// `launching`/`ready`/`turnDone` sind bewusst alle `.idle` (statischer
    /// Punkt) — der Unterschied ist nur für Effekte relevant, nicht optisch.
    var runtimeStatus: AgentSessionRuntimeStatus? {
        switch self {
        case .created:
            return nil
        case .launching, .ready, .turnDone:
            return .idle
        case .working:
            return .working
        case .awaitingInput:
            return .awaitingInput
        case .stopped:
            return .stopped
        case .errored:
            return .errored
        }
    }
}

/// Warum eine Session auf User-Input wartet — steuert den Notification-Text.
enum AwaitingInputKind: String, Equatable {
    /// `PermissionRequest`-Hook: echter Berechtigungs-Dialog.
    case permission
    /// `PreToolUse` mit `tool_name == "AskUserQuestion"`: Claude stellt eine Frage.
    case question
    /// `PreToolUse` mit `tool_name == "ExitPlanMode"`: Plan wartet auf Freigabe.
    case planApproval

    var notificationLabel: String {
        switch self {
        case .permission: return "wartet auf eine Berechtigung"
        case .question: return "hat eine Frage"
        case .planApproval: return "wartet auf Plan-Freigabe"
        }
    }
}

// MARK: - Signale

/// Alle Ereignisquellen, die den Session-Zustand bewegen können: Hook-Events,
/// Transcript-Watcher-Entscheidungen und Prozess-Lifecycle.
enum AgentSessionSignal: Equatable {
    case processLaunched
    /// Timeout ohne `SessionStart` nach dem Launch — Hooks vermutlich stumm,
    /// wir gehen degradiert auf `ready` statt ewig `launching`.
    case launchGraceExpired
    case sessionStarted
    case userPromptSubmitted
    case toolWillRun(toolName: String?)
    case toolDidRun
    case permissionRequested
    case turnStopped
    case sessionEnded(reason: String?)
    /// Transcript-Decider meldet Aktivität (`.working`).
    case transcriptActivity
    /// Transcript-Decider meldet Ruhe (`.idle`); `turnFinished` = frisch
    /// erkanntes Turn-Ende (dedupliziert via `priorTurnFinishedAt`).
    case transcriptIdle(turnFinished: Bool)
    case processTerminated(exitCode: Int32?)

    /// Mapping Hook-Event → Signal. `nil` für Events ohne Status-Relevanz
    /// (defensive `Notification`, unbekannte Namen).
    init?(hookEvent: ClaudeHookEvent) {
        switch hookEvent.hookEventName {
        case .sessionStart:
            self = .sessionStarted
        case .sessionEnd:
            self = .sessionEnded(reason: hookEvent.reason)
        case .userPromptSubmit:
            self = .userPromptSubmitted
        case .preToolUse:
            self = .toolWillRun(toolName: hookEvent.toolName)
        case .postToolUse:
            self = .toolDidRun
        case .permissionRequest:
            self = .permissionRequested
        case .stop:
            self = .turnStopped
        case .notification, .other:
            return nil
        }
    }
}

// MARK: - Effekte

/// Seiteneffekte eines Zustandswechsels. Entstehen NUR bei echten Übergängen —
/// idempotente Signale (Doppel-Stop, wiederholtes PermissionRequest) erzeugen
/// keine Effekte. Das ist die Dedup-Garantie für Notifications.
enum AgentSessionEffect: Equatable {
    /// Turn wurde beendet → „Agent fertig"-Notification + optionaler Ton.
    case turnCompleted
    /// Session braucht eine User-Entscheidung → „Rückfrage"-Notification.
    case inputRequested(AwaitingInputKind)
}

// MARK: - Reducer

/// Purer Zustands-Reducer: `(Zustand, Signal) → (neuer Zustand, Effekte)`.
/// Kein IO, keine Zeit, keine Abhängigkeiten — vollständig unit-testbar.
///
/// Prioritätsregeln:
/// - Hooks schlagen Transcript: in `awaitingInput` werden Decider-Meinungen
///   ignoriert (die JSONL zeigt während eines Permission-Dialogs „working").
/// - `stopped`/`errored` verlässt man nur über `processLaunched`.
/// - `SessionStart` downgraded nie einen laufenden Turn (Auto-Compact feuert
///   `SessionStart` mitten im Turn).
enum AgentSessionStateMachine {
    struct Transition: Equatable {
        var state: AgentSessionLifecycleState
        var effects: [AgentSessionEffect] = []
    }

    static func reduce(
        state: AgentSessionLifecycleState,
        signal: AgentSessionSignal
    ) -> Transition {
        // Prozessende ist final — nur ein neuer Launch belebt die Session.
        if state == .stopped || state == .errored {
            if case .processLaunched = signal {
                return Transition(state: .launching)
            }
            return Transition(state: state)
        }

        switch signal {
        case .processLaunched:
            return Transition(state: .launching)

        case .launchGraceExpired:
            guard state == .launching else { return Transition(state: state) }
            return Transition(state: .ready)

        case .sessionStarted:
            // Nur aus „unklaren" Zuständen nach ready — ein laufender Turn
            // bleibt unangetastet (Auto-Compact/Clear feuern SessionStart).
            switch state {
            case .created, .launching:
                return Transition(state: .ready)
            case .ready, .working, .awaitingInput, .turnDone:
                return Transition(state: state)
            case .stopped, .errored:
                return Transition(state: state) // unreachable (Guard oben)
            }

        case .userPromptSubmitted:
            return Transition(state: .working)

        case .toolWillRun(let toolName):
            if let kind = Self.awaitingKind(forToolName: toolName) {
                if state == .awaitingInput(kind) {
                    return Transition(state: state)
                }
                return Transition(state: .awaitingInput(kind), effects: [.inputRequested(kind)])
            }
            return Transition(state: .working)

        case .toolDidRun:
            return Transition(state: .working)

        case .permissionRequested:
            if state == .awaitingInput(.permission) {
                return Transition(state: state)
            }
            return Transition(state: .awaitingInput(.permission), effects: [.inputRequested(.permission)])

        case .turnStopped:
            if state == .turnDone {
                return Transition(state: state)
            }
            return Transition(state: .turnDone, effects: [.turnCompleted])

        case .sessionEnded:
            if case .awaitingInput = state {
                return Transition(state: .ready)
            }
            return Transition(state: state)

        case .transcriptActivity:
            if case .awaitingInput = state {
                return Transition(state: state) // Hook weiß es besser
            }
            return Transition(state: .working)

        case .transcriptIdle(let turnFinished):
            if case .awaitingInput = state {
                return Transition(state: state) // konservativ: Hook räumt auf
            }
            if turnFinished {
                if state == .turnDone {
                    return Transition(state: state) // Stop-Hook war schneller
                }
                return Transition(state: .turnDone, effects: [.turnCompleted])
            }
            // Ruhe ohne frisches Turn-Ende: bereit, aber kein Anlass für Effekte.
            switch state {
            case .turnDone:
                return Transition(state: state)
            default:
                return Transition(state: .ready)
            }

        case .processTerminated(let exitCode):
            let failed = (exitCode ?? 0) != 0
            return Transition(state: failed ? .errored : .stopped)
        }
    }

    /// Tools, deren `PreToolUse` „wartet auf User-Entscheidung" bedeutet.
    /// Deckt genau die Fälle ab, die bisher private User-Hooks
    /// (AskUserQuestion/ExitPlanMode-Matcher) erkannt haben.
    static func awaitingKind(forToolName toolName: String?) -> AwaitingInputKind? {
        switch toolName {
        case "AskUserQuestion":
            return .question
        case "ExitPlanMode":
            return .planApproval
        default:
            return nil
        }
    }
}
