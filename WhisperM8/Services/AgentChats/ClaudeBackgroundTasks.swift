import Darwin
import Foundation

/// Erkennt offene Hintergrund-Tasks einer Claude-Session aus ihrem Transcript.
///
/// Grund (E2E-Test 11.10.2026): „Turn fertig" heißt nicht „Arbeit fertig".
/// Startet Claude ein Bash-Kommando mit `run_in_background` oder einen
/// Subagent im Hintergrund, endet der Turn sofort — der Chat gilt als idle,
/// der Kontowechsel hielt ihn an, und der Task starb mit dem Prozess
/// (`<status>killed</status>`).
///
/// Beide Enden stehen im Transcript, ohne Eingriff in Claude:
/// - **Start:** `toolUseResult.backgroundTaskId` (Bash) bzw.
///   `toolUseResult.status == "async_launched"` mit `agentId` (Subagent).
/// - **Ende:** eine `<task-notification>` mit derselben `<task-id>` — als
///   `queue-operation` (enqueue) oder als User-Nachricht; egal ob
///   `completed`, `killed`, `failed` oder `stopped`.
///
/// Gelesen wird inkrementell ab dem letzten Offset; JSON geparst werden nur
/// Zeilen, die einen der Marker enthalten.
struct ClaudeBackgroundTaskTracker {
    private(set) var offset: UInt64 = 0
    private(set) var started: [String: Date] = [:]
    private(set) var finished: Set<String> = []
    private var partialLine = Data()
    private var fileIdentity: UInt64?

    /// Offen = gestartet, ohne Ende-Meldung. `startedAfter` blendet Tasks
    /// früherer Prozesse aus (die sind mit ihrem Prozess gestorben, auch wenn
    /// keine Meldung im Transcript steht).
    func openTaskIDs(startedAfter: Date? = nil) -> Set<String> {
        Set(started.compactMap { id, date in
            guard !finished.contains(id) else { return nil }
            if let startedAfter, date < startedAfter { return nil }
            return id
        })
    }

    /// Liest neu angehängte Zeilen bis zur Größe beim Nachsehen. Wurde die
    /// Datei ersetzt oder gekürzt, beginnt der Tracker von vorn.
    ///
    /// - Parameter readLimit: Höchstens so viele neue Bytes (Turn-Ende auf
    ///   dem Main Thread, WM8-105). Wären es mehr, oder müsste der Tracker
    ///   von vorn beginnen, liest er nichts und gibt `false` zurück.
    @discardableResult
    mutating func update(from url: URL, readLimit: UInt64? = nil, fileManager: FileManager = .default) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value else { return false }
        let identity = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        let restarts = identity != fileIdentity || size < offset
        if let readLimit {
            guard !restarts, size - offset <= readLimit else { return false }
        }
        if restarts {
            self = ClaudeBackgroundTaskTracker()
            fileIdentity = identity
        }
        guard size > offset else { return true }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            // Blockweise statt `readToEnd`: ein 65-MB-Transcript läge sonst
            // komplett im Speicher (Analyse 11.10.2026). Nur bis zur Größe
            // beim Nachsehen: Was danach dazukommt, liest das nächste Mal.
            while offset < size,
                  let chunk = try handle.read(upToCount: Int(min(UInt64(Self.chunkSize), size - offset))),
                  !chunk.isEmpty {
                offset += UInt64(chunk.count)
                consume(chunk)
            }
        } catch {
            return false
        }
        return true
    }

    /// Offene Läufe beim Turn-Ende (WM8-105): nur die im gerade beendeten
    /// Turn gestarteten. Ein Dev-Server oder `tail -f` aus einem früheren
    /// Turn endet nie und hielte sonst jedes „fertig“ des Chats auf.
    /// `nil` ohne Prozess-Start oder Turn-Start: unbekannt, das Board weckt
    /// wie bisher. Ohne Prozess zählten Läufe längst beendeter Prozesse ohne
    /// Ende-Meldung für immer (`claude --bg` hat keinen Terminal-Prozess).
    func openAtTurnEnd(processStart: Date?, turnStart: Date?) -> Int? {
        guard let processStart, let turnStart else { return nil }
        let since = max(processStart, turnStart.addingTimeInterval(-Self.turnStartTolerance))
        return openTaskIDs(startedAfter: since).count
    }

    /// Der Turn-Start der App kommt etwas nach Claudes eigenem (Registry,
    /// Hook); ein Lauf aus den ersten Sekunden des Turns zählt so noch mit.
    static let turnStartTolerance: TimeInterval = 5

    static let chunkSize = 4 * 1024 * 1024

    mutating func consume(_ data: Data) {
        var buffer = partialLine
        buffer.append(data)
        var lineStart = buffer.startIndex
        while let newline = buffer[lineStart...].firstIndex(of: 0x0A) {
            scan(line: buffer[lineStart..<newline])
            lineStart = buffer.index(after: newline)
        }
        partialLine = Data(buffer[lineStart...])
    }

    private static let startMarkers = [Data("backgroundTaskId".utf8), Data("async_launched".utf8)]
    private static let endMarker = Data("<task-notification>".utf8)

    private mutating func scan(line: Data) {
        let mayStart = Self.startMarkers.contains { line.range(of: $0) != nil }
        let mayEnd = line.range(of: Self.endMarker) != nil
        guard mayStart || mayEnd,
              let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        let type = object["type"] as? String
        if mayStart, type == "user", let result = object["toolUseResult"] as? [String: Any] {
            let id = (result["backgroundTaskId"] as? String)
                ?? (result["status"] as? String == "async_launched" ? result["agentId"] as? String : nil)
            if let id, !id.isEmpty {
                started[id] = Self.timestamp(object["timestamp"] as? String) ?? .distantPast
            }
        }
        if mayEnd, let text = Self.notificationText(object, type: type) {
            finished.formUnion(Self.taskIDs(in: text))
        }
    }

    /// Nur echte Meldungen zählen — eine Tool-Ausgabe, die zufällig
    /// `<task-id>` enthält (z. B. beim Lesen eines Transcripts), nicht.
    private static func notificationText(_ object: [String: Any], type: String?) -> String? {
        let text: String?
        switch type {
        case "queue-operation":
            text = object["content"] as? String
        case "user":
            text = (object["message"] as? [String: Any])?["content"] as? String
        default:
            text = nil
        }
        guard let text, text.hasPrefix("<task-notification>") else { return nil }
        return text
    }

    static func taskIDs(in text: String) -> [String] {
        var ids: [String] = []
        var rest = Substring(text)
        while let open = rest.range(of: "<task-id>") {
            let after = rest[open.upperBound...]
            guard let close = after.range(of: "</task-id>") else { break }
            ids.append(String(after[..<close.lowerBound]))
            rest = after[close.upperBound...]
        }
        return ids
    }

    private static func timestamp(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
}

