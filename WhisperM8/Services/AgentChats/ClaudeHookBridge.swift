import Foundation

/// High-Level-Bridge fuer das Hook-basierte Tracking von Claude-Code-Sessions.
///
/// **Event-driven via `DispatchSource.makeFileSystemObjectSource`**:
/// Kein Polling. Pro lokaler Session wird ein File-Descriptor auf das
/// Event-JSONL geoeffnet; der Kernel weckt uns nur, wenn Claude
/// tatsaechlich eine Hook-Zeile appended hat. Idle-CPU = 0%.
///
/// Verantwortlich fuer:
/// 1. Beim Launch: Settings-File schreiben + Event-File leer initialisieren
/// 2. DispatchSource pro Event-File (`.write | .extend`-Events)
/// 3. Hook-Silence-Detection nach `silenceTimeout` ohne Event
///    -> einmaliges `binding_hook_silent`-Log (Diagnostik), kein Fallback-Loop
/// 4. Decision-Handler-Callbacks bei SessionStart / SessionEnd
@MainActor
final class ClaudeHookBridge {
    typealias DecisionHandler = (UUID, ClaudeHookEvent) -> Void

    private let paths: ClaudeHookPaths
    private let silenceTimeout: TimeInterval
    private let preToolUseDeliveryInterval: TimeInterval
    private let store: ClaudeHookEventStore
    private var entries: [UUID: Entry] = [:]
    private var decisionHandler: DecisionHandler?

    private final class Entry {
        let localSessionID: UUID
        let eventFileURL: URL
        let attachedAt: Date
        var sawFirstEvent: Bool = false
        var silenceTimer: Timer?
        var fileDescriptor: Int32 = -1
        var source: DispatchSourceFileSystemObject?
        var lastDeliveredPreToolUseAt: Date?

        init(localSessionID: UUID, eventFileURL: URL, attachedAt: Date) {
            self.localSessionID = localSessionID
            self.eventFileURL = eventFileURL
            self.attachedAt = attachedAt
        }

        deinit {
            source?.cancel()
            if fileDescriptor >= 0 { close(fileDescriptor) }
            silenceTimer?.invalidate()
        }
    }

    init(
        paths: ClaudeHookPaths = ClaudeHookPaths(),
        silenceTimeout: TimeInterval = 5.0,
        preToolUseDeliveryInterval: TimeInterval = 1.0
    ) {
        self.paths = paths
        self.silenceTimeout = silenceTimeout
        self.preToolUseDeliveryInterval = preToolUseDeliveryInterval
        self.store = ClaudeHookEventStore()
    }

    func setDecisionHandler(_ handler: @escaping DecisionHandler) {
        self.decisionHandler = handler
    }

    /// Bereitet einen Launch vor: schreibt die Settings-Datei und gibt
    /// extra-Args fuer den Claude-Command zurueck. Idempotent.
    func prepareLaunch(localSessionID: UUID) -> [String] {
        guard let path = prepareSettingsFile(localSessionID: localSessionID) else {
            return []
        }
        return ["--settings", path]
    }

    /// Wie `prepareLaunch`, gibt aber direkt den Settings-Pfad zurueck —
    /// fuer Aufrufer, die den Pfad selbst in andere Argv-Strukturen einbauen
    /// (z. B. `claude --settings <path> --bg "<prompt>"` beim
    /// Background-Spawn). `nil` bei IO-Fehlern; der Caller faellt dann auf
    /// einen Launch ohne Hook-Bridge zurueck.
    ///
    /// `contextFragment` (Context-Profil-Keys, siehe
    /// `ClaudeContextSettingsBuilder`) wird mit dem Hook-Fragment in EINE
    /// Datei gemerged — Claude nimmt nur ein `--settings`. Mit
    /// `includeHooks: false` entsteht eine reine Profil-Datei ohne
    /// Event-File-Setup (Hook-Bridge deaktiviert, Profil soll trotzdem
    /// wirken). Sind beide Teile leer, gibt es nichts zu schreiben → nil.
    func prepareSettingsFile(
        localSessionID: UUID,
        contextFragment: [String: Any]? = nil,
        includeHooks: Bool = true
    ) -> String? {
        let settingsURL = paths.settingsFileURL(localSessionID: localSessionID)
        var fragments: [[String: Any]] = []
        do {
            if includeHooks {
                let eventURL = paths.eventFileURL(localSessionID: localSessionID)
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
                fragments.append(ClaudeHookSettingsBuilder.makeSettings(eventFilePath: eventURL.path))
            }
            if let contextFragment, !contextFragment.isEmpty {
                fragments.append(contextFragment)
            }
            let settings = ClaudeContextSettingsBuilder.merged(fragments)
            guard !settings.isEmpty else { return nil }
            try ClaudeHookSettingsBuilder.write(settings: settings, to: settingsURL)
            return settingsURL.path
        } catch {
            Logger.claudeBinding.warning("hook_prepare_failed localID=\(localSessionID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Beginnt das Tracken einer Session. Oeffnet einen Read-Only-FD auf das
    /// Event-File, registriert eine DispatchSource fuer `.write | .extend`
    /// und schedule einen einmaligen Silence-Timer fuer Diagnostik.
    func startTracking(localSessionID: UUID) {
        // Doppelt-Tracken vermeiden — wenn schon ein Entry da ist, alten
        // canceln und neu aufsetzen (Resume nach Restart).
        if let existing = entries[localSessionID] {
            cleanupEntry(existing)
        }

        let eventURL = paths.eventFileURL(localSessionID: localSessionID)
        store.resetCursor(for: eventURL)

        let entry = Entry(
            localSessionID: localSessionID,
            eventFileURL: eventURL,
            attachedAt: Date()
        )

        let fd = open(eventURL.path, O_EVTONLY)
        guard fd >= 0 else {
            Logger.claudeBinding.warning("hook_open_failed localID=\(localSessionID.uuidString, privacy: .public) path=\(eventURL.path, privacy: .public) errno=\(errno)")
            return
        }
        entry.fileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self, weak entry] in
            guard let self, let entry else { return }
            Task { @MainActor in
                await self.handleFileEvent(for: entry)
            }
        }
        source.setCancelHandler { [weak entry] in
            guard let entry else { return }
            if entry.fileDescriptor >= 0 {
                close(entry.fileDescriptor)
                entry.fileDescriptor = -1
            }
        }
        source.resume()
        entry.source = source

        // Initialer Drain — falls bereits Events zwischen prepareLaunch und
        // startTracking eingelaufen sind (selten, aber moeglich). Das Lesen
        // passiert off-main, weil Hook-Files bei langen Sessions gross werden
        // koennen.
        Task { @MainActor [weak self, weak entry, store] in
            let initialEvents = await Task.detached(priority: .utility) {
                store.readNewEvents(from: eventURL)
            }.value
            guard let self, let entry, !initialEvents.isEmpty else { return }
            entry.sawFirstEvent = true
            let now = Date()
            for event in initialEvents {
                self.deliver(event, for: entry, now: now)
            }
        }

        // Silence-Diagnostik: einmaliger Timer, kein Loop. Wenn nach
        // `silenceTimeout` Sekunden noch kein Event ankam, loggen wir das —
        // signalisiert, dass entweder Hooks deaktiviert sind oder der
        // Settings-Inject nicht griff.
        let timer = Timer.scheduledTimer(withTimeInterval: silenceTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let current = self.entries[localSessionID] else { return }
                if !current.sawFirstEvent {
                    Logger.claudeBinding.info("binding_hook_silent localID=\(localSessionID.uuidString, privacy: .public)")
                }
            }
        }
        entry.silenceTimer = timer

        entries[localSessionID] = entry
    }

