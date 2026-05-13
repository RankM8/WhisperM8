import AudioToolbox
import CoreAudio
import Foundation

/// Abstraktion ueber die rohe CoreAudio-API, damit der `AudioDuckingManager`
/// in Tests gegen einen Fake gefahren werden kann.
///
/// **Hinweis zum Listener-Modell:** Wir tracken NUR den Wechsel des
/// Default-Output-Devices (`kAudioHardwarePropertyDefaultOutputDevice`).
/// Per-Device-Volume-Listener gibt es bewusst nicht mehr — die Heuristik
/// "User vs System hat Volume geaendert" ist auf macOS nicht zuverlaessig
/// (BT-Profile-Switches sehen identisch aus wie User-Slider-Bewegungen).
protocol AudioVolumeControlling {
    func defaultOutputDeviceID() throws -> AudioDeviceID
    func readVolume(deviceID: AudioDeviceID) throws -> Float
    func setVolume(_ volume: Float, deviceID: AudioDeviceID) throws
    func deviceName(deviceID: AudioDeviceID) -> String
    /// Installiert einen Listener auf den Default-Output-Wechsel des Systems.
    /// Wird gerufen wann immer macOS das aktive Wiedergabe-Geraet wechselt
    /// (BT-Connect/Disconnect, manueller Wechsel, BT-Profile-Switch wenn das
    /// HFP-Profil als eigene DeviceID erscheint).
    /// Returns `nil` wenn nicht unterstuetzt (Test-Fakes mit eigenem Trigger).
    func addDefaultOutputDeviceListener(
        onChange: @escaping () -> Void
    ) -> Any?
    func removeDefaultOutputDeviceListener(token: Any)
}

enum AudioVolumeError: LocalizedError, Equatable {
    case noDevice
    case unsupportedProperty(AudioDeviceID)
    case immutableProperty(AudioDeviceID)
    case operationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .noDevice:
            return "No default output device is available."
        case .unsupportedProperty(let deviceID):
            return "Output device \(deviceID) does not expose a controllable system volume."
        case .immutableProperty(let deviceID):
            return "Output device \(deviceID) does not allow changing system volume right now."
        case .operationFailed(let status):
            return "CoreAudio operation failed with status \(status)."
        }
    }
}

/// CoreAudio-Implementation.
///
/// Volume-Property: `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` —
/// formal in `AudioHardwareDeprecated.h` aber funktional die einzige Property
/// die Multi-Channel-Devices (HDMI, AirPods) sauber als "System-Volume"
/// abstrahiert. Per-Channel-Modernisierung (`kAudioDevicePropertyVolumeScalar`)
/// erfordert Channel-Enumeration und ist fuer unser Use-Case unnoetig.
///
/// Default-Output-Listener nutzt `AudioObjectAddPropertyListenerBlock` (block-
/// based, modern, nicht deprecated). Wird auf MainQueue zugestellt, damit die
/// `@MainActor`-Isolation des Managers eingehalten wird.
struct CoreAudioVolumeController: AudioVolumeControlling {
    func defaultOutputDeviceID() throws -> AudioDeviceID {
        var deviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(AudioObjectID(kAudioObjectSystemObject), &address) else {
            throw AudioVolumeError.noDevice
        }

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr else {
            throw AudioVolumeError.operationFailed(status)
        }
        guard deviceID != kAudioObjectUnknown else {
            throw AudioVolumeError.noDevice
        }

        return deviceID
    }

    func readVolume(deviceID: AudioDeviceID) throws -> Float {
        var size = UInt32(MemoryLayout<Float32>.size)
        var volume: Float32 = 0
        var address = volumePropertyAddress

        guard AudioObjectHasProperty(deviceID, &address) else {
            throw AudioVolumeError.unsupportedProperty(deviceID)
        }

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
        guard status == noErr else {
            throw AudioVolumeError.operationFailed(status)
        }

        return normalized(volume)
    }

