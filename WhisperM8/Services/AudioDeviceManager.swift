import Foundation
import CoreAudio

struct AudioDevice: Identifiable, Equatable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let isDefault: Bool

    static let systemDefault = AudioDevice(id: 0, uid: "", name: "System Default", isDefault: false)
}

// C-Style Callback für Default Device Changes (muss außerhalb der Klasse sein)
private func defaultInputDeviceChangedProc(
    inObjectID: AudioObjectID,
    inNumberAddresses: UInt32,
    inAddresses: UnsafePointer<AudioObjectPropertyAddress>,
    inClientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData = inClientData else { return noErr }

    let manager = Unmanaged<AudioDeviceManager>.fromOpaque(clientData).takeUnretainedValue()
    let newDefaultID = manager.getDefaultInputDeviceID()
    let newDefaultName = manager.getDeviceName(deviceID: newDefaultID)

    Logger.debug("[AudioDeviceManager] Default device change callback fired")
    Logger.debug("[AudioDeviceManager] New default: \(newDefaultID) (\(newDefaultName))")
    Logger.debug("[AudioDeviceManager] Previous default: \(manager.currentDefaultDeviceID)")

    if newDefaultID != manager.currentDefaultDeviceID && newDefaultID != 0 {
        DispatchQueue.main.async {
            Logger.debug("[AudioDeviceManager] Updating currentDefaultDeviceID and notifying listeners")
            manager.currentDefaultDeviceID = newDefaultID
            manager.refreshDevices()
            manager.onDefaultDeviceChanged?(newDefaultID)
        }
    } else {
        Logger.debug("[AudioDeviceManager] No change or invalid device, skipping notification")
    }

    return noErr
}

@Observable
class AudioDeviceManager {
    static let shared = AudioDeviceManager()

    private(set) var availableDevices: [AudioDevice] = []
    fileprivate(set) var currentDefaultDeviceID: AudioDeviceID = 0
    private var listenerBlock: AudioObjectPropertyListenerBlock?

    /// Callback when default input device changes (for System Default mode)
    var onDefaultDeviceChanged: ((AudioDeviceID) -> Void)?

    var selectedDeviceUID: String? {
        get { UserDefaults.standard.string(forKey: "selectedAudioDeviceUID") }
        set {
            let oldValue = UserDefaults.standard.string(forKey: "selectedAudioDeviceUID")
            Logger.debug("[AudioDeviceManager] selectedDeviceUID changing: '\(oldValue ?? "nil")' -> '\(newValue ?? "nil")'")
            if let value = newValue {
                UserDefaults.standard.set(value, forKey: "selectedAudioDeviceUID")
            } else {
                UserDefaults.standard.removeObject(forKey: "selectedAudioDeviceUID")
            }
        }
    }

    /// Returns the AudioDeviceID for the selected device, or nil for System Default
    /// NOTE: Returns nil for Bluetooth devices - they need macOS Aggregate Device to work properly
    var selectedDeviceID: AudioDeviceID? {
        guard let uid = selectedDeviceUID, !uid.isEmpty else {
            Logger.debug("[AudioDeviceManager] selectedDeviceID: nil (System Default)")
            return nil
        }
        let device = availableDevices.first { $0.uid == uid }

        // If device not found, fall back to System Default
        guard let device = device else {
            Logger.debug("[AudioDeviceManager] selectedDeviceID: nil - device with UID '\(uid)' NOT FOUND, using System Default")
            return nil
        }

        // Check if it's a Bluetooth device (UID contains MAC address pattern or is not built-in)
        // Bluetooth devices need macOS Aggregate Device to switch to HFP mode for microphone
        let isBluetoothDevice = uid.contains(":input") ||
                                uid.contains("-") && !uid.hasPrefix("BuiltIn") && !uid.hasPrefix("AppleHDA")

        if isBluetoothDevice {
            Logger.debug("[AudioDeviceManager] selectedDeviceID: nil - '\(device.name)' is Bluetooth device, using System Default for proper HFP mode")
            return nil
        }

        Logger.debug("[AudioDeviceManager] selectedDeviceID: \(device.id) for UID '\(uid)' -> '\(device.name)'")
        return device.id
    }

