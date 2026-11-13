import Darwin
import Foundation

// MARK: - Übernahme beim Start

/// Holt beim Start die Chats vom Aufbewahrer zurück. Läuft früh in
/// `applicationDidFinishLaunching`, vor Absturz-Wiederaufnahme, Aufräumen der
/// Event-Dateien, `markStaleRunningSessionsClosed` und dem ersten Statusscan,
/// damit diese die übernommenen Chats schon als laufend kennen.
///
/// Grundsatz wie beim Beenden: Im Zweifel `--resume`, nie zwei Prozesse auf
/// einer Sitzung. Lebt ein Chat-Prozess noch, ohne dass die App ihn
/// übernehmen konnte, wird er erst beendet und erst nach seinem Ende
/// fortgesetzt.
@MainActor
final class HandoverTakeService {
    struct Dependencies {
        var paths: HandoverPaths
        var secretStore: HandoverSecretStoring
        var marker: AgentCrashRecoveryMarker
        var sessions: () -> [AgentChatSession]
        /// Controller bauen, Leitung übernehmen, Token, Status, Hooks.
        /// `false` = nicht übernommen (Leitung bleibt beim Aufrufer).
        var adopt: (HandoverClient.TakenChat, AgentChatSession) -> Bool
        /// In der Lücke beendet: letztes Bild, Status „beendet“.
        var showEnded: (HandoverClient.TakenChat, AgentChatSession) -> Void
        /// Fortsetzen per `--resume` beim Anzeigen (wie die Absturz-Wiederaufnahme).
        var scheduleResume: ([UUID]) -> Void
        var isSameProcess: (Int32, Double?) -> Bool = { HandoverPlanning.isSameProcess(pid: $0, expectedStartTime: $1) }
        /// Strenger für SIGKILL: Startzeit bekannt und passend.
        var isCertainlySameProcess: (Int32, Double?) -> Bool = {
            HandoverPlanning.isCertainlySameProcess(pid: $0, expectedStartTime: $1)
        }
        var terminateProcess: (Int32) -> Void = { kill($0, SIGTERM) }
        /// Letzte Stufe für Chats, die SIGHUP und SIGTERM überleben.
        var killProcess: (Int32) -> Void = { kill($0, SIGKILL) }
        /// So lange nach SIGTERM und nach SIGKILL auf das Ende warten.
        var signalWait: TimeInterval = 5
        /// Wartet off-main, bis der Prozess nicht mehr lebt.
        var waitUntilGone: @Sendable (Int32, Double?, TimeInterval) async -> Bool = { pid, start, timeout in
            let end = Date().addingTimeInterval(timeout)
            while Date() < end {
                if !HandoverPlanning.isSameProcess(pid: pid, expectedStartTime: start) { return true }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            return !HandoverPlanning.isSameProcess(pid: pid, expectedStartTime: start)
        }
        var ioTimeout: TimeInterval = 5
        /// Pause vor jedem TAKE (Stellschraube der Test-Instanz).
        var takeDelay: () -> TimeInterval = { HandoverTestKnobs.takeDelay() }
        /// Wie bei der Abgabe: Socket und empfangene Leitungen nur auf dem
        /// Main Thread, wo auch alle `forkpty` laufen.
        var isMainThread: () -> Bool = { Thread.isMainThread }
        /// Nach dem Ende des Aufbewahrers: so lange auf das Ende der Chats warten,
        /// bevor sie ein SIGTERM bekommen.
        var gracePeriod: TimeInterval = 8
    }

    struct Summary: Equatable {
        var previous: AgentCrashRecoveryMarker.PreviousRun
        var adopted: [UUID] = []
        var endedInGap: [UUID] = []
        /// Nicht übernommen; werden fortgesetzt oder beendet.
        var fallback: [UUID] = []

        /// Sessions, um die sich die Absturz-Wiederaufnahme nicht mehr kümmert.
        var handled: Set<UUID> { Set(adopted + endedInGap + fallback) }
    }

