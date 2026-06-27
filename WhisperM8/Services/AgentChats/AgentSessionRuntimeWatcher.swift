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
/// P2: Event-getrieben mit Poll-Fallback. Pro aktiver Transcript-Datei hängt
/// eine vnode-`FileEventSource` (Write/Extend → sofortiger, debounced Poll;
/// Delete/Rename → Re-Arm beim nächsten Tick). Der 1,5-s-Timer bleibt mit
/// drei Restaufgaben: URL-Resolution für Sessions ohne Datei, zeitbasierte
/// Status-Eskalation (stat-first: 1 stat()-Syscall statt 64-KB-Read) und
/// mtime-Fallback für verpasste Kernel-Events.
///
/// Bewusst vnode-Sources statt FSEvents für den Status: FSEvents coalesced
/// und beobachtet Subtrees — für die punktgenaue Datei-Beobachtung hier wäre
/// beides schädlich (der Scan-Trigger `AgentDirectoryEventMonitor` will
/// genau das und nutzt FSEvents). Kill-Switch ohne Rebuild:
/// `defaults write com.whisperm8.app agentEventDrivenWatchEnabled -bool NO`.
@MainActor
final class AgentSessionRuntimeWatcher {
    /// Tail-Größe pro Poll. Eine Claude-Assistant-Message kann mehrere KB groß
    /// sein (Tool-Use-Blöcke!), daher großzügig dimensioniert.
    nonisolated static let tailReadBytes: Int = 64 * 1024
    nonisolated static let pollInterval: TimeInterval = 1.5
    /// Coalescing-Fenster für vnode-Events — JSONL-Appends kommen in Bursts,
    /// ein Read pro Burst reicht.
    nonisolated static let eventDebounce: Duration = .milliseconds(180)
    /// Codex-URL-Resolution ist ein rekursiver ~/.codex/sessions-Walk —
    /// bei fehlender Datei nur jeden 4. Tick erneut versuchen.
    nonisolated static let resolveCooldownTicks = 3

    /// Pfade aller aktuell live-gewatchten Transcripts — der FSEvents-
    /// Scan-Trigger filtert sie heraus (aktive In-App-Sessions schreiben
    /// sekündlich und würden sonst dauerhaft Scans auslösen).
    static private(set) var sharedWatchedTranscriptPaths: Set<String> = []

    weak var statusStore: AgentSessionRuntimeStatusStore?
    /// Wird einmal pro neu erkanntem Turn-End aufgerufen. Empfänger ist
    /// `AgentChatsView`, das daraufhin `lastTurnAt` schreibt und ggf. den
    /// Auto-Namer anstößt.
    var onTurnFinished: ((UUID) -> Void)?

    private var watched: [UUID: WatchedSession] = [:]
    private var pollingSessionIDs: Set<UUID> = []
    /// Trailing-Edge: kam während eines laufenden Polls ein vnode-Event,
    /// wird die Session nach Abschluss SOFORT erneut gepollt — Events dürfen
    /// nicht verworfen werden (das alte Set-Verhalten hätte sie gedroppt).
    private var pendingRepoll: Set<UUID> = []
    /// Coalescing für geplante Event-Polls (ein Task pro Burst).
    private var scheduledEventPolls: Set<UUID> = []
    private var eventSources: [UUID: FileEventSource] = [:]
    /// Einmal pro Init gelesen — Kill-Switch wirkt nach App-Neustart.
    private let eventDrivenEnabled = AppPreferences.shared.isAgentEventDrivenWatchEnabled
    private var pollTimer: Timer?

    // Phase-3-Test-Seams: Datei-IO als @Sendable-Closures (laufen off-main in
    // Task.detached). Defaults = die echten static-Helfer → Verhalten 1:1.
    private let statProvider: @Sendable (URL) -> AgentTranscriptFileStat?
    private let tailProvider: @Sendable (URL, Int) -> String?
    private let urlResolver: @Sendable (WatchedSession) -> URL?

    init(
        statusStore: AgentSessionRuntimeStatusStore,
        onTurnFinished: ((UUID) -> Void)? = nil,
        statProvider: @escaping @Sendable (URL) -> AgentTranscriptFileStat? = { AgentSessionRuntimeWatcher.fileStat(at: $0) },
        tailProvider: @escaping @Sendable (URL, Int) -> String? = { AgentSessionRuntimeWatcher.readTail(at: $0, bytes: $1) },
        urlResolver: @escaping @Sendable (WatchedSession) -> URL? = { AgentSessionRuntimeWatcher.resolveTranscriptURL(for: $0) }
    ) {
        self.statusStore = statusStore
        self.onTurnFinished = onTurnFinished
        self.statProvider = statProvider
        self.tailProvider = tailProvider
        self.urlResolver = urlResolver
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
        entry.generation += 1
        watched[sessionID] = entry
        attachEventSourceIfPossible(sessionID: sessionID)
        ensureTimer()

        // Sofortiger Tick, damit der Status nicht erst nach `pollInterval`
        // aufschlägt — wichtig fürs Erlebnis beim Wechseln zwischen Sessions.
        pollOne(sessionID: sessionID)
    }