    /// Returns true if "System Default" is selected
    var isUsingSystemDefault: Bool {
        selectedDeviceUID == nil || selectedDeviceUID?.isEmpty == true
    }

    private init() {
        Logger.debug("[AudioDeviceManager] Initializing...")
        currentDefaultDeviceID = getDefaultInputDeviceID()
        Logger.debug("[AudioDeviceManager] Initial default device ID: \(currentDefaultDeviceID)")
        refreshDevices()
        startDeviceChangeListener()
        startDefaultDeviceListener()
        Logger.debug("[AudioDeviceManager] Initialization complete")
    }

    deinit {
        stopDeviceChangeListener()
        stopDefaultDeviceListener()
    }

    func refreshDevices() {
        Logger.debug("[AudioDeviceManager] refreshDevices() called")

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        )

        guard status == noErr else {
            Logger.debug("[AudioDeviceManager] Failed to get devices data size: \(status)")
            return
        }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )

        guard status == noErr else {
            Logger.debug("[AudioDeviceManager] Failed to get devices: \(status)")
            return
        }

        let defaultInputID = getDefaultInputDeviceID()
        Logger.debug("[AudioDeviceManager] Current system default input: \(defaultInputID)")

        let inputDevices = deviceIDs.compactMap { deviceID -> AudioDevice? in
            guard hasInputChannels(deviceID: deviceID) else { return nil }
            let name = getDeviceName(deviceID: deviceID)
            let uid = getDeviceUID(deviceID: deviceID)
            return AudioDevice(
                id: deviceID,
                uid: uid,
                name: name,
                isDefault: deviceID == defaultInputID
            )
        }

        Logger.debug("[AudioDeviceManager] Found \(inputDevices.count) input devices:")
        for device in inputDevices {
            Logger.debug("  - [\(device.id)] \(device.name) (UID: \(device.uid)) \(device.isDefault ? "[DEFAULT]" : "")")
        }

        Task { @MainActor in
            self.availableDevices = inputDevices
        }
    }

    func startDeviceChangeListener() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        listenerBlock = { [weak self] _, _ in
            Logger.debug("[AudioDeviceManager] Device list changed (hotplug)")
            self?.refreshDevices()
        }

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            DispatchQueue.main,
            listenerBlock!
        )
        Logger.debug("[AudioDeviceManager] Device change listener started")
    }

    private func stopDeviceChangeListener() {
        guard let block = listenerBlock else { return }

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            DispatchQueue.main,
            block
        )
    }

    // MARK: - Default Device Listener

    private func startDefaultDeviceListener() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            defaultInputDeviceChangedProc,
            Unmanaged.passUnretained(self).toOpaque()
        )

        if status != noErr {
            Logger.debug("[AudioDeviceManager] Failed to add default device listener: \(status)")
        } else {
            Logger.debug("[AudioDeviceManager] Default device listener started")
        }
    }

    private func stopDefaultDeviceListener() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectRemovePropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            defaultInputDeviceChangedProc,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    // MARK: - Helpers

    private func hasInputChannels(deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return false }

        let bufferListPointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(dataSize))
        defer { bufferListPointer.deallocate() }

        let result = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, bufferListPointer)
        guard result == noErr else { return false }

        let bufferList = bufferListPointer.pointee
        return bufferList.mNumberBuffers > 0
    }

    fileprivate func getDeviceName(deviceID: AudioDeviceID) -> String {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var name: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &name)
        guard status == noErr, let cfName = name?.takeUnretainedValue() else {
            return "Unknown Device"
        }

        return cfName as String
    }

    private func getDeviceUID(deviceID: AudioDeviceID) -> String {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var uid: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &uid)
        guard status == noErr, let cfUID = uid?.takeUnretainedValue() else {
            return ""
        }

        return cfUID as String
    }

    func getDefaultInputDeviceID() -> AudioDeviceID {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        return status == noErr ? deviceID : 0
    }
}