    private let dependencies: Dependencies
    /// Läuft gerade eine Übernahme? `app handover` antwortet dann „busy“.
    private(set) static var isTaking = false
    /// Ergebnis der Übernahme beim letzten Start, für `debug state`.
    private(set) static var lastSummary: Summary?

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    func takeAtLaunch() -> Summary {
        let previous = dependencies.marker.beginRunDetailed()
        var summary = Summary(previous: previous)
        Self.lastSummary = summary
        let onMain = dependencies.isMainThread()
        if !onMain {
            Logger.agentStore.error("handover_take_not_on_main_thread")
        }
        // Abseits des Main Threads keinen Socket öffnen; der Aufbewahrer wird
        // dann über die PID aus dem Marker beendet (unten).
        // Review Paket 4 (Startbremse): Der Verbindungsaufbau wartet bis zu
        // seiner Frist, auch wenn kein Socket da ist — beim normalen Start kostete
        // das 525 ms auf dem Main Thread. Gefragt wird deshalb nur, wenn es einen
        // Grund gibt: Marker „übergeben“ oder Discovery-Eintrag eines Aufbewahrers.
        // Ein Discovery-Eintrag zählt nur, wenn ein Aufbewahrer die Sperre hält.
        // Nach Absturz oder SIGKILL bleibt der Eintrag liegen; ohne diese
        // Prüfung kostete dann wieder jeder Start die volle Frist (Vic).
        let mayHaveKeeper = previous.handover != nil
            || HandoverKeeperLock.liveDiscovery(paths: dependencies.paths)
        // Befund 4 (Dex): Während der Übernahme läuft der Steuer-Socket noch
        // nicht. Ein zweiter Neustart sah „App nicht erreichbar“ und startete
        // klassisch neu; die gerade übernommenen Chats endeten. Die Sperre sagt
        // `app handover`, dass es warten soll.
        let takeLock = mayHaveKeeper ? HandoverTakeLock.acquire(paths: dependencies.paths) : nil
        defer { HandoverTakeLock.release(takeLock) }
        let keeperStatus = onMain && mayHaveKeeper ? Self.status(paths: dependencies.paths) : nil
        guard previous.handover != nil || keeperStatus != nil else { return summary }
        Self.isTaking = true
        defer { Self.isTaking = false }

        let observation = keeperStatus.map {
            HandoverKeeperObservation(
                runID: $0.runID, pid: $0.pid,
                compatible: $0.protocolRange.count == 2
                    && HandoverProtocol.negotiate(client: $0.protocolRange[0]...$0.protocolRange[1]) != nil)
        }
        let secret = previous.handover != nil && keeperStatus != nil
            ? HandoverTestKnobs.secret(dependencies.secretStore.load()) : .missing
        let plan = HandoverPlanning.launchPlan(
            markerHandover: previous.handover, keeper: observation, secret: secret)
        // Nur der Fall: `.take` trägt das Geheimnis (Befund 13.11.2026).
        Logger.agentStore.notice("handover_take_plan plan=\(plan.logLabel, privacy: .public)")

        var outcomes: [String: HandoverTakeOutcome] = [:]
        if !onMain, let handover = previous.handover,
           dependencies.isSameProcess(handover.keeperPID, handover.keeperStartTime) {
            // Kein Socket abseits des Main Threads: geordnet per Signal beenden,
            // die Chats enden mit ihm und werden danach fortgesetzt.
            dependencies.terminateProcess(handover.keeperPID)
        }
        let sessionsByID = Dictionary(dependencies.sessions().map { ($0.id.uuidString, $0) },
                                      uniquingKeysWith: { first, _ in first })
        switch plan {
        case .nothing, .keeperGone:
            break
        case .terminateKeeper(let pid):
            if pid == keeperStatus?.pid { dependencies.terminateProcess(pid) }
        case .release(let secret):
            release(secret: secret, keeperPID: keeperStatus?.pid)
        case .take(let secret):
            outcomes = take(secret: secret, keeperPID: keeperStatus?.pid, sessions: sessionsByID)
        }
        if case .found = secret { dependencies.secretStore.remove() }

        // Je Chat aus dem Marker entscheiden.
        var resumeNow: [UUID] = []
        var terminateFirst: [(UUID, Int32, Double?, Bool)] = []
        for chat in previous.handover?.chats ?? [] {
            let outcome = outcomes[chat.sessionID.uuidString] ?? .notTaken
            let session = sessionsByID[chat.sessionID.uuidString]
            let resumable = session.map { HandoverPlanning.isResumable($0.effectiveKind) && $0.status != .archived } ?? false
            let action = HandoverPlanning.chatAction(
                outcome: outcome,
                processAlive: dependencies.isSameProcess(chat.pid, chat.pidStartTime),
                resumable: resumable)
            switch action {
            case .adopt: summary.adopted.append(chat.sessionID)
            case .showEnded: summary.endedInGap.append(chat.sessionID)
            case .resume:
                summary.fallback.append(chat.sessionID)
                resumeNow.append(chat.sessionID)
            case .terminateThenResume, .terminate:
                summary.fallback.append(chat.sessionID)
                terminateFirst.append((chat.sessionID, chat.pid, chat.pidStartTime, action == .terminateThenResume))
            case .none:
                summary.fallback.append(chat.sessionID)
            }
        }
        if !resumeNow.isEmpty { dependencies.scheduleResume(resumeNow) }
        if !terminateFirst.isEmpty { finishOrphans(terminateFirst) }

        if let run = previous.handover?.runID {
            HandoverTakeReport(
                runID: run, finishedAt: Date().timeIntervalSince1970,
                adopted: summary.adopted.map(\.uuidString),
                endedInGap: summary.endedInGap.map(\.uuidString),
                fallback: summary.fallback.map(\.uuidString)
            ).write(paths: dependencies.paths)
        }
        dependencies.marker.finishHandoverTake()
        Self.lastSummary = summary
        Logger.agentStore.notice(
            "handover_take_finished adopted=\(summary.adopted.count) ended=\(summary.endedInGap.count) fallback=\(summary.fallback.count)")
        return summary
    }

