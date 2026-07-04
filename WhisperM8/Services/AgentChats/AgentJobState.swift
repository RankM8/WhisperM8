import Foundation

/// Persistierter Zustand eines Subagent-Jobs — Inhalt von
/// `agent-jobs/<short-id>/state.json`. Einzige Quelle der Wahrheit über den
/// Job; CLI-Supervisor und App lesen/schreiben denselben Kontrakt.
///
/// Anders als beim Workspace ist ein Decode-Fehler hier harmlos: die Leser
/// (Store, App-Sync) skippen unlesbare Jobs einzeln, statt alles zu
/// verlieren — deshalb strikte Enums statt lenientem String-Parsing.
struct AgentJobState: Codable, Equatable {
    static let currentVersion = 1

    enum State: String, Codable {
        case spawning
        case running
        case done
        case failed
        case stopped
        /// Der User hat den Job als interaktiven Chat übernommen — dauerhaft
        /// und exklusiv (beschlossen): der Supervisor zieht sich zurück,
        /// `agent send` verweigert ab jetzt.
        case takenOver
    }

    struct Worktree: Codable, Equatable {
        var path: String
        var branch: String
    }

    /// Vom Supervisor GEMESSENE Metadaten (beschlossene Politik: nie vom
    /// Modell erfragen — was das Modell berichtet, steht im Report).
    struct Metrics: Codable, Equatable {
        var lastTurnSeconds: Double?
        var diffChangedFiles: Int?
        var diffAdded: Int?
        var diffDeleted: Int?
    }

    var version: Int
    var shortId: String
    var provider: String
    var state: State
    var intent: String
    var cwd: String
    /// Aus dem ersten `thread.started` — Schlüssel für Resume + Rollout-JSONL.
    var codexThreadID: String?
    /// Claude-Session, die den Job gespawnt hat (`--parent`).
    var parentSessionID: String?
    /// PID des `claude`-Vorfahren im Prozessbaum des Spawn-Aufrufs — Fallback
    /// für die Parent-Zuordnung, wenn `--parent` fehlt (Claude Code exportiert
    /// keine Session-ID in die Bash-Umgebung). Die App matcht sie gegen die
    /// shellPids ihrer laufenden PTY-Sessions. PID-Reuse: nur relevant,
    /// solange der Chat läuft — akzeptierte Heuristik.
    var parentProcessID: Int32?
    /// ALLE Vorfahren-PIDs des Spawn-Aufrufs (aufsteigend). Namensunabhängige
    /// Ergänzung zu `parentProcessID`: p_comm ist unzuverlässig (native
    /// Installer-Binaries heißen "2.1.201", npm-Installs "node") — die App
    /// matcht stattdessen irgendeine Ketten-PID gegen ihre PTY-shellPids.
    var parentProcessAncestry: [Int32]?
    /// Liveness-Anker: Leser validieren mit kill(pid, 0), bevor sie
    /// `running` glauben. (PID-Reuse ist eine dokumentierte Limitation.)
    var supervisorPid: Int32?
    var turns: Int
    var sandbox: String
    /// Turn-Parameter, die der detachte Supervisor aus state.json
    /// rekonstruiert (er hat die CLI-Flags des Frontends nicht mehr).
    var model: String?
    var effort: String?
    var allowNetwork: Bool
    var worktree: Worktree?
    var failureReason: String?
    var codexVersion: String?
    var metrics: Metrics?
    var createdAt: Date
    var updatedAt: Date

    init(
        shortId: String,
        state: State,
        intent: String,
        cwd: String,
        sandbox: CodexSandboxMode,
        parentSessionID: String? = nil,
        codexVersion: String? = nil,
        createdAt: Date = Date()
    ) {
        self.version = Self.currentVersion
        self.shortId = shortId
        self.provider = "codex"
        self.state = state
        self.intent = intent
        self.cwd = cwd
        self.codexThreadID = nil
        self.parentSessionID = parentSessionID
        self.parentProcessID = nil
        self.parentProcessAncestry = nil
        self.supervisorPid = nil
        self.turns = 0
        self.sandbox = sandbox.rawValue
        self.model = nil
        self.effort = nil
        self.allowNetwork = false
        self.worktree = nil
        self.failureReason = nil
        self.codexVersion = codexVersion
        self.metrics = nil
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    /// spawning/running = es gehört (vermeintlich) ein lebender Supervisor
    /// dazu. Alles andere ist "idle auf Disk".
    var isActive: Bool {
        state == .spawning || state == .running
    }

    /// Pure Guard-Tabelle der erlaubten Übergänge. Leser wie Schreiber
    /// benutzen sie, damit z.B. ein spät eintreffender Supervisor einen
    /// bereits übernommenen Job nicht zurück auf done setzt.
    static func canTransition(from: State, to: State) -> Bool {
        switch (from, to) {
        case (.spawning, .running), (.spawning, .failed), (.spawning, .stopped):
            return true
        case (.running, .done), (.running, .failed), (.running, .stopped), (.running, .takenOver):
            return true
        // send startet einen neuen Turn auf abgeschlossenen Jobs:
        case (.done, .running), (.failed, .running), (.stopped, .running):
            return true
        // send reserviert einen ruhenden Job atomar (unterm Job-Lock) auf
        // spawning, BEVOR der Supervisor startet — so sieht ein zweiter,
        // paralleler send den Job sofort als aktiv (isActive) und prallt ab.
        case (.done, .spawning), (.failed, .spawning), (.stopped, .spawning):
            return true
        // Übernahme ist aus jedem Ruhezustand möglich:
        case (.done, .takenOver), (.failed, .takenOver), (.stopped, .takenOver):
            return true
        // takenOver ist terminal (Rückweg = bewusst v2).
        default:
            return false
        }
    }

    func canTransition(to next: State) -> Bool {
        Self.canTransition(from: state, to: next)
    }
}
