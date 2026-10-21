import Combine
import Foundation

/// Gemerkte Task-Ordner je Claude-Session-ID, gelernt aus den Hooks
/// `TaskCreated`/`TaskCompleted` (`team_name`). Eigene Datei in Application
/// Support, damit ein App-Neustart oder `--resume` den Ordner wiederfindet.
/// Threadsicher; Lesen und Schreiben nur auf der I/O-Queue des Stores.
final class AgentChatTaskListIndex: @unchecked Sendable {
    static let maxEntries = 400

    private struct Entry: Codable {
        let id: String
        let dir: String
    }

    private let fileURL: URL
    private let lock = NSLock()
    private var entries: [Entry]?

    init(fileURL: URL = AgentChatTaskListIndex.defaultFileURL()) {
        self.fileURL = fileURL
    }

    static func defaultFileURL() -> URL {
        AppInstance.applicationSupport
            .appendingPathComponent("WhisperM8", isDirectory: true)
            .appendingPathComponent("agent-task-lists.json")
    }

    func directory(forExternalID id: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return loaded().last(where: { $0.id == id }).map { URL(fileURLWithPath: $0.dir, isDirectory: true) }
    }

    func remember(_ directory: URL, forExternalID id: String) {
        lock.lock()
        defer { lock.unlock() }
        var list = loaded()
        guard list.last(where: { $0.id == id })?.dir != directory.path else { return }
        list.removeAll { $0.id == id }
        list.append(Entry(id: id, dir: directory.path))
        if list.count > Self.maxEntries { list.removeFirst(list.count - Self.maxEntries) }
        entries = list
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    private func loaded() -> [Entry] {
        if let entries { return entries }
        let list = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        entries = list
        return list
    }
}

/// Hält die Tasks der Claude-Chats, deren Kachel eine Notiz-Karte zeigen kann.
///
/// Muster wie `JarvisNotesStore`: Combine-Publisher je Session statt
/// `@Observable`, damit eine Task-Änderung nur Pfeil und Karte der eigenen
/// Kachel neu zeichnet. Lesen läuft auf einer Utility-Queue (Disk-I/O nie auf
/// dem Main Thread); Änderungen meldet ein FSEvents-Stream auf die
/// `tasks`-Ordner der Konten — kein Polling.
@MainActor
final class AgentChatTasksStore {
    static let shared = AgentChatTasksStore()

    /// Woran die App die Task-Liste eines Chats findet.
    struct Source: Hashable, Sendable {
        let externalSessionID: String
        /// Projektordner des Chats (Claudes Transcript-Pfad hängt daran).
        let cwd: String
    }

    @Published private(set) var tasks: [UUID: [AgentChatTask]] = [:]

    private var sources: [UUID: Source] = [:]
    private var directories: [UUID: URL] = [:]
    private var pendingLoads: Set<UUID> = []
    private var watchedRoots: Set<String> = []
    private var stream: FSEventStreamRef?

    private let ioQueue = DispatchQueue(label: "com.whisperm8.app.task-lists", qos: .utility)
    private let index: AgentChatTaskListIndex
    private let isEnabled: () -> Bool
    private let locateTranscript: @Sendable (Source) -> URL?
    private let watchesFileSystem: Bool

    init(
        index: AgentChatTaskListIndex = AgentChatTaskListIndex(),
        isEnabled: @escaping () -> Bool = { AppPreferences.shared.isAgentChatTasksInNotesEnabled },
        locateTranscript: @escaping @Sendable (Source) -> URL? = { source in
            AgentTranscriptLocator.locate(provider: .claude, externalSessionID: source.externalSessionID, cwd: source.cwd)
        },
        watchesFileSystem: Bool = true
    ) {
        self.index = index
        self.isEnabled = isEnabled
        self.locateTranscript = locateTranscript
        self.watchesFileSystem = watchesFileSystem
    }

    // MARK: Lesen (UI)

    /// Meldet die Tasks eines Chats und beobachtet seine Liste ab jetzt.
    /// `source == nil` (Codex, noch keine externe ID): keine Tasks.
    func tasksPublisher(for sessionID: UUID, source: Source?) -> AnyPublisher<[AgentChatTask], Never> {
        register(sessionID, source: source)
        return $tasks.map { $0[sessionID] ?? [] }.removeDuplicates().eraseToAnyPublisher()
    }

