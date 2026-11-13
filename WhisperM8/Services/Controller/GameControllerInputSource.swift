import CoreHaptics
import Foundation
import GameController

/// Live-Quelle: liest Gamepads über Apples GameController-Framework.
///
/// Es wird das allgemeine Profil (`GCExtendedGamepad`) verdrahtet; der
/// Touchpad-Klick kommt bei DualSense und DualShock dazu. Die PlayStation-
/// Taste und die Systemgesten auf Create bleiben unangetastet — die gehören
/// macOS (`preferredSystemGestureState` wird bewusst nicht verändert).
/// `GCKeyboard` und `GCMouse` fasst diese Klasse nicht an.
final class GameControllerInputSource: NSObject, ControllerInputSource, @unchecked Sendable {
    var onEvent: (@Sendable (ControllerInputEvent) -> Void)?
    var onReset: (@Sendable () -> Void)?
    var onDeviceChange: (@MainActor (ControllerDeviceInfo?) -> Void)?

    private var queue: DispatchQueue?
    private var observers: [NSObjectProtocol] = []
    /// Controller, von dem das letzte Ereignis kam. Nur auf `queue` gelesen
    /// und geschrieben.
    private var lastSource: ObjectIdentifier?
    /// Haptik-Engine je Controller. Nur auf dem Main Thread.
    private var hapticEngines: [ObjectIdentifier: CHHapticEngine] = [:]
    /// Alle Controller, an denen Handler hängen — auch solche, die
    /// `GCController.controllers()` nicht (mehr) nennt. Nur auf dem Main Thread.
    private var wiredControllers: [ObjectIdentifier: GCController] = [:]

    // MARK: - Start und Stopp

