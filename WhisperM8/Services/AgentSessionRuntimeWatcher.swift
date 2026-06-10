import Combine
import Foundation

/// Ephemeraler Speicher für `AgentSessionRuntimeStatus` pro `sessionID`.
/// Wird zur Laufzeit vom `AgentSessionRuntimeWatcher` gepflegt und von der
/// Sidebar (`SessionListButton`) zur Visualisierung beobachtet.
///
/// Bewusst nicht persistiert: nach App-Restart sind alle Sessions aus
/// Watcher-Sicht wieder „unbekannt" — der `AgentChatStatus` (`.running`/
/// `.closed`) auf der persistierten `AgentChatSession` bleibt die einzige
/// dauerhafte Wahrheit.
@MainActor
final class AgentSessionRuntimeStatusStore: ObservableObject {
    @Published private(set) var statuses: [UUID: AgentSessionRuntimeStatus] = [:]

    func status(for sessionID: UUID) -> AgentSessionRuntimeStatus? {
        statuses[sessionID]
    }

    /// Per-Item-Publisher für die Sidebar-Rows: emittiert nur Änderungen
    /// DIESER Session (removeDuplicates filtert fremde Ticks). @Published
    /// liefert beim Subscriben synchron den aktuellen Wert.
    ///
    /// Bewusst Combine statt einer @Observable-Migration des Stores:
    /// Observation trackt nur property-genau — `statuses` ist EINE Property,
    /// jede Mutation würde weiterhin alle lesenden Rows invalidieren.
    func statusPublisher(for sessionID: UUID) -> AnyPublisher<AgentSessionRuntimeStatus?, Never> {
        $statuses
            .map { $0[sessionID] }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    func setStatus(_ status: AgentSessionRuntimeStatus, for sessionID: UUID) {
        if statuses[sessionID] == status { return }
        // Signpost-EVENT (kein Intervall): zählt die tatsächlichen
        // @Published-Mutationen — also die Re-Render-Trigger der
        // Sidebar-Rows. Soll: ein Event pro echtem Statuswechsel, null
        // Events bei stabilem Status (in Instruments als Event-Dichte
        // ablesbar).
        PerfSignposts.sidebar.emitEvent("sidebar.statusChanged")
        statuses[sessionID] = status
    }

    func clear(sessionID: UUID) {
        statuses.removeValue(forKey: sessionID)
    }

    func clearAll() {
        guard !statuses.isEmpty else { return }
        statuses.removeAll()
    }
}

/// Polled-File-Watcher, der für jede aktive Session deren Transcript-File tailt
/// und daraus den `AgentSessionRuntimeStatus` ableitet. Bei erkanntem Turn-End
/// triggert er den Auto-Naming-Pfad via `onTurnFinished`.
///
/// Bewusst kein FSEventStream: Pollen mit ~1.5 s Intervall reicht für die
/// Sidebar-UX vollkommen aus, ist deutlich einfacher zu implementieren und
/// vermeidet das gesamte Coalescing-/Subdir-Watch-Verhalten von FSEvents.
@MainActor
final class AgentSessionRuntimeWatcher {
    /// Tail-Größe pro Poll. Eine Claude-Assistant-Message kann mehrere KB groß
    /// sein (Tool-Use-Blöcke!), daher großzügig dimensioniert.
    nonisolated static let tailReadBytes: Int = 64 * 1024
    nonisolated static let pollInterval: TimeInterval = 1.5

    weak var statusStore: AgentSessionRuntimeStatusStore?
    /// Wird einmal pro neu erkanntem Turn-End aufgerufen. Empfänger ist
    /// `AgentChatsView`, das daraufhin `lastTurnAt` schreibt und ggf. den
    /// Auto-Namer anstößt.
    var onTurnFinished: ((UUID) -> Void)?

    private var watched: [UUID: WatchedSession] = [:]
    private var pollingSessionIDs: Set<UUID> = []
    private var pollTimer: Timer?

    init(statusStore: AgentSessionRuntimeStatusStore, onTurnFinished: ((UUID) -> Void)? = nil) {
        self.statusStore = statusStore
        self.onTurnFinished = onTurnFinished
    }

    deinit {
        pollTimer?.invalidate()
    }

    /// Beginnt das Tracking einer Session. Wenn `transcriptURL` zum Zeitpunkt
    /// des Aufrufs `nil` ist (Claude/Codex haben das File noch nicht angelegt
    /// oder die `externalSessionID` ist noch nicht gebunden), wird beim
    /// nächsten Poll erneut versucht zu lokalisieren.
    func watch(
        sessionID: UUID,
        provider: AgentProvider,
        externalSessionID: String?,
        cwd: String,
        priorTurnFinishedAt: Date?
    ) {
        var entry = watched[sessionID] ?? WatchedSession(
            id: sessionID,
            provider: provider,
            cwd: cwd,
            externalSessionID: externalSessionID,
            transcriptURL: nil,
            lastTurnFinishedAt: priorTurnFinishedAt
        )
        entry.provider = provider
        entry.cwd = cwd
        if let externalSessionID {
            entry.externalSessionID = externalSessionID
        }
        if entry.transcriptURL == nil {
            entry.transcriptURL = resolveTranscriptURL(for: entry)
        }
        watched[sessionID] = entry
        ensureTimer()

        // Sofortiger Tick, damit der Status nicht erst nach `pollInterval`
        // aufschlägt — wichtig fürs Erlebnis beim Wechseln zwischen Sessions.
        pollOne(sessionID: sessionID)
    }