    /// Chats mit laufenden oder offenen Tasks — für den Schalter „Notizen auf/zu“.
    var sessionsWithOpenTasksPublisher: AnyPublisher<Set<UUID>, Never> {
        $tasks.map { all in Set(all.filter { AgentChatTaskSummary.hasOpen($0.value) }.keys) }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    func register(_ sessionID: UUID, source: Source?) {
        guard isEnabled() else { return }
        guard let source, !source.externalSessionID.isEmpty else {
            if sources.removeValue(forKey: sessionID) != nil {
                directories[sessionID] = nil
                tasks[sessionID] = nil
            }
            return
        }
        guard sources[sessionID] != source else { return }
        sources[sessionID] = source
        directories[sessionID] = nil
        resolveAndLoad(sessionID)
    }

    // MARK: Hooks

    /// `TaskCreated`/`TaskCompleted` aus der Hook-Bridge: Claude nennt den
    /// Teamnamen der Session — daraus der Ordner, gemerkt je Session-ID.
    func handleHookEvent(localSessionID: UUID, event: ClaudeHookEvent) {
        guard isEnabled(),
              let externalID = event.sessionID, !externalID.isEmpty,
              let team = event.teamName, !team.isEmpty,
              let transcript = event.transcriptPath, !transcript.isEmpty else { return }
        let configDir = AgentChatTaskDirectory.configDir(forTranscript: URL(fileURLWithPath: transcript))
        let directory = AgentChatTaskDirectory.listDirectory(configDir: configDir, teamName: team)
        let index = self.index
        ioQueue.async { index.remember(directory, forExternalID: externalID) }
        // Nur Chats mit sichtbarer Kachel lesen; die übrigen finden den
        // gemerkten Ordner, sobald ihre Kachel erscheint.
        for (sessionID, source) in sources where source.externalSessionID == externalID {
            if directories[sessionID] != directory {
                directories[sessionID] = directory
                watch(root: directory.deletingLastPathComponent())
            }
            scheduleLoad(sessionID)
        }
    }

    // MARK: Auflösen und Lesen

    private func resolveAndLoad(_ sessionID: UUID) {
        guard let source = sources[sessionID] else { return }
        let index = self.index
        let locate = self.locateTranscript
        ioQueue.async { [weak self] in
            let directory = Self.resolveDirectory(source: source, index: index, locate: locate)
            let loaded = directory.map { AgentChatTaskDirectory.readTasks(in: $0) } ?? []
            Task { @MainActor [weak self] in
                guard let self, self.sources[sessionID] == source else { return }
                self.directories[sessionID] = directory
                if let directory { self.watch(root: directory.deletingLastPathComponent()) }
                self.publish(loaded, for: sessionID)
            }
        }
    }

    /// Gemerkter Ordner aus dem Hook, sonst die erste vorhandene Vermutung im
    /// Konfig-Ordner des Transcripts, sonst die erste Vermutung (entsteht mit
    /// der ersten Task). Ohne Transcript (Chat noch ohne ersten Turn) keiner.
    nonisolated static func resolveDirectory(
        source: Source,
        index: AgentChatTaskListIndex,
        locate: (Source) -> URL?,
        fileManager: FileManager = .default
    ) -> URL? {
        if let known = index.directory(forExternalID: source.externalSessionID) { return known }
        guard let transcript = locate(source) else { return nil }
        let guesses = AgentChatTaskDirectory.guessedDirectories(
            configDir: AgentChatTaskDirectory.configDir(forTranscript: transcript),
            externalSessionID: source.externalSessionID)
        return guesses.first { fileManager.fileExists(atPath: $0.path) } ?? guesses.first
    }

    private func scheduleLoad(_ sessionID: UUID) {
        guard let directory = directories[sessionID], pendingLoads.insert(sessionID).inserted else { return }
        let source = sources[sessionID]
        ioQueue.async { [weak self] in
            let loaded = AgentChatTaskDirectory.readTasks(in: directory)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pendingLoads.remove(sessionID)
                guard self.sources[sessionID] == source, self.directories[sessionID] == directory else { return }
                self.publish(loaded, for: sessionID)
            }
        }
    }

    private func publish(_ loaded: [AgentChatTask], for sessionID: UUID) {
        if tasks[sessionID] ?? [] != loaded { tasks[sessionID] = loaded }
    }

    // MARK: FSEvents

    /// Pure: welche Chats ein Ereignis betrifft — ihr Ordner selbst oder eine
    /// Datei darin. Chats ohne aufgelösten Ordner versuchen es bei jedem
    /// Ereignis unter einem beobachteten Wurzelordner erneut (das Transcript
    /// kann inzwischen da sein).
    nonisolated static func affectedSessions(paths: [String], directories: [UUID: URL]) -> Set<UUID> {
        var result: Set<UUID> = []
        for (sessionID, directory) in directories {
            // FSEvents meldet echte Pfade: Symlinks im Konfig-Ordner auflösen.
            let dir = directory.resolvingSymlinksInPath().path
            if paths.contains(where: { $0 == dir || $0.hasPrefix(dir + "/") }) { result.insert(sessionID) }
        }
        return result
    }

    private func handleFileEvents(paths: [String]) {
        for sessionID in Self.affectedSessions(paths: paths, directories: directories) {
            scheduleLoad(sessionID)
        }
        for sessionID in sources.keys where directories[sessionID] == nil {
            resolveAndLoad(sessionID)
        }
    }

    private func watch(root: URL) {
        guard watchesFileSystem else { return }
        let path = root.resolvingSymlinksInPath().path
        guard !watchedRoots.contains(path), FileManager.default.fileExists(atPath: path) else { return }
        watchedRoots.insert(path)
        restartStream()
    }

    private func restartStream() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        guard !watchedRoots.isEmpty else { return }
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info,
                  let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] else { return }
            let store = Unmanaged<AgentChatTasksStore>.fromOpaque(info).takeUnretainedValue()
            Task { @MainActor in store.handleFileEvents(paths: paths) }
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            Array(watchedRoots).sorted() as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        ) else {
            Logger.agentPerformance.error("task_lists_fsevents_start_failed")
            return
        }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "com.whisperm8.app.task-lists-fsevents", qos: .utility))
        FSEventStreamStart(stream)
        self.stream = stream
        Logger.agentPerformance.info("task_lists_fsevents_started roots=\(self.watchedRoots.count, privacy: .public)")
    }
}
