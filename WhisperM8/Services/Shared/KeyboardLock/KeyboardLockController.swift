import AppKit
import Carbon.HIToolbox
import Combine
import CoreGraphics

/// Tastatursperre zum Reinigen: verwirft alle Tastatur-Ereignisse, bis der
/// Nutzer per Maus entsperrt oder die Frist abläuft. Maus und Trackpad bleiben
/// frei. Mehrere Wege heben die Sperre auf (siehe docs/features/keyboard-cleaning.md):
/// Knopf, Frist, Bildschirmsperre/Ruhezustand, App-Ende, Absturz (Tap stirbt
/// mit dem Prozess). Hängt der Main Thread länger als
/// `KeyboardLockPolicy.heartbeatTimeout`, lässt der Tap (eigener Thread) alles
/// durch, bis das Lebenszeichen aus `tick()` zurück ist.
@MainActor
final class KeyboardLockController: ObservableObject {
    static let shared = KeyboardLockController()

    enum StartResult: Equatable {
        case locked
        case alreadyLocked
        case missingPermission
    }

    /// Woher die Auslöser fürs Entsperren kommen. Tests geben eigene
    /// `NotificationCenter` hinein und posten die Namen selbst.
    struct NotificationSources {
        var workspace: NotificationCenter
        /// Systemweite Benachrichtigungen (`com.apple.screenIsLocked`). Ist es ein
        /// `DistributedNotificationCenter`, wird mit `.deliverImmediately`
        /// abonniert — sonst hielte AppKit sie zurück, solange die App inaktiv ist.
        var distributed: NotificationCenter
        var app: NotificationCenter

        static var live: NotificationSources {
            NotificationSources(
                workspace: NSWorkspace.shared.notificationCenter,
                distributed: DistributedNotificationCenter.default(),
                app: NotificationCenter.default
            )
        }
    }

    static let screenLockedNotification = Notification.Name("com.apple.screenIsLocked")

    @Published private(set) var isLocked = false
    /// Nur für die Anzeige (Countdown); die Frist selbst läuft über die Uptime.
    @Published private(set) var deadline: Date?
    /// Ein Passwortfeld (Secure Event Input) ist aktiv — dann sieht macOS'
    /// Tap keine Tasten, sie kommen durch.
    @Published private(set) var secureInputActive = false
    @Published private(set) var capsLockOn = false
    @Published private(set) var canExtend = false
    @Published private(set) var lastUnlockReason: KeyboardUnlockReason?

    private let tap: KeyboardEventTapping
    private let panel: KeyboardLockPanelPresenting
    private let now: () -> Date
    private let uptime: () -> TimeInterval
    private let secureInputProbe: () -> Bool
    private let capsLockProbe: () -> Bool
    private let keysDownProbe: () -> Set<Int64>
    private let screenLockedProbe: () -> Bool
    private let notificationSources: () -> NotificationSources
    /// Geteilt mit dem Tap-Thread; entscheidet je Ereignis.
    private let gate: KeyboardLockGate
    private var lockedAtUptime: TimeInterval = 0
    private var allowedDuration: TimeInterval = 0
    private var ticker: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var distributedObservers: [(DistributedNotificationCenter, DistributedObserver)] = []

