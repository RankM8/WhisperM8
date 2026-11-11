import AppKit
import Foundation
import Observation
import os

/// Führt Aktionen aus und sagt, in welchem Zustand die App gerade ist.
/// Die Live-Fassung ist der `ControllerActionDispatcher`.
@MainActor
protocol ControllerActionPerforming: AnyObject {
    /// Zustand der App im Moment der Eingabe. Wird je Geste gezogen.
    func snapshot() -> ControllerAppSnapshot
    func perform(_ action: ControllerAction, in context: ControllerContext)
}

/// Eine aufgelöste Geste: was erkannt wurde, in welchem Zusammenhang, und
/// was daraus wurde. Für den Debug-Kanal und die Tests.
struct ControllerResolution: Equatable {
    var gesture: ControllerGesture
    var context: ControllerContext
    var action: ControllerAction?
    var executed: Bool
}

/// Ob Eingaben ankommen, während ein anderes Programm vorne ist.
enum ControllerBackgroundState: String {
    /// In den Einstellungen ausgeschaltet.
    case off
    /// Eingeschaltet, aber das System behält den Schalter nicht.
    case unavailable
    /// Eingeschaltet, bisher kam im Hintergrund nichts an.
    case waiting
    /// Im Hintergrund ist schon mindestens eine Taste angekommen.
    case received
}

/// Anzeige-Zustand der Controller-Steuerung (Einstellungsseite, Legende).
/// Eigener kleiner Beobachtungswert: Die großen Ansichten lesen ihn nicht.
@MainActor
@Observable
final class ControllerStatus {
    var device: ControllerDeviceInfo?
    var isRunning = false
    var isPaused = false
    var background: ControllerBackgroundState = .off
    /// Zuletzt gedrückte Taste (Tasten-Test auf der Einstellungsseite).
    var lastButton: ControllerButton?
    var lastButtonCount = 0
}

/// Zählt Roh-Ereignisse je Taste, getrennt danach, ob die App vorne war.
/// Wird auf der Eingabe-Queue geschrieben und vom Debug-Kanal gelesen.
final class ControllerEventCounters: @unchecked Sendable {
    struct Counts: Equatable {
        var downActive = 0
        var upActive = 0
        var downInactive = 0
        var upInactive = 0
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var counts: [ControllerButton: Counts] = [:]
        var appIsActive = true
        var lastEventAt: Date?
    }

    func setAppActive(_ active: Bool) {
        lock.withLock { $0.appIsActive = active }
    }

    func record(_ event: ControllerInputEvent) {
        guard case let .button(button, pressed) = event else {
            lock.withLock { $0.lastEventAt = Date() }
            return
        }
        lock.withLock { state in
            var counts = state.counts[button, default: Counts()]
            switch (pressed, state.appIsActive) {
            case (true, true): counts.downActive += 1
            case (false, true): counts.upActive += 1
            case (true, false): counts.downInactive += 1
            case (false, false): counts.upInactive += 1
            }
            state.counts[button] = counts
            state.lastEventAt = Date()
        }
    }

    var snapshot: (counts: [ControllerButton: Counts], lastEventAt: Date?) {
        lock.withLock { ($0.counts, $0.lastEventAt) }
    }

    var receivedInBackground: Bool {
        lock.withLock { $0.counts.values.contains { $0.downInactive > 0 } }
    }

    func reset() {
        lock.withLock { $0.counts = [:]; $0.lastEventAt = nil }
    }
}

/// Verbindet Eingabe-Quelle, Erkennung und Ausführung.
///
/// Ablauf: Roh-Ereignisse kommen auf der Eingabe-Queue an, die
/// `ControllerGesturePump` macht daraus Gesten. Nur diese diskreten Gesten
/// gehen zum Main Thread; dort werden Zusammenhang und Aktion bestimmt.
@MainActor
final class ControllerManager {
    static let shared = ControllerManager(source: GameControllerInputSource())

    let status = ControllerStatus()
    let counters = ControllerEventCounters()

    /// Führt aus. Ohne Ausführer werden Gesten nur aufgelöst und gezählt.
    weak var performer: ControllerActionPerforming?

    /// Trockenlauf (Debug-Kanal): auflösen, aber nichts ausführen.
    var isDryRun = false
    /// Ersetzt im Schnappschuss, was die Test-Instanz nie hat: ein aktives
    /// Fenster. Nur über den Debug-Kanal gesetzt.
    var debugOverride: ControllerDebugOverride?
    /// Die letzten Auflösungen, neueste zuletzt (Debug-Kanal, Tests).
    private(set) var recentResolutions: [ControllerResolution] = []
    /// Wird nach jeder aufgelösten Geste aufgerufen (Rückmeldung, Legende).
    var onResolution: ((ControllerResolution) -> Void)?
    /// Lauf, Verbindung oder Pause haben sich geändert.
    var onStateChange: (() -> Void)?

