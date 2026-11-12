import CoreGraphics
import Foundation
import os

/// Setzt Mausbewegungen und Klicks ins System um. Wird nur auf der
/// Eingabe-Queue der Pumpe aufgerufen. Die Live-Fassung ist der
/// `CGEventPointerPoster`; Tests setzen einen Spion ein.
protocol ControllerPointerPosting: AnyObject {
    func post(_ output: ControllerPointerOutput)
}

/// Touchpad als Maus auf der Eingabe-Queue: Fingerdaten gehen nie in den
/// Erkenner und nie zum Main Thread, nur der Klick meldet sich dort (für den
/// kurzen Haptik-Impuls). Entscheidet je Ereignis, ob es der Zeiger
/// übernimmt oder der Erkenner bekommt.
///
/// Touchpad-Druck bei eingeschaltetem Schalter:
/// - L2 gedrückt (auch als Taste in einer anderen Ebene): geht an den
///   Erkenner (`.inLayer(.whereTo, .press(.touchpad))` öffnet den Verlauf)
///   — kein Klick.
/// - sonst, solange der Zeiger wirken darf: Klick, Loslassen lässt die Taste los.
/// - pausiert oder im Trockenlauf: nichts.
/// Ist der Schalter aus, geht der Druck wie bisher an den Erkenner.
///
/// App Nap: Solange Finger gemeldet werden oder die Taste gedrückt ist, hält
/// der Treiber eine Aktivität. Ist ein anderes Programm vorne, ruckelte der
/// Zeiger sonst. Je Meldung wird nur die Zeit vermerkt; ein Zeitgeber auf der
/// Queue (einmal angelegt) beendet die Aktivität nach `idleTimeout` Ruhe.
final class ControllerPointerDriver: @unchecked Sendable {
    struct Settings: Equatable, Sendable {
        /// Schalter „Touchpad als Maus“ an und Steuerung läuft.
        var enabled = false
        /// Der Zeiger darf wirken: keine Pause, kein Trockenlauf.
        var active = false
        var speed = ControllerTouchpadPointer.Config.defaultSpeed
        var doubleClickInterval: TimeInterval = 0.5
    }

    enum Disposition: Equatable {
        /// Weiter an den Erkenner.
        case recognizer
        /// Vom Zeiger übernommen (oder bewusst verworfen).
        case handled
        /// Ein Klick ging raus: Eine gehaltene Ebenen-Taste gilt nicht mehr
        /// als getippt.
        case clicked
    }

    /// Wohin der laufende Touchpad-Druck ging.
    private enum Route { case recognizer, pointer, dropped }

    /// Ein Klick ging raus (für den Haptik-Impuls). Aufgerufen auf der Queue.
    var onClick: (@Sendable () -> Void)?

    /// So lange nach der letzten Meldung endet die Aktivität gegen App Nap.
    private let idleTimeout: TimeInterval

    private let poster: ControllerPointerPosting?
    private let queue: DispatchQueue?
    private let clock: @Sendable () -> TimeInterval
    private var tracker = ControllerTouchpadPointer()
    private(set) var settings = Settings()
    private var route: Route?
    private var activity: NSObjectProtocol?
    private var idleTimer: DispatchSourceTimer?
    private var lastInputAt: TimeInterval = 0

    /// - Parameters:
    ///   - queue: Eingabe-Queue der Pumpe, für den Ruhe-Zeitgeber. Ohne Queue
    ///     (Tests) gibt es keine Aktivität.
    init(
        poster: ControllerPointerPosting?,
        queue: DispatchQueue? = nil,
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        idleTimeout: TimeInterval = 1.0
    ) {
        self.poster = poster
        self.queue = queue
        self.clock = clock
        self.idleTimeout = idleTimeout
    }

    deinit {
        idleTimer?.cancel()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }

    /// Hält gerade eine Aktivität gegen App Nap (Tests).
    var holdsActivity: Bool { activity != nil }

    // MARK: - Nur auf der Queue der Pumpe

    func apply(_ settings: Settings) {
        self.settings = settings
        tracker.config.speed = min(max(settings.speed, ControllerTouchpadPointer.Config.speedRange.lowerBound),
                                   ControllerTouchpadPointer.Config.speedRange.upperBound)
        tracker.config.doubleClickInterval = settings.doubleClickInterval
        if !settings.active {
            reset()
            endActivity()
        }
    }

    /// - Parameter l2Held: L2 ist gerade gedrückt (auch als Taste in einer
    ///   anderen Ebene): Der Touchpad-Druck gehört dann dem Verlauf.
    func handle(_ event: ControllerInputEvent, at time: TimeInterval, l2Held: Bool) -> Disposition {
        switch event {
        case let .touch(finger, x, y):
            guard settings.active else { return .handled }
            noteInput(at: time)
            let output = tracker.touch(finger, x: x, y: y, at: time)
            if let transition = tracker.lastTransition { log(transition) }
            if let output { poster?.post(output) }
            return .handled
        case .button(.touchpad, pressed: true):
            guard settings.enabled else { return .recognizer }
            if l2Held {
                route = .recognizer
                return .recognizer
            }
            guard settings.active else {
                route = .dropped
                return .handled
            }
            route = .pointer
            noteInput(at: time)
            poster?.post(tracker.press(at: time))
            onClick?()
            return .clicked
        case .button(.touchpad, pressed: false):
            defer { route = nil }
            guard route == .pointer else {
                // Der Erkenner übergeht ein Loslassen ohne Drücken.
                return .recognizer
            }
            if let output = tracker.release(at: time) { poster?.post(output) }
            noteInput(at: time)
            return .handled
        default:
            return .recognizer
        }
    }

