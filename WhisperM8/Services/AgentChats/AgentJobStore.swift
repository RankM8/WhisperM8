import Foundation

/// Disk-Store für Subagent-Jobs: ein Verzeichnis pro Job unter
/// `~/Library/Application Support/WhisperM8/agent-jobs/<short-id>/` mit
///   state.json          — AgentJobState (atomar via temp+rename)
///   events.jsonl        — roher codex-exec-Event-Stream (append-only)
///   last-message.txt    — Report des letzten Turns
///   pending-prompt.txt  — Prompt-Handoff Frontend → Supervisor (E6)
///   supervisor.log      — stdout/stderr des detachten Supervisors
///
/// Bewusst NICHT unter ~/.claude/ oder ~/.codex/ (die gelten im Projekt als
/// extern/read-only), sondern neben AgentSessions.json. Struktur spiegelt
/// SupervisorJobReaders Welt, damit die App denselben Beobachter-Ansatz
/// fahren kann.
struct AgentJobStore {
    enum StoreError: LocalizedError, Equatable {
        case jobAlreadyExists(String)
        case jobNotFound(String)
        case invalidTransition(from: AgentJobState.State, to: AgentJobState.State)

        var errorDescription: String? {
            switch self {
            case .jobAlreadyExists(let id):
                return "Job \(id) existiert bereits."
            case .jobNotFound(let id):
                return "Job \(id) nicht gefunden."
            case .invalidTransition(let from, let to):
                return "Unerlaubter Zustandswechsel \(from.rawValue) → \(to.rawValue)."
            }
        }
    }