    func unwatch(sessionID: UUID) {
        detachEventSource(sessionID: sessionID)
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
        entry.lastStat = nil
        entry.cachedLastEvent = nil
        entry.generation += 1
        watched[sessionID] = entry
        detachEventSource(sessionID: sessionID)
        attachEventSourceIfPossible(sessionID: sessionID)
        pollOne(sessionID: sessionID)
    }

    /// Manuell als „beendet" markieren — z. B. wenn der Subprocess via
    /// `processTerminated` exited. Schreibt direkt den finalen Status, ohne auf
    /// das nächste Poll-Tick zu warten.
    func markTerminated(sessionID: UUID, exitCode: Int32?) {
        let status: AgentSessionRuntimeStatus = (exitCode ?? 0) != 0 ? .errored : .stopped
        statusStore?.setStatus(status, for: sessionID)
        detachEventSource(sessionID: sessionID)
        watched.removeValue(forKey: sessionID)
        if watched.isEmpty {
            stopTimer()
        }
    }

    // MARK: - vnode-Event-Sources (P2)

    private func attachEventSourceIfPossible(sessionID: UUID) {
        guard eventDrivenEnabled,
              eventSources[sessionID] == nil,
              let url = watched[sessionID]?.transcriptURL else { return }

        let source = FileEventSource(url: url)
        source.onChange = { [weak self] in
            self?.scheduleEventPoll(sessionID: sessionID)
        }
        source.onFileGone = { [weak self] in
            // Delete/Rename (z. B. Atomic-Rewrite): Source ist weg, Cache
            // nullen — der nächste Timer-Tick re-resolved und re-attacht.
            guard let self, var entry = self.watched[sessionID] else { return }
            entry.transcriptURL = nil
            entry.lastStat = nil
            entry.cachedLastEvent = nil
            entry.generation += 1
            self.watched[sessionID] = entry
            self.detachEventSource(sessionID: sessionID)
        }

        if source.start() {
            eventSources[sessionID] = source
            Self.sharedWatchedTranscriptPaths.insert(url.path)
        }
        // Schlägt start() fehl (FD-Limit o. ä.), bleibt die Session ohne
        // Source auf dem klassischen Timer-Poll — der Fallback lebt immer.
    }

    private func detachEventSource(sessionID: UUID) {
        guard let source = eventSources.removeValue(forKey: sessionID) else { return }
        if let url = watched[sessionID]?.transcriptURL {
            Self.sharedWatchedTranscriptPaths.remove(url.path)
        }
        source.stop()
        // Pfad-Set defensiv neu aufbauen, falls die URL oben schon genullt war.
        Self.sharedWatchedTranscriptPaths = Set(
            eventSources.keys.compactMap { watched[$0]?.transcriptURL?.path }
        )
    }

    /// Debounced Poll nach vnode-Event: ein Read pro Burst; läuft ein Poll
    /// bereits, wird via `pendingRepoll` nachgefasst statt gedroppt.
    private func scheduleEventPoll(sessionID: UUID) {
        if pollingSessionIDs.contains(sessionID) {
            pendingRepoll.insert(sessionID)
            return
        }
        guard !scheduledEventPolls.contains(sessionID) else { return }
        scheduledEventPolls.insert(sessionID)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.eventDebounce)
            guard let self else { return }
            self.scheduledEventPolls.remove(sessionID)
            self.pollOne(sessionID: sessionID)
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
        guard var entry = watched[sessionID],
              !pollingSessionIDs.contains(sessionID) else { return }

        // Codex-URL-Resolution drosseln: der rekursive ~/.codex-Walk muss
        // bei fehlender Datei nicht alle 1,5 s laufen.
        if entry.transcriptURL == nil, entry.provider == .codex {
            if entry.resolveCooldown > 0 {
                entry.resolveCooldown -= 1
                watched[sessionID] = entry
                return
            }
        }

        pollingSessionIDs.insert(sessionID)
        // Manuelles Token statt withInterval: Begin und End laufen über die
        // Task-Grenze. Das End steht VOR dem `guard let self` — das Intervall
        // muss auch dann schließen, wenn der Watcher inzwischen weg ist.
        let pollToken = PerfBudgets.sidebarStatusPoll.begin()
        let snapshotEntry = entry
        let snapshotGeneration = entry.generation
        let statProvider = self.statProvider
        let tailProvider = self.tailProvider
        let urlResolver = self.urlResolver