    // MARK: Schritte

    private func take(secret: String, keeperPID: Int32?, sessions: [String: AgentChatSession]) -> [String: HandoverTakeOutcome] {
        guard let client = try? HandoverClient.connect(paths: dependencies.paths, timeout: 1) else { return [:] }
        client.timeout = dependencies.ioTimeout
        defer { client.close() }
        do {
            try client.verifyServer(expectedPID: keeperPID)
        } catch {
            // Fremder oder falscher Prozess am Socket: nichts beenden.
            Logger.agentStore.error("handover_take_verify_failed error=\(HandoverLog.label(error), privacy: .public)")
            return [:]
        }
        do {
            _ = try client.helloTake(secret: secret)
        } catch HandoverClient.ClientError.incompatible {
            try? client.release(secret: secret)
            return [:]
        } catch {
            // Befund 2 (Dex): Lehnt der Aufbewahrer das Geheimnis ab, hielte er
            // seine (gleich beendeten) Chats bis zur Frist und blockierte jede
            // weitere Übergabe. Wie bei fehlendem Geheimnis beenden; seine
            // PID ist oben geprüft.
            Logger.agentStore.error("handover_take_hello_failed error=\(HandoverLog.label(error), privacy: .public)")
            if let keeperPID { dependencies.terminateProcess(keeperPID) }
            return [:]
        }
        var outcomes: [String: HandoverTakeOutcome] = [:]
        let held = (try? client.list()) ?? []
        for summary in held {
            let chatID = summary.manifest.chatID
            // Unbekannte Chats (gelöscht) bleiben beim Aufbewahrer; `DONE`
            // beendet sie geordnet.
            guard let session = sessions[chatID] else { continue }
            let delay = dependencies.takeDelay()
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            let taken: HandoverClient.TakenChat
            do {
                taken = try client.take(chatID: chatID)
            } catch {
                Logger.agentStore.error("handover_take_chat_failed chat=\(chatID, privacy: .public) error=\(HandoverLog.label(error), privacy: .public)")
                // Befund 6 (Dex): Ist die Verbindung tot, scheitert jeder
                // weitere Chat genauso. Der Rest geht sofort in den Rückfall.
                if Self.connectionIsGone(error) { return outcomes }
                continue
            }
            // Review Paket 1, Befund 3: SwiftTerm prüft die Startzeit nicht.
            // Lebt unter der PID ein anderer Prozess (PID neu vergeben), wird
            // nicht übernommen; der Rückfall setzt den Chat fort.
            let sameProcess = dependencies.isSameProcess(taken.manifest.pid, taken.manifest.pidStartTime)
            if taken.exited || taken.descriptor == nil {
                dependencies.showEnded(taken, session)
                outcomes[chatID] = .endedInGap(exitStatus: taken.exitStatus)
            } else if !sameProcess {
                Logger.agentStore.error("handover_take_pid_mismatch chat=\(chatID, privacy: .public) pid=\(taken.manifest.pid)")
                if let fd = taken.descriptor { Darwin.close(fd) }
            } else if dependencies.adopt(taken, session) {
                outcomes[chatID] = .adopted
            } else if let fd = taken.descriptor {
                // Die App hält die einzige Leitung: schließen beendet den Chat
                // (SIGHUP), danach setzt der Rückfall ihn fort.
                Darwin.close(fd)
            }
        }
        try? client.done()
        return outcomes
    }

