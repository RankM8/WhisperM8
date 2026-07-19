import Foundation

// MARK: - Blockierendes `chats wait`

/// Wartet, bis eine beobachtete Session einen Statuswechsel erlebt, der das
/// gewählte Prädikat erfüllt — und gibt genau ein Event aus. Ersetzt das
/// Report-/Notification-System des alten Jarvis-Plans.
///
/// Mechanik: pro Transcript-Datei ein `DispatchSourceFileSystemObject`
/// (Muster: `ClaudeHookBridge`) plus ein Fallback-Poll-Timer (Missed-Event-
/// Netz) plus ein Timeout-Timer. Bei jedem Write wird der Status one-shot neu
/// abgeleitet (`ChatsStatusProbe`) und gegen den zuletzt bekannten Zustand
/// geprüft. Kein FSEvents, keine App nötig.
final class ChatsWaitEngine {
    enum Predicate: Equatable {
        case attention        // awaitingInput | errored | Turn-Ende (working→idle/stopped)
        case idle             // Ziel(e) beenden ihren Turn
        case statusChange     // jeder Übergang

        static func parse(_ raw: String) -> Predicate? {
            switch raw {
            case "attention": return .attention
            case "idle": return .idle
            case "statusChange": return .statusChange
            default: return nil
            }
        }
    }

    struct Event {
        var sessionID: UUID
        var projectName: String
        var title: String
        var from: AgentSessionRuntimeStatus?
        var to: AgentSessionRuntimeStatus?
        var afterSeconds: Int
        var revision: Int?
        var source: String
    }

    private let entries: [ChatsSessionEntry]
    private let predicate: Predicate
    private let sinceRevision: Int?
    private let timeout: TimeInterval
    private let debounceInterval: TimeInterval = 0.3
    private let fallbackPollInterval: TimeInterval = 10

    private var lastStatus: [UUID: AgentSessionRuntimeStatus?] = [:]
    private var lastRevision: [UUID: Int] = [:]
    private var turnStartAt: [UUID: Date] = [:]
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var fileDescriptors: [Int32] = []
    /// Aktuell beobachteter Transcript-Pfad je Session — Grundlage der
    /// Rotations-Erkennung (Pfadwechsel → Re-Arm im Fallback-Poll).
    private var watchedPaths: [UUID: String] = [:]
    /// Sessions, deren Watch nach delete/rename gecancelt wurde und die im
    /// Fallback-Poll neu armiert werden müssen.
    private var pendingRearm: Set<UUID> = []
    private let queue = DispatchQueue(label: "com.whisperm8.chats-wait")
    private var resolved = false

    init(entries: [ChatsSessionEntry], predicate: Predicate, sinceRevision: Int?, timeout: TimeInterval) {
        self.entries = entries
        self.predicate = predicate
        self.sinceRevision = sinceRevision
        self.timeout = timeout
    }

    /// Blockiert bis zum Event, Timeout oder SIGINT. `nil` = Timeout.
    func run() -> Event? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Event?

        // Initiale Statusaufnahme — erfüllt das Prädikat vielleicht schon
        // (inkl. --since-Kurzschluss).
        let now = Date()
        for entry in entries {
            let info = ChatsStatusProbe.probe(entry: entry, now: now)
            lastStatus[entry.session.id] = info.status
            if let rev = info.revision { lastRevision[entry.session.id] = rev }
            if info.status == .working { turnStartAt[entry.session.id] = info.since ?? now }
            // --since: liegt schon ein neueres Event vor?
            if let sinceRevision, let rev = info.revision, rev > sinceRevision,
               let event = evaluate(entry: entry, previous: nil, current: info, now: now) {
                return event
            }
        }

        // Watches armieren.
        for entry in entries {
            let info = ChatsStatusProbe.probe(entry: entry, now: now)
            guard let path = info.transcriptPath else { continue }
            armWatch(path: path, entry: entry, semaphore: semaphore) { result = $0 }
            watchedPaths[entry.session.id] = path
            if watchers.count >= 64 {
                CLIIO.err("Hinweis: nur die ersten 64 Sessions werden beobachtet.")
                break
            }
        }

        // Lost-Event-Fenster schließen (GPT-Review): Zwischen der initialen
        // Statusaufnahme und der Watch-Armierung können Writes passiert sein —
        // einmal sofort re-evaluieren, NACHDEM die Watches stehen.
        queue.async { [weak self] in
            self?.reevaluateAll(semaphore: semaphore) { result = $0 }
        }

