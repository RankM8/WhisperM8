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

    /// Stabile Geräte-UID (überlebt Trennen und Wiederverbinden, anders als
    /// die `AudioDeviceID`). Schlüssel des `AudioDuckingJournal`.
    func deviceUID(deviceID: AudioDeviceID) -> String?
    func deviceID(forUID uid: String) -> AudioDeviceID?
    func isBluetooth(deviceID: AudioDeviceID) -> Bool
    /// Bluetooth-Gerät im Headset-Profil (HFP), also mit aktivem Mikrofon.
    /// AirPods merken sich für Musik- und Headset-Profil je eine eigene
    /// Lautstärke; was wir im Musik-Profil setzen, kommt beim Rückwechsel wieder.
    func isInHeadsetMode(deviceID: AudioDeviceID) -> Bool
}

/// Neutrale Defaults für Fakes, die nur Lautstärke und Routing modellieren.
extension AudioVolumeControlling {
    func deviceUID(deviceID: AudioDeviceID) -> String? { nil }
    func deviceID(forUID uid: String) -> AudioDeviceID? { nil }
    func isBluetooth(deviceID: AudioDeviceID) -> Bool { false }
    func isInHeadsetMode(deviceID: AudioDeviceID) -> Bool { false }
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

    func deviceUID(deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { ptr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        let uid = cfUID as String
        return uid.isEmpty ? nil : uid
    }

    func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID = uid as CFString
        var deviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { qualifier in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                qualifier,
                &size,
                &deviceID
            )
        }
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    func isBluetooth(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport) == noErr else {
            return false
        }
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// Erkennung über die Abtastrate des Ausgangs: Musik-Profil 44,1/48 kHz,
    /// Headset-Profil 16/24 kHz (gemessen an AirPods Pro: 48 kHz → 24 kHz
    /// beim Mikrofon-Start, 25.10.2026).
    func isInHeadsetMode(deviceID: AudioDeviceID) -> Bool {
        guard isBluetooth(deviceID: deviceID) else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate) == noErr else {
            return false
        }
        return rate > 0 && rate < 32_000
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
