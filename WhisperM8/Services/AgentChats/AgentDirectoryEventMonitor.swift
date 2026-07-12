import Foundation

/// FSEvents-Monitor auf `~/.claude/projects` und `~/.codex/sessions` (P2 S4):
/// triggert den Session-Scan, sobald extern neue Transcript-Dateien
/// auftauchen — statt auf den 30-s-Foreground-Scan zu warten.
///
/// Hier ist FSEvents die richtige Wahl: Coalescing und Subdir-Rekursion —
/// die Gründe, aus denen der Runtime-Watcher vnode-Sources nutzt — sind für
/// einen Scan-Trigger erwünscht statt schädlich.
@MainActor
final class AgentDirectoryEventMonitor {
    static let shared = AgentDirectoryEventMonitor()

    private var stream: FSEventStreamRef?
    private var debounceTask: Task<Void, Never>?
    private let debounceInterval: TimeInterval
    private let rootURLs: [URL]

    init(
        rootURLs: [URL]? = nil,
        debounceInterval: TimeInterval = 5.0
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        // `.claude-profiles` statt der einzelnen Profil-projects-Dirs: so
        // werden auch NACH App-Start angelegte Account-Profile erfasst.
        // `relevantPaths` filtert Nicht-Transcript-JSONL (history.jsonl etc.).
        self.rootURLs = rootURLs ?? [
            home.appendingPathComponent(".claude/projects", isDirectory: true),
            home.appendingPathComponent(".claude-profiles", isDirectory: true),
            home.appendingPathComponent(".codex/sessions", isDirectory: true),
        ]
        self.debounceInterval = debounceInterval
    }

    /// Pure, testbarer Filter: nur .jsonl-Transcript-Pfade sind relevant, und
    /// Pfade aktuell live-gewatchter Transcripts werden VERWORFEN — sonst
    /// würde jede aktive In-App-Session (schreibt sekündlich) dauerhaft Scans
    /// auslösen. Transcripts liegen immer unter einem `projects/`- (Claude)
    /// bzw. `sessions/`-Segment (Codex) — das haelt Profil-interne JSONL wie
    /// `history.jsonl` aus dem Scan-Trigger heraus (der `.claude-profiles`-
    /// Root wird als GANZES gewatcht, damit neue Profile ohne Neustart zaehlen).
    nonisolated static func relevantPaths(
        _ paths: [String],
        watchedTranscriptPaths: Set<String>
    ) -> [String] {
        paths.filter { path in
            path.hasSuffix(".jsonl")
                && (path.contains("/projects/") || path.contains("/sessions/"))
                && !watchedTranscriptPaths.contains(path)
        }
    }

    func start() {
        guard stream == nil else { return }

        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let callback: FSEventStreamCallback = { _, info, eventCount, eventPaths, _, _ in
            guard let info else { return }
            let monitor = Unmanaged<AgentDirectoryEventMonitor>.fromOpaque(info).takeUnretainedValue()
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
            rootURLs.map(\.path) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            2.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        ) else {
            Logger.agentPerformance.error("agent_fsevents_start_failed")
            return
        }

        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "com.whisperm8.app.fsevents", qos: .utility))
        FSEventStreamStart(stream)
        self.stream = stream
        Logger.agentPerformance.info("agent_fsevents_started roots=\(self.rootURLs.map(\.path).joined(separator: ","), privacy: .public)")
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
        let relevant = Self.relevantPaths(
            paths,
            watchedTranscriptPaths: AgentSessionRuntimeWatcher.sharedWatchedTranscriptPaths
        )
        guard !relevant.isEmpty else { return }

        // Debounce: externe Sessions schreiben in Bursts — ein Scan pro
        // Burst reicht. Der .fsEvent-Cooldown im Coordinator (10 s) ist die
        // zweite Bremse.
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [debounceInterval] in
            try? await Task.sleep(for: .seconds(debounceInterval))
            guard !Task.isCancelled else { return }
            AgentScanCoordinator.shared.requestScan(reason: .fsEvent)
        }
    }
}