        // Fallback-Poll (Missed-Event-Netz) — re-armiert außerdem Watches auf
        // rotierte Transcripts (delete/rename cancelt nur; der Locator im
        // Probe findet die neue Datei, hier hängen wir den Watch wieder an).
        let pollTimer = DispatchSource.makeTimerSource(queue: queue)
        pollTimer.schedule(deadline: .now() + fallbackPollInterval, repeating: fallbackPollInterval)
        pollTimer.setEventHandler { [weak self] in
            guard let self else { return }
            self.rearmRotatedWatches(semaphore: semaphore) { result = $0 }
            self.reevaluateAll(semaphore: semaphore) { result = $0 }
        }
        pollTimer.resume()

        // Timeout.
        let timeoutTimer = DispatchSource.makeTimerSource(queue: queue)
        timeoutTimer.schedule(deadline: .now() + timeout)
        timeoutTimer.setEventHandler { [weak self] in
            guard let self, !self.resolved else { return }
            self.resolved = true
            semaphore.signal()
        }
        timeoutTimer.resume()

        // SIGINT → Exit 130 (der Aufrufer prüft danach `resolved`).
        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: queue)
        signal(SIGINT, SIG_IGN)
        sigintSource.setEventHandler { [weak self] in
            guard let self, !self.resolved else { return }
            self.resolved = true
            self.interrupted = true
            semaphore.signal()
        }
        sigintSource.resume()

        semaphore.wait()

        pollTimer.cancel()
        timeoutTimer.cancel()
        sigintSource.cancel()
        for watcher in watchers { watcher.cancel() }
        return result
    }

    private(set) var interrupted = false

    // MARK: - Intern

    private func armWatch(
        path: String,
        entry: ChatsSessionEntry,
        semaphore: DispatchSemaphore,
        deliver: @escaping (Event) -> Void
    ) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        fileDescriptors.append(fd)
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: queue)
        var debounceWorkItem: DispatchWorkItem?
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let mask = source.data
            if mask.contains(.delete) || mask.contains(.rename) {
                // Datei rotiert (Kompaktierung) — Watch schließen und für den
                // Re-Arm im Fallback-Poll vormerken (der Locator im Probe
                // findet die neue Datei).
                source.cancel()
                self.watchedPaths.removeValue(forKey: entry.session.id)
                self.pendingRearm.insert(entry.session.id)
                return
            }
            // Debounce: mehrere Writes bündeln.
            debounceWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.reevaluate(entry: entry, semaphore: semaphore, deliver: deliver)
            }
            debounceWorkItem = work
            self.queue.asyncAfter(deadline: .now() + self.debounceInterval, execute: work)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watchers.append(source)
    }

    /// Re-armiert Watches für Sessions, deren Transcript rotiert wurde —
    /// sobald der Locator (via Probe) den neuen Pfad kennt.
    private func rearmRotatedWatches(semaphore: DispatchSemaphore, deliver: @escaping (Event) -> Void) {
        guard !resolved, !pendingRearm.isEmpty else { return }
        for entry in entries where pendingRearm.contains(entry.session.id) {
            let info = ChatsStatusProbe.probe(entry: entry, now: Date())
            guard let path = info.transcriptPath else { continue }
            pendingRearm.remove(entry.session.id)
            watchedPaths[entry.session.id] = path
            armWatch(path: path, entry: entry, semaphore: semaphore, deliver: deliver)
        }
    }

    private func reevaluateAll(semaphore: DispatchSemaphore, deliver: @escaping (Event) -> Void) {
        for entry in entries {
            reevaluate(entry: entry, semaphore: semaphore, deliver: deliver)
            if resolved { return }
        }
    }

    private func reevaluate(entry: ChatsSessionEntry, semaphore: DispatchSemaphore, deliver: @escaping (Event) -> Void) {
        guard !resolved else { return }
        let now = Date()
        let current = ChatsStatusProbe.probe(entry: entry, now: now)
        let previous = lastStatus[entry.session.id] ?? nil

        // Turn-Start-Tracking für afterSeconds.
        if current.status == .working, turnStartAt[entry.session.id] == nil {
            turnStartAt[entry.session.id] = current.since ?? now
        }

        if let event = evaluate(entry: entry, previous: previous, current: current, now: now) {
            resolved = true
            deliver(event)
            semaphore.signal()
            return
        }

        lastStatus[entry.session.id] = current.status
        if let rev = current.revision { lastRevision[entry.session.id] = rev }
    }

    /// Test-Zugang zur puren Übergangs-Bewertung (ohne Filesystem-Watching).
    func evaluateForTest(
        entry: ChatsSessionEntry,
        previous: AgentSessionRuntimeStatus?,
        current: ChatsRuntimeInfo,
        now: Date = Date()
    ) -> Event? {
        evaluate(entry: entry, previous: previous, current: current, now: now)
    }

    /// Prüft, ob der Übergang previous→current das Prädikat erfüllt.
    private func evaluate(
        entry: ChatsSessionEntry,
        previous: AgentSessionRuntimeStatus?,
        current: ChatsRuntimeInfo,
        now: Date
    ) -> Event? {
        let to = current.status
        let matches: Bool
        switch predicate {
        case .attention:
            // awaitingInput/errored immer; Turn-Ende (working→idle/stopped).
            if to == .awaitingInput || to == .errored {
                matches = previous != to
            } else if (to == .idle || to == .stopped), previous == .working {
                matches = true
            } else if previous == nil, to == .awaitingInput || to == .errored {
                matches = true
            } else {
                matches = false
            }
        case .idle:
            matches = (to == .idle || to == .stopped) && previous != to
        case .statusChange:
            matches = previous != to && previous != nil
        }
        guard matches else { return nil }

        let start = turnStartAt[entry.session.id] ?? current.since ?? now
        return Event(
            sessionID: entry.session.id,
            projectName: entry.projectName,
            title: entry.session.title,
            from: previous,
            to: to,
            afterSeconds: max(0, Int(now.timeIntervalSince(start))),
            revision: current.revision,
            source: current.source
        )
    }
}