    private let source: ControllerInputSource
    private let pump: ControllerGesturePump
    private let preferences: () -> AppPreferences
    private var activeObservers: [NSObjectProtocol] = []
    private var userPaused = false
    private var systemPaused = false

    init(
        source: ControllerInputSource,
        pump: ControllerGesturePump = ControllerGesturePump(),
        preferences: @escaping () -> AppPreferences = { AppPreferences.shared }
    ) {
        self.source = source
        self.pump = pump
        self.preferences = preferences

        let counters = self.counters
        source.onEvent = { [pump] event in
            counters.record(event)
            pump.ingest(event)
        }
        source.onReset = { [pump] in pump.reset() }
        source.onDeviceChange = { [weak self] info in self?.deviceChanged(info) }
        pump.onGestures = { [weak self] gestures in
            Task { @MainActor in self?.handle(gestures) }
        }
    }

    // MARK: - Ein und Aus

    /// Gleicht den Lauf mit den Schaltern ab. Aufgerufen beim App-Start und
    /// wenn sich ein Schalter ändert.
    func applyPreferences() {
        let prefs = preferences()
        let shouldRun = prefs.isControllerFeatureEnabled && prefs.isControllerEnabled
        if shouldRun, !status.isRunning {
            start()
        } else if !shouldRun, status.isRunning {
            stop()
        }
        if status.isRunning { applyBackgroundPreference() }
    }