    /// Verbindung zum Aufbewahrer verloren (nicht nur ein Chat abgelehnt).
    static func connectionIsGone(_ error: Error) -> Bool {
        guard let wire = error as? HandoverWireError else { return false }
        switch wire {
        case .closed, .io, .timedOut: return true
        default: return false
        }
    }

    private func release(secret: String, keeperPID: Int32?) {
        guard let client = try? HandoverClient.connect(paths: dependencies.paths, timeout: 1) else {
            if let keeperPID { dependencies.terminateProcess(keeperPID) }
            return
        }
        client.timeout = dependencies.ioTimeout
        defer { client.close() }
        do {
            try client.release(secret: secret)
        } catch {
            if let keeperPID { dependencies.terminateProcess(keeperPID) }
        }
    }

    /// Chats, deren Prozess noch lebt: Nach dem Ende des Aufbewahrers bekommen
    /// sie SIGHUP. Wer danach noch lebt, bekommt SIGTERM, wer auch das
    /// übersteht, SIGKILL. Fortgesetzt wird nur, wer nachweislich weg ist.
    ///
    /// Befund kill-mid-take (Dex, 13.11.2026): Ohne SIGKILL kam ein Chat, der
    /// SIGTERM überlebte, nie zurück — etwa ein Prozess, der beim Aufräumen
    /// auf eine Leitung ohne Leser schreibt. Die Sitzung liegt auf der Platte,
    /// `--resume` setzt sie fort.
    private func finishOrphans(_ chats: [(UUID, Int32, Double?, Bool)]) {
        let dependencies = self.dependencies
        Task { @MainActor in
            var resume: [UUID] = []
            for (sessionID, pid, start, resumeAfter) in chats {
                var gone = await dependencies.waitUntilGone(pid, start, dependencies.gracePeriod)
                if !gone, dependencies.isSameProcess(pid, start) {
                    dependencies.terminateProcess(pid)
                    gone = await dependencies.waitUntilGone(pid, start, dependencies.signalWait)
                }
                // SIGKILL nur für Chats, die danach fortgesetzt werden (ein
                // Terminal-Tab kommt nie zurück, sein Job kann absichtlich
                // gegen HUP gesichert sein), und nur bei bekannter, passender
                // Startzeit — sonst träfe er womöglich einen fremden Prozess
                // unter derselben PID (Vic zu 54a493b4).
                if !gone, resumeAfter, dependencies.isSameProcess(pid, start) {
                    if dependencies.isCertainlySameProcess(pid, start) {
                        Logger.agentStore.notice(
                            "handover_orphan_killed session=\(sessionID.uuidString, privacy: .public) pid=\(pid)")
                        dependencies.killProcess(pid)
                        gone = await dependencies.waitUntilGone(pid, start, dependencies.signalWait)
                    } else {
                        Logger.agentStore.error(
                            "handover_orphan_kill_skipped session=\(sessionID.uuidString, privacy: .public) pid=\(pid) reason=start_time_unknown")
                    }
                }
                if gone, resumeAfter {
                    resume.append(sessionID)
                } else if !gone {
                    Logger.agentStore.error(
                        "handover_orphan_still_running session=\(sessionID.uuidString, privacy: .public) pid=\(pid)")
                }
            }
            if !resume.isEmpty { dependencies.scheduleResume(resume) }
        }
    }

