import AudioToolbox
import CoreAudio
import Foundation

/// Reduziert die System-Lautstaerke waehrend einer Aufnahme und stellt sie
/// am Ende deterministisch wieder her — auch bei AirPods und anderen
/// Bluetooth-Devices, die ihr eigenes Profil-Switching machen.
///
/// **Designprinzipien:**
///
/// 1. **Pre-Switch-Capture.** Die Original-Volume wird *vor* dem Start des
///    `AVAudioEngine` gelesen (also vor dem A2DP→HFP-Profile-Switch bei
///    Bluetooth-Devices). Der Coordinator MUSS `beginCapture()` aufrufen
///    bevor er den Recorder startet.
///
/// 2. **Multi-Device-Capture.** Jedes Device, das waehrend der Session jemals
///    Default-Output war, wird tracked und am Ende restored. Wenn macOS
///    waehrend der Aufnahme von AirPods-A2DP auf AirPods-HFP (eigene DeviceID
///    auf manchen Macs) wechselt, werden beide Devices gecaptured.
///
/// 3. **Routing-Listener statt Time-Reinforce.** Wir lauschen auf
///    `kAudioHardwarePropertyDefaultOutputDevice`-Aenderungen. Kein Polling,
///    keine Timer-basierten "Reinforce"-Calls.
///
/// 4. **2 s Settle-Window nach `endCapture()`.** Faengt verzoegerte
///    HFP→A2DP-Reverse-Switches ab. Bei Routing-Event innerhalb des Fensters
///    werden alle bekannten Devices nochmal auf Original gesetzt.
///
/// 5. **Keine User-Eingriff-Detection.** Wenn der User mitten in der Aufnahme
///    manuell die Volume aendert, wird sie am Ende trotzdem auf Original
///    zurueckgesetzt. Begruendung: auf macOS gibt es kein zuverlaessiges
///    Signal "User vs System hat Volume geaendert"; ein BT-Profile-Switch
///    erzeugt einen identischen Event. Das alte Design hat das versucht und
///    in der Praxis dauerhaft geduckte AirPods produziert — der seltene
///    "User wollte mitten im Aufnehmen lauter drehen"-Fall (User dreht halt
///    nochmal nach) ist deutlich weniger schmerzhaft als "Volume bleibt
///    leise bis manueller Systemeinstellungs-Eingriff".
@MainActor
final class AudioDuckingManager {
    static let shared = AudioDuckingManager()

    enum Phase: Equatable {
        case idle
        case capturing
        case restoring
    }

    private struct DeviceCapture {
        let deviceID: AudioDeviceID
        let name: String
        let originalVolume: Float
        var lastAppliedTarget: Float?
    }

    private let volumeController: AudioVolumeControlling
    private let settleWindowDuration: TimeInterval
    private let enforceInterval: TimeInterval
    private(set) var phase: Phase = .idle
    private var captures: [AudioDeviceID: DeviceCapture] = [:]
    private var routingListenerToken: Any?
    private var settleTask: Task<Void, Never>?
    private var enforceTask: Task<Void, Never>?

    /// Toleranz fuer Volume-Vergleiche. CoreAudio quantisiert intern auf
    /// ~ 1/100 Schritten; 0.01 fasst das gut.
    private static let volumeTolerance: Float = 0.01

    init(
        volumeController: AudioVolumeControlling = CoreAudioVolumeController(),
        settleWindowDuration: TimeInterval = 2.0,
        enforceInterval: TimeInterval = 0.2
    ) {
        self.volumeController = volumeController
        self.enforceInterval = enforceInterval
        self.settleWindowDuration = settleWindowDuration
    }

    /// Whether audio ducking is enabled (from UserDefaults).
    var isEnabled: Bool {
        AppPreferences.shared.isAudioDuckingEnabled
    }

    /// Target volume level during recording.
    var targetVolume: Float {
        min(max(Float(AppPreferences.shared.audioDuckingFactor), 0.01), 1)
    }

    var hasActiveDuckingSession: Bool {
        phase != .idle
    }