// MARK: - CLI-Befehl

enum ChatsWaitCommand {
    static func run(_ arguments: [String]) -> Int32 {
        var refs: [String] = []
        var predicateRaw = "attention"
        var sinceRevision: Int?
        var timeout: TimeInterval = 1800
        var json = false
        var index = 0
        func value(_ flag: String) -> String? {
            index += 1
            guard index < arguments.count else { CLIIO.err("\(flag) erwartet einen Wert."); return nil }
            return arguments[index]
        }
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--ref": guard let v = value(arg) else { return ChatsCLIExit.usage }; refs.append(v)
            case "--until": guard let v = value(arg) else { return ChatsCLIExit.usage }; predicateRaw = v
            case "--since":
                guard let v = value(arg), let rev = Int(v) else { CLIIO.err("--since erwartet eine Zahl."); return ChatsCLIExit.usage }
                sinceRevision = rev
            case "--timeout":
                guard let v = value(arg), let secs = TimeInterval(v), secs > 0 else { CLIIO.err("--timeout erwartet positive Sekunden."); return ChatsCLIExit.usage }
                timeout = secs
            case "--json": json = true
            default: CLIIO.err("Unbekannte Option: \(arg)"); return ChatsCLIExit.usage
            }
            index += 1
        }
        guard let predicate = ChatsWaitEngine.Predicate.parse(predicateRaw) else {
            CLIIO.err("--until muss attention|idle|statusChange sein.")
            return ChatsCLIExit.usage
        }

        let context = ChatsCommandContext.load()
        var entries: [ChatsSessionEntry]
        if refs.isEmpty {
            // Alle aktiven Sessions mit auffindbarem Transcript.
            entries = context.scopedEntries(all: false)
        } else {
            entries = []
            for ref in refs {
                switch context.resolve(ref: ref, includeArchived: false) {
                case .success(let entry): entries.append(entry)
                case .failure(let code): return code
                }
            }
        }
        guard !entries.isEmpty else {
            CLIIO.err("Keine Sessions zu beobachten.")
            return ChatsCLIExit.notFound
        }

        let engine = ChatsWaitEngine(entries: entries, predicate: predicate,
                                     sinceRevision: sinceRevision, timeout: timeout)
        let event = engine.run()

        if engine.interrupted {
            return ChatsCLIExit.interrupted
        }
        guard let event else {
            if json {
                CLIIO.out(ChatsOutput.encodeJSON(["schemaVersion": 1, "event": "timeout"]))
            } else {
                CLIIO.err("Timeout — kein Ereignis innerhalb von \(Int(timeout)) s.")
            }
            return ChatsCLIExit.timeout
        }

        if json {
            CLIIO.out(ChatsOutput.encodeJSON([
                "schemaVersion": 1,
                "event": "statusChanged",
                "session": [
                    "id": event.sessionID.uuidString,
                    "title": event.title,
                    "project": event.projectName,
                ],
                "from": event.from?.rawValue ?? NSNull(),
                "to": event.to?.rawValue ?? "unknown",
                "afterSeconds": event.afterSeconds,
                "revision": event.revision ?? NSNull(),
                "source": event.source,
            ]))
        } else {
            let from = event.from?.rawValue ?? "?"
            let to = event.to?.rawValue ?? "unknown"
            CLIIO.out("● \(event.projectName)/\(event.title): \(from) → \(to) (nach \(event.afterSeconds) s)")
        }
        return ChatsCLIExit.ok
    }
}
