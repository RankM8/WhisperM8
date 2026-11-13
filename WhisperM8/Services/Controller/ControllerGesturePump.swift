import Foundation
import os

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
    /// Weiche gegen die doppelte Taste der Paddles, vor dem Erkenner. Ohne
    /// HID-Paddles ein reiner Durchgang.
    private var gate = ControllerPaddleGate()
    /// Zahlen der Weiche für den Debug-Kanal, von jedem Thread lesbar.
    private let gateStatsLock = OSAllocatedUnfairLock(initialState: ControllerPaddleGate.Stats())
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
    /// `origin`: Familie des Geräts (die Weiche prüft nur Xbox-Ereignisse).
    func ingest(_ event: ControllerInputEvent, origin: ControllerFamily = .playStation) {
        queue.async { [self] in
            // Zeit beim Empfang selbst messen: Die Zeitstempel des Frameworks
            // lagen bis macOS 26.1 in einer anderen Zeitbasis.
            let now = clock()
            feed(gate.gameController(event, origin: origin, at: now), at: now)
        }
    }

    /// Ein gebündelter HID-Bericht des Xbox-Controllers. Kommt schon auf
    /// `queue` an (`IOHIDManagerSetDispatchQueue`), darf aber von überall kommen.
    func ingestHID(_ report: ControllerHIDReport) {
        queue.async { [self] in
            let now = clock()
            feed(gate.hid(report, at: now), at: now)
        }
    }

    /// Paddles über HID lesbar oder nicht (Rückfall: reiner Durchgang).
    func setPaddleSourceAvailable(_ available: Bool) {
        queue.async { [self] in
            let now = clock()
            feed(gate.setPaddleSource(available: available), at: now)
        }
    }

    /// Zahlen der Weiche (Debug-Kanal).
    var paddleGateStats: ControllerPaddleGate.Stats {
        gateStatsLock.withLock { $0 }
    }

    /// Alles Gehaltene lösen (Trennung, Ruhezustand, Ausschalten).
    func reset() {
        queue.async { [self] in
            gate.reset()
            emit(recognizer.reset(at: clock()))
            reschedule()
        }
    }

    /// Was die Weiche freigibt, mit der Zeit des Durchlassens in den Erkenner
    /// (nie eine ältere: Der Erkenner verträgt keine rückwärts laufende Zeit).
    private func feed(_ events: [ControllerInputEvent], at now: TimeInterval) {
        var gestures: [ControllerGesture] = []
        for event in events { gestures += recognizer.handle(event, at: now) }
        publishGateStats()
        emit(gestures)
        reschedule()
    }

    // MARK: - Zeitgeber (nur auf `queue`)

    private func publishGateStats() {
        let stats = gate.stats
        gateStatsLock.withLock { $0 = stats }
    }

    private func emit(_ gestures: [ControllerGesture]) {
        let idle = recognizer.isIdle
        let becameIdle = idle && !wasIdle
        wasIdle = idle
        guard !gestures.isEmpty || becameIdle else { return }
        onGestures?(gestures, idle)
    }

    private func reschedule() {
        let deadlines = [recognizer.nextDeadline, gate.nextDeadline].compactMap { $0 }
        guard let deadline = deadlines.min() else {
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
            let now = self.clock()
            var gestures: [ControllerGesture] = []
            for event in self.gate.tick(at: now) { gestures += self.recognizer.handle(event, at: now) }
            gestures += self.recognizer.tick(at: now)
            self.publishGateStats()
            self.emit(gestures)
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
        guard recognizer.isIdle, !gate.isHolding, let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
    }
}
