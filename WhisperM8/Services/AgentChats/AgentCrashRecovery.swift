import Darwin
import Foundation

/// Wiederaufnahme nach einem unsauberen App-Ende.
///
/// **Vorfall 23.09.2026:** Ein SIGPIPE beendete die App wortlos (siehe
/// `SigpipeGuard`). Jeder Vordergrund-Chat hängt an einem PTY der App — stirbt
/// sie, bekommt `claude`/`codex` ein SIGHUP und endet. Nach dem Neustart waren
/// die Tabs zwar wieder da, aber kein Chat lief; der User musste jeden einzeln
/// wieder anstoßen.
///
/// **Mechanik:** Die App führt während des Laufs einen Marker mit den Sessions,
/// deren PTY gerade läuft. Ein sauberes Ende (Cmd+Q, Menü „Beenden",
/// `make dev`/`make kill` per SIGTERM → `NSApp.terminate`) entfernt ihn in
/// `applicationShouldTerminate`, bevor die PTYs beim Quit sterben. Liegt er beim nächsten Start noch da, ist die
/// App abgestürzt oder wurde hart gekillt — dann bekommen genau die damals
/// laufenden Sessions `shouldLaunchOnOpen`, dieselbe Mechanik wie
/// `whisperm8 chats resume`. Gestartet wird wie dort erst, wenn der Tab
/// angezeigt wird. Gestoppte Chats (selbst beendet, `close --stop`) stehen
/// nicht mehr im Marker, archivierte filtert der Planer.
///
/// Kill-Switch: `defaults write com.whisperm8.app agentCrashRecoveryEnabled -bool NO`
final class AgentCrashRecoveryMarker {
    struct Contents: Codable, Equatable {
        var pid: Int32
        var runningSessionIDs: [UUID]
        var updatedAt: Date
    }

    static let shared = AgentCrashRecoveryMarker()

    private let fileURL: URL
    private let ownPID: Int32
    private let isProcessAlive: (Int32) -> Bool
    private let lock = NSLock()
    /// Nach dem sauberen Ende: späte `record`-Aufrufe (PTY-Exits während des
    /// Quits) dürfen den Marker nicht wieder anlegen.
    private var isFinished = false
    private var isOwner = false

    init(
        fileURL: URL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperM8", isDirectory: true)
            .appendingPathComponent("running-sessions.json"),
        ownPID: Int32 = getpid(),
        isProcessAlive: @escaping (Int32) -> Bool = { kill($0, 0) == 0 }
    ) {
        self.fileURL = fileURL
        self.ownPID = ownPID
        self.isProcessAlive = isProcessAlive
    }

    /// Beim Start aufrufen. Liefert die beim unsauberen Ende laufenden
    /// Sessions (leer nach sauberem Ende oder beim ersten Start) und übernimmt
    /// den Marker für diesen Lauf. Lebt der Besitzer des vorhandenen Markers
    /// noch (zweite Instanz, die sich gleich wieder beendet), bleibt er
    /// unangetastet.
    func beginRun() -> [UUID] {
        lock.lock(); defer { lock.unlock() }
        let previous = read()
        if let previous, previous.pid != ownPID, isProcessAlive(previous.pid) {
            return []
        }
        isOwner = true
        write(Contents(pid: ownPID, runningSessionIDs: [], updatedAt: Date()))
        guard let previous, previous.pid != ownPID else { return [] }
        return previous.runningSessionIDs
    }

    /// Aktuellen Satz laufender PTYs festhalten.
    func record(runningSessionIDs: Set<UUID>) {
        lock.lock(); defer { lock.unlock() }
        guard isOwner, !isFinished else { return }
        let sorted = runningSessionIDs.sorted { $0.uuidString < $1.uuidString }
        if read()?.runningSessionIDs == sorted { return }
        write(Contents(pid: ownPID, runningSessionIDs: sorted, updatedAt: Date()))
    }

    /// Sauberes Ende: Marker entfernen. Nur der eigene — eine zweite Instanz,
    /// die sich im Single-Instance-Check beendet, darf den Marker der
    /// laufenden App nicht löschen.
    func endRunCleanly() {
        lock.lock(); defer { lock.unlock() }
        isFinished = true
        guard isOwner, read()?.pid == ownPID else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func read() -> Contents? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Contents.self, from: data)
    }

    private func write(_ contents: Contents) {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(contents) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Pure Auswahl: Welche der beim Absturz laufenden Sessions wieder hochfahren?
enum AgentCrashRecoveryPlanner {
    static func sessionsToResume(
        previouslyRunning: [UUID],
        sessions: [AgentChatSession]
    ) -> [UUID] {
        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<UUID>()
        return previouslyRunning.filter { id in
            guard seen.insert(id).inserted, let session = byID[id] else { return false }
            guard session.status != .archived else { return false }
            // Wie `chats resume`: nur Kinds mit Resume-Kommando. Subagent-Jobs
            // laufen beim eigenen Supervisor weiter.
            switch session.effectiveKind {
            case .chat, .backgroundChat: return true
            case .agentView, .terminal, .subagentJob: return false
            }
        }
    }
}

/// Start-Verdrahtung: Marker übernehmen, Registry anhängen und nach einem
/// unsauberen Ende die damals laufenden Chats zum Resume vormerken.
@MainActor
enum AgentCrashRecoveryCoordinator {
    static func start(
        marker: AgentCrashRecoveryMarker = .shared,
        registry: AgentTerminalRegistry? = nil,
        windowStore: AgentWindowStore? = nil,
        store: AgentSessionStore = AgentSessionStore(),
        isEnabled: Bool = AppPreferences.shared.isAgentCrashRecoveryEnabled
    ) {
        let registry = registry ?? .shared
        let windowStore = windowStore ?? .shared
        let previouslyRunning = marker.beginRun()
        registry.onRunningSetChanged = { marker.record(runningSessionIDs: $0) }
        marker.record(runningSessionIDs: registry.activeSessionIDs)

        guard !previouslyRunning.isEmpty else { return }
        guard isEnabled else {
            Logger.agentStore.notice("crash_recovery_skipped reason=disabled previous=\(previouslyRunning.count)")
            return
        }
        let resumeIDs = AgentCrashRecoveryPlanner.sessionsToResume(
            previouslyRunning: previouslyRunning,
            sessions: store.loadWorkspace().sessions
        )
        for id in resumeIDs {
            try? store.updateSession(id: id) { $0.shouldLaunchOnOpen = true }
            // Ein Chat kann ohne offenen Tab gelaufen sein (`close` lässt das
            // PTY leben) — dann den Tab zurückholen, ohne die Auswahl zu ändern.
            if windowStore.windowID(containingTab: id) == nil {
                windowStore.openTab(id, in: windowStore.primaryWindowID, select: false)
            }
        }
        Logger.agentStore.notice(
            "crash_recovery_resumed count=\(resumeIDs.count) previous=\(previouslyRunning.count)"
        )
    }
}