    /// Eintritt in die Capturing-Phase. MUSS vor `audioRecorder.startRecording()`
    /// aufgerufen werden — sonst capturen wir die Volume erst nach dem
    /// Bluetooth-Profile-Switch und merken uns einen falschen "Original"-Wert.
    func beginCapture() {
        Logger.audio.info("[AudioDucking] beginCapture entered: phase=\(String(describing: self.phase), privacy: .public) enabled=\(self.isEnabled, privacy: .public) target=\(self.format(self.targetVolume), privacy: .public)")
        guard isEnabled else {
            Logger.audio.info("[AudioDucking] Disabled; skipping beginCapture")
            return
        }

        switch phase {
        case .capturing:
            // Schon aktiv — KEIN teardown, sonst wuerde der frische captureAndDuck
            // die bereits geduckte Volume als neues "Original" einlesen → Permadown.
            Logger.audio.info("[AudioDucking] beginCapture during .capturing — no-op")
            return
        case .restoring:
            // Settle-Window einer vorherigen Session laeuft noch — sauber abbauen,
            // damit die naechste Session frische Originals captured.
            Logger.audio.info("[AudioDucking] beginCapture during .restoring — tearing down settle window")
            teardown()
        case .idle:
            break
        }

        phase = .capturing
        installRoutingListener()
        captureAndDuckCurrentDevice()
        startCapturingEnforceLoop()
    }

    /// Verlaesst die Capturing-Phase: setzt alle bekannten Devices auf ihre
    /// Original-Volumes und startet das 2-Sekunden-Settle-Window. Innerhalb
    /// des Fensters werden Routing-Events weiter abgehoert und triggern ein
    /// erneutes Restore (faengt HFP→A2DP-Reverse-Switches ab).
    func endCapture() {
        Logger.audio.info("[AudioDucking] endCapture entered: phase=\(String(describing: self.phase), privacy: .public) capturedDevices=\(self.captures.count, privacy: .public)")
        guard phase == .capturing else {
            Logger.audio.info("[AudioDucking] endCapture called in phase \(String(describing: self.phase), privacy: .public); ignoring")
            return
        }

        enforceTask?.cancel()
        enforceTask = nil
        phase = .restoring
        restoreAllDevices()
        startSettleWindow()
    }

    /// Sofortiger Abbau ohne Settle-Window — fuer App-Quit-Pfade.
    /// Setzt alle bekannten Devices einmal auf Original und raeumt komplett auf.
    func endCaptureImmediate() {
        guard phase != .idle else { return }
        restoreAllDevices()
        teardown()
    }

    // MARK: - Test introspection

    #if DEBUG
    var debug_capturedDeviceIDs: Set<AudioDeviceID> {
        Set(captures.keys)
    }

    func debug_originalVolume(for deviceID: AudioDeviceID) -> Float? {
        captures[deviceID]?.originalVolume
    }
    #endif

    // MARK: - Internals

