import AudioToolbox
import CoreAudio
import Foundation

protocol AudioVolumeControlling {
    func defaultOutputDeviceID() throws -> AudioDeviceID
    func readVolume(deviceID: AudioDeviceID) throws -> Float
    func setVolume(_ volume: Float, deviceID: AudioDeviceID) throws
    func deviceName(deviceID: AudioDeviceID) -> String
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
        "Device \(deviceID)"
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

/// Manages audio ducking (reducing system volume) during recording.
@MainActor
final class AudioDuckingManager {
    static let shared = AudioDuckingManager()

    private struct DuckedDevice {
        let id: AudioDeviceID
        let name: String
        let originalVolume: Float
        var targetVolume: Float
    }

    private let volumeController: AudioVolumeControlling
    private var duckedDevices: [AudioDeviceID: DuckedDevice] = [:]
    private var restoreTask: Task<Void, Never>?

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

        restoreTask?.cancel()
        restoreTask = nil

        do {
            try duckCurrentOutputDevice()
        } catch {
            Logger.audio.error("[AudioDucking] Duck failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Restore every output device touched during this recording session.
    func restore() {
        restoreTask?.cancel()

        guard !duckedDevices.isEmpty else {
            Logger.audio.debug("[AudioDucking] Not ducked; nothing to restore")
            return
        }

        let devicesToRestore = duckedDevices
        duckedDevices.removeAll()

        Logger.audio.debug("[AudioDucking] Restoring \(devicesToRestore.count) output device(s)")
        restoreDevices(devicesToRestore)

        restoreTask = Task { @MainActor in
            for delay in [0.3, 0.7, 1.2, 2.0] {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                restoreDevices(devicesToRestore, onlyIfStillBelowOriginal: true)
            }
        }
    }

    private func duckCurrentOutputDevice() throws {
        let deviceID = try volumeController.defaultOutputDeviceID()
        let deviceName = volumeController.deviceName(deviceID: deviceID)
        let currentVolume = try volumeController.readVolume(deviceID: deviceID)
        let target = min(targetVolume, currentVolume)

        guard currentVolume > targetVolume else {
            if duckedDevices[deviceID] == nil {
                Logger.audio.debug("[AudioDucking] \(deviceName, privacy: .public) already at or below target: \(self.format(currentVolume), privacy: .public)")
            }
            return
        }

        let originalVolume = duckedDevices[deviceID]?.originalVolume ?? currentVolume
        try volumeController.setVolume(targetVolume, deviceID: deviceID)
        let actualVolume = (try? volumeController.readVolume(deviceID: deviceID)) ?? targetVolume

        duckedDevices[deviceID] = DuckedDevice(
            id: deviceID,
            name: deviceName,
            originalVolume: originalVolume,
            targetVolume: target
        )

        Logger.audio.debug("[AudioDucking] Ducked \(deviceName, privacy: .public): \(self.format(currentVolume), privacy: .public) -> \(self.format(actualVolume), privacy: .public), original \(self.format(originalVolume), privacy: .public)")
    }

    private func restoreDevices(_ devices: [AudioDeviceID: DuckedDevice], onlyIfStillBelowOriginal: Bool = false) {
        for device in devices.values {
            do {
                let currentVolume = try volumeController.readVolume(deviceID: device.id)
                if onlyIfStillBelowOriginal, currentVolume >= device.originalVolume - 0.03 {
                    continue
                }

                try volumeController.setVolume(device.originalVolume, deviceID: device.id)
                let actualVolume = (try? volumeController.readVolume(deviceID: device.id)) ?? device.originalVolume

                Logger.audio.debug("[AudioDucking] Restored \(device.name, privacy: .public): \(self.format(currentVolume), privacy: .public) -> \(self.format(actualVolume), privacy: .public)")
            } catch {
                Logger.audio.error("[AudioDucking] Restore failed for \(device.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func format(_ volume: Float) -> String {
        "\(Int(round(volume * 100)))%"
    }
}