    static func status(paths: HandoverPaths) -> HandoverKeeperStatus? {
        guard let client = try? HandoverClient.connect(paths: paths, timeout: 0.5) else { return nil }
        defer { client.close() }
        client.timeout = 2
        return try? client.status()
    }
}


// MARK: - Sperre während der Übernahme

/// Die App hält `take.lock`, solange sie beim Start übernimmt. `app handover`
/// wartet, statt „nicht erreichbar“ zu melden (Befund 4, Dex).
enum HandoverTakeLock {
    static func acquire(paths: HandoverPaths) -> Int32? {
        let fd = open(paths.takeLockFileURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    static func release(_ fd: Int32?) {
        guard let fd else { return }
        flock(fd, LOCK_UN)
        close(fd)
    }

    static func isHeld(paths: HandoverPaths) -> Bool {
        HandoverKeeperLock.isHeld(url: paths.takeLockFileURL)
    }
}

// MARK: - Sperre des Aufbewahrers ohne Warten prüfen

enum HandoverKeeperLock {
    /// Hält gerade ein Aufbewahrer die Sperre `keeper.lock`? Prüft ohne zu
    /// warten mit einer geteilten Sperre: Der Aufbewahrer hält sie exklusiv.
    static func isHeld(paths: HandoverPaths) -> Bool {
        isHeld(url: paths.lockFileURL)
    }

    /// Hält jemand die Sperre in `url` exklusiv?
    static func isHeld(url: URL) -> Bool {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }

    /// `true`, wenn ein Discovery-Eintrag da ist und ein Aufbewahrer lebt.
    /// Einen veralteten Eintrag (niemand hält die Sperre) entfernt sie samt
    /// dem Socket des toten Aufbewahrers (Befund kill-mid-take: nach SIGKILL
    /// blieben beide liegen).
    static func liveDiscovery(paths: HandoverPaths) -> Bool {
        guard FileManager.default.fileExists(atPath: paths.discoveryFileURL.path) else { return false }
        if isHeld(paths: paths) { return true }
        removeStaleSocket(at: paths.socketURL)
        try? FileManager.default.removeItem(at: paths.discoveryFileURL)
        Logger.agentStore.notice("handover_stale_discovery_removed")
        return false
    }

    /// Nur einen eigenen Socket entfernen, nie etwas anderes (wie der
    /// Aufbewahrer selbst beim Start).
    static func removeStaleSocket(at url: URL) {
        var existing = stat()
        guard lstat(url.path, &existing) == 0, (existing.st_mode & S_IFMT) == S_IFSOCK,
              existing.st_uid == getuid() else { return }
        unlink(url.path)
    }
}
