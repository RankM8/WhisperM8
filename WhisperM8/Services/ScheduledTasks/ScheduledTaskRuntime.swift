import AppKit
import Foundation

// MARK: - Laufzeit: Zeitgeber, Aufwachen, App-Start

/// Hängt den Planer an die App: ein einziger Zeitgeber auf den nächsten
/// Termin (spätestens alle 15 Minuten), dazu Aufwachen des Macs und Uhr- oder
/// Zeitzonenwechsel. Beim App-Start holt der erste Durchlauf Verpasstes nach.
///
/// Kosten: Ruhend ein Wall-Clock-Timer und drei Beobachter, kein Polling von
/// Dateien. Ein Durchlauf liest `scheduled-tasks.json` und je Aufgabe den
/// jüngsten Lauf-Ordner, abseits des Main Threads (Actor).
///
/// Läuft nur mit eingeschaltetem Labs-Schalter (`scheduledTasksEnabled`, ab
/// Werk aus). Ausschalten hält den Zeitgeber an; laufende Läufe laufen zu Ende.
@MainActor
final class ScheduledTaskRuntime {
    static let shared = ScheduledTaskRuntime()

    /// Längster Abstand zwischen zwei Durchläufen, falls ein Ereignis fehlt.
    static let maxInterval: TimeInterval = 15 * 60

    let scheduler = ScheduledTaskScheduler(environment: .live)
    private var timer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    private var switchObservation: NSKeyValueObservation?
    private(set) var isRunning = false

    private init() {}

    /// App-Start. Beobachtet den Schalter, auch wenn er aus ist; ohne Schalter
    /// startet sonst nichts.
    func startIfEnabled() {
        observeSwitch()
        guard AppPreferences.shared.isScheduledTasksEnabled else { return }
        start()
    }

    /// Schalter in den Einstellungen.
    func settingChanged(enabled: Bool) {
        enabled ? start() : stop()
        ScheduledTasksOverviewModel.shared.reload()
    }

    /// Auch ein Umschalten von außen (`defaults write`) startet oder hält den
    /// Zeitgeber an. KVO meldet nur Änderungen dieses einen Schlüssels.
    private func observeSwitch() {
        guard switchObservation == nil else { return }
        switchObservation = UserDefaults.standard.observe(\.scheduledTasksEnabled, options: [.new]) { _, _ in
            Task { @MainActor in
                let enabled = AppPreferences.shared.isScheduledTasksEnabled
                guard enabled != ScheduledTaskRuntime.shared.isRunning else { return }
                ScheduledTaskRuntime.shared.settingChanged(enabled: enabled)
            }
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in ScheduledTaskRuntime.shared.tick(reason: "wake") }
        })
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in ScheduledTaskRuntime.shared.tick(reason: "clock") }
            })
        }
        ScheduledTaskNotifications.registerCategories()
        let scheduler = scheduler
        Task {
            await scheduler.start()
            await MainActor.run { ScheduledTaskRuntime.shared.tick(reason: "launch") }
        }
        Logger.scheduledTasks.info("runtime_started")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        timer?.cancel()
        timer = nil
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0); NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        Logger.scheduledTasks.info("runtime_stopped")
    }

    /// Ein Durchlauf; danach den Zeitgeber neu stellen. Auch nach jeder
    /// Änderung über die CLI (neuer Termin).
    func tick(reason: String) {
        guard isRunning else { return }
        let scheduler = scheduler
        Task {
            let next = await scheduler.evaluate(reason: reason)
            await MainActor.run {
                ScheduledTaskRuntime.shared.arm(next: next)
                // Gestartete oder eingetragene Läufe, neuer nächster Termin.
                ScheduledTasksOverviewModel.shared.reload()
            }
        }
    }

    private func arm(next: Date?) {
        guard isRunning else { return }
        let now = Date()
        let target = min(next ?? now.addingTimeInterval(Self.maxInterval), now.addingTimeInterval(Self.maxInterval))
        // Eine Sekunde Puffer: Der Termin soll beim Feuern schon erreicht sein.
        let delay = max(1, target.timeIntervalSince(now) + 1)
        timer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: .main)
        // Wall-Clock: Schläft der Mac über den Termin, feuert der Timer beim Aufwachen.
        source.schedule(wallDeadline: .now() + delay, leeway: .seconds(2))
        source.setEventHandler { ScheduledTaskRuntime.shared.tick(reason: "timer") }
        source.resume()
        timer = source
    }
}

// MARK: - Echte Abhängigkeiten