    init(
        tap: KeyboardEventTapping? = nil,
        panel: KeyboardLockPanelPresenting? = nil,
        now: @escaping () -> Date = Date.init,
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        secureInputProbe: @escaping () -> Bool = { IsSecureEventInputEnabled() },
        capsLockProbe: @escaping () -> Bool = {
            CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift)
        },
        keysDownProbe: @escaping () -> Set<Int64> = KeyboardLockController.liveKeysDown,
        screenLockedProbe: @escaping () -> Bool = KeyboardLockController.liveScreenLocked,
        notificationSources: (() -> NotificationSources)? = nil
    ) {
        self.tap = tap ?? LiveKeyboardEventTap()
        self.panel = panel ?? KeyboardLockPanelController()
        self.now = now
        self.uptime = uptime
        self.secureInputProbe = secureInputProbe
        self.capsLockProbe = capsLockProbe
        self.keysDownProbe = keysDownProbe
        self.screenLockedProbe = screenLockedProbe
        self.notificationSources = notificationSources ?? { .live }
        self.gate = KeyboardLockGate(clock: uptime)
    }

    /// Verbleibende Sperrzeit in Sekunden (Uptime-basiert).
    var remaining: TimeInterval {
        guard isLocked else { return 0 }
        return max(0, allowedDuration - (uptime() - lockedAtUptime))
    }

    // MARK: - Steuerung

    @discardableResult
    func lock(duration: TimeInterval = KeyboardLockPolicy.defaultDuration) -> StartResult {
        guard !isLocked else { return .alreadyLocked }
        // Erst den Zustand, dann den Tap: Das erste Ereignis trifft schon
        // eine aktive Sperre mit frischem Lebenszeichen.
        gate.activate(keysDownAtLock: keysDownProbe())
        let gate = self.gate
        let installed = tap.install { [weak self] event, flags in
            // Läuft auf dem Tap-Thread: nur das Gate, Anzeige asynchron.
            let decision = gate.decide(event)
            if case .flagsChanged = event {
                Self.publishCapsLock(flags.contains(.maskAlphaShift), to: self)
            }
            return decision
        }
        guard installed else {
            gate.deactivate()
            Logger.keyboardLock.notice("keyboard_lock_denied reason=tap_create_failed")
            return .missingPermission
        }
        lockedAtUptime = uptime()
        allowedDuration = min(duration, KeyboardLockPolicy.maximumDuration)
        isLocked = true
        lastUnlockReason = nil
        secureInputActive = secureInputProbe()
        capsLockOn = capsLockProbe()
        refreshDisplay()
        startObserving()
        startTicker()
        panel.show(controller: self)
        Logger.keyboardLock.info("keyboard_lock_started duration=\(Int(duration), privacy: .public)s secure_input=\(self.secureInputActive, privacy: .public)")
        return .locked
    }

    func unlock(reason: KeyboardUnlockReason) {
        guard isLocked else { return }
        // Erst das Gate (alles geht durch, kein Wiedereinschalten mehr), dann
        // den Tap abbauen.
        gate.deactivate()
        tap.uninstall()
        stopTicker()
        stopObserving()
        isLocked = false
        deadline = nil
        canExtend = false
        allowedDuration = 0
        lastUnlockReason = reason
        panel.hide()
        Logger.keyboardLock.info("keyboard_lock_ended reason=\(reason.rawValue, privacy: .public)")
    }

    func extend() {
        guard isLocked else { return }
        allowedDuration = KeyboardLockPolicy.extendedDuration(
            allowed: allowedDuration,
            elapsed: uptime() - lockedAtUptime
        )
        refreshDisplay()
    }

    /// Lebenszeichen für den Tap-Thread, dann Frist, Sperrbildschirm und
    /// Passwortfeld; läuft sekündlich (`heartbeatInterval`), solange gesperrt.
    func tick() {
        guard isLocked else { return }
        gate.heartbeat()
        if remaining <= 0 {
            unlock(reason: .timeout)
            return
        }
        // Rückfall, falls die Benachrichtigung zur Bildschirmsperre ausbleibt.
        if screenLockedProbe() {
            unlock(reason: .screenLocked)
            return
        }
        let secure = secureInputProbe()
        if secure != secureInputActive { secureInputActive = secure }
        refreshDisplay()
    }

    /// Countdown-Ziel für die Anzeige aus der Uptime-Restzeit; nur neu setzen,
    /// wenn es spürbar abweicht (Wanduhr gesprungen), damit nicht jede
    /// Sekunde ein Publish das Panel neu aufbaut.
    private func refreshDisplay() {
        let target = now().addingTimeInterval(remaining)
        if let deadline, abs(deadline.timeIntervalSince(target)) < 1 {
            // unverändert
        } else {
            deadline = target
        }
        let extendable = KeyboardLockPolicy.canExtend(allowed: allowedDuration)
        if extendable != canExtend { canExtend = extendable }
    }

    // MARK: - Ereignisse

    /// Anzeige „Feststelltaste an“ nachführen. Vom Tap-Thread asynchron auf
    /// den Main Thread; Tests rufen den Handler direkt auf dem Main Thread.
    nonisolated private static func publishCapsLock(_ on: Bool, to controller: KeyboardLockController?) {
        guard let controller else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated { controller.updateCapsLock(on) }
        } else {
            DispatchQueue.main.async { [weak controller] in
                MainActor.assumeIsolated { controller?.updateCapsLock(on) }
            }
        }
    }

    private func updateCapsLock(_ on: Bool) {
        guard isLocked, on != capsLockOn else { return }
        capsLockOn = on
    }

    // MARK: - Laufzeit

    private func startTicker() {
        stopTicker()
        let timer = Timer(timeInterval: KeyboardLockPolicy.heartbeatInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    /// Bildschirmsperre, Ruhezustand, Benutzerwechsel und App-Ende entsperren
    /// sofort — auf dem Sperrbildschirm muss das Passwort sicher durchgehen.
    private func startObserving() {
        stopObserving()
        let sources = notificationSources()
        let watch: [(NotificationCenter, Notification.Name, KeyboardUnlockReason)] = [
            (sources.workspace, NSWorkspace.willSleepNotification, .systemSleep),
            (sources.workspace, NSWorkspace.screensDidSleepNotification, .screensSlept),
            (sources.workspace, NSWorkspace.sessionDidResignActiveNotification, .sessionResigned),
            (sources.distributed, Self.screenLockedNotification, .screenLocked),
            (sources.app, NSApplication.willTerminateNotification, .appTerminating),
        ]
        for (center, name, reason) in watch {
            let fire: @MainActor () -> Void = { [weak self] in self?.unlock(reason: reason) }
            if let distributed = center as? DistributedNotificationCenter {
                let observer = DistributedObserver(fire: fire)
                distributed.addObserver(
                    observer,
                    selector: #selector(DistributedObserver.received(_:)),
                    name: name,
                    object: nil,
                    suspensionBehavior: .deliverImmediately
                )
                distributedObservers.append((distributed, observer))
            } else {
                let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { fire() }
                }
                observers.append((center, token))
            }
        }
    }

    private func stopObserving() {
        for (center, token) in observers {
            center.removeObserver(token)
        }
        for (center, observer) in distributedObservers {
            center.removeObserver(observer)
        }
        observers = []
        distributedObservers = []
    }

    /// Tasten, die gerade gedrückt sind (virtuelle Keycodes 0…127). Die
    /// Feststelltaste filtert `KeyboardLockPolicy.init` heraus.
    nonisolated static func liveKeysDown() -> Set<Int64> {
        var down = Set<Int64>()
        for code in 0..<128 where CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(code)) {
            down.insert(Int64(code))
        }
        return down
    }

    /// Ob der Bildschirm gerade gesperrt ist (WindowServer-Sitzungsdaten).
    nonisolated static func liveScreenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }
}

/// Ziel für das Selector-API von `DistributedNotificationCenter` (nur dort gibt
/// es `suspensionBehavior`). Zustellung kommt auf dem Main Thread an.
private final class DistributedObserver: NSObject {
    private let fire: @MainActor () -> Void

    init(fire: @escaping @MainActor () -> Void) {
        self.fire = fire
    }

    @objc func received(_ notification: Notification) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { fire() }
        } else {
            DispatchQueue.main.async { [fire] in
                MainActor.assumeIsolated { fire() }
            }
        }
    }
}
