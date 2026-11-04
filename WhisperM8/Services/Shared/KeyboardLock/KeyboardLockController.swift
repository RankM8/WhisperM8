import AppKit
import Carbon.HIToolbox
import Combine
import CoreGraphics

/// Tastatursperre zum Reinigen: verwirft alle Tastatur-Ereignisse, bis der
/// Nutzer per Maus entsperrt oder die Frist abläuft. Maus und Trackpad bleiben
/// frei. Mehrere Wege heben die Sperre auf (siehe docs/features/keyboard-cleaning.md):
/// Knopf, Frist, Bildschirmsperre/Ruhezustand, App-Ende, Absturz (Tap stirbt
/// mit dem Prozess), hängender Main Thread (macOS schaltet den Tap ab).
@MainActor
final class KeyboardLockController: ObservableObject {
    static let shared = KeyboardLockController()

    enum StartResult: Equatable {
        case locked
        case alreadyLocked
        case missingPermission
    }

    @Published private(set) var isLocked = false
    @Published private(set) var lockedAt: Date?
    @Published private(set) var deadline: Date?
    /// Ein Passwortfeld (Secure Event Input) ist aktiv — dann sieht macOS'
    /// Tap keine Tasten, sie kommen durch.
    @Published private(set) var secureInputActive = false
    @Published private(set) var capsLockOn = false
    @Published private(set) var lastUnlockReason: KeyboardUnlockReason?

    private let tap: KeyboardEventTapping
    private let now: () -> Date
    private let secureInputProbe: () -> Bool
    private let capsLockProbe: () -> Bool
    private let keysDownProbe: () -> Set<Int64>
    private let panel: KeyboardLockPanelPresenting
    private var policy = KeyboardLockPolicy()
    private var ticker: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(
        tap: KeyboardEventTapping? = nil,
        panel: KeyboardLockPanelPresenting? = nil,
        now: @escaping () -> Date = Date.init,
        secureInputProbe: @escaping () -> Bool = { IsSecureEventInputEnabled() },
        capsLockProbe: @escaping () -> Bool = {
            CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift)
        },
        keysDownProbe: @escaping () -> Set<Int64> = KeyboardLockController.liveKeysDown
    ) {
        self.tap = tap ?? LiveKeyboardEventTap()
        self.panel = panel ?? KeyboardLockPanelController()
        self.now = now
        self.secureInputProbe = secureInputProbe
        self.capsLockProbe = capsLockProbe
        self.keysDownProbe = keysDownProbe
    }

    var canExtend: Bool {
        guard let deadline, let lockedAt else { return false }
        return KeyboardLockPolicy.canExtend(current: deadline, lockedAt: lockedAt)
    }

    // MARK: - Steuerung

    @discardableResult
    func lock(duration: TimeInterval = KeyboardLockPolicy.defaultDuration) -> StartResult {
        guard !isLocked else { return .alreadyLocked }
        policy = KeyboardLockPolicy(keysDownAtLock: keysDownProbe())
        let installed = tap.install { [weak self] event, flags in
            self?.handle(event, flags: flags) ?? .pass
        }
        guard installed else {
            Logger.keyboardLock.notice("keyboard_lock_denied reason=tap_create_failed")
            return .missingPermission
        }
        let start = now()
        lockedAt = start
        deadline = start.addingTimeInterval(duration)
        isLocked = true
        lastUnlockReason = nil
        secureInputActive = secureInputProbe()
        capsLockOn = capsLockProbe()
        startObserving()
        startTicker()
        panel.show(controller: self)
        Logger.keyboardLock.info("keyboard_lock_started duration=\(Int(duration), privacy: .public)s secure_input=\(self.secureInputActive, privacy: .public)")
        return .locked
    }

    func unlock(reason: KeyboardUnlockReason) {
        guard isLocked else { return }
        tap.uninstall()
        stopTicker()
        stopObserving()
        isLocked = false
        lockedAt = nil
        deadline = nil
        lastUnlockReason = reason
        policy = KeyboardLockPolicy()
        panel.hide()
        Logger.keyboardLock.info("keyboard_lock_ended reason=\(reason.rawValue, privacy: .public)")
    }

    func extend() {
        guard isLocked, let deadline, let lockedAt else { return }
        self.deadline = KeyboardLockPolicy.extendedDeadline(current: deadline, lockedAt: lockedAt, now: now())
    }

    /// Prüft Frist und Passwortfeld; läuft sekündlich, solange gesperrt.
    func tick() {
        guard isLocked else { return }
        if let deadline, now() >= deadline {
            unlock(reason: .timeout)
            return
        }
        let secure = secureInputProbe()
        if secure != secureInputActive { secureInputActive = secure }
    }

    // MARK: - Ereignisse

    func handle(_ event: KeyboardLockPolicy.Event, flags: CGEventFlags) -> KeyboardLockPolicy.Decision {
        guard isLocked else { return .pass }
        if case .flagsChanged = event {
            let caps = flags.contains(.maskAlphaShift)
            if caps != capsLockOn { capsLockOn = caps }
        }
        let decision = policy.decide(event)
        if decision == .reenableTap {
            Logger.keyboardLock.info("keyboard_lock_tap_reenabled")
        }
        return decision
    }

    // MARK: - Laufzeit

    private func startTicker() {
        stopTicker()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
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
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let watch: [(NotificationCenter, Notification.Name, KeyboardUnlockReason)] = [
            (workspace, NSWorkspace.willSleepNotification, .systemSleep),
            (workspace, NSWorkspace.screensDidSleepNotification, .systemSleep),
            (workspace, NSWorkspace.sessionDidResignActiveNotification, .sessionResigned),
            (distributed, Notification.Name("com.apple.screenIsLocked"), .screenLocked),
            (NotificationCenter.default, NSApplication.willTerminateNotification, .appTerminating),
        ]
        observers = watch.map { center, name, reason in
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.unlock(reason: reason) }
            }
            return (center, token)
        }
    }

    private func stopObserving() {
        for (center, token) in observers {
            center.removeObserver(token)
        }
        observers = []
    }

    /// Tasten, die gerade gedrückt sind (virtuelle Keycodes 0…127).
    nonisolated static func liveKeysDown() -> Set<Int64> {
        var down = Set<Int64>()
        for code in 0..<128 where CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(code)) {
            down.insert(Int64(code))
        }
        return down
    }
}