    /// Einmal je Abheben bzw. Aufsetzen, nie je Meldung: Zeigt am Gerät, wie
    /// das Framework ein Abheben meldet ((0, 0) oder nur Lücke/Sprung).
    private func log(_ transition: ControllerTouchpadPointer.Transition) {
        switch transition {
        case let .lifted(finger):
            Logger.controller.debug("controller_touch_lifted finger=\(finger.rawValue, privacy: .public)")
        case let .landed(finger, reason):
            Logger.controller.debug("controller_touch_landed finger=\(finger.rawValue, privacy: .public) reason=\(reason.rawValue, privacy: .public)")
        }
    }

    // MARK: - Aktivität gegen App Nap (nur auf der Queue)

    private func noteInput(at time: TimeInterval) {
        lastInputAt = time
        guard activity == nil, let queue else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Controller touchpad moves the pointer")
        let timer = idleTimer ?? {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler { [weak self] in self?.idleTimerFired() }
            timer.resume()
            idleTimer = timer
            return timer
        }()
        timer.schedule(deadline: .now() + idleTimeout, leeway: .milliseconds(10))
    }

    private func idleTimerFired() {
        let quiet = clock() - lastInputAt
        if tracker.pressed == nil, quiet >= idleTimeout {
            endActivity()
        } else {
            idleTimer?.schedule(deadline: .now() + max(idleTimeout - quiet, idleTimeout / 2), leeway: .milliseconds(10))
        }
    }

    private func endActivity() {
        idleTimer?.schedule(deadline: .distantFuture)
        guard let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
    }

    /// Finger vergessen, eine gedrückte Taste loslassen.
    func reset() {
        if let output = tracker.reset() { poster?.post(output) }
    }
}

/// Live-Fassung: Mausereignisse über `CGEvent`. Braucht die
/// Bedienungshilfen-Berechtigung; ohne sie verwirft das System die Ereignisse
/// still (die Einstellungsseite zeigt dann einen Hinweis). Nur auf der
/// Eingabe-Queue der Pumpe.
final class CGEventPointerPoster: ControllerPointerPosting, @unchecked Sendable {
    /// Markierung in `eventSourceUserData` („WM8P“), damit eigene
    /// Mausereignisse erkennbar bleiben.
    static let marker: Int64 = 0x574D_3850

    private let source = CGEventSource(stateID: .hidSystemState)
    /// Zuletzt gesetzte Position mit Nachkommastellen. Steht der echte Zeiger
    /// noch dort, geht es von hier weiter — so gehen langsame Bewegungen unter
    /// einem Punkt nicht verloren.
    private var lastPosted: CGPoint?
    private var held: ControllerPointerButton?

    func post(_ output: ControllerPointerOutput) {
        let location = currentLocation()
        switch output {
        case let .move(dx, dy):
            let target = Self.clamp(CGPoint(x: location.x + dx, y: location.y + dy), from: location)
            let type: CGEventType
            switch held {
            case .left: type = .leftMouseDragged
            case .right: type = .rightMouseDragged
            case nil: type = .mouseMoved
            }
            send(type, at: target, button: held ?? .left) { event in
                event.setIntegerValueField(.mouseEventDeltaX, value: Int64((target.x - location.x).rounded()))
                event.setIntegerValueField(.mouseEventDeltaY, value: Int64((target.y - location.y).rounded()))
            }
            lastPosted = target
        case let .buttonDown(button, clickCount):
            held = button
            send(button == .left ? .leftMouseDown : .rightMouseDown, at: location, button: button) { event in
                event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
            }
            lastPosted = location
        case let .buttonUp(button, clickCount):
            held = nil
            send(button == .left ? .leftMouseUp : .rightMouseUp, at: location, button: button) { event in
                event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
            }
            lastPosted = location
        }
    }

    private func send(
        _ type: CGEventType, at point: CGPoint, button: ControllerPointerButton, configure: (CGEvent) -> Void
    ) {
        guard let event = CGEvent(
            mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
            mouseButton: button == .left ? .left : .right) else { return }
        event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        configure(event)
        event.post(tap: .cghidEventTap)
    }

    private func currentLocation() -> CGPoint {
        let system = CGEvent(source: nil)?.location ?? lastPosted ?? .zero
        if let lastPosted, abs(lastPosted.x - system.x) < 1, abs(lastPosted.y - system.y) < 1 {
            return lastPosted
        }
        return system
    }

    /// Hält den Zeiger auf den Bildschirmen: Liegt das Ziel auf keinem, bleibt
    /// er am Rand des Bildschirms, auf dem er gerade ist.
    static func clamp(_ point: CGPoint, from origin: CGPoint) -> CGPoint {
        if display(containing: point) != nil { return point }
        guard let display = display(containing: origin) else { return origin }
        let bounds = CGDisplayBounds(display)
        return CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX - 1),
            y: min(max(point.y, bounds.minY), bounds.maxY - 1))
    }

    private static func display(containing point: CGPoint) -> CGDirectDisplayID? {
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &display, &count) == .success, count > 0 else { return nil }
        return display
    }
}
