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
        /// Dritter Zustand „übergeben“ (Neustart ohne Chatverlust): Die Chats
        /// liegen beim Aufbewahrer. Fehlt das Feld, gilt der Marker wie
        /// bisher als „fortsetzen“; ältere Apps ignorieren es.
        var handover: HandedOver?
    }

    /// Wem die App ihre Chats übergeben hat. Je Chat PID samt Startzeit: Lebt
    /// beim nächsten Start unter der PID ein anderer Prozess, wird er nicht
    /// beendet, sondern der Chat gilt als tot.
    struct HandedOver: Codable, Equatable {
        var keeperPID: Int32
        var keeperStartTime: Double?
        var runID: String
        var chats: [Chat]

        struct Chat: Codable, Equatable {
            var sessionID: UUID
            var pid: Int32
            var pidStartTime: Double?
        }
    }

    /// Was der vorige Lauf hinterlassen hat.
    struct PreviousRun: Equatable {
        /// Beim unsauberen Ende laufende Chats; nach einer Übergabe die
        /// abgegebenen plus die, deren Abgabe scheiterte.
        var runningSessionIDs: [UUID]
        var handover: HandedOver?

        static let none = PreviousRun(runningSessionIDs: [], handover: nil)
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
    /// Übergabe des vorigen Laufs, solange die Übernahme nicht abgeschlossen
    /// ist. Bleibt im Marker stehen: Stürzt diese App vor oder während der
    /// Übernahme ab, findet die nächste den Aufbewahrer noch.
    private var pendingHandover: HandedOver?
    /// Marker absichtlich stehen gelassen („fortsetzen“ oder „übergeben“):
    /// ein späteres `endRunCleanly` darf ihn nicht mehr löschen.
    private var keepsMarker = false

    init(
        fileURL: URL = AppInstance.applicationSupport
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
        beginRunDetailed().runningSessionIDs
    }

    /// Wie `beginRun`, liefert aber auch den Zustand „übergeben“.
    func beginRunDetailed() -> PreviousRun {
        lock.lock(); defer { lock.unlock() }
        let previous = read()
        if let previous, previous.pid != ownPID, isProcessAlive(previous.pid) {
            return .none
        }
        isOwner = true
        pendingHandover = previous?.pid != ownPID ? previous?.handover : nil
        write(Contents(pid: ownPID, runningSessionIDs: [], updatedAt: Date(), handover: pendingHandover))
        guard let previous, previous.pid != ownPID else { return .none }
        return PreviousRun(runningSessionIDs: previous.runningSessionIDs, handover: previous.handover)
    }

    /// Übernahme abgeschlossen (übernommen, freigegeben oder aufgegeben): der
    /// Zustand „übergeben“ verschwindet aus dem Marker.
    func finishHandoverTake() {
        lock.lock(); defer { lock.unlock() }
        guard isOwner, !isFinished, pendingHandover != nil else { return }
        pendingHandover = nil
        let current = read()
        write(Contents(pid: ownPID, runningSessionIDs: current?.runningSessionIDs ?? [], updatedAt: Date()))
    }

    /// Aktuellen Satz laufender PTYs festhalten.
    func record(runningSessionIDs: Set<UUID>) {
        lock.lock(); defer { lock.unlock() }
        guard isOwner, !isFinished else { return }
        let sorted = runningSessionIDs.sorted { $0.uuidString < $1.uuidString }
        if read()?.runningSessionIDs == sorted { return }
        write(Contents(pid: ownPID, runningSessionIDs: sorted, updatedAt: Date(), handover: pendingHandover))
    }

    /// Beenden mit „beim nächsten Start fortsetzen“ (Cmd+Q-Dialog, D4): der
    /// Marker bleibt mit den gerade laufenden Chats stehen und wird nicht mehr
    /// fortgeschrieben — sonst leerte ihn das Sterben der PTYs beim Quit.
    /// Der nächste Start nimmt sie über den Wiederaufnahme-Weg wieder auf.
    func keepForResume(runningSessionIDs: Set<UUID>) {
        lock.lock(); defer { lock.unlock() }
        guard isOwner, !isFinished else { return }
        write(Contents(pid: ownPID, runningSessionIDs: runningSessionIDs.sorted { $0.uuidString < $1.uuidString },
                       updatedAt: Date(), handover: pendingHandover))
        isFinished = true
        keepsMarker = true
    }

    /// Beenden mit Übergabe: Die Chats liegen beim Aufbewahrer. Erst nach
    /// `commit()` aufrufen. Der Marker bleibt stehen und wird nicht mehr
    /// fortgeschrieben; die neue App übernimmt oder setzt fort.
    /// `alsoResume`: laufende Chats, die nicht übergeben wurden (Abgabe
    /// gescheitert) — sie enden auf dem heutigen Weg und werden fortgesetzt.
    func markHandedOver(_ handover: HandedOver, alsoResume: Set<UUID> = []) {
        lock.lock(); defer { lock.unlock() }
        guard isOwner, !isFinished else { return }
        let all = alsoResume.union(handover.chats.map(\.sessionID))
        write(Contents(pid: ownPID,
                       runningSessionIDs: all.sorted { $0.uuidString < $1.uuidString },
                       updatedAt: Date(),
                       handover: handover))
        isFinished = true
        keepsMarker = true
    }

    /// Sauberes Ende: Marker entfernen. Nur der eigene — eine zweite Instanz,
    /// die sich im Single-Instance-Check beendet, darf den Marker der
    /// laufenden App nicht löschen.
    func endRunCleanly() {
        lock.lock(); defer { lock.unlock() }
        isFinished = true
        guard isOwner, !keepsMarker, read()?.pid == ownPID else { return }
        // Übernahme nicht abgeschlossen: der Zustand „übergeben“ muss für den
        // nächsten Start stehen bleiben, sonst hielte der Aufbewahrer Chats,
        // die keiner mehr kennt.
        if let pendingHandover {
            write(Contents(pid: ownPID, runningSessionIDs: pendingHandover.chats.map(\.sessionID),
                           updatedAt: Date(), handover: pendingHandover))
            return
        }
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
    /// - Returns: die zum Fortsetzen vorgemerkten Sessions (für den Schutz
    ///   ihrer Event-Dateien beim Aufräumen, `pruneAtLaunch`).
    @discardableResult
    static func start(
        marker: AgentCrashRecoveryMarker = .shared,
        registry: AgentTerminalRegistry? = nil,
        windowStore: AgentWindowStore? = nil,
        store: AgentSessionStore = AgentSessionStore(),
        isEnabled: Bool = AppPreferences.shared.isAgentCrashRecoveryEnabled
    ) -> [UUID] {
        let registry = registry ?? .shared
        let windowStore = windowStore ?? .shared
        let previouslyRunning = marker.beginRun()
        registry.onRunningSetChanged = { marker.record(runningSessionIDs: $0) }
        marker.record(runningSessionIDs: registry.activeSessionIDs)

        guard !previouslyRunning.isEmpty else { return [] }
        guard isEnabled else {
            Logger.agentStore.notice("crash_recovery_skipped reason=disabled previous=\(previouslyRunning.count)")
            return []
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
        return resumeIDs
    }
}
