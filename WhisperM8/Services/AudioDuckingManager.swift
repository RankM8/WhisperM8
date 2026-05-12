import AudioToolbox
import CoreAudio
import Foundation

/// Abstraktion ueber die rohe CoreAudio-API, damit der `AudioDuckingManager`
/// in Tests gegen einen Fake gefahren werden kann.
protocol AudioVolumeControlling {
    func defaultOutputDeviceID() throws -> AudioDeviceID
    func readVolume(deviceID: AudioDeviceID) throws -> Float
    func setVolume(_ volume: Float, deviceID: AudioDeviceID) throws
    func deviceName(deviceID: AudioDeviceID) -> String
    /// Installiert einen Listener, der gerufen wird wenn die System-Volume
    /// fuer `deviceID` sich aendert (egal aus welchem Grund). Liefert ein
    /// Token-Handle das beim Entfernen wieder verwendet werden muss.
    /// Returns `nil` wenn der Controller keinen Listener unterstuetzt
    /// (z. B. im Test-Fake — Tests treiben Volume-Events direkt).
    func addVolumeChangeListener(
        deviceID: AudioDeviceID,
        onChange: @escaping () -> Void
    ) -> Any?
    func removeVolumeChangeListener(deviceID: AudioDeviceID, token: Any)
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

/// CoreAudio-Implementation. Nutzt fuer Volume-Read/Write die
/// `kAudioHardwareServiceDeviceProperty_VirtualMainVolume`-Property — das ist
/// formal in `AudioHardwareDeprecated.h` aber funktional die einzige Property
/// die Multi-Channel-Devices (HDMI, AirPods) korrekt als "System-Volume"
/// abstrahiert. Die per-Channel-Modernisierung (`kAudioDevicePropertyVolumeScalar`)
/// erfordert Channel-Enumeration und ist fuer unser Use-Case unnoetig.
///
/// Listener nutzt `AudioObjectAddPropertyListenerBlock` (block-based, modern API,
/// nicht deprecated) — wird gerufen wann immer die Volume sich aendert: User
/// dreht am Slider, eine andere App ruft setVolume, Bluetooth-Resync, etc.
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