    func unwatch(sessionID: UUID) {
        watched.removeValue(forKey: sessionID)
        statusStore?.clear(sessionID: sessionID)
        if watched.isEmpty {
            stopTimer()
        }
    }

    func setExternalSessionID(_ externalSessionID: String, for sessionID: UUID) {
        guard var entry = watched[sessionID] else { return }
        entry.externalSessionID = externalSessionID
        entry.transcriptURL = resolveTranscriptURL(for: entry)
        watched[sessionID] = entry
        pollOne(sessionID: sessionID)
    }

    /// Manuell als „beendet" markieren — z. B. wenn der Subprocess via
    /// `processTerminated` exited. Schreibt direkt den finalen Status, ohne auf
    /// das nächste Poll-Tick zu warten.
    func markTerminated(sessionID: UUID, exitCode: Int32?) {
        let status: AgentSessionRuntimeStatus = (exitCode ?? 0) != 0 ? .errored : .stopped
        statusStore?.setStatus(status, for: sessionID)
        watched.removeValue(forKey: sessionID)
        if watched.isEmpty {
            stopTimer()
        }
    }

    // MARK: - Polling

    private func ensureTimer() {
        guard pollTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollAll()
            }
        }
        timer.tolerance = Self.pollInterval * 0.25
        pollTimer = timer
    }

    private func stopTimer() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func pollAll() {
        for sessionID in watched.keys {
            pollOne(sessionID: sessionID)
        }
    }

    private func pollOne(sessionID: UUID) {
        guard let entry = watched[sessionID],
              !pollingSessionIDs.contains(sessionID) else { return }
        pollingSessionIDs.insert(sessionID)
        // Manuelles Token statt withInterval: Begin und End laufen über die
        // Task-Grenze. Das End steht VOR dem `guard let self` — das Intervall
        // muss auch dann schließen, wenn der Watcher inzwischen weg ist.
        let pollToken = PerfBudgets.sidebarStatusPoll.begin()

        Task { @MainActor [weak self] in
            let snapshot = await Task.detached(priority: .utility) {
                Self.pollSnapshot(for: entry, now: Date())
            }.value

            PerfBudgets.sidebarStatusPoll.end(pollToken)
            guard let self else { return }
            self.pollingSessionIDs.remove(sessionID)
            guard var current = self.watched[sessionID] else { return }
            current.transcriptURL = snapshot.transcriptURL

            guard let decision = snapshot.decision else {
                self.watched[sessionID] = current
                if self.statusStore?.status(for: sessionID) == nil {
                    self.statusStore?.setStatus(.working, for: sessionID)
                }
                return
            }

            self.statusStore?.setStatus(decision.status, for: sessionID)

            if decision.turnFinished {
                current.lastTurnFinishedAt = Date()
                self.watched[sessionID] = current
                self.onTurnFinished?(sessionID)
            } else {
                self.watched[sessionID] = current
            }
        }
    }

    private func resolveTranscriptURL(for entry: WatchedSession) -> URL? {
        Self.resolveTranscriptURL(for: entry)
    }

    nonisolated private static func resolveTranscriptURL(for entry: WatchedSession) -> URL? {
        guard let externalSessionID = entry.externalSessionID, !externalSessionID.isEmpty else {
            return nil
        }
        return AgentTranscriptLocator.locate(
            provider: entry.provider,
            externalSessionID: externalSessionID,
            cwd: entry.cwd
        )
    }

    // MARK: - File helpers

    nonisolated private static func pollSnapshot(
        for entry: WatchedSession,
        now: Date
    ) -> AgentSessionRuntimePollSnapshot {
        let transcriptURL = entry.transcriptURL ?? resolveTranscriptURL(for: entry)
        guard let url = transcriptURL,
              let mtime = fileMTime(at: url),
              let tail = readTail(at: url, bytes: tailReadBytes) else {
            return AgentSessionRuntimePollSnapshot(transcriptURL: transcriptURL, decision: nil)
        }

        let lastEvent = AgentTranscriptParser.lastEvent(in: tail, provider: entry.provider)
        let decision = AgentTranscriptStatusDecider.decide(
            lastEvent: lastEvent,
            fileMTime: mtime,
            now: now,
            priorTurnFinishedAt: entry.lastTurnFinishedAt
        )
        return AgentSessionRuntimePollSnapshot(transcriptURL: transcriptURL, decision: decision)
    }

    nonisolated private static func fileMTime(at url: URL) -> Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return attrs[.modificationDate] as? Date
    }

    /// Liest die letzten `bytes` Bytes der Datei als UTF-8-String. Truncation
    /// am Anfang wird durch das Zeilen-Splitting im Parser absorbiert (erste
    /// halbe Zeile ist nicht parsebar → wird übersprungen).
    nonisolated private static func readTail(at url: URL, bytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            let offset = UInt64(max(0, Int64(size) - Int64(bytes)))
            try handle.seek(toOffset: offset)
            let data = handle.readData(ofLength: bytes)
            return String(data: data, encoding: .utf8)
                ?? String(decoding: data, as: UTF8.self)
        } catch {
            return nil
        }
    }
}

private struct WatchedSession {
    let id: UUID
    var provider: AgentProvider
    var cwd: String
    var externalSessionID: String?
    var transcriptURL: URL?
    var lastTurnFinishedAt: Date?
}

private struct AgentSessionRuntimePollSnapshot {
    var transcriptURL: URL?
    var decision: AgentTranscriptStatusDecider.Decision?
}
