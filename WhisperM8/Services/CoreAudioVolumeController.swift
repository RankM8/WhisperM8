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
