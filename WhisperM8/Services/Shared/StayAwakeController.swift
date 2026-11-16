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
    /// Wann jemand anderes den Ruhezustand zuletzt wieder eingeschaltet hat,
    /// während der Knopf ihn aus haben wollte (WM8-122). Die App schaltet ihn
    /// dann gleich wieder aus; der Knopf nennt es im Tooltip.
    @Published private(set) var lastExternalResetAt: Date?

    /// Darf dieser Prozess den Ruhezustand des Rechners anfassen? Die
    /// Test-Instanz nie (WM8-122): `pmset -a disablesleep` gilt für den ganzen
    /// Mac, und die sudo-Regel gilt für jeden Prozess des Users. In der Nacht
    /// vom 15. auf den 16.11.2026 schaltete eine Test-Instanz beim Start den
    /// Ruhezustand wieder ein, den die Haupt-App abgeschaltet hatte.
    let isAvailable: Bool

    private let system: StayAwakeSystem
    private let preferences: AppPreferences
    private let marker: URL
    private let now: () -> Date
    private let queue = DispatchQueue(label: "com.whisperm8.stay-awake", qos: .utility)
    /// Dieser Prozess als Besitzer des Merkers (WM8-122).
    private let owner: StayAwakeMarker

    private(set) var conditions = StayAwakeConditions(anyChatWorking: false, onACPower: true, batteryPercent: nil, thermalState: .nominal)
    private var lastWorkingAt: Date?
    /// Zuletzt an `pmset` geschickter Wert; `nil` = noch nie.
    private var applied: Bool?
    private var watchdogStarted = false
    private var started = false
    private var cancellables: Set<AnyCancellable> = []
    private var timer: Timer?
    /// Warten darauf, dass `start()` die Freigabe geprüft hat (`whenPermissionKnown`).
    private var permissionWaiters: [@MainActor () -> Void] = []

    init(
        system: StayAwakeSystem = LiveStayAwakeSystem(),
        preferences: AppPreferences = .shared,
        marker: URL = AppInstance.applicationSupport
            .appendingPathComponent("WhisperM8", isDirectory: true)
            .appendingPathComponent("stay-awake.active"),
        now: @escaping () -> Date = Date.init,
        isAvailable: Bool = !AppInstance.isTestInstance,
        owner: StayAwakeMarker = StayAwakeMarker(pid: getpid(), startMicros: ProcessStartTime.microseconds(pid: getpid()))
    ) {
        self.owner = owner
        self.system = system
        self.preferences = preferences
        self.marker = marker
        self.now = now
        self.isAvailable = isAvailable
        mode = isAvailable && preferences.stayAwakeWhileWorking ? .whileWorking : .off
    }

    /// Einmal beim ersten Erscheinen der Sidebar (oder beim ersten Druck auf
    /// den Wach-Schalter am Controller, siehe `whenPermissionKnown`). Räumt
    /// Reste eines Absturzes auf und hört danach auf Chat-Status, Strom und
    /// Temperatur.
    func start(workingPublisher: AnyPublisher<Bool, Never>? = nil) {
        guard !started else { return }
        started = true
        guard isAvailable else {
            // Test-Instanz: kein sudo, kein pmset, keine Wache, nie ein
            // Admin-Dialog, weder beim Start noch beim Beenden.
            permission = .missing
            Logger.stayAwake.info("stay_awake_unavailable test_instance=true")
            let waiters = permissionWaiters
            permissionWaiters = []
            waiters.forEach { $0() }
            return
        }
        let system = self.system
        let marker = self.marker
        let owner = self.owner
        queue.async { [weak self] in
            let installed = system.isPermissionInstalled()
            // Merker von einem Absturz: Die Wache hat den Ruhezustand in der
            // Regel schon zurückgesetzt, sicher ist sicher. Gehört er einer
            // anderen App, die noch lebt (Übergabe, zweite App), bleibt alles
            // stehen (WM8-122).
            if FileManager.default.fileExists(atPath: marker.path) {
                if Self.mayRelease(marker: marker, owner: owner, system: system) {
                    if installed { _ = system.setSleepDisabled(false) }
                    try? FileManager.default.removeItem(at: marker)
                    Logger.stayAwake.info("stay_awake_stale_marker_reset installed=\(installed, privacy: .public)")
                } else {
                    Logger.stayAwake.info("stay_awake_marker_other_owner at=start")
                }
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.permission = installed ? .ready : .missing
                if !installed, self.mode != .off {
                    // Regel wurde entfernt: nicht still weiterversprechen.
                    self.setMode(.off)
                }
                self.evaluate()
                let waiters = self.permissionWaiters
                self.permissionWaiters = []
                waiters.forEach { $0() }
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

    /// Ruft `then`, sobald feststeht, ob die Freigabe da ist. Der Controller
    /// (R1 + ▶) braucht das, wenn die Seitenleiste seit dem App-Start
    /// verborgen war und `start()` deshalb noch nie lief: Das holt er hier
    /// nach. Geprüft wird still (`sudo -n -l`), nie mit Dialog.
    func whenPermissionKnown(
        workingPublisher: AnyPublisher<Bool, Never>? = nil, _ then: @escaping @MainActor () -> Void
    ) {
        start(workingPublisher: workingPublisher)
        guard permission == .unknown else { return then() }
        permissionWaiters.append(then)
    }

    /// Bräuchte der nächste Klick die einmalige Admin-Freigabe, und fehlt
    /// sie? Der Controller (R1 + ▶) öffnet dann keinen Dialog, sondern
    /// verweist auf den Knopf in der Seitenleiste.
    var nextStepNeedsPermission: Bool {
        mode.next != .off && permission != .ready
    }

    /// Klick auf den Knopf: Aus → Bei Arbeit am Strom → Immer → Aus.
    func cycle() {
        guard isAvailable, !isAwaitingPermission else { return }
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
        guard isAvailable else { return }
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
        guard isAvailable, !isAwaitingPermission else { return }
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
        guard isAvailable else { return }
        let system = self.system
        // Hält die App den Mac gerade wach, im selben Takt nachsehen, ob es
        // noch gilt (WM8-122): Ein anderer Prozess mit derselben sudo-Regel
        // kann den Ruhezustand wieder einschalten, ohne dass die App es merkt.
        let verify = applied == true
        queue.async { [weak self] in
            let power = system.powerState()
            let actual = verify ? system.isSleepDisabled() : nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.conditions.onACPower = power.onACPower
                self.conditions.batteryPercent = power.batteryPercent
                self.conditions.thermalState = ProcessInfo.processInfo.thermalState
                if StayAwakePolicy.wasResetFromOutside(applied: self.applied, actual: actual) {
                    self.noteExternalReset()
                }
                self.evaluate()
            }
        }
    }

    /// Von außen wieder eingeschaltet: Anzeige ehrlich stellen und beim
    /// folgenden `evaluate()` neu abschalten, falls der Knopf es weiter will.
    private func noteExternalReset() {
        lastExternalResetAt = now()
        isHoldingAwake = false
        applied = nil
        Logger.stayAwake.notice("stay_awake_external_reset mode=\(self.mode.rawValue, privacy: .public)")
    }

    func evaluate() {
        guard isAvailable else { return }
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
        let owner = self.owner
        let startWatchdog = desired && !watchdogStarted
        if startWatchdog { watchdogStarted = true }
        queue.async { [weak self] in
            if desired {
                // Dieser Prozess ist jetzt Besitzer; eine ältere App lässt den
                // Ruhezustand beim Beenden dann in Ruhe.
                FileManager.default.createFile(atPath: marker.path, contents: Data(owner.fileContents.utf8))
                if startWatchdog { system.startWatchdog(appPID: owner.pid, marker: marker) }
            }
            // Ausschalten nur, wenn keine andere lebende App den Mac wach hält.
            let mayRelease = desired || Self.mayRelease(marker: marker, owner: owner, system: system)
            let ok = mayRelease ? system.setSleepDisabled(desired) : true
            if !desired, mayRelease { try? FileManager.default.removeItem(at: marker) }
            let actual = system.isSleepDisabled() ?? desired
            if mayRelease {
                Logger.stayAwake.info("stay_awake_applied disabled=\(desired, privacy: .public) ok=\(ok, privacy: .public) actual=\(actual, privacy: .public)")
            } else {
                Logger.stayAwake.info("stay_awake_marker_other_owner at=release")
            }
            Task { @MainActor [weak self] in
                // Hält eine andere App wach, hält diese nicht.
                self?.isHoldingAwake = mayRelease ? actual : false
                if !ok { self?.applied = nil }
            }
        }
    }

    /// Beim Beenden synchron: Danach läuft kein Code mehr, der aufräumen könnte.
    func releaseForTermination() {
        guard isAvailable, applied == true else { return }
        applied = false
        // Hat die neue App schon übernommen (Neustart mit Übergabe), bleibt
        // der Mac wach und ihr Merker stehen (WM8-122).
        guard Self.mayRelease(marker: marker, owner: owner, system: system) else {
            Logger.stayAwake.info("stay_awake_marker_other_owner at=terminate")
            return
        }
        _ = system.setSleepDisabled(false)
        try? FileManager.default.removeItem(at: marker)
    }

    /// Liest den Merker und fragt die Regel (`StayAwakeMarker.mayRelease`).
    /// Blockierend (Datei, `sysctl`): nur auf der eigenen Queue oder beim Beenden.
    nonisolated static func mayRelease(marker: URL, owner: StayAwakeMarker, system: StayAwakeSystem) -> Bool {
        let exists = FileManager.default.fileExists(atPath: marker.path)
        let parsed = exists ? (try? String(contentsOf: marker, encoding: .utf8)).flatMap(StayAwakeMarker.parse) : nil
        return StayAwakeMarker.mayRelease(marker: parsed, markerExists: exists, own: owner, isAlive: system.isAlive)
    }
}