    private func captureAndDuckCurrentDevice() {
        do {
            let deviceID = try volumeController.defaultOutputDeviceID()
            captureAndDuck(deviceID: deviceID)
        } catch {
            Logger.audio.error("[AudioDucking] Could not determine default output device: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func captureAndDuck(deviceID: AudioDeviceID) {
        // Wenn wir das Geraet schon in der Session beruehrt haben, nur ggf.
        // nachducken (Volume wurde extern erhoeht) — Original bleibt unveraendert.
        if let existing = captures[deviceID] {
            redockIfNeeded(deviceID: deviceID, name: existing.name)
            return
        }

        // Erstkontakt mit diesem Device: Volume lesen.
        let current: Float
        do {
            current = try volumeController.readVolume(deviceID: deviceID)
        } catch {
            // Geraet hat keine kontrollierbare Volume (HDMI, Aggregate, ...)
            // oder ist verschwunden. Wir tracken es nicht.
            Logger.audio.info("[AudioDucking] Skip capture for device \(deviceID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }

        let name = volumeController.deviceName(deviceID: deviceID)
        let target = targetVolume

        guard current > target + Self.volumeTolerance else {
            // Schon leise genug — nichts tun. Insbesondere KEIN Capture-Eintrag
            // erzeugen, sonst wuerde Restore spaeter eine eventuell vom User
            // erhoehte Volume wieder runterdruecken.
            Logger.audio.info("[AudioDucking] \(name, privacy: .public) already at/below target (\(self.format(current), privacy: .public)); skipping capture")
            return
        }

        do {
            try volumeController.setVolume(target, deviceID: deviceID)
        } catch {
            Logger.audio.error("[AudioDucking] Duck failed for \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }

        captures[deviceID] = DeviceCapture(
            deviceID: deviceID,
            name: name,
            originalVolume: current,
            lastAppliedTarget: target
        )
        Logger.audio.info("[AudioDucking] Captured+ducked \(name, privacy: .public): \(self.format(current), privacy: .public) → \(self.format(target), privacy: .public)")
    }

    private func redockIfNeeded(deviceID: AudioDeviceID, name: String) {
        let target = targetVolume
        let current: Float
        do {
            current = try volumeController.readVolume(deviceID: deviceID)
        } catch {
            return
        }
        guard current > target + Self.volumeTolerance else { return }

        do {
            try volumeController.setVolume(target, deviceID: deviceID)
            captures[deviceID]?.lastAppliedTarget = target
            // Periodischer Re-Duck nach BT-Profile-Switch — auf .info, weil das die
            // Stelle ist an der wir die System-Volume gegen den BT-Stack durchsetzen.
            // Wenn das auftaucht, hat der Enforce-Loop tatsaechlich was korrigiert.
            Logger.audio.info("[AudioDucking] Re-ducked \(name, privacy: .public): \(self.format(current), privacy: .public) → \(self.format(target), privacy: .public)")
        } catch {
            Logger.audio.error("[AudioDucking] Re-duck failed for \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func restoreAllDevices() {
        for capture in captures.values {
            let preRestore = (try? volumeController.readVolume(deviceID: capture.deviceID)) ?? capture.originalVolume
            // Wenn die Volume bereits beim Original ist, kein Re-Set noetig —
            // verhindert Log-Spam waehrend des Settle-Window-Enforce-Loops.
            guard abs(preRestore - capture.originalVolume) > Self.volumeTolerance else { continue }

            do {
                try volumeController.setVolume(capture.originalVolume, deviceID: capture.deviceID)
                Logger.audio.info("[AudioDucking] Restored \(capture.name, privacy: .public): \(self.format(preRestore), privacy: .public) → \(self.format(capture.originalVolume), privacy: .public)")
            } catch {
                Logger.audio.debug("[AudioDucking] Restore best-effort failed for \(capture.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func installRoutingListener() {
        guard routingListenerToken == nil else { return }
        routingListenerToken = volumeController.addDefaultOutputDeviceListener { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleRoutingChange()
            }
        }
    }

    private func handleRoutingChange() {
        switch phase {
        case .capturing:
            // Neues Default-Device → ggf. capturen und ducken.
            captureAndDuckCurrentDevice()
        case .restoring:
            // Verzoegerter Routing-Switch (z. B. HFP→A2DP-Reverse). Alle
            // bekannten Devices nochmal auf Original setzen — idempotent.
            restoreAllDevices()
        case .idle:
            // Spaeter Listener-Fire nach Teardown — sollte nicht passieren,
            // ist aber unschaedlich.
            break
        }
    }

    /// Periodisches Re-Ducken waehrend `.capturing`. Notwendig weil Bluetooth-
    /// Profile-Switches (A2DP↔HFP auf dem GLEICHEN Device) KEIN Default-Output-
    /// Routing-Event ausloesen — sie aendern aber die Volume-Property. Ohne
    /// diesen Loop springt die System-Volume nach unserem initialen Duck auf
    /// die BT-internen Mode-Defaults zurueck.
    private func startCapturingEnforceLoop() {
        enforceTask?.cancel()
        let interval = enforceInterval
        enforceTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                guard let self, self.phase == .capturing else { return }
                self.captureAndDuckCurrentDevice()  // idempotent: redockIfNeeded oder neuer Capture
            }
        }
    }

    /// Settle-Window mit periodischem Re-Restore — analoges Argument: ein
    /// HFP→A2DP-Reverse-Switch nach Recording-Stop kann die Volume aendern
    /// ohne dass die DeviceID switcht. Wir setzen daher waehrend des Windows
    /// alle `enforceInterval` Sekunden nochmal auf die Originale.
    private func startSettleWindow() {
        settleTask?.cancel()
        let duration = settleWindowDuration
        let interval = enforceInterval
        settleTask = Task { @MainActor [weak self] in
            let stepsRaw = duration / interval
            let steps = max(1, Int(stepsRaw.rounded(.up)))
            for _ in 0..<steps {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                guard let self, self.phase == .restoring else { return }
                self.restoreAllDevices()  // idempotent
            }
            self?.teardown()
        }
    }

    private func teardown() {
        if let token = routingListenerToken {
            volumeController.removeDefaultOutputDeviceListener(token: token)
            routingListenerToken = nil
        }
        enforceTask?.cancel()
        enforceTask = nil
        settleTask?.cancel()
        settleTask = nil
        captures.removeAll()
        phase = .idle
    }

    private func format(_ volume: Float) -> String {
        "\(Int(round(volume * 100)))%"
    }
}