/// Startzeit eines Prozesses (`sysctl`, `p_starttime`) — trennt Tasks des
/// laufenden Prozesses von denen eines früheren.
enum ProcessStartTime {
    static func of(pid: pid_t) -> Date? {
        microseconds(pid: pid).map { Date(timeIntervalSince1970: TimeInterval($0) / 1_000_000) }
    }

    /// Startzeit in µs seit 1970, `nil` wenn der Prozess nicht mehr lesbar
    /// ist. Unterscheidet einen Prozess von einem späteren mit derselben PID.
    static func microseconds(pid: pid_t) -> UInt64? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        guard start.tv_sec > 0 else { return nil }
        return UInt64(start.tv_sec) * 1_000_000 + UInt64(start.tv_usec)
    }
}

/// Hält je Session einen Tracker, damit wiederholte Prüfungen (Vormerkungen
/// alle 2 s) nur angehängte Bytes lesen. Thread-sicher: der teure erste
/// Durchlauf läuft per `prefetch` im Hintergrund (Analyse 11.10.2026: 0,2–0,4 s
/// je 22–65 MB auf dem Main Thread), danach liest `openTaskCount` auf dem
/// MainActor nur noch Neues. I/O passiert nie unter dem Lock.
final class ClaudeBackgroundTaskMonitor: @unchecked Sendable {
    static let shared = ClaudeBackgroundTaskMonitor()
    private let lock = NSLock()
    private var trackers: [UUID: ClaudeBackgroundTaskTracker] = [:]
    /// Lesen im Hintergrund nacheinander, nie parallel: Nach einem App-Start
    /// lasen sonst bis zu 15 Chats zugleich ihre großen Transcripts.
    private let readQueue = DispatchQueue(label: "com.whisperm8.background-tasks.read", qos: .utility)
    /// Mehr liest das Turn-Ende auf dem Main Thread nie (WM8-105).
    static let turnEndReadLimit: UInt64 = 2 * 1024 * 1024

    /// Tracker herausnehmen, außerhalb des Locks aktualisieren, zurücklegen.
    private func updatedTracker(sessionID: UUID, transcriptURL: URL) -> ClaudeBackgroundTaskTracker {
        lock.lock()
        var tracker = trackers[sessionID] ?? ClaudeBackgroundTaskTracker()
        lock.unlock()
        tracker.update(from: transcriptURL)
        lock.lock()
        // Ein parallel weiter gelesener Tracker gewinnt.
        if let current = trackers[sessionID], current.offset > tracker.offset {
            tracker = current
        } else {
            trackers[sessionID] = tracker
        }
        lock.unlock()
        return tracker
    }

