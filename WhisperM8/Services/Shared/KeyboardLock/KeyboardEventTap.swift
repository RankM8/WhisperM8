import AppKit
import CoreGraphics

/// Entscheidung je Ereignis. Läuft auf dem Tap-Thread, nie auf dem Main
/// Thread — darf also keinen Main-Actor-Zustand anfassen.
typealias KeyboardEventTapHandler = @Sendable (KeyboardLockPolicy.Event, CGEventFlags) -> KeyboardLockPolicy.Decision

/// Dünne Hülle um den echten `CGEventTap`, damit der Controller ohne
/// Systemeingriff testbar bleibt.
@MainActor
protocol KeyboardEventTapping: AnyObject {
    /// Installiert den Tap. `false`, wenn macOS ihn verweigert (fehlende
    /// Bedienungshilfen-Freigabe).
    func install(handler: @escaping KeyboardEventTapHandler) -> Bool
    func uninstall()
}

/// Aktiver Tap auf HID-Ebene: sitzt vor Apps, Systemkürzeln (⌘-Tab) und den
/// Carbon-Hotkeys. Er läuft auf einem EIGENEN Thread mit eigenem Runloop
/// (`KeyboardTapSession`): Ein stockender Main Thread lässt macOS den Tap
/// also nicht mehr abschalten, und keine Taste rutscht durch. Damit ein
/// echter Hänger die Tastatur trotzdem freigibt, sperrt die Entscheidung nur,
/// solange das Lebenszeichen vom Main Thread frisch ist (`KeyboardLockGate`).
/// Stirbt die App, verschwindet der Tap mit dem Prozess.
@MainActor
final class LiveKeyboardEventTap: KeyboardEventTapping {
    /// `NX_SYSDEFINED` — in `CGEventType` nicht als Fall vorhanden.
    nonisolated static let systemDefinedType: UInt32 = 14

    private var session: KeyboardTapSession?
    /// App Nap aus, solange gesperrt: Er würde den Timer des Lebenszeichens
    /// drosseln, und die Sperre ließe dann fälschlich Tasten durch.
    private var activity: NSObjectProtocol?

    func install(handler: @escaping KeyboardEventTapHandler) -> Bool {
        uninstall()
        guard let session = KeyboardTapSession.start(handler: handler) else { return false }
        self.session = session
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Keyboard lock heartbeat"
        )
        return true
    }

    func uninstall() {
        session?.stop()
        session = nil
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
        activity = nil
    }

    /// Ob das Ereignis weitergereicht wird. Nach `.reenableTap` geht es durch —
    /// verworfen wird nur bei `.swallow`.
    nonisolated static func delivers(_ decision: KeyboardLockPolicy.Decision) -> Bool {
        decision != .swallow
    }

    /// Übersetzt ein `CGEvent` in das Ereignis der reinen Logik.
    nonisolated static func event(type: CGEventType, cgEvent: CGEvent) -> KeyboardLockPolicy.Event {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            return .tapDisabled
        case .keyDown:
            return .keyDown(keyCode: cgEvent.getIntegerValueField(.keyboardEventKeycode))
        case .keyUp:
            return .keyUp(keyCode: cgEvent.getIntegerValueField(.keyboardEventKeycode))
        case .flagsChanged:
            return .flagsChanged(keyCode: cgEvent.getIntegerValueField(.keyboardEventKeycode))
        default:
            if type.rawValue == systemDefinedType, let nsEvent = NSEvent(cgEvent: cgEvent) {
                return .systemDefined(subtype: nsEvent.subtype.rawValue)
            }
            return .other
        }
    }
}

/// Ein Tap samt eigenem Thread und Runloop, von `start` bis `stop`.
///
/// Ablauf: Der Main Thread legt den Port an (dort fällt die Entscheidung über
/// die Freigabe) und startet den Thread. Der Thread hängt die Runloop-Quelle
/// an SEINEN Runloop, schaltet den Tap ein und läuft, bis `stop` kommt. `stop`
/// schaltet den Tap sofort aus (die Tastatur ist damit frei, noch bevor der
/// Thread reagiert) und hält den Runloop an. Quelle entfernen und Port
/// ungültig machen passiert danach auf dem Tap-Thread selbst; dann endet er.
/// Der Thread hält die Session bis dahin fest, der Callback-Zeiger bleibt
/// also gültig. Ein Mach-Port ist kein Dateideskriptor und wird bei `execve`
/// nicht vererbt — close-on-exec ist hier kein Thema.
final class KeyboardTapSession: @unchecked Sendable {
    private let handler: KeyboardEventTapHandler
    /// Schützt `port`, `runLoop` und `stopped`.
    private let lock = NSLock()
    private var port: CFMachPort?
    private var runLoop: CFRunLoop?
    private var stopped = false

