import AppKit
import CoreGraphics
import Foundation

/// Reine Rechnung für die aktive Zeit: welcher Teil eines Intervalls als
/// Vordergrund- und welcher als aktive Zeit zählt. Ohne Uhr, ohne I/O.
enum StatisticsActivityMath {
    /// Längste Lücke zwischen zwei Buchungen, der wir trauen. Feuert der Timer
    /// viel später (der Mac schlief, ohne dass `willSleep` ankam), wird nur
    /// dieses letzte Stück gebucht statt der ganzen Nacht.
    static let maxGap: TimeInterval = 3 * 60

    struct Booking: Equatable, Sendable {
        var foreground: DateInterval?
        var active: DateInterval?
    }

    /// `[start, end)` war WhisperM8 vorne. Aktiv ist der Teil bis zur letzten
    /// Eingabe plus `idleThreshold`. Die Eingabezeit kennen wir nur zum Ende
    /// des Intervalls (`idleSeconds` = Sekunden seit der letzten Eingabe).
    static func booking(
        from start: Date,
        to end: Date,
        idleSeconds: TimeInterval,
        idleThreshold: TimeInterval = StatisticsTime.idleThreshold,
        maxGap: TimeInterval = StatisticsActivityMath.maxGap
    ) -> Booking {
        guard end > start else { return Booking() }
        let clampedStart = max(start, end.addingTimeInterval(-maxGap))
        let lastInput = end.addingTimeInterval(-max(0, idleSeconds))
        let activeEnd = min(end, lastInput.addingTimeInterval(idleThreshold))
        return Booking(
            foreground: DateInterval(start: clampedStart, end: end),
            active: activeEnd > clampedStart ? DateInterval(start: clampedStart, end: activeEnd) : nil
        )
    }

    /// Verteilt eine Buchung auf Tage und Stunden. Läuft auf der Store-Queue.
    static func apply(_ booking: Booking, to db: inout StatsDatabase, calendar: Calendar) {
        if let foreground = booking.foreground {
            for slice in StatisticsTime.slices(from: foreground.start, to: foreground.end, calendar: calendar) {
                db.updateDay(slice.dayKey) { $0.foregroundSeconds += slice.seconds }
            }
        }
        if let active = booking.active {
            for slice in StatisticsTime.slices(from: active.start, to: active.end, calendar: calendar) {
                db.updateDay(slice.dayKey) { day in
                    day.activeSeconds += slice.seconds
                    day.addHourly(active: slice.seconds, hour: slice.hour)
                }
            }
        }
    }
}

/// System- und App-Ereignisse, die die Zeitmessung beeinflussen.
enum StatisticsSystemEvent: Equatable, Sendable {
    case appBecameActive
    case appResignedActive
    case systemWillSleep
    case systemDidWake
    case screensDidSleep
    case screensDidWake
    case sessionResignedActive
    case sessionBecameActive
    case screenLocked
    case screenUnlocked
}

/// Misst Vordergrund- und aktive Zeit. Gezählt wird nur, solange
/// `NSApp.isActive` gilt und weder Ruhezustand, Bildschirmschlaf, Sperre noch
/// Benutzerwechsel dazwischenkommen. In dieser Zeit fragt ein Timer einmal pro
/// Minute die Leerlaufzeit ab und bucht das Stück seit dem letzten Tick; sonst
/// läuft gar nichts.
@MainActor
final class StatisticsActivityTracker {
    struct Environment {
        var now: () -> Date
        /// Sekunden seit der letzten Eingabe (Tastatur, Maus, Trackpad).
        var idleSeconds: () -> TimeInterval
        var isAppActive: () -> Bool
        /// Bei jeder Buchung frisch geholt: wechselt die Zeitzone (Reise,
        /// Systemeinstellung), landen spätere Buchungen am richtigen Tag.
        var calendar: () -> Calendar
        /// `nil`: kein Timer (Tests rufen `tick()` selbst).
        var tickInterval: TimeInterval?