    private func start() {
        status.isRunning = true
        counters.setAppActive(NSApp?.isActive ?? true)
        let center = NotificationCenter.default
        activeObservers = [
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [counters] _ in
                counters.setAppActive(true)
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self, counters] _ in
                counters.setAppActive(false)
                MainActor.assumeIsolated { self?.appResignedActive() }
            },
        ]
        source.start(queue: pump.queue)
        Logger.controller.info("controller_started")
        onStateChange?()
    }

    private func stop() {
        status.isRunning = false
        activeObservers.forEach(NotificationCenter.default.removeObserver)
        activeObservers = []
        source.stop()
        pump.reset()
        status.device = nil
        status.background = .off
        Logger.controller.info("controller_stopped")
        onStateChange?()
    }

    /// Hintergrund-Empfang erst nach dem ersten Verbinden setzen: Ältere
    /// Systeme vertrugen den Schalter vor dem ersten Controller nicht.
    private func applyBackgroundPreference() {
        guard status.device != nil else { return }
        guard preferences().isControllerBackgroundEnabled else {
            source.setBackgroundMonitoring(false)
            status.background = .off
            return
        }
        guard source.setBackgroundMonitoring(true) else {
            status.background = .unavailable
            return
        }
        status.background = counters.receivedInBackground ? .received : .waiting
    }

    private func deviceChanged(_ info: ControllerDeviceInfo?) {
        guard status.isRunning else { return }
        status.device = info
        defer { onStateChange?() }
        if info == nil {
            // Alles Gehaltene gilt als losgelassen; die Quelle hat die Pumpe
            // bereits zurückgesetzt.
            Logger.controller.info("controller_disconnected")
        } else {
            Logger.controller.info("controller_connected name=\(info?.name ?? "", privacy: .public) category=\(info?.category ?? "", privacy: .public)")
            applyBackgroundPreference()
        }
    }

    /// Ohne Hintergrund-Empfang sieht die App das Loslassen nicht mehr, wenn
    /// sie den Fokus verliert — dann jetzt alles lösen.
    private func appResignedActive() {
        guard status.isRunning, !preferences().isControllerBackgroundEnabled else { return }
        pump.reset()
    }

    // MARK: - Pause

    var isPaused: Bool { userPaused || systemPaused }

    /// Pause durch den Nutzer (Akkord L1 + R1, Menü).
    func togglePause() {
        userPaused.toggle()
        pauseChanged()
    }

    /// Pause durch das System (Bildschirmsperre, Ruhezustand, Spiel vorne).
    func setSystemPaused(_ paused: Bool) {
        guard systemPaused != paused else { return }
        systemPaused = paused
        if paused { pump.reset() }
        pauseChanged()
    }

    private func pauseChanged() {
        status.isPaused = isPaused
        onStateChange?()
        Logger.controller.info("controller_pause user=\(self.userPaused, privacy: .public) system=\(self.systemPaused, privacy: .public)")
    }

    // MARK: - Gesten

    private func handle(_ gestures: [ControllerGesture]) {
        // Nach dem Ausschalten können noch Gesten unterwegs sein.
        guard status.isRunning || isDebugRunActive else { return }
        for gesture in gestures {
            noteButton(of: gesture)
            let resolution = resolve(gesture)
            remember(resolution)
            onResolution?(resolution)
        }
        if status.background == .waiting, counters.receivedInBackground {
            status.background = .received
        }
    }

    /// Löst eine Geste im aktuellen Zustand auf und führt sie aus, sofern kein
    /// Trockenlauf läuft.
    private func resolve(_ gesture: ControllerGesture) -> ControllerResolution {
        var snapshot = performer?.snapshot() ?? ControllerAppSnapshot(window: .none)
        snapshot.isPaused = isPaused
        snapshot.backgroundEnabled = preferences().isControllerBackgroundEnabled
        let context = ControllerContextResolver.context(for: snapshot)
        let action = ControllerBindingResolver.action(for: gesture, in: context)
        guard let action, !isDryRun, let performer else {
            return ControllerResolution(gesture: gesture, context: context, action: action, executed: false)
        }
        if action == .pauseToggle {
            togglePause()
        } else {
            performer.perform(action, in: context)
        }
        return ControllerResolution(gesture: gesture, context: context, action: action, executed: true)
    }

    private func remember(_ resolution: ControllerResolution) {
        recentResolutions.append(resolution)
        if recentResolutions.count > 64 { recentResolutions.removeFirst(recentResolutions.count - 64) }
    }

    private func noteButton(of gesture: ControllerGesture) {
        let button: ControllerButton?
        switch gesture {
        case let .press(pressed): button = pressed
        case let .holdPending(pending, _): button = pending
        case let .move(direction, .dpad, false):
            switch direction {
            case .up: button = .dpadUp
            case .down: button = .dpadDown
            case .left: button = .dpadLeft
            case .right: button = .dpadRight
            }
        default: button = nil
        }
        guard let button else { return }
        status.lastButton = button
        status.lastButtonCount += 1
    }

    // MARK: - Rückmeldung am Gerät

    func setLight(_ color: ControllerLightColor?) {
        guard status.isRunning, !isPaused, preferences().isControllerLightEnabled else { return }
        source.setLight(color)
    }

    func play(_ pattern: ControllerHapticPattern) {
        guard status.isRunning, !isPaused, preferences().isControllerHapticsEnabled else { return }
        source.play(pattern)
    }

    // MARK: - Debug-Kanal

    /// Läuft gerade ein Lauf des Debug-Kanals? Läufe schließen sich aus,
    /// sonst stellte einer den Trockenlauf des anderen zurück.
    private(set) var isDebugRunActive = false

    /// Speist künstliche Roh-Ereignisse in dieselbe Kette wie echte Hardware.
    func inject(_ event: ControllerInputEvent) {
        pump.ingest(event)
    }

    /// Klammert einen Lauf des Debug-Kanals: setzt Trockenlauf und Angaben,
    /// führt die Schritte aus, löst danach alles Gehaltene, wartet, bis die
    /// Eingabe-Kette leer ist, und stellt erst dann zurück.
    /// - Returns: `false`, wenn schon ein Lauf aktiv ist.
    func runDebug(
        dryRun: Bool, override: ControllerDebugOverride, steps: () async -> Void
    ) async -> Bool {
        guard !isDebugRunActive else { return false }
        isDebugRunActive = true
        let previousDryRun = isDryRun
        isDryRun = dryRun
        debugOverride = override
        clearRecentResolutions()
        await steps()
        pump.reset()
        await drainInput()
        isDryRun = previousDryRun
        debugOverride = nil
        isDebugRunActive = false
        return true
    }

    /// Wartet, bis alles, was die Eingabe-Queue schon hat, auf dem Main Thread
    /// angekommen und aufgelöst ist.
    private func drainInput() async {
        let queue = pump.queue
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { continuation.resume() }
        }
        // Gesten springen per Task auf den Main Thread; einmal durchlassen.
        try? await Task.sleep(for: .milliseconds(150))
    }

    func clearRecentResolutions() {
        recentResolutions = []
    }
}

/// Angaben, die der Debug-Kanal dem Schnappschuss unterschiebt.
struct ControllerDebugOverride: Equatable {
    /// Fenster, das als aktives Agent-Chats-Fenster gelten soll.
    var windowID: UUID?
    /// Die App gilt als vorne, auch wenn sie es nicht ist.
    var assumeFrontmost = false
}
