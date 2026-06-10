import AppKit
import Foundation

/// Prozessweiter In-Memory-Kern für den Agent-Workspace (Refactor-Plan P1).
///
/// Vorher machte JEDE Mutation über die `AgentSessionStore`-Facade ein
/// synchrones Voll-Load (Decode + Migrationsprüfung) und Voll-Save der
/// kompletten AgentSessions.json — ohne Lock. UI, Indexer/Scan,
/// RuntimeWatcher und AutoNamer haben sich dabei gegenseitig Writes
/// überschrieben (Last-Writer-Wins auf Dateiebene).
///
/// Jetzt: genau EIN Load pro Prozess (lazy beim ersten Zugriff), alle Reads
/// aus dem Speicher, alle Mutationen prozessweit serialisiert hinter einem
/// NSLock, Persistenz Equatable-diff-gated und (für die Produktions-URL)
/// debounced + atomar.
///
/// Architektur-Entscheid: bewusst KEIN actor/@MainActor-Kern — die Facade
/// ist synchron-throws und wird aus Detached-Tasks (Scan/Index/Retention)
/// sowie non-MainActor-Tests aufgerufen. MainActor-Observability liefert die
/// dünne Projektion `AgentWorkspaceUIModel`.
final class AgentWorkspaceStore: @unchecked Sendable {
    enum PersistencePolicy {
        /// Jede Änderung wird sofort (synchron) geschrieben; Save-Fehler
        /// werfen. Verhalten der Tests (eigene temp-fileURLs).
        case immediate
        /// Änderungen werden gesammelt und nach dem Intervall atomar
        /// geschrieben; Save-Fehler werden geloggt und beim nächsten Flush
        /// erneut versucht. Produktions-Verhalten.
        case debounced(TimeInterval)
    }

    private let lock = NSLock()
    private var canonical: AgentWorkspace?
    private let loadInitial: () -> AgentWorkspace
    private let persist: (AgentWorkspace) throws -> Void
    /// Invariante des Kerns: `canonical` ist IMMER normalisiert (Migrations-
    /// Prunes wie removeUnresumableClaudeSessions). Vorher liefen die Prunes
    /// bei jedem Disk-Load — also implizit vor jeder Mutation und jedem Read;
    /// jetzt laufen sie einmal beim Initial-Load und nach jeder Mutation.
    private let normalize: (AgentWorkspace) -> AgentWorkspace
    private let policy: PersistencePolicy

    /// Debounce-Zustand: serielle Queue + rearmierbarer WorkItem.
    private let flushQueue = DispatchQueue(label: "com.whisperm8.app.workspace-flush", qos: .utility)
    private var pendingFlush: DispatchWorkItem?
    private var dirty = false
    private var terminateObserver: NSObjectProtocol?

    /// Wird nach jeder effektiven Mutation mit dem neuen Stand gerufen
    /// (außerhalb des Locks). Konsument: `AgentWorkspaceUIModel`.
    var onWorkspaceChanged: ((AgentWorkspace) -> Void)?

    init(
        loadInitial: @escaping () -> AgentWorkspace,
        persist: @escaping (AgentWorkspace) throws -> Void,
        normalize: @escaping (AgentWorkspace) -> AgentWorkspace = { $0 },
        policy: PersistencePolicy = .immediate
    ) {
        self.loadInitial = loadInitial
        self.persist = persist
        self.normalize = normalize
        self.policy = policy

        if case .debounced = policy {
            // App-Ende darf keine gepufferten Änderungen verlieren.
            terminateObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.flush()
            }
        }
    }

    deinit {
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
        }
    }

    func read<T>(_ body: (AgentWorkspace) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(loadedLocked())
    }

    /// Serialisierte Mutation: Lock → Body → Equatable-Diff → Persist.
    /// Der Body darf KEINE Subprozesse/Blocking-I/O enthalten (läuft unter
    /// dem prozessweiten Lock) — git-Lookups etc. vorher berechnen und als
    /// Wert hineinreichen.
    func mutate<T>(_ body: (inout AgentWorkspace) throws -> T) throws -> T {
        lock.lock()
        var workspace = loadedLocked()
        let before = workspace
        let result: T
        do {
            result = try body(&workspace)
        } catch {
            lock.unlock()
            throw error
        }
        workspace = normalize(workspace)

        guard workspace != before else {
            lock.unlock()
            return result
        }

        canonical = workspace
        do {
            try persistLocked(workspace)
        } catch {
            lock.unlock()
            throw error
        }
        lock.unlock()
        onWorkspaceChanged?(workspace)
        return result
    }

    func replace(_ workspace: AgentWorkspace) throws {
        try mutate { $0 = workspace }
    }

    /// Erzwingt das sofortige Schreiben gepufferter Änderungen (debounced-
    /// Policy). Für .immediate ein No-op.
    func flush() {
        lock.lock()
        pendingFlush?.cancel()
        pendingFlush = nil
        guard dirty, let workspace = canonical else {
            lock.unlock()
            return
        }
        dirty = false
        lock.unlock()

        do {
            try persist(workspace)
        } catch {
            Logger.agentPerformance.error("agent_store_flush_failed error=\(error.localizedDescription, privacy: .public)")
            lock.lock()
            dirty = true
            lock.unlock()
        }
    }

    // MARK: - Intern (nur unter Lock rufen)

    private func loadedLocked() -> AgentWorkspace {
        if let canonical { return canonical }
        let loaded = loadInitial()
        canonical = loaded
        return loaded
    }

    private func persistLocked(_ workspace: AgentWorkspace) throws {
        switch policy {
        case .immediate:
            try persist(workspace)
        case .debounced(let interval):
            dirty = true
            pendingFlush?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.flush()
            }
            pendingFlush = workItem
            flushQueue.asyncAfter(deadline: .now() + interval, execute: workItem)
        }
    }
}

/// Liefert pro Datei-Pfad genau EINE Store-Instanz — damit teilen sich alle
/// ad-hoc erzeugten `AgentSessionStore`-Facade-Kopien (UI, Scan, AutoNamer,
/// RecordingCoordinator, …) denselben serialisierten Kern.
enum AgentWorkspaceStoreRegistry {
    private static let lock = NSLock()
    private static var stores: [String: AgentWorkspaceStore] = [:]

    static func store(for fileURL: URL) -> AgentWorkspaceStore {
        let key = fileURL.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        if let existing = stores[key] {
            return existing
        }

        let repository = AgentWorkspaceRepository(fileURL: fileURL)
        // Debounce NUR für die Produktions-URL: explizit injizierte fileURLs
        // (= alle Tests) behalten die synchrone Datei-Semantik.
        let isDefaultURL = key == AgentWorkspaceRepository.defaultFileURL().standardizedFileURL.path
        let store = AgentWorkspaceStore(
            loadInitial: { repository.load(migrate: AgentSessionStore.migratedWorkspace) },
            persist: { try repository.save($0) },
            normalize: AgentSessionStore.migratedWorkspace,
            policy: isDefaultURL ? .debounced(0.5) : .immediate
        )
        stores[key] = store
        return store
    }
}