        static var live: Environment {
            Environment(
                now: Date.init,
                idleSeconds: {
                    // ~0 = „irgendein Ereignis“ (kCGAnyInputEventType).
                    guard let anyEvent = CGEventType(rawValue: ~0) else { return 0 }
                    return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyEvent)
                },
                isAppActive: { NSApp?.isActive ?? false },
                calendar: { Calendar.current },
                tickInterval: 60
            )
        }
    }

    private let store: StatisticsStore
    private let env: Environment

    private var running = false
    /// Gesetzt, solange gezählt wird: bis hierhin ist schon gebucht.
    private(set) var countingSince: Date?
    private var timer: Timer?

    private var appActive = false
    private var systemAsleep = false
    private var screensAsleep = false
    private var screenLocked = false
    private var sessionInactive = false

    init(store: StatisticsStore, environment: Environment) {
        self.store = store
        self.env = environment
    }

    var isCounting: Bool { countingSince != nil }

    func start() {
        guard !running else { return }
        running = true
        appActive = env.isAppActive()
        reevaluate()
    }

    /// Bucht bis jetzt und hört auf (Statistik aus, App-Ende).
    func stop() {
        guard running else { return }
        running = false
        reevaluate()
    }

    func handle(_ event: StatisticsSystemEvent) {
        switch event {
        case .appBecameActive:
            appActive = true
            // Wer WhisperM8 nach vorne holt, sitzt am entsperrten, wachen
            // Mac. Verpasste Gegenstücke (z. B. ein verschlucktes
            // `screenIsUnlocked`) dürfen die Messung nicht dauerhaft sperren.
            systemAsleep = false
            screensAsleep = false
            screenLocked = false
            sessionInactive = false
        case .appResignedActive: appActive = false
        case .systemWillSleep: systemAsleep = true
        case .systemDidWake: systemAsleep = false
        case .screensDidSleep: screensAsleep = true
        case .screensDidWake: screensAsleep = false
        case .sessionResignedActive: sessionInactive = true
        case .sessionBecameActive: sessionInactive = false
        case .screenLocked: screenLocked = true
        case .screenUnlocked: screenLocked = false
        }
        reevaluate()
    }

    /// Bucht das Stück seit dem letzten Tick. Vom Timer und vor jedem Stopp.
    func tick() {
        guard let since = countingSince else { return }
        let now = env.now()
        guard now > since else {
            // Uhr zurückgestellt: neu ansetzen statt negativ zu buchen.
            countingSince = now
            return
        }
        let booking = StatisticsActivityMath.booking(from: since, to: now, idleSeconds: env.idleSeconds())
        countingSince = now
        let calendar = env.calendar()
        store.update { db in StatisticsActivityMath.apply(booking, to: &db, calendar: calendar) }
    }

    private var shouldCount: Bool {
        running && appActive && !systemAsleep && !screensAsleep && !screenLocked && !sessionInactive
    }

    private func reevaluate() {
        if shouldCount {
            guard countingSince == nil else { return }
            countingSince = env.now()
            startTimer()
        } else if countingSince != nil {
            tick()
            countingSince = nil
            stopTimer()
        }
    }

    private func startTimer() {
        guard timer == nil, let interval = env.tickInterval else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = max(10, interval / 4)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

/// Hört auf App-, Ruhezustands-, Bildschirm- und Sperr-Ereignisse und reicht
/// sie als `StatisticsSystemEvent` weiter. Muster wie in
/// `KeyboardLockController`: systemweite Sperr-Meldungen mit
/// `.deliverImmediately`, sonst hielte AppKit sie bei inaktiver App zurück.
@MainActor
final class StatisticsSystemEventObserver {
    static let screenLockedNotification = Notification.Name("com.apple.screenIsLocked")
    static let screenUnlockedNotification = Notification.Name("com.apple.screenIsUnlocked")

    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var distributed: [(DistributedNotificationCenter, StatisticsDistributedObserver)] = []

    func start(handler: @escaping @MainActor (StatisticsSystemEvent) -> Void) {
        stop()
        let app = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        let local: [(NotificationCenter, Notification.Name, StatisticsSystemEvent)] = [
            (app, NSApplication.didBecomeActiveNotification, .appBecameActive),
            (app, NSApplication.didResignActiveNotification, .appResignedActive),
            (workspace, NSWorkspace.willSleepNotification, .systemWillSleep),
            (workspace, NSWorkspace.didWakeNotification, .systemDidWake),
            (workspace, NSWorkspace.screensDidSleepNotification, .screensDidSleep),
            (workspace, NSWorkspace.screensDidWakeNotification, .screensDidWake),
            (workspace, NSWorkspace.sessionDidResignActiveNotification, .sessionResignedActive),
            (workspace, NSWorkspace.sessionDidBecomeActiveNotification, .sessionBecameActive),
        ]
        for (center, name, event) in local {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { handler(event) }
            }
            tokens.append((center, token))
        }
        let center = DistributedNotificationCenter.default()
        for (name, event) in [
            (Self.screenLockedNotification, StatisticsSystemEvent.screenLocked),
            (Self.screenUnlockedNotification, StatisticsSystemEvent.screenUnlocked),
        ] {
            let observer = StatisticsDistributedObserver { handler(event) }
            center.addObserver(
                observer,
                selector: #selector(StatisticsDistributedObserver.received(_:)),
                name: name,
                object: nil,
                suspensionBehavior: .deliverImmediately
            )
            distributed.append((center, observer))
        }
    }

    func stop() {
        for (center, token) in tokens { center.removeObserver(token) }
        for (center, observer) in distributed { center.removeObserver(observer) }
        tokens = []
        distributed = []
    }
}

private final class StatisticsDistributedObserver: NSObject {
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