    func addVolumeChangeListener(
        deviceID: AudioDeviceID,
        onChange: @escaping () -> Void
    ) -> Any? {
        var address = volumePropertyAddress
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            onChange()
        }
        // Main-Queue: passt zur @MainActor-Isolation des Managers; serielle
        // Verarbeitung verhindert Race-Conditions beim Lesen/Updaten.
        let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, DispatchQueue.main, block)
        guard status == noErr else {
            Logger.audio.error("[AudioDucking] Listener install failed status=\(status, privacy: .public)")
            return nil
        }
        return ListenerToken(deviceID: deviceID, block: block)
    }

    func removeVolumeChangeListener(deviceID: AudioDeviceID, token: Any) {
        guard let listenerToken = token as? ListenerToken else { return }
        var address = volumePropertyAddress
        _ = AudioObjectRemovePropertyListenerBlock(listenerToken.deviceID, &address, DispatchQueue.main, listenerToken.block)
    }

    private final class ListenerToken {
        let deviceID: AudioDeviceID
        let block: AudioObjectPropertyListenerBlock
        init(deviceID: AudioDeviceID, block: @escaping AudioObjectPropertyListenerBlock) {
            self.deviceID = deviceID
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
/// am Ende EINMAL wieder her — ohne Retry-Loop, ohne dem User in seine
/// manuellen Anpassungen reinzufunken.
///
/// **Kritisches Verhalten gegenueber User-Eingriffen:**
/// Wenn der User WAEHREND der Aufnahme die Lautstaerke selbst aendert (z. B.
/// im Menubar-Slider), markieren wir die Session als "user took over" und
/// fuehren beim Stop **keinen Restore** durch — der User hat das letzte Wort.
///
/// **Single-shot Restore:**
/// Beim Stop wird EINMAL `setVolume(originalVolume)` aufgerufen. Frueher gab's
/// einen 4.2-Sekunden-Retry-Loop, der gegen manuelle Volume-Aenderungen
/// kaempfte — die haben wir hier bewusst rausgeworfen.
@MainActor
final class AudioDuckingManager {
    static let shared = AudioDuckingManager()

    private struct DuckedDevice {
        let id: AudioDeviceID
        let name: String
        let originalVolume: Float
        let appliedTargetVolume: Float
        /// Wenn der User den Slider waehrend des Ducks bewegt, wird das
        /// hier `true` — und der Restore wird beim Stop UEBERSPRUNGEN.
        var userTookOver: Bool
        /// Token fuer den Property-Listener; muss beim Restore unbedingt
        /// wieder entfernt werden, sonst leaken wir Listener.
        var listenerToken: Any?
    }

    private let volumeController: AudioVolumeControlling
    private var duckedDevices: [AudioDeviceID: DuckedDevice] = [:]
    /// Flag waehrend unserer eigenen setVolume-Aufrufe — verhindert dass
    /// unser eigener Volume-Change-Listener uns selbst als "User-Eingriff"
    /// interpretiert.
    private var isApplyingOurOwnChange = false
    /// Toleranz fuer Volume-Vergleiche. CoreAudio quantisiert intern auf
    /// ~ 1/100 Schritten; 0.01 fasst das gut.
    private static let volumeTolerance: Float = 0.01

    init(volumeController: AudioVolumeControlling = CoreAudioVolumeController()) {
        self.volumeController = volumeController
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
        !duckedDevices.isEmpty
    }

    /// Reduce current default output volume while recording.
    func duck() {
        guard isEnabled else {
            Logger.audio.debug("[AudioDucking] Ducking disabled; skipping")
            return
        }

        do {
            try duckCurrentOutputDevice()
        } catch {
            Logger.audio.error("[AudioDucking] Duck failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Restore every output device touched during this recording session —
    /// single shot, no retries, no fighting with manual user adjustments.
    func restore() {
        guard !duckedDevices.isEmpty else {
            Logger.audio.debug("[AudioDucking] Not ducked; nothing to restore")
            return
        }

        let devicesToRestore = duckedDevices
        duckedDevices.removeAll()

        for device in devicesToRestore.values {
            // Listener IMMER entfernen, auch wenn wir nichts restoren — sonst
            // bleibt der Callback aktiv und ruft `handleExternalVolumeChange`
            // fuer eine nicht mehr existierende Session auf.
            if let token = device.listenerToken {
                volumeController.removeVolumeChangeListener(deviceID: device.id, token: token)
            }

            guard !device.userTookOver else {
                Logger.audio.debug("[AudioDucking] \(device.name, privacy: .public): user took over — keeping their volume, not restoring")
                continue
            }

            do {
                isApplyingOurOwnChange = true
                try volumeController.setVolume(device.originalVolume, deviceID: device.id)
                isApplyingOurOwnChange = false
                let actual = (try? volumeController.readVolume(deviceID: device.id)) ?? device.originalVolume
                Logger.audio.debug("[AudioDucking] Restored \(device.name, privacy: .public) to \(self.format(actual), privacy: .public)")
            } catch {
                isApplyingOurOwnChange = false
                Logger.audio.error("[AudioDucking] Restore failed for \(device.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Internals

    private func duckCurrentOutputDevice() throws {
        let deviceID = try volumeController.defaultOutputDeviceID()
        let deviceName = volumeController.deviceName(deviceID: deviceID)
        let currentVolume = try volumeController.readVolume(deviceID: deviceID)

        // Falls die Lautstaerke schon unter dem Target ist: gar nichts tun.
        // Wir wollen keinen ungewollten "Restore auf hoeher als jetzt" beim
        // Stop verursachen.
        guard currentVolume > targetVolume + Self.volumeTolerance else {
            if duckedDevices[deviceID] == nil {
                Logger.audio.debug("[AudioDucking] \(deviceName, privacy: .public) already at/below target: \(self.format(currentVolume), privacy: .public)")
            }
            return
        }

        // Re-Duck eines bereits geduckten Geraets: originalVolume MUSS aus
        // der bestehenden Session uebernommen werden, sonst speichern wir
        // unseren eigenen target-Wert als "Original" → permanentes Ducking.
        let existingOriginal = duckedDevices[deviceID]?.originalVolume
        let originalVolume = existingOriginal ?? currentVolume

        // Listener installieren BEVOR wir setzen, damit der erste Event
        // (unser eigener setVolume) korrekt durch isApplyingOurOwnChange
        // ausgefiltert wird. Wenn schon ein Listener existiert (re-duck),
        // wiederverwenden statt zwei zu installieren.
        let listenerToken: Any?
        if let existing = duckedDevices[deviceID]?.listenerToken {
            listenerToken = existing
        } else {
            listenerToken = volumeController.addVolumeChangeListener(deviceID: deviceID) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.handleExternalVolumeChange(deviceID: deviceID)
                }
            }
        }

        isApplyingOurOwnChange = true
        try volumeController.setVolume(targetVolume, deviceID: deviceID)
        isApplyingOurOwnChange = false

        let actualVolume = (try? volumeController.readVolume(deviceID: deviceID)) ?? targetVolume

        duckedDevices[deviceID] = DuckedDevice(
            id: deviceID,
            name: deviceName,
            originalVolume: originalVolume,
            appliedTargetVolume: actualVolume,
            userTookOver: false,
            listenerToken: listenerToken
        )

        Logger.audio.debug("[AudioDucking] Ducked \(deviceName, privacy: .public): \(self.format(currentVolume), privacy: .public) -> \(self.format(actualVolume), privacy: .public), will restore to \(self.format(originalVolume), privacy: .public)")
    }

    /// Wird vom Property-Listener gerufen, wenn die System-Volume sich
    /// aendert. Vergleichen mit unserem zuletzt gesetzten Target — wenn
    /// die Aenderung NICHT von uns kommt, hat der User (oder eine andere
    /// App) den Slider beruehrt → wir markieren `userTookOver` und werden
    /// am Ende NICHT restoren.
    private func handleExternalVolumeChange(deviceID: AudioDeviceID) {
        guard !isApplyingOurOwnChange else { return }
        guard var device = duckedDevices[deviceID] else { return }
        guard !device.userTookOver else { return }

        let newVolume = (try? volumeController.readVolume(deviceID: deviceID)) ?? device.appliedTargetVolume
        let drift = abs(newVolume - device.appliedTargetVolume)
        // Wenn die Aenderung innerhalb der Toleranz unseres Targets liegt,
        // ist das nur das Echo von CoreAudio-Quantisierung oder ein
        // doppelter Listener — kein User-Eingriff.
        guard drift > Self.volumeTolerance else { return }

        device.userTookOver = true
        duckedDevices[deviceID] = device
        Logger.audio.debug("[AudioDucking] \(device.name, privacy: .public): external volume change detected \(self.format(device.appliedTargetVolume), privacy: .public) -> \(self.format(newVolume), privacy: .public); restore disabled")
    }

    private func format(_ volume: Float) -> String {
        "\(Int(round(volume * 100)))%"
    }
}
