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
    private let notificationCenter: NotificationCenter

    /// Debounce-Zustand: serielle Queue + rearmierbarer WorkItem.
    private let flushQueue = DispatchQueue(label: "com.whisperm8.app.workspace-flush", qos: .utility)
    private var pendingFlush: DispatchWorkItem?
    private var dirty = false
    /// Zeitpunkt der ersten noch ungesicherten Mutation — Basis der harten
    /// Max-Latenz: Dauermutationen im Abstand < Debounce-Intervall dürfen den
    /// Write nicht beliebig hinauszögern (Review-Befund 2026-07-13).
    private var firstDirtyAt: Date?
    static let maxDebounceLatency: TimeInterval = 2.0
    /// Serialisiert die eigentlichen Persist-Aufrufe: Zwei parallel gestartete
    /// Flushes könnten sonst in beliebiger Reihenfolge schreiben — beendet
    /// sich der ÄLTERE Snapshot zuletzt, regressiert die Datei, ohne wieder
    /// dirty zu sein (Review-Befund 2026-07-13). Unter diesem Lock wird immer
    /// der NEUESTE canonical-Stand gezogen und geschrieben.
    private let persistLock = NSLock()
    private var terminateObserver: NSObjectProtocol?
    private var resignObserver: NSObjectProtocol?

    /// Wird nach jeder effektiven Mutation mit dem neuen Stand gerufen
    /// (außerhalb des Locks). Konsument: `AgentWorkspaceUIModel`.
    var onWorkspaceChanged: ((AgentWorkspace) -> Void)?

    init(
        loadInitial: @escaping () -> AgentWorkspace,
        persist: @escaping (AgentWorkspace) throws -> Void,
        normalize: @escaping (AgentWorkspace) -> AgentWorkspace = { $0 },
        policy: PersistencePolicy = .immediate,
        notificationCenter: NotificationCenter = .default
    ) {
        self.loadInitial = loadInitial
        self.persist = persist
        self.normalize = normalize
        self.policy = policy
        self.notificationCenter = notificationCenter

        if case .debounced = policy {
            // App-Ende darf keine gepufferten Änderungen verlieren.
            terminateObserver = notificationCenter.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.flushSync(reason: "terminate")
            }

            // Sicherheitsnetz gegen nicht-graceful Quit: Force-Quit/Crash kündigt
            // sich oft durch Fokusverlust an. Bei Resign-Active gepufferte
            // Änderungen sofort sichern (flush ist No-op, wenn nichts dirty ist).
            resignObserver = notificationCenter.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.flush(reason: "resign")
            }
        }
    }

    deinit {
        if let terminateObserver {
            notificationCenter.removeObserver(terminateObserver)
        }
        if let resignObserver {
            notificationCenter.removeObserver(resignObserver)
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
        workspace = PerfBudgets.storeNormalize.withInterval {
            normalize(workspace)
        }

        let changed = PerfBudgets.storeEquality.withInterval {
            workspace != before
        }
        guard changed else {
            lock.unlock()
            return result
        }

        canonical = workspace
        do {
            try persistLocked(workspace)
        } catch {
            canonical = before
            lock.unlock()
            throw error
        }
        lock.unlock()
        onWorkspaceChanged?(workspace)
        return result
    }

    /// Variante mit fachlichem Änderungsvertrag. `false` verwirft den lokalen
    /// CoW-Snapshot sofort: keine Normalisierung, kein Deep-Equatable, kein
    /// Callback und kein Persist. Bei `true` garantiert der Aufrufer eine
    /// effektive Änderung; die Normalisierung bleibt als Sicherheitsnetz.
    func mutateIfChanged(
        _ body: (inout AgentWorkspace) throws -> Bool
    ) throws {
        lock.lock()
        var workspace = loadedLocked()
        let before = workspace
        let didChange: Bool
        do {
            didChange = try body(&workspace)
        } catch {
            lock.unlock()
            throw error
        }

        guard didChange else {
            lock.unlock()
            return
        }

        workspace = PerfBudgets.storeNormalize.withInterval {
            normalize(workspace)
        }
        canonical = workspace
        do {
            try persistLocked(workspace)
        } catch {
            canonical = before
            lock.unlock()
            throw error
        }
        lock.unlock()
        onWorkspaceChanged?(workspace)
    }

    func replace(_ workspace: AgentWorkspace) throws {
        try mutate { $0 = workspace }
    }

    /// Erzwingt das sofortige Schreiben gepufferter Änderungen (debounced-
    /// Policy). Für .immediate ein No-op. `reason` nur für Telemetrie
    /// (Datenverlust-Diagnose): "debounce" (Timer), "terminate" (App-Ende),
    /// "create"/"delete" (strukturelle Mutation, crash-safe sofort).
    func flush(reason: String = "debounce") {
        // Die Test-Policy behaelt ihre bisherige Semantik: Mutationen
        // persistieren synchron, flush selbst ist ein vollstaendiger No-op.
        guard case .debounced = policy else { return }

        lock.lock()
        pendingFlush?.cancel()
        pendingFlush = nil
        lock.unlock()

        // Auch strukturelle Sofort-Flushes umgehen nur das Debounce-Intervall,
        // nie die Utility-Queue: JSON-Encoding und atomare Writes duerfen den
        // MainActor nicht blockieren. Immer enqueueen: Falls ein laufender
        // Persist gerade fehlschlaegt, setzt dessen Catch dirty erst danach
        // wieder; der seriell nachgeordnete Drain muss diesen Retry sehen.
        //
        // BEWUSSTER TRADE-OFF (2026-07-13): "crash-safe sofort" heisst seit
        // dem Async-Umbau "sofort enqueued", nicht "vor Rueckkehr auf Disk".
        // Ein SIGKILL im Millisekunden-Fenster bis zum Drain verliert die
        // letzte strukturelle Mutation — vorher blockierte dafuer der Main
        // Thread pro Flush 50-200 ms (3-MB-Encode, der eigentliche
        // Chat-Start-Freeze). Abgefedert wird das doppelt: graceful Quit
        // wartet ueber flushSync/willTerminate, und verlorene Sessions
        // adoptiert der Indexer-Scan aus den externen Transcripts zurueck
        // (Superset-Prinzip). Restrisiko: backgroundShortID-Bindungen.
        flushQueue.async { [weak self] in
            self?.drain(reason: reason)
        }
    }

    /// Ausschliesslich fuer willTerminate: NotificationCenter stellt den
    /// Observer synchron auf dem Main Thread zu, daher muss vor der Rueckkehr
    /// auch der serielle Persist-Drain abgeschlossen sein.
    private func flushSync(reason: String) {
        lock.lock()
        pendingFlush?.cancel()
        pendingFlush = nil
        lock.unlock()

        // Der Drain dispatcht selbst nie auf Main; flushQueue ist eine eigene
        // Utility-Queue. sync muss auch bei dirty=false stattfinden: Ein Drain
        // kann den Snapshot bereits beansprucht haben und noch im Write sein.
        // So wartet Terminate verlustfrei, ohne einen zyklischen MainActor-Wait.
        flushQueue.sync {
            drain(reason: reason)
        }
    }

    /// Laeuft ausnahmslos auf flushQueue. persistLock schuetzt weiterhin auch
    /// gegen bereits gestartete Drains und zieht erst danach canonical neu.
    private func drain(reason: String) {
        // Persist serialisieren: unter persistLock den NEUESTEN Stand ziehen —
        // ein parallel gestarteter zweiter Flush wartet hier und sieht danach
        // dirty=false (oder einen neueren Stand). So kann nie ein älterer
        // Snapshot einen neueren Write überholen.
        persistLock.lock()
        defer { persistLock.unlock() }

        lock.lock()
        guard dirty, let workspace = canonical else {
            lock.unlock()
            return
        }
        dirty = false
        firstDirtyAt = nil
        lock.unlock()

        do {
            try persist(workspace)
            // Häufige Debounce-Flushes leise (.info), strukturelle/terminale
            // Flushes sichtbar (.notice) — Letztere sind der Datenverlust-Beweis.
            if reason == "debounce" {
                Logger.agentStore.info("agent_store_flushed reason=debounce sessions=\(workspace.sessions.count)")
            } else {
                Logger.agentStore.notice("agent_store_flushed reason=\(reason, privacy: .public) sessions=\(workspace.sessions.count)")
            }
        } catch {
            Logger.agentStore.error("agent_store_flush_failed reason=\(reason, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            lock.lock()
            dirty = true
            if firstDirtyAt == nil { firstDirtyAt = Date() }
            lock.unlock()
        }
    }

    // MARK: - Intern (nur unter Lock rufen)

    private func loadedLocked() -> AgentWorkspace {
        if let canonical { return canonical }
        let loaded = loadInitial()
        canonical = loaded
        Logger.agentStore.notice("agent_store_loaded sessions=\(loaded.sessions.count)")
        return loaded
    }

    private func persistLocked(_ workspace: AgentWorkspace) throws {
        switch policy {
        case .immediate:
            try persist(workspace)
        case .debounced(let interval):
            dirty = true
            let now = Date()
            if firstDirtyAt == nil { firstDirtyAt = now }
            pendingFlush?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.flush()
            }
            pendingFlush = workItem
            // Harte Max-Latenz: das Rearmieren darf den Write nur bis
            // `firstDirtyAt + maxDebounceLatency` hinauszögern — sonst bliebe
            // bei Dauermutationen (< interval Abstand) beliebig lange alles
            // nur im Speicher (Crash = Verlust weit über 0,5 s hinaus).
            let latestAllowed = (firstDirtyAt ?? now).addingTimeInterval(Self.maxDebounceLatency)
            let delay = max(0, min(now.addingTimeInterval(interval), latestAllowed).timeIntervalSince(now))
            flushQueue.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }
}

/// Dünne MainActor-Projektion des Workspace-Stands für SwiftUI (P1 S6).
/// Ersetzt die früheren ~24 manuellen `workspace = store.loadWorkspace()`-
/// Reloads in `AgentChatsView`: Jede Facade-Mutation meldet den neuen Stand
/// über `onWorkspaceChanged`, die @Observable-Property invalidiert genau die
/// lesenden Views.
@MainActor
@Observable
final class AgentWorkspaceUIModel {
    static let shared = AgentWorkspaceUIModel()

    private(set) var workspace: AgentWorkspace

    init(store: AgentWorkspaceStore = AgentWorkspaceStoreRegistry.store(for: AgentWorkspaceRepository.defaultFileURL())) {
        self.workspace = store.read { $0 }
        store.onWorkspaceChanged = { [weak self, weak store] _ in
            guard let store else { return }
            if Thread.isMainThread {
                // Immer den jüngsten kanonischen Stand lesen: Callbacks
                // paralleler Mutationen können nach dem Unlock überholen.
                MainActor.assumeIsolated {
                    self?.workspace = store.read { $0 }
                }
            } else {
                Task { @MainActor [weak self, weak store] in
                    guard let store else { return }
                    self?.workspace = store.read { $0 }
                }
            }
        }
        // Schließt das kleine Fenster zwischen Initial-Read und Callback-
        // Installation: eine genau dort erfolgte Mutation wird so nachgezogen.
        self.workspace = store.read { $0 }
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