    /// Stoppt das Tracking + Cleanup der Ressourcen. Settings/Event-Files
    /// bleiben auf Disk bis zum Retention-Job.
    func stopTracking(localSessionID: UUID) {
        guard let entry = entries.removeValue(forKey: localSessionID) else { return }
        cleanupEntry(entry)
    }

    func hasReceivedAnyEvent(localSessionID: UUID) -> Bool {
        entries[localSessionID]?.sawFirstEvent == true
    }

    // MARK: - Internals

    private func cleanupEntry(_ entry: Entry) {
        entry.source?.cancel()
        entry.silenceTimer?.invalidate()
    }

    private func handleFileEvent(for entry: Entry) async {
        let eventURL = entry.eventFileURL
        let store = self.store
        let events = await Task.detached(priority: .utility) {
            store.readNewEvents(from: eventURL)
        }.value
        guard !events.isEmpty else { return }
        entry.sawFirstEvent = true
        entry.silenceTimer?.invalidate()
        entry.silenceTimer = nil
        let now = Date()
        for event in events {
            deliver(event, for: entry, now: now)
        }
    }

    private func deliver(_ event: ClaudeHookEvent, for entry: Entry, now: Date) {
        if Self.isThrottledToolEvent(event) {
            if let last = entry.lastDeliveredPreToolUseAt,
               now.timeIntervalSince(last) < preToolUseDeliveryInterval {
                return
            }
            entry.lastDeliveredPreToolUseAt = now
            Logger.claudeBinding.debug("binding_hook_event_received localID=\(entry.localSessionID.uuidString, privacy: .public) event=\(event.hookEventName.rawValue, privacy: .public) sessionID=\(event.sessionID ?? "nil", privacy: .public)")
        } else {
            Logger.claudeBinding.info("binding_hook_event_received localID=\(entry.localSessionID.uuidString, privacy: .public) event=\(event.hookEventName.rawValue, privacy: .public) sessionID=\(event.sessionID ?? "nil", privacy: .public)")
        }
        decisionHandler?(entry.localSessionID, event)
    }

    /// Pre-/PostToolUse koennen schnell aufeinander folgen (viele Tools) —
    /// gemeinsam drosseln (geteilter Timestamp), damit weder Event- noch
    /// Log-Spam entsteht. Die seltenen Events (UserPromptSubmit/Notification/
    /// Stop/Lifecycle) kommen immer ungedrosselt durch.
    ///
    /// AUSNAHME von der Drossel: PreToolUse mit AskUserQuestion/ExitPlanMode
    /// ist die EINZIGE Quelle fuer „Claude hat eine Frage/wartet auf
    /// Plan-Freigabe". Solche Events folgen typischerweise <1 s auf ein
    /// anderes Tool-Event — verworfen hiesse: Chat pulsiert „arbeitet",
    /// waehrend er in Wahrheit auf den User wartet, und die
    /// Rueckfrage-Notification fehlt. (Pur + statisch fuer Unit-Tests.)
    nonisolated static func isThrottledToolEvent(_ event: ClaudeHookEvent) -> Bool {
        switch event.hookEventName {
        case .preToolUse:
            return AgentSessionStateMachine.awaitingKind(forToolName: event.toolName) == nil
        case .postToolUse:
            return true
        default:
            return false
        }
    }
}
