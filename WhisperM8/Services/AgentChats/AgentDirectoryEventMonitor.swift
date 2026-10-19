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
    private var settleTask: Task<Void, Never>?
    private let debounceInterval: TimeInterval
    private let settleInterval: TimeInterval
    private let rootURLs: [URL]
    /// Höchstwartezeit des Debounce (LR-AK-016): Reißt der Strom relevanter
    /// Events nicht ab, wird trotzdem nach dieser Zeit ein Scan angefordert.
    private let maxWaitInterval: TimeInterval
    /// Beginn des aktuell laufenden Debounce-Fensters.
    private var debounceWindowStart: Date?
    /// Scan-Anforderung (Test-Seam).
    private let requestScan: @MainActor (AgentScanCoordinator.Reason) -> Void

    init(
        rootURLs: [URL]? = nil,
        debounceInterval: TimeInterval = 5.0,
        settleInterval: TimeInterval = 30.0,
        maxWaitInterval: TimeInterval = 30.0,
        requestScan: @escaping @MainActor (AgentScanCoordinator.Reason) -> Void = {
            AgentScanCoordinator.shared.requestScan(reason: $0)
        }
    ) {
        self.maxWaitInterval = maxWaitInterval
        self.requestScan = requestScan
        let home = AppInstance.home
        // `.claude-profiles` statt der einzelnen Profil-projects-Dirs: so
        // werden auch NACH App-Start angelegte Account-Profile erfasst.
        // `relevantPaths` filtert Nicht-Transcript-JSONL (history.jsonl etc.).
        self.rootURLs = rootURLs ?? [
            home.appendingPathComponent(".claude/projects", isDirectory: true),
            home.appendingPathComponent(".claude-profiles", isDirectory: true),
            home.appendingPathComponent(".codex/sessions", isDirectory: true),
        ]
        self.debounceInterval = debounceInterval
        self.settleInterval = settleInterval
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
                // Subagent-Transcripts ueberspringt der Indexer grundsaetzlich
                // (`ClaudeSessionIndexer`, Filter auf `/subagents/`). Ein Scan,
                // den sie ausloesen, kann per Konstruktion nichts finden — er
                // laeuft nur ueber alle 3.030 Dateien und verdraengt dabei
                // alles andere. Und sie sind die MEHRHEIT: 2.270 der 3.030
                // vorhandenen JSONL liegen unter `/subagents/`, jeder laufende
                // Subagent schreibt im Sekundentakt.
                //
                // ACHTUNG: Diese Bedingung gehoert mit dem Filter im Indexer
                // zusammen. Sollen Subagent-Transcripts kuenftig indiziert
                // werden, muessen BEIDE Stellen gemeinsam geaendert werden.
                && !path.contains("/subagents/")
                && !watchedTranscriptPaths.contains(path)
        }
    }

    /// LR-AK-033 (C): Nur Strukturaenderungen (neue, umbenannte, geloeschte
    /// Datei) sind Scan-Ausloeser. Ein reines Modify einer bekannten Datei
    /// aendert nichts, was der Scan nicht ueber seine Laufzeit-Pfade ohnehin
    /// sieht — und jeder extern aktive Chat schreibt sekuendlich, das hielt den
    /// Indexer in einer Dauerschleife. Verlorene Events (Dropped/MustScan)
    /// zaehlen als Strukturaenderung, weil dann unklar ist, was passiert ist.
    nonisolated static func triggersScan(flags: UInt32) -> Bool {
        let structural = UInt32(
            kFSEventStreamEventFlagItemCreated
                | kFSEventStreamEventFlagItemRenamed
                | kFSEventStreamEventFlagItemRemoved
                | kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped
        )
        return flags & structural != 0
    }

    func start() {
        guard stream == nil else { return }

        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let callback: FSEventStreamCallback = { _, info, eventCount, eventPaths, eventFlags, _ in
            guard let info else { return }
            let monitor = Unmanaged<AgentDirectoryEventMonitor>.fromOpaque(info).takeUnretainedValue()
            guard let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] else {
                return
            }
            // Nur Pfade mit strukturellem Flag weiterreichen (siehe `triggersScan`).
            var structuralPaths: [String] = []
            for index in 0..<min(eventCount, paths.count)
            where AgentDirectoryEventMonitor.triggersScan(flags: UInt32(eventFlags[index])) {
                structuralPaths.append(paths[index])
            }
            guard !structuralPaths.isEmpty else { return }
            Task { @MainActor in
                monitor.handleEvents(paths: structuralPaths)
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
        settleTask?.cancel()
        settleTask = nil
    }

    func handleEvents(paths: [String]) {
        let relevant = Self.relevantPaths(
            paths,
            watchedTranscriptPaths: AgentSessionRuntimeWatcher.sharedWatchedTranscriptPaths
        )
        guard !relevant.isEmpty else { return }

        // Debounce: externe Sessions schreiben in Bursts — ein Scan pro
        // Burst reicht. Der .fsEvent-Cooldown im Coordinator (10 s) ist die
        // zweite Bremse.
        // Trailing-Debounce MIT Höchstwartezeit: dauernde Events dürfen den
        // Scan nicht endlos verschieben (LR-AK-016).
        let windowStart = debounceWindowStart ?? Date()
        debounceWindowStart = windowStart
        let remainingMax = max(0, maxWaitInterval - Date().timeIntervalSince(windowStart))
        let wait = min(debounceInterval, remainingMax)
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else { return }
            self.debounceWindowStart = nil
            self.requestScan(.fsEvent)
        }

        // Nachzügler-Scan: Eine frisch angelegte Datei kann beim ersten Scan
        // noch ohne cwd sein und wird dann als „skipped“ gecacht. Ihr weiteres
        // Wachstum ist nur Modify und löst seit LR-AK-033 keinen Scan mehr aus —
        // ohne diesen zweiten Durchlauf bliebe sie bis zum nächsten
        // Foreground-Scan unsichtbar. Ein Folge-Event ersetzt den Task; der
        // Coordinator-Cooldown verschiebt ihn höchstens, er verfällt nicht.
        settleTask?.cancel()
        settleTask = Task { @MainActor [settleInterval, weak self] in
            try? await Task.sleep(for: .seconds(settleInterval))
            guard !Task.isCancelled, let self else { return }
            self.requestScan(.fsEvent)
        }
    }
}
