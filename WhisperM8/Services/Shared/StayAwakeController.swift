import AppKit
import Combine
import Foundation

/// Hält den Mac wach, während Chats arbeiten (Stufe 1) oder immer (Stufe 2).
/// Mittel ist `pmset -a disablesleep`: Nur das hält den Mac auch zugeklappt
/// wach. Die offizielle Sperre (`PreventUserIdleSystemSleep`) verhindert nur
/// den Leerlaufschlaf, und die setzt Claude Code während eines Turns schon
/// selbst (`caffeinate -i`).
@MainActor
final class StayAwakeController: ObservableObject {
    static let shared = StayAwakeController()

    enum PermissionState: Equatable {
        case unknown
        case missing
        case ready
    }

    @Published private(set) var mode: StayAwakeMode = .off
    /// Ist der Ruhezustand gerade wirklich aus?
    @Published private(set) var isHoldingAwake = false
    @Published private(set) var permission: PermissionState = .unknown
    /// Admin-Dialog offen: Knopf solange gesperrt.
    @Published private(set) var isAwaitingPermission = false
    @Published private(set) var lastEndReason: StayAwakeEndReason?
    @Published private(set) var alwaysSince: Date?

    private let system: StayAwakeSystem
    private let preferences: AppPreferences
    private let marker: URL
    private let now: () -> Date
    private let queue = DispatchQueue(label: "com.whisperm8.stay-awake", qos: .utility)

    private(set) var conditions = StayAwakeConditions(anyChatWorking: false, onACPower: true, batteryPercent: nil, thermalState: .nominal)
    private var lastWorkingAt: Date?
    /// Zuletzt an `pmset` geschickter Wert; `nil` = noch nie.
    private var applied: Bool?
    private var watchdogStarted = false
    private var started = false
    private var cancellables: Set<AnyCancellable> = []
    private var timer: Timer?

    init(
        system: StayAwakeSystem = LiveStayAwakeSystem(),
        preferences: AppPreferences = .shared,
        marker: URL = AppInstance.applicationSupport
            .appendingPathComponent("WhisperM8", isDirectory: true)
            .appendingPathComponent("stay-awake.active"),
        now: @escaping () -> Date = Date.init
    ) {
        self.system = system
        self.preferences = preferences
        self.marker = marker
        self.now = now
        mode = preferences.stayAwakeWhileWorking ? .whileWorking : .off
    }