    private init(handler: @escaping KeyboardEventTapHandler) {
        self.handler = handler
    }

    /// `nil`, wenn macOS den Tap verweigert oder der Thread nicht anläuft.
    static func start(handler: @escaping KeyboardEventTapHandler) -> KeyboardTapSession? {
        let session = KeyboardTapSession(handler: handler)
        return session.launch() ? session : nil
    }

    private func launch() -> Bool {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << LiveKeyboardEventTap.systemDefinedType)

        guard let port = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: keyboardLockTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }
        // Erst einschalten, wenn der Thread den Port bedient.
        CGEvent.tapEnable(tap: port, enable: false)
        lock.withLock { self.port = port }

        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            self.run(port: port, ready: ready)
        }
        thread.name = "com.whisperm8.keyboard-lock-tap"
        thread.qualityOfService = .userInteractive
        thread.start()

        let signaled = ready.wait(timeout: .now() + 2) == .success
        guard signaled, lock.withLock({ runLoop != nil }) else {
            // Der Thread sieht `stopped` und baut selbst ab, sobald er läuft.
            stop()
            Logger.keyboardLock.error("keyboard_lock_tap_thread_start_failed signaled=\(signaled, privacy: .public)")
            return false
        }
        return true
    }

    /// Hauptschleife des Tap-Threads.
    private func run(port: CFMachPort, ready: DispatchSemaphore) {
        let runLoop = CFRunLoopGetCurrent()
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        let running: Bool = lock.withLock {
            guard !stopped, let runLoop, let source else { return false }
            self.runLoop = runLoop
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            return true
        }
        ready.signal()

        if running {
            // Endet über CFRunLoopStop aus `stop`. Das Sekunden-Zeitlimit fängt
            // nur das Rennen ab, dass `stop` kam, bevor der Runloop lief.
            while !lock.withLock({ stopped }) {
                if CFRunLoopRunInMode(.defaultMode, 1, false) == .finished { break }
            }
            if let runLoop, let source {
                CFRunLoopRemoveSource(runLoop, source, .commonModes)
            }
        }
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
        lock.withLock {
            self.port = nil
            self.runLoop = nil
        }
    }

    /// Vom Main Thread: Tap sofort aus, Runloop anhalten. Mehrfach harmlos.
    func stop() {
        let runLoop: CFRunLoop? = lock.withLock {
            guard !stopped else { return nil }
            stopped = true
            if let port { CGEvent.tapEnable(tap: port, enable: false) }
            return self.runLoop
        }
        if let runLoop {
            CFRunLoopStop(runLoop)
            CFRunLoopWakeUp(runLoop)
        }
    }

    /// Auf dem Tap-Thread: Ereignis entscheiden, abgeschalteten Tap wieder
    /// einschalten (nur solange nicht gestoppt).
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let mapped = LiveKeyboardEventTap.event(type: type, cgEvent: event)
        let decision = handler(mapped, event.flags)
        if decision == .reenableTap {
            let reenabled: Bool = lock.withLock {
                guard !stopped, let port else { return false }
                CGEvent.tapEnable(tap: port, enable: true)
                return true
            }
            if reenabled {
                Logger.keyboardLock.info("keyboard_lock_tap_reenabled")
            }
        }
        return LiveKeyboardEventTap.delivers(decision) ? Unmanaged.passUnretained(event) : nil
    }
}

/// C-Callback des Taps. Läuft auf dem Tap-Thread (siehe `KeyboardTapSession`).
private func keyboardLockTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let session = Unmanaged<KeyboardTapSession>.fromOpaque(refcon).takeUnretainedValue()
    return session.handle(type: type, event: event)
}
