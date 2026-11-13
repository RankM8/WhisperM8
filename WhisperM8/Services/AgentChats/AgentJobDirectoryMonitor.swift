import Foundation

/// FSEvents-Monitor auf das Subagent-Job-Verzeichnis
/// (`~/Library/Application Support/WhisperM8/agent-jobs/`) — Vorbild
/// `AgentDirectoryEventMonitor`, aber mit eigenem Callback statt Scan-Trigger:
/// der `AgentJobWorkspaceSync` hängt sich an `onJobsChanged`.
///
/// Kürzeres Debounce (0,5 s statt 5 s): state.json-Flips sind einzelne,
/// atomare Writes — der User soll den Phasenwechsel (running→done) zeitnah
/// in der Sidebar sehen.
@MainActor
final class AgentJobDirectoryMonitor {
    /// Endet mit dem Besitzer (deinit der Subscription), auch ohne stop().
    private var subscription: FSEventsSubscription?
    private var debounceTask: Task<Void, Never>?
    private let debounceInterval: TimeInterval
    private let rootURL: URL

    /// Wird (debounced) gerufen, sobald sich Job-Zustände geändert haben
    /// können — der Sync liest dann alle state.jsons frisch.
    var onJobsChanged: (() -> Void)?

    init(
        rootURL: URL = AgentJobStore.defaultRootDirectory,
        debounceInterval: TimeInterval = 0.5
    ) {
        self.rootURL = rootURL
        self.debounceInterval = debounceInterval
    }

    /// Pure, testbarer Pfadfilter: NUR `state.json` und `last-message.txt`
    /// sind sync-relevant. `events.jsonl` wird während eines Turns im Burst
    /// beschrieben (jede codex-Event-Zeile ein Append) und würde sonst
    /// Dauer-Syncs auslösen; Temp-Dateien (`state.json.tmp-…`) und
    /// supervisor.log sind ebenfalls Rauschen.
    nonisolated static func relevantPaths(_ paths: [String]) -> [String] {
        paths.filter { path in
            let name = (path as NSString).lastPathComponent
            return name == "state.json" || name == "last-message.txt"
        }
    }

    func start() {
        guard subscription == nil else { return }

        // Das Root-Verzeichnis kann vor dem ersten CLI-Job fehlen — FSEvents
        // braucht einen existierenden Pfad, sonst kommen nie Events.
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        guard let subscription = FSEventsSubscription(
            paths: [rootURL.path],
            latency: 0.3,
            flags: FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents),
            queue: DispatchQueue(label: "com.whisperm8.app.job-fsevents", qos: .utility),
            handler: { [weak self] paths, _ in
                Task { @MainActor [weak self] in self?.handleEvents(paths: paths) }
            }
        ) else {
            Logger.agentPerformance.error("agent_job_fsevents_start_failed")
            return
        }
        self.subscription = subscription
        Logger.agentPerformance.info("agent_job_fsevents_started root=\(self.rootURL.path, privacy: .public)")
    }

    func stop() {
        guard let subscription else { return }
        subscription.cancel()
        self.subscription = nil
        debounceTask?.cancel()
        debounceTask = nil
    }

    private func handleEvents(paths: [String]) {
        guard !Self.relevantPaths(paths).isEmpty else { return }

        // Debounce: ein Turn-Ende schreibt state.json + last-message.txt kurz
        // hintereinander — ein Sync pro Burst reicht.
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [debounceInterval] in
            try? await Task.sleep(for: .seconds(debounceInterval))
            guard !Task.isCancelled else { return }
            self.onJobsChanged?()
        }
    }
}