extension ScheduledTaskScheduler.Environment {
    static var live: Self {
        Self(
            store: ScheduledTaskStore(),
            now: Date.init,
            calendar: { Calendar.current },
            isEnabled: { AppPreferences.shared.isScheduledTasksEnabled },
            claudePath: { AgentCommandBuilder.commandPath("claude") },
            accountEnvironment: { account in
                guard account != ClaudeAccountProfiles.mainProfileName else { return [:] }
                let profiles = ClaudeAccountProfiles()
                guard ClaudeAccountProfiles.isValidProfileName(account) else { return nil }
                let dir = profiles.configDir(forProfile: account)
                // Kein stilles Ausweichen auf main wie bei Chats: Ein Lauf im
                // falschen Konto wäre schlimmer als keiner.
                guard FileManager.default.fileExists(atPath: dir.path) else { return nil }
                return ["CLAUDE_CONFIG_DIR": dir.path]
            },
            baseEnvironment: {
                var env = LoginShellEnvironment.shared.processEnvironment()
                env.merge(AppInstance.childEnvironmentOverrides) { _, new in new }
                // Nur das WhisperM8-Plugin, kein vom Nutzer gesetzter Plugin-Ordner:
                // dessen Skills und Hooks gingen an der Bereinigung vorbei (Paket 4).
                env.merge(ClaudePluginBootstrap.launchEnvironment(includingInherited: false)) { _, new in new }
                env["NO_COLOR"] = "1"
                return env
            },
            authStatus: { claudePath, environment, directory in
                // DefaultProcessRunner setzt die Login-Shell-Umgebung selbst;
                // hier zählen nur Konto und Test-Instanz.
                var overrides = AppInstance.childEnvironmentOverrides
                if let configDir = environment["CLAUDE_CONFIG_DIR"] { overrides["CLAUDE_CONFIG_DIR"] = configDir }
                guard let result = try? await DefaultProcessRunner().run(
                    executable: claudePath, arguments: ["auth", "status", "--json"],
                    workingDirectory: directory, environmentOverrides: overrides, timeout: 20) else { return nil }
                return ScheduledTaskLauncher.parseAuthStatus(stdout: result.stdout, exitCode: result.exitCode)
            },
            supportsNativeName: {
                AppPreferences.shared.isClaudeNativeNameEnabled
                    && ClaudeCLIVersion.supportsNativeName(ClaudeCLIVersionProbe.shared.installedVersion())
            },
            directoryExists: { path in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            },
            spawn: { plan in try ScheduledTaskLauncher.spawnDetached(plan) },
            processStartTime: { ProcessAncestry.startTime(for: $0) },
            isProcessAlive: { ScheduledTaskRunEvaluator.isProcessAlive(pid: $0, startedAt: $1) },
            watchExit: { pid, handler in
                ScheduledTaskExitWatcher.shared.watch(pid: pid) {
                    handler()
                    // Ende eines Laufs: Ergebnis in Seitenleiste und Detail.
                    Task { @MainActor in ScheduledTasksOverviewModel.shared.reload() }
                }
            },
            notifyFailure: { notice in ScheduledTaskNotifications.post(notice) },
            prepareRunConfig: { task, runDirectory in
                let profiles = ClaudeAccountProfiles()
                return try ScheduledTaskRunConfigBuilder.prepare(
                    task: task,
                    sources: .init(configDirectory: profiles.configDir(forProfile: task.account),
                                   claudeJSON: profiles.claudeJSONURL(forProfile: task.account)),
                    runDirectory: runDirectory)
            }
        )
    }
}

/// Beobachtet das Ende eines Prozesses per kqueue (`DispatchSource`), auch
/// eines Prozesses, den eine frühere App-Instanz gestartet hat.
final class ScheduledTaskExitWatcher: @unchecked Sendable {
    static let shared = ScheduledTaskExitWatcher()

    private let lock = NSLock()
    private var sources: [Int32: DispatchSourceProcess] = [:]
    private let queue = DispatchQueue(label: "com.whisperm8.scheduled-tasks.exit", qos: .utility)

    func watch(pid: Int32, handler: @escaping @Sendable () -> Void) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        let fired = OnceFlag()
        source.setEventHandler { [weak self] in
            guard fired.consume() else { return }
            self?.finish(pid)
            handler()
        }
        lock.lock()
        sources[pid]?.cancel()
        sources[pid] = source
        lock.unlock()
        source.resume()
        // Schon vor dem Anmelden beendet: kqueue meldet dann nichts mehr.
        if kill(pid, 0) != 0, errno == ESRCH {
            queue.async { [weak self] in
                guard fired.consume() else { return }
                self?.finish(pid)
                handler()
            }
        }
    }

    private func finish(_ pid: Int32) {
        lock.lock()
        let source = sources.removeValue(forKey: pid)
        lock.unlock()
        source?.cancel()
    }

    private final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var used = false

        func consume() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if used { return false }
            used = true
            return true
        }
    }
}

extension UserDefaults {
    /// Für KVO auf den Labs-Schalter; Name = Schlüssel (`PreferenceKeys.scheduledTasksEnabled`).
    @objc dynamic var scheduledTasksEnabled: Bool { bool(forKey: PreferenceKeys.scheduledTasksEnabled) }
}