    static var defaultRootDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperM8/agent-jobs", isDirectory: true)
    }

    var rootDirectory: URL
    /// kill(pid, 0): 0 = lebt; -1 mit EPERM = lebt (gehört jemand anderem);
    /// -1 mit ESRCH = tot.
    var livenessProbe: (Int32) -> Bool
    var now: () -> Date

    init(
        rootDirectory: URL = AgentJobStore.defaultRootDirectory,
        livenessProbe: ((Int32) -> Bool)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.rootDirectory = rootDirectory
        self.livenessProbe = livenessProbe ?? { pid in
            kill(pid, 0) == 0 || errno == EPERM
        }
        self.now = now
    }

    // MARK: - Pfade

    func jobDirectory(for shortId: String) -> URL {
        rootDirectory.appendingPathComponent(shortId, isDirectory: true)
    }

    func stateURL(for shortId: String) -> URL {
        jobDirectory(for: shortId).appendingPathComponent("state.json")
    }

    func eventsURL(for shortId: String) -> URL {
        jobDirectory(for: shortId).appendingPathComponent("events.jsonl")
    }

    func lastMessageURL(for shortId: String) -> URL {
        jobDirectory(for: shortId).appendingPathComponent("last-message.txt")
    }

    func pendingPromptURL(for shortId: String) -> URL {
        jobDirectory(for: shortId).appendingPathComponent("pending-prompt.txt")
    }

    func supervisorLogURL(for shortId: String) -> URL {
        jobDirectory(for: shortId).appendingPathComponent("supervisor.log")
    }

    func reportSchemaURL(for shortId: String) -> URL {
        jobDirectory(for: shortId).appendingPathComponent("report-schema.json")
    }

    // MARK: - Short-IDs

    /// 8 Hex-Zeichen, kollisionsgeprüft gegen existierende Job-Verzeichnisse.
    func generateShortID() -> String {
        for _ in 0..<32 {
            let candidate = String(format: "%08x", UInt32.random(in: UInt32.min...UInt32.max))
            if !FileManager.default.fileExists(atPath: jobDirectory(for: candidate).path) {
                return candidate
            }
        }
        // Praktisch unerreichbar — UUID-Suffix als letzter Ausweg.
        return String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }

    // MARK: - Lifecycle

    func createJob(initial: AgentJobState) throws {
        let directory = jobDirectory(for: initial.shortId)
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw StoreError.jobAlreadyExists(initial.shortId)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeState(initial)
    }

    func readState(shortId: String) -> AgentJobState? {
        guard let data = try? Data(contentsOf: stateURL(for: shortId)) else { return nil }
        return Self.decode(data)
    }

    /// Atomar: Temp-Datei IM SELBEN Verzeichnis + rename(2) — same-volume-
    /// Garantie, Leser sehen nie halbe JSONs. Setzt updatedAt.
    func writeState(_ state: AgentJobState) throws {
        var updated = state
        updated.updatedAt = now()
        let data = try Self.encode(updated)

        let destination = stateURL(for: state.shortId)
        let temp = jobDirectory(for: state.shortId)
            .appendingPathComponent("state.json.tmp-\(UUID().uuidString)")
        try data.write(to: temp)
        guard rename(temp.path, destination.path) == 0 else {
            try? FileManager.default.removeItem(at: temp)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Read-modify-write. Minimiert das Fenster zwischen Frontend- und
    /// Supervisor-Writes (beide schreiben ganze Snapshots via rename).
    @discardableResult
    func mutateState(shortId: String, _ change: (inout AgentJobState) -> Void) throws -> AgentJobState {
        guard var state = readState(shortId: shortId) else {
            throw StoreError.jobNotFound(shortId)
        }
        change(&state)
        try writeState(state)
        return state
    }

    /// Zustandswechsel mit Guard-Tabelle — verweigert z.B. done→running,
    /// wenn inzwischen jemand übernommen hat.
    @discardableResult
    func transition(shortId: String, to next: AgentJobState.State, mutate: ((inout AgentJobState) -> Void)? = nil) throws -> AgentJobState {
        guard var state = readState(shortId: shortId) else {
            throw StoreError.jobNotFound(shortId)
        }
        guard state.canTransition(to: next) else {
            throw StoreError.invalidTransition(from: state.state, to: next)
        }
        state.state = next
        mutate?(&state)
        try writeState(state)
        return state
    }

    func removeJob(shortId: String) throws {
        let directory = jobDirectory(for: shortId)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw StoreError.jobNotFound(shortId)
        }
        try FileManager.default.removeItem(at: directory)
    }

    // MARK: - Events / Report / Prompt-Handoff

    func appendEvent(shortId: String, rawLine: String) {
        let url = eventsURL(for: shortId)
        let data = Data((rawLine + "\n").utf8)
        if let handle = FileHandle(forWritingAtPath: url.path) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    func writeLastMessage(shortId: String, text: String) {
        try? text.write(to: lastMessageURL(for: shortId), atomically: true, encoding: .utf8)
    }

    func readLastMessage(shortId: String) -> String? {
        (try? String(contentsOf: lastMessageURL(for: shortId), encoding: .utf8))
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    func writePendingPrompt(shortId: String, prompt: String) throws {
        try prompt.write(to: pendingPromptURL(for: shortId), atomically: true, encoding: .utf8)
    }

    /// Liest UND löscht den Prompt — der Supervisor konsumiert genau einmal.
    func consumePendingPrompt(shortId: String) -> String? {
        let url = pendingPromptURL(for: shortId)
        guard let prompt = try? String(contentsOf: url, encoding: .utf8), !prompt.isEmpty else {
            return nil
        }
        try? FileManager.default.removeItem(at: url)
        return prompt
    }

    // MARK: - Lesen mit Orphan-Korrektur

    /// Alle Jobs, mit Liveness-Korrektur: state sagt aktiv, aber der
    /// Supervisor-Prozess ist tot → failed ("supervisor died"). Unlesbare
    /// state.json werden geskippt, nie geworfen.
    func readAllCorrected() -> [AgentJobState] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var result: [AgentJobState] = []
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            guard let state = readState(shortId: entry.lastPathComponent) else { continue }
            result.append(correctIfOrphaned(state))
        }
        return result.sorted { $0.updatedAt > $1.updatedAt }
    }

    func readCorrected(shortId: String) -> AgentJobState? {
        readState(shortId: shortId).map(correctIfOrphaned)
    }

    /// Korrigiert verwaiste Jobs und persistiert die Korrektur (best effort).
    func correctIfOrphaned(_ state: AgentJobState) -> AgentJobState {
        guard state.isActive else { return state }

        if let pid = state.supervisorPid {
            guard !livenessProbe(pid) else { return state }
            var corrected = state
            corrected.state = .failed
            corrected.failureReason = "supervisor died (pid \(pid) nicht mehr vorhanden)"
            try? writeState(corrected)
            return corrected
        }

        // spawning ohne PID: kurzlebiger Normalzustand — aber wenn er
        // >30 s hängt, ist der Spawn gescheitert (Frontend gecrasht o.ä.).
        if state.state == .spawning, now().timeIntervalSince(state.updatedAt) > 30 {
            var corrected = state
            corrected.state = .failed
            corrected.failureReason = "spawn timed out (kein Supervisor gestartet)"
            try? writeState(corrected)
            return corrected
        }
        return state
    }

    // MARK: - Codierung

    static func encode(_ state: AgentJobState) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(state)
    }

    static func decode(_ data: Data) -> AgentJobState? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let state = try? decoder.decode(AgentJobState.self, from: data) else { return nil }
        // Höhere Schema-Version = von einer neueren WhisperM8-Version
        // geschrieben — nicht anfassen, als unlesbar behandeln.
        guard state.version <= AgentJobState.currentVersion else { return nil }
        return state
    }
}
