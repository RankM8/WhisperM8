import AppKit
import Foundation

/// Globaler Singleton der den Indexer-Scan von `~/.claude/projects/` und
/// `~/.codex/sessions/` koordiniert. Verantwortlich fuer:
///
/// - Coalescing: nur ein Scan gleichzeitig in flight
/// - Cooldown: foreground-triggered Scans throttle (30 s), damit
///   schnelles Cmd+Tab nicht den Indexer ueberlastet
/// - Lifecycle-Hooks: feuert beim App-Start + bei jeder Foreground-
///   Reaktivierung, ohne dass User den manuellen "Aktualisieren"-Button
///   klicken muss
/// - Bypassed Cooldown bei manuellem Trigger (User-Intent gewinnt)
///
/// Posted `AgentScanCoordinator.scanDidCompleteNotification` nach jedem
/// erfolgreichen Scan — die UI haengt sich daran und reloaded ihren
/// Workspace-Snapshot.
@MainActor
final class AgentScanCoordinator {
    static let shared = AgentScanCoordinator()

    /// Wird gepostet nach jedem erfolgreichen Scan, damit UI-Views ihren
    /// Workspace neu laden koennen.
    static let scanDidCompleteNotification = Notification.Name("AgentScanCoordinator.scanDidComplete")

    /// Posted waehrend ein Scan laeuft (start: true) bzw. nach Abschluss
    /// (start: false). UI zeigt darauf basierend einen Spinner.
    static let scanRunningChangedNotification = Notification.Name("AgentScanCoordinator.scanRunningChanged")

    enum Reason: String {
        case launch        // appDidFinishLaunching
        case foreground    // didBecomeActive
        case manual        // User-Klick auf "Aktualisieren"
        case afterCreate   // nach createSession (optional)
        case fsEvent       // FSEvents-Trigger: neue Transcript-Dateien (P2)
    }

    private var inFlight = false
    private var lastCompletedAt: Date?
    private let cooldown: TimeInterval = 30
    /// Kürzerer Cooldown für FSEvents-Trigger — die sind bereits 5 s
    /// debounced und zeigen ECHTE neue Dateien an.
    private let fsEventCooldown: TimeInterval = 10
    private var lifecycleObservers: [NSObjectProtocol] = []

    /// P1 S5: Liefert die Session-IDs mit lebendem PTY. Früher schloss der
    /// Scan mit leerer Menge — und konnte damit live laufende Sessions auf
    /// `.closed` flippen. Closure-DI für Tests.
    var activeSessionIDsProvider: @MainActor () -> Set<UUID> = {
        AgentTerminalRegistry.shared.activeSessionIDs
    }

    private init() {}

    /// Registriert die App-Lifecycle-Hooks. Idempotent — kann mehrmals
    /// aufgerufen werden, installiert aber nur einmal.
    func installLifecycleHooks() {
        guard lifecycleObservers.isEmpty else { return }

        let didBecomeActive = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                AgentScanCoordinator.shared.requestScan(reason: .foreground)
            }
        }
        lifecycleObservers.append(didBecomeActive)
    }

    var isRunning: Bool { inFlight }

    /// Hauptentry. Coalescing + Cooldown-Logik:
    /// - In-flight: ignoriere weitere Requests
    /// - Cooldown aktiv und Reason != .manual: ignoriere
    /// - sonst: starte Scan
    func requestScan(reason: Reason) {
        if inFlight {
            // NICHT verwerfen (Review-Befund 2026-07-13): Eine Datei, die
            // NACH dem Enumerator-Durchlauf des laufenden Scans entsteht,
            // hat evtl. nur diesen einen FSEvent — verworfen bliebe sie bis
            // zum nächsten Foreground-Scan unsichtbar. Als pending merken;
            // markScanCompleted holt den Scan nach.
            pendingReason = pendingReason ?? reason
            Logger.agentPerformance.debug("agent_scan_deferred reason=\(reason.rawValue, privacy: .public) cause=in-flight")
            return
        }
        if reason != .manual, let last = lastCompletedAt {
            let elapsed = Date().timeIntervalSince(last)
            let limit = reason == .fsEvent ? fsEventCooldown : cooldown
            if elapsed < limit {
                pendingReason = pendingReason ?? reason
                scheduleCooldownRetry(after: limit - elapsed)
                Logger.agentPerformance.debug("agent_scan_deferred reason=\(reason.rawValue, privacy: .public) cause=cooldown elapsed=\(Int(elapsed))s")
                return
            }
        }
        startScan(reason: reason)
    }

    /// Merker für einen während in-flight/cooldown angeforderten Scan.
    private var pendingReason: Reason?
    private var cooldownRetryScheduled = false

    private func scheduleCooldownRetry(after delay: TimeInterval) {
        guard !cooldownRetryScheduled else { return }
        cooldownRetryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, 1)) { [weak self] in
            guard let self else { return }
            self.cooldownRetryScheduled = false
            guard let reason = self.pendingReason else { return }
            self.pendingReason = nil
            self.requestScan(reason: reason)
        }
    }

    private func startScan(reason: Reason) {
        inFlight = true
        NotificationCenter.default.post(
            name: Self.scanRunningChangedNotification,
            object: nil,
            userInfo: ["running": true, "reason": reason.rawValue]
        )
        let startedAt = Date()

        // P1 S5: Der Detached-Block macht nur noch das reine Indexing
        // (JSONL-Parsing off-main); der Merge läuft danach auf dem MainActor
        // über die Facade — mit der ECHTEN Active-Menge statt einer leeren
        // (vorher konnten live laufende Sessions auf .closed flippen).
        Task.detached(priority: .utility) { [reason] in
            let cacheStore = AgentSessionIndexCacheStore()
            var cache = cacheStore.load()
            let codex = CodexSessionIndexer().indexedSessionResult(cache: &cache)
            let claude = ClaudeSessionIndexer().indexedSessionResult(cache: &cache)
            cacheStore.save(cache)

            await MainActor.run {
                let coordinator = AgentScanCoordinator.shared
                let activeSessionIDs = coordinator.activeSessionIDsProvider()
                let store = AgentSessionStore()
                try? store.markStaleRunningSessionsClosed(excluding: activeSessionIDs)
                try? store.mergeIndexedSessions(codex.sessions + claude.sessions)
                let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                Logger.agentPerformance.info("agent_scan_completed reason=\(reason.rawValue, privacy: .public) durationMs=\(durationMs) codex=\(codex.stats.scannedFiles) claude=\(claude.stats.scannedFiles)")
                coordinator.markScanCompleted()
            }
        }
    }

    private func markScanCompleted() {
        inFlight = false
        lastCompletedAt = Date()
        // Während des Laufs angeforderte Scans nachholen — requestScan
        // landet dabei im Cooldown-Pfad und plant den Retry zeitgenau.
        if let reason = pendingReason {
            pendingReason = nil
            requestScan(reason: reason)
        }
        NotificationCenter.default.post(
            name: Self.scanRunningChangedNotification,
            object: nil,
            userInfo: ["running": false]
        )
        NotificationCenter.default.post(
            name: Self.scanDidCompleteNotification,
            object: nil
        )
    }

    deinit {
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }
}