    /// Einmal beim ersten Erscheinen der Sidebar. Räumt Reste eines Absturzes
    /// auf und hört danach auf Chat-Status, Strom und Temperatur.
    func start(workingPublisher: AnyPublisher<Bool, Never>? = nil) {
        guard !started else { return }
        started = true
        let system = self.system
        let marker = self.marker
        queue.async { [weak self] in
            let installed = system.isPermissionInstalled()
            // Merker von einem Absturz: Die Wache hat den Ruhezustand in der
            // Regel schon zurückgesetzt, sicher ist sicher.
            if FileManager.default.fileExists(atPath: marker.path) {
                if installed { _ = system.setSleepDisabled(false) }
                try? FileManager.default.removeItem(at: marker)
                Logger.stayAwake.info("stay_awake_stale_marker_reset installed=\(installed, privacy: .public)")
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.permission = installed ? .ready : .missing
                if !installed, self.mode != .off {
                    // Regel wurde entfernt: nicht still weiterversprechen.
                    self.setMode(.off)
                }
                self.evaluate()
            }
        }

        let working = workingPublisher ?? AgentSessionStatusCoordinator.shared.statusStore.$statuses
            .map { $0.values.contains(.working) }
            .eraseToAnyPublisher()
        working
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isWorking in
                guard let self else { return }
                if self.conditions.anyChatWorking && !isWorking { self.lastWorkingAt = self.now() }
                self.conditions.anyChatWorking = isWorking
                self.evaluate()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshPower() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.releaseForTermination() } }
            .store(in: &cancellables)

        // Strom, Akku und das Ende der Nachlaufzeit: alle 30 s reichen.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPower() }
        }
        refreshPower()
    }

    /// Klick auf den Knopf: Aus → Bei Arbeit am Strom → Immer → Aus.
    func cycle() {
        guard !isAwaitingPermission else { return }
        let target = mode.next
        if target == .off {
            setMode(.off)
            evaluate()
            return
        }
        withPermission { [weak self] in
            self?.setMode(target)
            self?.evaluate()
        }
    }

    /// Schalter in den Einstellungen für Stufe 1.
    func setWhileWorking(_ enabled: Bool) {
        if !enabled {
            setMode(.off)
            evaluate()
            return
        }
        guard mode == .off else { return }
        withPermission { [weak self] in
            self?.setMode(.whileWorking)
            self?.evaluate()
        }
    }

    func removePermission() {
        guard !isAwaitingPermission else { return }
        setMode(.off)
        evaluate()
        isAwaitingPermission = true
        let system = self.system
        let prompt = String(localized: "WhisperM8 wants to remove its permission to keep your Mac awake.")
        queue.async { [weak self] in
            _ = system.removePermission(prompt: prompt)
            let installed = system.isPermissionInstalled()
            Task { @MainActor [weak self] in
                self?.isAwaitingPermission = false
                self?.permission = installed ? .ready : .missing
                self?.applied = nil
            }
        }
    }

    // MARK: Intern

    private func withPermission(_ action: @escaping () -> Void) {
        if permission == .ready {
            action()
            return
        }
        isAwaitingPermission = true
        let system = self.system
        let prompt = String(localized: "WhisperM8 wants to keep your Mac awake while chats work. This is asked only once.")
        queue.async { [weak self] in
            let installed = system.isPermissionInstalled() || system.installPermission(prompt: prompt)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isAwaitingPermission = false
                self.permission = installed ? .ready : .missing
                Logger.stayAwake.info("stay_awake_permission installed=\(installed, privacy: .public)")
                if installed { action() }
            }
        }
    }

    private func setMode(_ newMode: StayAwakeMode) {
        if newMode == .always, mode != .always {
            alwaysSince = now()
            lastEndReason = nil
        } else if newMode != .always {
            alwaysSince = nil
        }
        mode = newMode
        // Stufe 2 gilt nie über einen Neustart hinaus; Stufe 1 bleibt beim
        // Wechsel nach „Immer“ gemerkt, damit die App danach dorthin zurückfällt.
        if newMode == .off { preferences.stayAwakeWhileWorking = false }
        if newMode == .whileWorking { preferences.stayAwakeWhileWorking = true }
        Logger.stayAwake.info("stay_awake_mode mode=\(newMode.rawValue, privacy: .public)")
    }

    func refreshPower() {
        let system = self.system
        queue.async { [weak self] in
            let power = system.powerState()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.conditions.onACPower = power.onACPower
                self.conditions.batteryPercent = power.batteryPercent
                self.conditions.thermalState = ProcessInfo.processInfo.thermalState
                self.evaluate()
            }
        }
    }

    func evaluate() {
        if mode == .always, let since = alwaysSince,
           let reason = StayAwakePolicy.endReason(conditions, alwaysSince: since, now: now()) {
            lastEndReason = reason
            Logger.stayAwake.info("stay_awake_always_ended reason=\(reason.rawValue, privacy: .public)")
            setMode(preferences.stayAwakeWhileWorking ? .whileWorking : .off)
        }
        let desired = permission == .ready && StayAwakePolicy.shouldDisableSleep(
            mode: mode, conditions: conditions, lastWorkingAt: lastWorkingAt, now: now())
        apply(desired)
    }

    private func apply(_ desired: Bool) {
        // Ohne Freigabe nie `sudo` aufrufen. Wird die Regel entfernt, setzt
        // `removeScript` den Ruhezustand als root selbst zurück.
        guard applied != desired, permission == .ready else { return }
        applied = desired
        let system = self.system
        let marker = self.marker
        let startWatchdog = desired && !watchdogStarted
        if startWatchdog { watchdogStarted = true }
        queue.async { [weak self] in
            if desired {
                FileManager.default.createFile(atPath: marker.path, contents: Data())
                if startWatchdog { system.startWatchdog(appPID: getpid(), marker: marker) }
            }
            let ok = system.setSleepDisabled(desired)
            if !desired { try? FileManager.default.removeItem(at: marker) }
            let actual = system.isSleepDisabled() ?? desired
            Logger.stayAwake.info("stay_awake_applied disabled=\(desired, privacy: .public) ok=\(ok, privacy: .public) actual=\(actual, privacy: .public)")
            Task { @MainActor [weak self] in
                self?.isHoldingAwake = actual
                if !ok { self?.applied = nil }
            }
        }
    }

    /// Beim Beenden synchron: Danach läuft kein Code mehr, der aufräumen könnte.
    private func releaseForTermination() {
        guard applied == true else { return }
        applied = false
        _ = system.setSleepDisabled(false)
        try? FileManager.default.removeItem(at: marker)
    }
}