        Task { @MainActor [weak self] in
            let snapshot = await Task.detached(priority: .utility) {
                Self.pollSnapshot(
                    for: snapshotEntry,
                    now: Date(),
                    statProvider: statProvider,
                    tailProvider: tailProvider,
                    urlResolver: urlResolver
                )
            }.value

            PerfBudgets.sidebarStatusPoll.end(pollToken)
            guard let self else { return }
            self.pollingSessionIDs.remove(sessionID)
            defer {
                // Trailing-Edge: kam während des Polls ein vnode-Event,
                // sofort nachfassen.
                if self.pendingRepoll.remove(sessionID) != nil {
                    self.pollOne(sessionID: sessionID)
                }
            }
            guard var current = self.watched[sessionID] else { return }

            // Generation-Guard: hat sich der Eintrag während des Polls
            // geändert (neue externalSessionID, File-Gone-Reset), darf der
            // veraltete Snapshot keinen Cache zurückschreiben.
            guard current.generation == snapshotGeneration else { return }

            current.transcriptURL = snapshot.transcriptURL
            current.lastStat = snapshot.stat
            current.cachedLastEvent = snapshot.lastEvent
            if snapshot.transcriptURL == nil, current.provider == .codex {
                current.resolveCooldown = Self.resolveCooldownTicks
            }

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

            // URL erstmals aufgelöst → Event-Source nachrüsten.
            if snapshot.transcriptURL != nil {
                self.attachEventSourceIfPossible(sessionID: sessionID)
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

    nonisolated static func pollSnapshot(
        for entry: WatchedSession,
        now: Date,
        statProvider: @Sendable (URL) -> AgentTranscriptFileStat?,
        tailProvider: @Sendable (URL, Int) -> String?,
        urlResolver: @Sendable (WatchedSession) -> URL?
    ) -> AgentSessionRuntimePollSnapshot {
        let transcriptURL = entry.transcriptURL ?? urlResolver(entry)
        guard let url = transcriptURL,
              let stat = statProvider(url) else {
            return AgentSessionRuntimePollSnapshot(transcriptURL: transcriptURL, decision: nil, stat: nil, lastEvent: nil)
        }

        // Stat-first (P2 S1): Datei unverändert → KEIN 64-KB-Read; die
        // zeitbasierten Eskalationen (8 s/30 s im Decider) werden mit dem
        // gecachten letzten Event re-evaluiert. I/O pro Tick = 1 stat().
        if let lastStat = entry.lastStat, lastStat == stat {
            let decision = AgentTranscriptStatusDecider.decide(
                lastEvent: entry.cachedLastEvent,
                fileMTime: stat.mtime,
                now: now,
                priorTurnFinishedAt: entry.lastTurnFinishedAt
            )
            return AgentSessionRuntimePollSnapshot(
                transcriptURL: url,
                decision: decision,
                stat: stat,
                lastEvent: entry.cachedLastEvent
            )
        }

        guard let tail = tailProvider(url, tailReadBytes) else {
            return AgentSessionRuntimePollSnapshot(transcriptURL: url, decision: nil, stat: nil, lastEvent: nil)
        }

        let lastEvent = AgentTranscriptParser.lastEvent(in: tail, provider: entry.provider)
        let decision = AgentTranscriptStatusDecider.decide(
            lastEvent: lastEvent,
            fileMTime: stat.mtime,
            now: now,
            priorTurnFinishedAt: entry.lastTurnFinishedAt
        )
        return AgentSessionRuntimePollSnapshot(
            transcriptURL: url,
            decision: decision,
            stat: stat,
            lastEvent: lastEvent
        )
    }

    nonisolated private static func fileStat(at url: URL) -> AgentTranscriptFileStat? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date else {
            return nil
        }
        return AgentTranscriptFileStat(mtime: mtime, size: (attrs[.size] as? Int) ?? 0)
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

struct AgentTranscriptFileStat: Equatable {
    var mtime: Date
    var size: Int
}

struct WatchedSession {
    let id: UUID
    var provider: AgentProvider
    var cwd: String
    var externalSessionID: String?
    var transcriptURL: URL?
    var lastTurnFinishedAt: Date?
    /// Stat-first-Cache (P2): mtime+size des letzten Reads + das geparste
    /// letzte Event. Unveränderter Stat → kein erneuter Tail-Read.
    var lastStat: AgentTranscriptFileStat?
    var cachedLastEvent: AgentTranscriptEvent?
    /// Drosselt die Codex-URL-Resolution (rekursiver Verzeichnis-Walk).
    var resolveCooldown: Int = 0
    /// Write-back-Guard: Snapshots, die gegen eine ältere Generation
    /// gestartet wurden, dürfen den Cache nicht überschreiben.
    var generation: Int = 0
}

struct AgentSessionRuntimePollSnapshot {
    var transcriptURL: URL?
    var decision: AgentTranscriptStatusDecider.Decision?
    /// Stat + geparstes Event zum Zurückschreiben in den WatchedSession-Cache.
    var stat: AgentTranscriptFileStat?
    var lastEvent: AgentTranscriptEvent?
}
