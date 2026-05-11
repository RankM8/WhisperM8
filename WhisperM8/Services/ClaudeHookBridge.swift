import Foundation

/// High-Level-Bridge fuer das Hook-basierte Tracking von Claude-Code-Sessions.
/// Verantwortlich fuer:
/// 1. Beim Launch: Settings-File schreiben + Event-File leeren
/// 2. Periodisches Tailing der Event-Datei (Default 500 ms)
/// 3. Hook-Silence-Detection nach 5s ohne Event → Fallback-Hint
/// 4. Decision-Handler-Callbacks bei SessionStart / SessionEnd
///
/// Bridge ist passiv gegenueber dem Store — sie ruft den `decisionHandler`
/// auf und der Aufrufer entscheidet (genau wie bei `ClaudeActiveSessionTracker`),
/// was mit der neuen ID passieren soll.
@MainActor
final class ClaudeHookBridge {
    typealias DecisionHandler = (UUID, ClaudeHookEvent) -> Void

    private let paths: ClaudeHookPaths
    private let pollInterval: TimeInterval
    private let silenceTimeout: TimeInterval
    private let store: ClaudeHookEventStore
    private var entries: [UUID: Entry] = [:]
    private var timer: Timer?
    private var decisionHandler: DecisionHandler?

    private struct Entry {
        let localSessionID: UUID
        let eventFileURL: URL
        let attachedAt: Date
        var sawFirstEvent: Bool
        var silenceLogged: Bool
    }

    init(
        paths: ClaudeHookPaths = ClaudeHookPaths(),
        pollInterval: TimeInterval = 0.5,
        silenceTimeout: TimeInterval = 5.0
    ) {
        self.paths = paths
        self.pollInterval = pollInterval
        self.silenceTimeout = silenceTimeout
        self.store = ClaudeHookEventStore()
    }

    func setDecisionHandler(_ handler: @escaping DecisionHandler) {
        self.decisionHandler = handler
    }

    /// Bereitet einen Launch vor: schreibt die Settings-Datei und gibt
    /// extra-Args fuer den Claude-Command zurueck (`--settings <path>`).
    /// Idempotent: bei wiederholtem Aufruf wird die Settings-Datei
    /// ueberschrieben (Pfad ist deterministisch pro localID).
    func prepareLaunch(localSessionID: UUID) -> [String] {
        let settingsURL = paths.settingsFileURL(localSessionID: localSessionID)
        let eventURL = paths.eventFileURL(localSessionID: localSessionID)
        do {
            // Frisches Event-File anlegen (alte Events einer geloeschten
            // Session der gleichen UUID waeren irrefuehrend).
            try? FileManager.default.createDirectory(
                at: paths.eventsDirectory,
                withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: eventURL)
            try Data().write(to: eventURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: eventURL.path
            )
            try ClaudeHookSettingsBuilder.writeSettingsFile(
                eventFilePath: eventURL.path,
                to: settingsURL
            )
            return ["--settings", settingsURL.path]
        } catch {
            Logger.claudeBinding.warning("hook_prepare_failed localID=\(localSessionID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Beginnt das Polling fuer eine lokale Session. Setzt das Cursor des
    /// Event-Stores fuer diese Datei zurueck, damit auch alte Events (die
    /// theoretisch zwischen `prepareLaunch` und `startTracking` reinkamen)
    /// noch konsumiert werden.
    func startTracking(localSessionID: UUID) {
        let eventURL = paths.eventFileURL(localSessionID: localSessionID)
        store.resetCursor(for: eventURL)
        entries[localSessionID] = Entry(
            localSessionID: localSessionID,
            eventFileURL: eventURL,
            attachedAt: Date(),
            sawFirstEvent: false,
            silenceLogged: false
        )
        ensureTimerRunning()
    }

    /// Stoppt das Polling fuer eine Session. Settings- und Event-Files
    /// bleiben erstmal liegen — werden vom Retention-Job (Phase 7) abgeraeumt.
    func stopTracking(localSessionID: UUID) {
        entries.removeValue(forKey: localSessionID)
        if entries.isEmpty {
            stopTimer()
        }
    }

    /// Liefert `true` wenn fuer eine Session bereits mind. ein Hook-Event
    /// angekommen ist. Wird vom Fallback-Resolver konsultiert: wenn FALSE
    /// nach Silence-Timeout, dann auf Transcript-Tail-Mode wechseln.
    func hasReceivedAnyEvent(localSessionID: UUID) -> Bool {
        entries[localSessionID]?.sawFirstEvent == true
    }

    // MARK: - Internals

    private func ensureTimerRunning() {
        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard !entries.isEmpty else { return }
        let now = Date()
        for (localID, entry) in entries {
            let events = store.readNewEvents(from: entry.eventFileURL)
            if !events.isEmpty {
                var updated = entry
                updated.sawFirstEvent = true
                entries[localID] = updated
                for event in events {
                    Logger.claudeBinding.info("binding_hook_event_received localID=\(localID.uuidString, privacy: .public) event=\(event.hookEventName.rawValue, privacy: .public) sessionID=\(event.sessionID ?? "nil", privacy: .public)")
                    decisionHandler?(localID, event)
                }
            } else if !entry.sawFirstEvent
                && !entry.silenceLogged
                && now.timeIntervalSince(entry.attachedAt) >= silenceTimeout {
                var updated = entry
                updated.silenceLogged = true
                entries[localID] = updated
                Logger.claudeBinding.info("binding_hook_silent localID=\(localID.uuidString, privacy: .public)")
            }
        }
    }
}
