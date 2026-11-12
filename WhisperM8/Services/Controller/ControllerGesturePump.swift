import Foundation

/// Treibt den `ControllerGestureRecognizer` auf einer eigenen seriellen Queue:
/// nimmt Roh-Ereignisse an, stellt den Zeitgeber für Halten und Wiederholen
/// und gibt fertige Gesten weiter.
///
/// Im Ruhezustand läuft nichts — der Zeitgeber ist nur gestellt, solange eine
/// Taste gedrückt oder ein Stick ausgelenkt ist. So lange hält die Pumpe auch
/// eine Aktivität gegen App Nap, sonst käme ein Halten im Menüleisten-Betrieb
/// verspätet an.
final class ControllerGesturePump: @unchecked Sendable {
    /// Eigene Queue, nie eine globale: Das Framework liefert Eingaben
    /// verzögert, wenn sich die Handler eine ausgelastete Queue teilen.
    let queue = DispatchQueue(label: "com.whisperm8.controller.input", qos: .userInteractive)

    /// Fertige Gesten, dazu ob danach nichts mehr gedrückt oder ausgelenkt
    /// ist. Aufgerufen auf `queue`. Wird der Erkenner ruhig, kommt ein Aufruf
    /// auch ohne Gesten (Stick losgelassen): Der Manager verwirft nach dem
    /// Aufwecken bis genau zu diesem Punkt.
    var onGestures: (@Sendable (_ gestures: [ControllerGesture], _ idleAfter: Bool) -> Void)?

    private var recognizer: ControllerGestureRecognizer
    private let clock: @Sendable () -> TimeInterval
    private var timer: DispatchSourceTimer?
    private var activity: NSObjectProtocol?
    private var wasIdle = true

    init(
        config: ControllerGestureRecognizer.Config = .init(),
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.recognizer = ControllerGestureRecognizer(config: config)
        self.clock = clock
    }

    deinit {
        timer?.cancel()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }

    /// Ein Roh-Ereignis verarbeiten. Von jedem Thread aus aufrufbar.
    func ingest(_ event: ControllerInputEvent) {
        queue.async { [self] in
            // Zeit beim Empfang selbst messen: Die Zeitstempel des Frameworks
            // lagen bis macOS 26.1 in einer anderen Zeitbasis.
            emit(recognizer.handle(event, at: clock()))
            reschedule()
        }
    }

    /// Alles Gehaltene lösen (Trennung, Ruhezustand, Ausschalten).
    func reset() {
        queue.async { [self] in
            emit(recognizer.reset(at: clock()))
            reschedule()
        }
    }

    // MARK: - Zeitgeber (nur auf `queue`)

    private func emit(_ gestures: [ControllerGesture]) {
        let idle = recognizer.isIdle
        let becameIdle = idle && !wasIdle
        wasIdle = idle
        guard !gestures.isEmpty || becameIdle else { return }
        onGestures?(gestures, idle)
    }

    private func reschedule() {
        guard let deadline = recognizer.nextDeadline else {
            timer?.schedule(deadline: .distantFuture)
            endActivityIfIdle()
            return
        }
        beginActivity()
        let delay = max(0, deadline - clock())
        ensureTimer().schedule(deadline: .now() + delay, leeway: .milliseconds(2))
    }

    private func ensureTimer() -> DispatchSourceTimer {
        if let timer { return timer }
        // `.strict`: kein Zusammenlegen mit anderen Zeitgebern — sonst würde
        // ein Halten spürbar zu spät erkannt.
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.emit(self.recognizer.tick(at: self.clock()))
            self.reschedule()
        }
        timer.schedule(deadline: .distantFuture)
        timer.resume()
        self.timer = timer
        return timer
    }

    private func beginActivity() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Controller input in progress")
    }

    private func endActivityIfIdle() {
        guard recognizer.isIdle, let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
    }
}