    func start(queue: DispatchQueue) {
        guard self.queue == nil else { return }
        self.queue = queue
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            guard let self, let controller = note.object as? GCController else { return }
            self.wire(controller)
            self.announceDevice()
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            if let controller = note.object as? GCController {
                self.hapticEngines[ObjectIdentifier(controller)] = nil
            }
            // Das Zurücksetzen muss auf die Handler-Queue, sonst überholt es
            // die letzten Ereignisse des getrennten Controllers.
            queue.async { [weak self] in
                self?.lastSource = nil
                self?.onReset?()
            }
            self.announceDevice()
        })
        observers.append(center.addObserver(forName: .GCControllerDidBecomeCurrent, object: nil, queue: .main) { [weak self] _ in
            self?.announceDevice()
        })
        GCController.controllers().forEach(wire)
        announceDevice()
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        for controller in GCController.controllers() {
            wiredControllers[ObjectIdentifier(controller)] = controller
        }
        wiredControllers.values.forEach(unwire)
        wiredControllers = [:]
        hapticEngines = [:]
        if let queue {
            queue.async { [weak self] in
                self?.lastSource = nil
                self?.onReset?()
            }
        }
        queue = nil
        GCController.shouldMonitorBackgroundEvents = false
    }

    @discardableResult
    func setBackgroundMonitoring(_ enabled: Bool) -> Bool {
        GCController.shouldMonitorBackgroundEvents = enabled
        // Zurücklesen: Unter macOS 15.4 fiel der Wert sofort wieder auf false.
        return GCController.shouldMonitorBackgroundEvents
    }

    // MARK: - Verdrahtung

    private func wire(_ controller: GCController) {
        guard let queue, let pad = controller.extendedGamepad else { return }
        // Erst die Queue, dann die Handler (Vorgabe des Frameworks).
        controller.handlerQueue = queue
        let id = ObjectIdentifier(controller)
        wiredControllers[id] = controller

        for (input, button) in Self.buttons(of: pad) {
            input.pressedChangedHandler = { [weak self] _, _, pressed in
                self?.deliver(.button(button, pressed: pressed), from: id)
            }
        }

        // Trigger als Analogwert: `isPressed` meldet schon bei 0,02 gedrückt,
        // ein aufliegender Finger würde auslösen. Die Schwelle setzt der Kern.
        pad.leftTrigger.valueChangedHandler = { [weak self] _, value, _ in
            self?.deliver(.trigger(.l2, value: value), from: id)
        }
        pad.rightTrigger.valueChangedHandler = { [weak self] _, value, _ in
            self?.deliver(.trigger(.r2, value: value), from: id)
        }
        pad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in
            self?.deliver(.stick(.left, x: x, y: y), from: id)
        }
        pad.rightThumbstick.valueChangedHandler = { [weak self] _, x, y in
            self?.deliver(.stick(.right, x: x, y: y), from: id)
        }
    }

    /// Alle Tasten, die `wire` belegt. Beim DualSense ist Create die
    /// „Options“-Taste des Frameworks und Options die „Menu“-Taste (gemessen
    /// 11.11.2026).
    private static func buttons(of pad: GCExtendedGamepad) -> [(GCControllerButtonInput, ControllerButton)] {
        var list: [(GCControllerButtonInput?, ControllerButton)] = [
            (pad.buttonA, .cross), (pad.buttonB, .circle), (pad.buttonX, .square), (pad.buttonY, .triangle),
            (pad.dpad.up, .dpadUp), (pad.dpad.down, .dpadDown), (pad.dpad.left, .dpadLeft), (pad.dpad.right, .dpadRight),
            (pad.leftShoulder, .l1), (pad.rightShoulder, .r1),
            (pad.leftThumbstickButton, .l3), (pad.rightThumbstickButton, .r3),
            (pad.buttonOptions, .create), (pad.buttonMenu, .options),
        ]
        if let dualSense = pad as? GCDualSenseGamepad {
            list.append((dualSense.touchpadButton, .touchpad))
        } else if let dualShock = pad as? GCDualShockGamepad {
            list.append((dualShock.touchpadButton, .touchpad))
        }
        return list.compactMap { input, button in input.map { ($0, button) } }
    }

    /// Baut jeden Handler ab, den `wire` gesetzt hat — auch Steuerkreuz,
    /// Trigger und Touchpad, die nicht alle in `allButtons` stehen. Sonst
    /// liefen nach dem Ausschalten weiter Ereignisse in die Pumpe.
    private func unwire(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }
        for (input, _) in Self.buttons(of: pad) {
            input.pressedChangedHandler = nil
            input.valueChangedHandler = nil
        }
        for input in pad.allButtons { input.pressedChangedHandler = nil; input.valueChangedHandler = nil }
        for trigger in [pad.leftTrigger, pad.rightTrigger] {
            trigger.pressedChangedHandler = nil
            trigger.valueChangedHandler = nil
        }
        pad.dpad.valueChangedHandler = nil
        pad.leftThumbstick.valueChangedHandler = nil
        pad.rightThumbstick.valueChangedHandler = nil
        pad.valueChangedHandler = nil
    }

    /// Auf `queue`. Wechselt die Quelle (zweiter Controller), gilt vorher alles
    /// Gehaltene als losgelassen.
    private func deliver(_ event: ControllerInputEvent, from id: ObjectIdentifier) {
        if lastSource != id {
            if lastSource != nil { onReset?() }
            lastSource = id
        }
        onEvent?(event)
    }

    // MARK: - Gerät

    private var preferredController: GCController? {
        GCController.current ?? GCController.controllers().first { $0.extendedGamepad != nil }
    }

    private func announceDevice() {
        let info = preferredController.map(Self.info)
        let handler = onDeviceChange
        Task { @MainActor in handler?(info) }
    }

    static func info(for controller: GCController) -> ControllerDeviceInfo {
        var battery: Float?
        if let reported = controller.battery, reported.batteryState != .unknown {
            battery = reported.batteryLevel
        }
        return ControllerDeviceInfo(
            name: controller.vendorName ?? controller.productCategory,
            category: controller.productCategory,
            batteryLevel: battery,
            hasLight: controller.light != nil,
            hasHaptics: controller.haptics != nil
        )
    }

    // MARK: - Lichtleiste und Haptik

    func setLight(_ color: ControllerLightColor?) {
        guard let color, let light = preferredController?.light else { return }
        light.color = GCColor(red: color.red, green: color.green, blue: color.blue)
    }

    func play(_ pattern: ControllerHapticPattern) {
        guard let controller = preferredController, let haptics = controller.haptics else { return }
        let id = ObjectIdentifier(controller)
        do {
            let engine = try hapticEngine(for: id, haptics: haptics)
            let player = try engine.makePlayer(with: CHHapticPattern(events: Self.events(for: pattern), parameters: []))
            // Asynchron starten: Das Hochfahren der Engine soll den Main
            // Thread nicht aufhalten.
            engine.start { [weak self] error in
                if let error {
                    DispatchQueue.main.async { self?.hapticEngines[id] = nil }
                    Logger.controller.info("controller_haptics_failed error=\(error.localizedDescription, privacy: .public)")
                    return
                }
                try? player.start(atTime: CHHapticTimeImmediate)
            }
        } catch {
            // Engine nach Ruhezustand oder Trennung oft unbrauchbar: verwerfen,
            // der nächste Impuls baut sie neu.
            hapticEngines[id] = nil
            Logger.controller.info("controller_haptics_failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func hapticEngine(for id: ObjectIdentifier, haptics: GCDeviceHaptics) throws -> CHHapticEngine {
        if let engine = hapticEngines[id] { return engine }
        guard let engine = haptics.createEngine(withLocality: .default) else {
            throw CHHapticError(.engineNotRunning)
        }
        // Stoppt von selbst, wenn nichts spielt — keine Dauerlast.
        engine.isAutoShutdownEnabled = true
        engine.stoppedHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.hapticEngines[id] = nil }
        }
        engine.resetHandler = { [weak self] in
            DispatchQueue.main.async { self?.hapticEngines[id] = nil }
        }
        hapticEngines[id] = engine
        return engine
    }

    /// Einfache, durchgehende Ereignisse: Kurze „Transient“-Impulse sind auf
    /// den Motoren eines Gamepads kaum zu spüren.
    static func events(for pattern: ControllerHapticPattern) -> [CHHapticEvent] {
        func pulse(at time: TimeInterval, duration: TimeInterval, intensity: Float) -> CHHapticEvent {
            CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5),
                ],
                relativeTime: time,
                duration: duration)
        }
        switch pattern {
        case .recordingStarted:
            return [pulse(at: 0, duration: 0.09, intensity: 0.9)]
        case .recordingStopped:
            return [pulse(at: 0, duration: 0.07, intensity: 0.45)]
        case .chatWaiting:
            return [pulse(at: 0, duration: 0.08, intensity: 0.8), pulse(at: 0.16, duration: 0.08, intensity: 0.8)]
        case .rejected:
            return [0, 0.07, 0.14].map { pulse(at: $0, duration: 0.03, intensity: 0.5) }
        case .inputCleared:
            return [pulse(at: 0, duration: 0.04, intensity: 0.6)]
        case .toggled:
            return [pulse(at: 0, duration: 0.035, intensity: 0.4)]
        }
    }
}
