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
    private var stream: FSEventStreamRef?
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
        guard stream == nil else { return }

        // Das Root-Verzeichnis kann vor dem ersten CLI-Job fehlen — FSEvents
        // braucht einen existierenden Pfad, sonst kommen nie Events.
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let callback: FSEventStreamCallback = { _, info, eventCount, eventPaths, _, _ in
            guard let info else { return }
            let monitor = Unmanaged<AgentJobDirectoryMonitor>.fromOpaque(info).takeUnretainedValue()
            guard let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] else {
                return
            }
            _ = eventCount
            Task { @MainActor in
                monitor.handleEvents(paths: paths)
            }
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [rootURL.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        ) else {
            Logger.agentPerformance.error("agent_job_fsevents_start_failed")
            return
        }

        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "com.whisperm8.app.job-fsevents", qos: .utility))
        FSEventStreamStart(stream)
        self.stream = stream
        Logger.agentPerformance.info("agent_job_fsevents_started root=\(self.rootURL.path, privacy: .public)")
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
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
