import Foundation

// MARK: - Zustandsachsen (Vertrag wm8.*/1)

/// Aufbewahrung. Sagt NICHTS über laufende Prozesse aus — genau diese
/// Vermischung im alten `running` war die Quelle der Anomalie „running ohne
/// Prozess" nach einem App-Absturz.
enum ChatsCatalogState: String, Equatable {
    case active
    case inactive
    case archived

    static func from(_ status: AgentChatStatus) -> ChatsCatalogState {
        switch status {
        case .archived: return .archived
        case .closed: return .inactive
        default: return .active
        }
    }
}

/// Ausführung. `worker` und `attachment` sind bewusst GETRENNT: Bei
/// Hintergrund-Agenten ist das PTY nur ein `claude attach` — es zu killen
/// trennt die Anzeige, während der Agent im Supervisor-Daemon weiterläuft.
struct ChatsExecutionAxis: Equatable {
    enum Mode: String, Equatable { case foreground, background, none, unknown }
    enum Worker: String, Equatable { case alive, exited, missing, unknown }
    enum Attachment: String, Equatable { case attached, detached, none, unknown }

    var mode: Mode
    var worker: Worker
    var attachment: Attachment

    var json: [String: Any] {
        ["mode": mode.rawValue, "worker": worker.rawValue, "attachment": attachment.rawValue]
    }
}

/// Gespräch. `launching` ist ein EIGENER Wert und darf nicht auf `ready` oder
/// `idle` abgebildet werden — ein startender Chat sieht sonst aufnahmebereit
/// aus und nimmt Prompts an, die verloren gehen (belegter Start-Race).
struct ChatsConversationAxis: Equatable {
    enum State: String, Equatable {
        case launching, ready, working, needsInput, turnDone, stopped, errored, unknown
    }

    var state: State
    /// Nur bei `needsInput`: worauf gewartet wird.
    var reason: AwaitingInputKind?
    var sinceSec: Int?

    var json: [String: Any] {
        var dict: [String: Any] = ["state": state.rawValue]
        if let reason { dict["reason"] = reason.rawValue }
        if let sinceSec { dict["sinceSec"] = sinceSec }
        return dict
    }
}

/// Belastbarkeit der Aussage. Ohne diese Achse sähe eine Transcript-Schätzung
/// genauso verbindlich aus wie ein Hook-Beleg.
struct ChatsEvidenceAxis: Equatable {
    enum Quality: String, Equatable { case observed, inferred, unknown }

    var quality: Quality
    /// `app`, `hook`, `transcript`, `supervisorJob`
    var source: String
    var ageMs: Int?

    var json: [String: Any] {
        var dict: [String: Any] = ["quality": quality.rawValue, "source": source]
        if let ageMs { dict["ageMs"] = ageMs }
        return dict
    }
}

/// Die vier Achsen einer Session, plus abgeleitete Hinweise.
struct ChatsSessionAxes: Equatable {
    var catalog: ChatsCatalogState
    var execution: ChatsExecutionAxis
    var conversation: ChatsConversationAxis
    var evidence: ChatsEvidenceAxis
}

// MARK: - Ableitung

/// Baut die Achsen aus den vorhandenen Quellen. Pur: alle Eingaben werden
/// übergeben, nichts wird gelesen — damit jede Kombination testbar bleibt,
/// auch die anomalen.
enum ChatsSessionAxesBuilder {
    /// - Parameter lifecycle: feingranularer Zustand der App (`nil` = die App
    ///   kennt die Session nicht).
    /// - Parameter runtime: Laufzeitstatus aus Live-Merge oder Schätzung.
    /// - Parameter isAttachedPTY: `nil` = keine Live-Information.
    static func build(
        status: AgentChatStatus,
        kind: AgentSessionKind,
        lifecycle: String?,
        runtimeStatus: AgentSessionRuntimeStatus?,
        awaitingReason: AwaitingInputKind?,
        isAttachedPTY: Bool?,
        source: String,
        statusSince: Date?,
        observedAt: Date?,
        now: Date
    ) -> ChatsSessionAxes {
        let catalog = ChatsCatalogState.from(status)

        // Hintergrund-Chats: Das PTY belegt nur die Anzeige. Ohne echten
        // Supervisor-Job-Status bleibt `worker` bewusst `unknown` statt
        // fälschlich `alive`.
        let isBackground = kind == .backgroundChat
        let attachment: ChatsExecutionAxis.Attachment = {
            guard let isAttachedPTY else { return .unknown }
            return isAttachedPTY ? .attached : .detached
        }()
        let worker: ChatsExecutionAxis.Worker = {
            if isBackground { return .unknown }
            guard let isAttachedPTY else {
                return runtimeStatus == .stopped ? .exited : .unknown
            }
            if isAttachedPTY { return .alive }
            return runtimeStatus == .stopped ? .exited : .missing
        }()
        let mode: ChatsExecutionAxis.Mode = {
            if isBackground { return .background }
            if isAttachedPTY == true { return .foreground }
            if isAttachedPTY == false { return .none }
            return .unknown
        }()

        let conversationState = conversation(lifecycle: lifecycle, runtimeStatus: runtimeStatus)
        let sinceSec = statusSince.map { Int(max(0, now.timeIntervalSince($0))) }

        let quality: ChatsEvidenceAxis.Quality = {
            switch source {
            case "app", "hook", "supervisorJob": return .observed
            case "transcriptEstimate", "transcript": return .inferred
            default: return .unknown
            }
        }()

        return ChatsSessionAxes(
            catalog: catalog,
            execution: ChatsExecutionAxis(mode: mode, worker: worker, attachment: attachment),
            conversation: ChatsConversationAxis(
                state: conversationState,
                reason: conversationState == .needsInput ? awaitingReason : nil,
                sinceSec: sinceSec),
            evidence: ChatsEvidenceAxis(
                quality: quality,
                source: source,
                ageMs: observedAt.map { Int(max(0, now.timeIntervalSince($0)) * 1000) }))
    }

    /// Der Lifecycle der App ist feiner als der Runtime-Status und gewinnt,
    /// wenn vorhanden — nur so bleibt `launching` unterscheidbar.
    static func conversation(
        lifecycle: String?,
        runtimeStatus: AgentSessionRuntimeStatus?
    ) -> ChatsConversationAxis.State {
        if let lifecycle {
            switch lifecycle {
            case "launching": return .launching
            case "ready": return .ready
            case "working": return .working
            case "awaitingInput": return .needsInput
            case "turnDone": return .turnDone
            case "stopped": return .stopped
            case "errored": return .errored
            default: break
            }
        }
        switch runtimeStatus {
        case .working: return .working
        case .awaitingInput: return .needsInput
        case .idle: return .ready
        case .stopped: return .stopped
        case .errored: return .errored
        case nil: return .unknown
        }
    }
}