    /// Anzahl offener Hintergrund-Tasks des laufenden Prozesses; 0, wenn das
    /// Transcript (noch) nicht auffindbar ist.
    func openTaskCount(sessionID: UUID, transcriptURL: URL?, processID: pid_t?) -> Int {
        guard let transcriptURL else { return 0 }
        let tracker = updatedTracker(sessionID: sessionID, transcriptURL: transcriptURL)
        let processStart = processID.flatMap(ProcessStartTime.of(pid:))
        return tracker.openTaskIDs(startedAfter: processStart).count
    }

    /// Transcript (Workspace + Locator, ohne Glob — läuft im 2-s-Takt) und PID
    /// (Terminal-Registry) einer laufenden App-Session.
    @MainActor
    func liveTarget(sessionID id: UUID) -> (url: URL?, pid: pid_t?) {
        let workspace = AgentWorkspaceUIModel.shared.workspace
        guard let session = workspace.sessions.first(where: { $0.id == id }),
              session.provider == .claude,
              let externalID = session.externalSessionID, !externalID.isEmpty,
              let cwd = AccountMoveFacts.cwd(for: session, projects: workspace.projects) else { return (nil, nil) }
        let url = AgentTranscriptLocator.locate(
            provider: .claude,
            externalSessionID: externalID,
            cwd: AgentSessionStore.canonicalProjectPath(cwd),
            globFallback: false
        )
        return (url, AgentTerminalRegistry.shared.controller(for: id)?.processID)
    }

    @MainActor
    func openTaskCount(liveSessionID id: UUID) -> Int {
        let target = liveTarget(sessionID: id)
        return openTaskCount(sessionID: id, transcriptURL: target.url, processID: target.pid)
    }

    /// Offene Läufe des gerade beendeten Turns, fürs Board (WM8-105). Liest
    /// auf dem Main Thread höchstens `turnEndReadLimit` neue Bytes; war der
    /// Tracker nie angelesen, wurde die Datei ersetzt oder gekürzt, oder ist
    /// mehr neu, heißt es `nil` (unbekannt, weckt wie bisher) und der Rest
    /// wird im Hintergrund gelesen. Ohne Prozess ebenfalls `nil`.
    @MainActor
    func openTaskCountAtTurnEnd(liveSessionID id: UUID, turnStartedAt: Date?) -> Int? {
        let target = liveTarget(sessionID: id)
        guard let url = target.url, let pid = target.pid else { return nil }
        return openTaskCountAtTurnEnd(
            sessionID: id, transcriptURL: url, processStart: ProcessStartTime.of(pid: pid), turnStart: turnStartedAt)
    }

    /// Kern von `openTaskCountAtTurnEnd(liveSessionID:)`, ohne App-Zustand.
    func openTaskCountAtTurnEnd(sessionID id: UUID, transcriptURL url: URL, processStart: Date?, turnStart: Date?,
                                readLimit: UInt64 = turnEndReadLimit) -> Int? {
        guard processStart != nil else { return nil }
        lock.lock()
        let existing = trackers[id]
        lock.unlock()
        guard var tracker = existing, tracker.update(from: url, readLimit: readLimit) else {
            catchUp(sessionID: id, transcriptURL: url)
            return nil
        }
        store(tracker, for: id)
        return tracker.openAtTurnEnd(processStart: processStart, turnStart: turnStart)
    }

    /// Für Tests: wartet, bis alles Nachlesen auf der Queue durch ist.
    func waitForReads() {
        readQueue.sync {}
    }

    /// Legt einen weiter gelesenen Tracker zurück; ein parallel weiter
    /// gelesener gewinnt.
    private func store(_ tracker: ClaudeBackgroundTaskTracker, for id: UUID) {
        lock.lock()
        if let current = trackers[id], current.offset > tracker.offset {
            // nichts: der andere ist weiter
        } else {
            trackers[id] = tracker
        }
        lock.unlock()
    }

    /// Liest im Hintergrund nach, nacheinander mit allen anderen Lesern.
    func catchUp(sessionID id: UUID, transcriptURL url: URL) {
        readQueue.async { [self] in _ = updatedTracker(sessionID: id, transcriptURL: url) }
    }

    /// Erster Durchlauf im Hintergrund — vor dem Umzugs-Sheet bzw. dem
    /// CLI-Umzug, damit `decide()` synchron bleiben kann und trotzdem nur
    /// noch angehängte Bytes liest.
    @MainActor
    func prefetch(liveSessionIDs ids: [UUID]) async {
        let targets = ids.compactMap { id -> (UUID, URL)? in
            liveTarget(sessionID: id).url.map { (id, $0) }
        }
        // Nacheinander auf der Lese-Queue, nie parallel.
        for (id, url) in targets {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                readQueue.async { [self] in
                    _ = updatedTracker(sessionID: id, transcriptURL: url)
                    done.resume()
                }
            }
        }
    }

    func forget(sessionID: UUID) {
        lock.lock()
        trackers.removeValue(forKey: sessionID)
        lock.unlock()
    }
}