    func setVolume(_ volume: Float, deviceID: AudioDeviceID) throws {
        var normalizedVolume = normalized(volume)
        var address = volumePropertyAddress

        guard AudioObjectHasProperty(deviceID, &address) else {
            throw AudioVolumeError.unsupportedProperty(deviceID)
        }

        var canSet = DarwinBoolean(false)
        let settableStatus = AudioObjectIsPropertySettable(deviceID, &address, &canSet)
        guard settableStatus == noErr else {
            throw AudioVolumeError.operationFailed(settableStatus)
        }
        guard canSet.boolValue else {
            throw AudioVolumeError.immutableProperty(deviceID)
        }

        let size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &normalizedVolume)
        guard status == noErr else {
            throw AudioVolumeError.operationFailed(status)
        }
    }

    func deviceName(deviceID: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfName: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &cfName) { ptr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        if status == noErr {
            return cfName as String
        }
        return "Device \(deviceID)"
    }

    func addDefaultOutputDeviceListener(
        onChange: @escaping () -> Void
    ) -> Any? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            onChange()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        guard status == noErr else {
            Logger.audio.error("[AudioDucking] Default-output listener install failed status=\(status, privacy: .public)")
            return nil
        }
        return ListenerToken(block: block)
    }

    func removeDefaultOutputDeviceListener(token: Any) {
        guard let listenerToken = token as? ListenerToken else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            listenerToken.block
        )
    }

    private final class ListenerToken {
        let block: AudioObjectPropertyListenerBlock
        init(block: @escaping AudioObjectPropertyListenerBlock) {
            self.block = block
        }
    }

    private var volumePropertyAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func normalized(_ volume: Float) -> Float {
        min(max(0, volume), 1)
    }
}

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
    private(set) var phase: Phase = .idle
    private var captures: [AudioDeviceID: DeviceCapture] = [:]
    private var routingListenerToken: Any?
    private var settleTask: Task<Void, Never>?

    /// Toleranz fuer Volume-Vergleiche. CoreAudio quantisiert intern auf
    /// ~ 1/100 Schritten; 0.01 fasst das gut.
    private static let volumeTolerance: Float = 0.01

    init(
        volumeController: AudioVolumeControlling = CoreAudioVolumeController(),
        settleWindowDuration: TimeInterval = 2.0
    ) {
        self.volumeController = volumeController
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
        guard isEnabled else {
            Logger.audio.debug("[AudioDucking] Disabled; skipping beginCapture")
            return
        }

        switch phase {
        case .capturing:
            // Schon aktiv — KEIN teardown, sonst wuerde der frische captureAndDuck
            // die bereits geduckte Volume als neues "Original" einlesen → Permadown.
            Logger.audio.debug("[AudioDucking] beginCapture during .capturing — no-op")
            return
        case .restoring:
            // Settle-Window einer vorherigen Session laeuft noch — sauber abbauen,
            // damit die naechste Session frische Originals captured.
            Logger.audio.debug("[AudioDucking] beginCapture during .restoring — tearing down settle window")
            teardown()
        case .idle:
            break
        }

        phase = .capturing
        installRoutingListener()
        captureAndDuckCurrentDevice()
    }

    /// Verlaesst die Capturing-Phase: setzt alle bekannten Devices auf ihre
    /// Original-Volumes und startet das 2-Sekunden-Settle-Window. Innerhalb
    /// des Fensters werden Routing-Events weiter abgehoert und triggern ein
    /// erneutes Restore (faengt HFP→A2DP-Reverse-Switches ab).
    func endCapture() {
        guard phase == .capturing else {
            Logger.audio.debug("[AudioDucking] endCapture called in phase \(String(describing: self.phase), privacy: .public); ignoring")
            return
        }

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
            Logger.audio.debug("[AudioDucking] Skip capture for device \(deviceID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }

        let name = volumeController.deviceName(deviceID: deviceID)
        let target = targetVolume

        guard current > target + Self.volumeTolerance else {
            // Schon leise genug — nichts tun. Insbesondere KEIN Capture-Eintrag
            // erzeugen, sonst wuerde Restore spaeter eine eventuell vom User
            // erhoehte Volume wieder runterdruecken.
            Logger.audio.debug("[AudioDucking] \(name, privacy: .public) already at/below target (\(self.format(current), privacy: .public)); skipping capture")
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
        Logger.audio.debug("[AudioDucking] Captured+ducked \(name, privacy: .public): \(self.format(current), privacy: .public) → \(self.format(target), privacy: .public)")
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
            Logger.audio.debug("[AudioDucking] Re-ducked \(name, privacy: .public): \(self.format(current), privacy: .public) → \(self.format(target), privacy: .public)")
        } catch {
            Logger.audio.error("[AudioDucking] Re-duck failed for \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func restoreAllDevices() {
        for capture in captures.values {
            do {
                try volumeController.setVolume(capture.originalVolume, deviceID: capture.deviceID)
                Logger.audio.debug("[AudioDucking] Restored \(capture.name, privacy: .public) to \(self.format(capture.originalVolume), privacy: .public)")
            } catch {
                // Device kann inzwischen weg sein — best effort.
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

    private func startSettleWindow() {
        settleTask?.cancel()
        let duration = settleWindowDuration
        settleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.teardown()
        }
    }

    private func teardown() {
        if let token = routingListenerToken {
            volumeController.removeDefaultOutputDeviceListener(token: token)
            routingListenerToken = nil
        }
        settleTask?.cancel()
        settleTask = nil
        captures.removeAll()
        phase = .idle
    }

    private func format(_ volume: Float) -> String {
        "\(Int(round(volume * 100)))%"
    }
}
