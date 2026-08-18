import Foundation

/// FSEvents-Watcher für das Changes-Panel: beobachtet den Working Tree GENAU
/// EINES Projekts und meldet debounced „etwas hat sich geändert". Lebt nur,
/// solange das Panel sichtbar ist (start/stop am View-Lifecycle) — Panel zu
/// heißt null Kosten. Kein globaler Dienst, kein Singleton.
///
/// `.git`-interne Events sind erwünscht (Commit/Stage ändern die Liste);
/// die Rückkopplung durch den eigenen `git status` verhindert dessen
/// `--no-optional-locks` (siehe `GitChangesSnapshot.load`).
@MainActor
final class ProjectChangesWatcher {
    private var stream: FSEventStreamRef?
    private var debounceTask: Task<Void, Never>?
    private let debounceInterval: TimeInterval
    private let onChange: () -> Void

    init(debounceInterval: TimeInterval = 0.75, onChange: @escaping () -> Void) {
        self.debounceInterval = debounceInterval
        self.onChange = onChange
    }

    func start(path: String) {
        stop()
        guard FileManager.default.fileExists(atPath: path) else { return }

        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<ProjectChangesWatcher>.fromOpaque(info).takeUnretainedValue()
            Task { @MainActor in
                watcher.scheduleChange()
            }
        }

        // FSEvents-eigene Latenz (1 s) fasst Bursts zusammen; kein
        // kFileEvents-Flag — Verzeichnisgranularität reicht (wir laden ohnehin
        // den ganzen Status) und ist bei node_modules-Stürmen deutlich billiger.
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
        ) else {
            Logger.agentPerformance.error("project_changes_fsevents_start_failed")
            return
        }

        FSEventStreamSetDispatchQueue(
            stream,
            DispatchQueue(label: "com.whisperm8.app.project-changes", qos: .utility)
        )
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        debounceTask?.cancel()
        debounceTask = nil
    }

    private func scheduleChange() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [debounceInterval, onChange] in
            try? await Task.sleep(for: .seconds(debounceInterval))
            guard !Task.isCancelled else { return }
            onChange()
        }
    }
}
