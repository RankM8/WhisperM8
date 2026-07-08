import AVFoundation
import Combine
import CoreAudio

@Observable
class AudioRecorder {
    private var engine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var recordingURL: URL?
    private var converter: AVAudioConverter?
    private let resourceLock = NSLock()

    // For automatic device switching in System Default mode
    private var configurationObserver: NSObjectProtocol?
    private var isUsingSystemDefault: Bool = false
    private var isRestarting: Bool = false
    private var lastConfigChangeTime: Date = .distantPast
    private var buffersWritten: Int = 0

    // Target format: 16kHz Mono for optimal API compatibility
    private let targetFormat: AVAudioFormat = {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
    }()

    var audioLevel: Float = 0
    var isRecording = false

    func startRecording() async throws {
        Logger.debug("[AudioRecorder] ========== START RECORDING ==========")

        // Always cleanup first
        if engine != nil {
            Logger.debug("[AudioRecorder] Cleaning up previous engine")
            _ = stopRecording()
        }

        // Reset state
        audioLevel = 0
        recordingURL = nil
        resourceLock.withLock {
            audioFile = nil
            converter = nil
            buffersWritten = 0
        }
        isRestarting = false
        lastConfigChangeTime = .distantPast

        // Check permission
        Logger.debug("[AudioRecorder] Requesting microphone permission...")
        let permission = await AVCaptureDevice.requestAccess(for: .audio)
        Logger.debug("[AudioRecorder] Microphone permission: \(permission)")
        guard permission else {
            Logger.debug("[AudioRecorder] ERROR: Microphone permission denied!")
            throw RecordingError.microphonePermissionDenied
        }

        // Create fresh engine
        let engine = AVAudioEngine()
        Logger.debug("[AudioRecorder] Created new AVAudioEngine")

        // Check if using System Default or specific device
        let deviceManager = AudioDeviceManager.shared
        let deviceID = deviceManager.selectedDeviceID
        isUsingSystemDefault = (deviceID == nil)

        Logger.debug("[AudioRecorder] isUsingSystemDefault: \(isUsingSystemDefault)")
        Logger.debug("[AudioRecorder] selectedDeviceUID: \(deviceManager.selectedDeviceUID ?? "nil")")

        // Set specific input device if selected (NOT for System Default)
        if let deviceID = deviceID {
            Logger.debug("[AudioRecorder] Setting specific input device: \(deviceID)")
            let result = setInputDevice(deviceID, for: engine)
            Logger.debug("[AudioRecorder] setInputDevice result: \(result)")
        } else {
            Logger.debug("[AudioRecorder] Using System Default - not setting specific device")
            let currentDefault = deviceManager.getDefaultInputDeviceID()
            let currentDefaultName = deviceManager.availableDevices.first { $0.id == currentDefault }?.name ?? "Unknown"
            Logger.debug("[AudioRecorder] Current system default: \(currentDefault) (\(currentDefaultName))")
        }

        // Access inputNode AFTER setting device (this triggers device binding)
        Logger.debug("[AudioRecorder] Accessing inputNode (this binds the device)...")
        let inputNode = engine.inputNode

        // Get the actual device being used
        if let audioUnit = inputNode.audioUnit {
            let (currentDeviceID, status) = currentEngineDeviceID(audioUnit)
            if status == noErr {
                let deviceName = deviceManager.availableDevices.first { $0.id == currentDeviceID }?.name ?? "Unknown"
                Logger.debug("[AudioRecorder] Engine actually using device: \(currentDeviceID) (\(deviceName))")
            } else {
                Logger.debug("[AudioRecorder] Could not get current device from AudioUnit: \(status)")
            }
        }

        // Input format from device - MUST use inputFormat(forBus:) for correct hardware format.
        // Mit Retry + Validierung: CoreAudio liefert direkt nach dem Binden
        // (Bluetooth-Wechsel, Systemlast) zeitweise 0 Hz / 0 Kanäle — ein
        // installTap damit wirft eine unfangbare NSException → Prozess-Abort.
        // Gleiche Schutzlogik wie in handleConfigurationChange().
        var validFormat: AVAudioFormat?
        for attempt in 1...5 {
            let format = inputNode.inputFormat(forBus: 0)
            if AudioFormatDecision.isRecordable(format) {
                validFormat = format
                Logger.debug("[AudioRecorder] Input format (attempt \(attempt)): \(format.sampleRate)Hz, \(format.channelCount) channels")
                break
            }
            Logger.debug("[AudioRecorder] Input format invalid (attempt \(attempt)): \(format.sampleRate)Hz, \(format.channelCount)ch — retrying…")
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        guard let inputFormat = validFormat else {
            Logger.debug("[AudioRecorder] ERROR: No recordable input format after retries — aborting start")
            throw RecordingError.invalidFormat
        }

        // Create converter if needed
        if AudioFormatDecision.needsConversion(from: inputFormat, to: targetFormat) {
            Logger.debug("[AudioRecorder] Creating audio converter (input differs from target)")
            resourceLock.withLock {
                converter = AVAudioConverter(from: inputFormat, to: targetFormat)
            }
        } else {
            Logger.debug("[AudioRecorder] No converter needed - formats match")
        }

        // Temp file for M4A output
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        Logger.debug("[AudioRecorder] Recording to: \(url.path)")

        // Audio file settings for M4A (AAC)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32000
        ]

        let file = try AVAudioFile(forWriting: url, settings: settings)
        resourceLock.withLock {
            audioFile = file
        }
        recordingURL = url

        // Install tap for recording + level metering
        // Use larger buffer size (4096) for better Bluetooth compatibility
        Logger.debug("[AudioRecorder] Installing tap on inputNode...")
        installRecordingTap(on: inputNode, inputFormat: inputFormat, label: "TAP", logHundredthCallback: true)

        Logger.debug("[AudioRecorder] Starting engine...")
        do {
            try engine.start()
            Logger.debug("[AudioRecorder] Engine started successfully!")
        } catch {
            Logger.debug("[AudioRecorder] ERROR starting engine: \(error)")
            inputNode.removeTap(onBus: 0)
            resourceLock.withLock {
                audioFile = nil
                converter = nil
            }
            recordingURL = nil
            throw error
        }

        self.engine = engine
        isRecording = true

        // Setup observer for configuration changes (only for System Default mode)
        setupConfigurationObserver()

        Logger.debug("[AudioRecorder] Recording started successfully")
        Logger.debug("[AudioRecorder] =====================================")
    }

    func stopRecording() -> URL? {
        Logger.debug("[AudioRecorder] ========== STOP RECORDING ==========")
        guard isRecording else {
            Logger.debug("[AudioRecorder] Not recording, nothing to stop")
            return nil
        }

        // Remove configuration observer
        removeConfigurationObserver()

        // Remove tap first
        if let engine = engine {
            Logger.debug("[AudioRecorder] Removing tap and stopping engine")
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        resourceLock.withLock {
            converter = nil
            audioFile = nil
        }
        isRecording = false
        isRestarting = false
        isUsingSystemDefault = false
        audioLevel = 0

        // Save URL and reset
        let url = recordingURL
        recordingURL = nil

        Logger.debug("[AudioRecorder] Recording stopped, file: \(url?.path ?? "nil")")
        Logger.debug("[AudioRecorder] =====================================")
        return url
    }

    // MARK: - Configuration Change Handling

    private func setupConfigurationObserver() {
        // Only observe for System Default mode (Bluetooth devices trigger config changes)
        guard isUsingSystemDefault, let engine = engine else {
            Logger.debug("[AudioRecorder] Not setting up config observer (not System Default or no engine)")
            return
        }

        Logger.debug("[AudioRecorder] Setting up config observer for System Default mode")

        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            Logger.debug("[AudioRecorder] AVAudioEngineConfigurationChange received!")

            // Handle config change asynchronously
            Task { @MainActor in
                await self.handleConfigurationChange()
            }
        }
    }

    private func removeConfigurationObserver() {
        if let observer = configurationObserver {
            Logger.debug("[AudioRecorder] Removing configuration observer")
            NotificationCenter.default.removeObserver(observer)
            configurationObserver = nil
        }
    }

    @MainActor
    private func handleConfigurationChange() async {
        Logger.debug("[AudioRecorder] ========== CONFIG CHANGE ==========")
        guard isRecording, !isRestarting, let engine = engine else {
            Logger.debug("[AudioRecorder] Skip: isRecording=\(isRecording), isRestarting=\(isRestarting), engine=\(engine != nil)")
            return
        }

        isRestarting = true

        // Remove observer to prevent re-entry during handling
        removeConfigurationObserver()

        // 1. Stop engine and remove old tap (but DON'T destroy engine)
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        Logger.debug("[AudioRecorder] Tap removed, engine stopped")

        // 2. Wait for Bluetooth HFP profile switch to stabilize (300ms is sufficient)
        Logger.debug("[AudioRecorder] Waiting 300ms for HFP stabilization...")
        try? await Task.sleep(nanoseconds: 300_000_000)

        // 3. Query NEW format with retry logic (format may be temporarily invalid)
        let inputNode = engine.inputNode
        var newFormat: AVAudioFormat?
        let maxRetries = 5

        for attempt in 1...maxRetries {
            // CRITICAL: Use inputFormat(forBus:) NOT outputFormat(forBus:)
            let format = inputNode.inputFormat(forBus: 0)
            if AudioFormatDecision.isRecordable(format) {
                newFormat = format
                Logger.debug("[AudioRecorder] New format (attempt \(attempt)): \(format.sampleRate)Hz, \(format.channelCount)ch")
                break
            }
            Logger.debug("[AudioRecorder] Format invalid (attempt \(attempt)), retrying...")
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        guard let inputFormat = newFormat else {
            Logger.debug("[AudioRecorder] ERROR: Could not get valid format after \(maxRetries) retries")
            isRestarting = false
            isRecording = false
            audioLevel = 0
            return
        }

        // Log what device we're now using
        if let audioUnit = inputNode.audioUnit {
            let (currentDeviceID, status) = currentEngineDeviceID(audioUnit)
            if status == noErr {
                let deviceName = AudioDeviceManager.shared.availableDevices.first { $0.id == currentDeviceID }?.name ?? "Unknown"
                Logger.debug("[AudioRecorder] Engine using device: \(currentDeviceID) (\(deviceName))")
            }
        }

        // 4. Create converter for new format if needed
        if AudioFormatDecision.needsConversion(from: inputFormat, to: targetFormat) {
            Logger.debug("[AudioRecorder] Creating converter: \(inputFormat.sampleRate)Hz → 16kHz")
            let newConverter = AVAudioConverter(from: inputFormat, to: targetFormat)
            resourceLock.withLock {
                converter = newConverter
            }
            if newConverter == nil {
                Logger.debug("[AudioRecorder] ERROR: Failed to create converter!")
            }
        } else {
            resourceLock.withLock {
                converter = nil
            }
            Logger.debug("[AudioRecorder] No converter needed - format matches target")
        }

        // 5. Install tap with NEW format (use larger buffer for Bluetooth)
        Logger.debug("[AudioRecorder] Installing tap with new format...")
        let hasAudioFile = resourceLock.withLock { self.audioFile != nil }
        Logger.debug("[AudioRecorder] audioFile is \(hasAudioFile ? "valid" : "NIL")")

        installRecordingTap(on: inputNode, inputFormat: inputFormat, label: "NEW TAP", logHundredthCallback: false)

        // 6. Restart the engine
        Logger.debug("[AudioRecorder] Restarting engine...")
        do {
            engine.prepare()
            try engine.start()
            Logger.debug("[AudioRecorder] Engine restarted successfully!")

            // Re-setup observer after short delay to avoid immediate re-trigger
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            setupConfigurationObserver()
            Logger.debug("[AudioRecorder] Config observer re-installed")
        } catch {
            Logger.debug("[AudioRecorder] ERROR restarting engine: \(error)")
            isRecording = false
            audioLevel = 0
        }

        isRestarting = false
        Logger.debug("[AudioRecorder] ========== CONFIG CHANGE DONE ==========")
    }

    // MARK: - Audio Processing

    /// Installiert den Aufnahme-Tap auf `inputNode`: gedrosseltes Callback-Logging,
    /// Pegelmessung und Schreiben in die Datei. `label` unterscheidet die Log-Zeilen
    /// der beiden Aufrufer ("TAP" beim Erststart, "NEW TAP" beim Format-Reinstall).
    /// `logHundredthCallback` bewahrt das bisherige Verhalten: nur der Erststart
    /// loggt zusaetzlich den 100. Callback.
    private func installRecordingTap(
        on inputNode: AVAudioInputNode,
        inputFormat: AVAudioFormat,
        label: String,
        logHundredthCallback: Bool
    ) {
        // Defensiv: ein evtl. vorhandener Tap würde installTap ebenfalls mit
        // einer unfangbaren NSException quittieren; removeTap ohne Tap ist
        // ein No-op.
        inputNode.removeTap(onBus: 0)

        var tapCallCount = 0
        let capturedTargetFormat = self.targetFormat
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }

            tapCallCount += 1
            if tapCallCount == 1 {
                Logger.debug("[AudioRecorder] \(label): First callback received! frameLength=\(buffer.frameLength)")
            } else if tapCallCount == 10 {
                Logger.debug("[AudioRecorder] \(label): 10 callbacks received")
            } else if logHundredthCallback, tapCallCount == 100 {
                Logger.debug("[AudioRecorder] \(label): 100 callbacks received")
            }

            let level = self.calculateLevel(buffer: buffer)
            Task { @MainActor in
                self.audioLevel = level
            }

            self.writeBuffer(buffer, inputFormat: inputFormat, targetFormat: capturedTargetFormat)
        }
    }

    /// Fragt die DeviceID ab, die das AudioUnit aktuell als Input nutzt.
    /// Gemeinsamer CoreAudio-Boilerplate beider Aufrufer; das Logging und die
    /// Aufloesung des Geraetenamens bleiben bewusst beim jeweiligen Aufrufer.
    private func currentEngineDeviceID(_ audioUnit: AudioUnit) -> (deviceID: AudioDeviceID, status: OSStatus) {
        var currentDeviceID: AudioDeviceID = 0
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &currentDeviceID,
            &propertySize
        )
        return (currentDeviceID, status)
    }

    private func calculateLevel(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        return AudioLevelMeter.normalized(
            samples: UnsafeBufferPointer(start: channelData, count: frames)
        )
    }

    private func writeBuffer(_ buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat, targetFormat: AVAudioFormat) {
        resourceLock.withLock {
            writeBufferLocked(buffer, inputFormat: inputFormat, targetFormat: targetFormat)
        }
    }

    private func writeBufferLocked(_ buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat, targetFormat: AVAudioFormat) {
        guard let audioFile else {
            // Log only first time
            if buffersWritten == 0 {
                Logger.debug("[AudioRecorder] writeBuffer: No audioFile!")
            }
            return
        }

        do {
            if let converter = converter {
                // Need to convert
                let frameCapacity = AVAudioFrameCount(
                    Double(buffer.frameLength) * targetFormat.sampleRate / inputFormat.sampleRate
                )

                guard let convertedBuffer = AVAudioPCMBuffer(
                    pcmFormat: targetFormat,
                    frameCapacity: frameCapacity
                ) else {
                    if buffersWritten == 0 {
                        Logger.debug("[AudioRecorder] writeBuffer: Failed to create convertedBuffer")
                    }
                    return
                }

                var error: NSError?
                let status = converter.convert(to: convertedBuffer, error: &error) { inNumPackets, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }

                if status == .haveData {
                    try audioFile.write(from: convertedBuffer)
                    buffersWritten += 1
                    if buffersWritten == 1 {
                        Logger.debug("[AudioRecorder] First buffer written successfully!")
                    } else if buffersWritten % 100 == 0 {
                        Logger.debug("[AudioRecorder] Buffers written: \(buffersWritten)")
                    }
                } else {
                    if buffersWritten == 0 {
                        Logger.debug("[AudioRecorder] writeBuffer: Converter status = \(status.rawValue), error = \(error?.localizedDescription ?? "nil")")
                    }
                }
            } else {
                // No conversion needed
                try audioFile.write(from: buffer)
                buffersWritten += 1
                if buffersWritten == 1 {
                    Logger.debug("[AudioRecorder] First buffer written successfully (no conversion)!")
                }
            }
        } catch {
            if buffersWritten == 0 {
                Logger.debug("[AudioRecorder] writeBuffer ERROR: \(error.localizedDescription)")
            }
        }
    }

    @discardableResult
    private func setInputDevice(_ deviceID: AudioDeviceID, for engine: AVAudioEngine) -> OSStatus {
        // Access inputNode first to create the AudioUnit
        guard let audioUnit = engine.inputNode.audioUnit else {
            Logger.debug("[AudioRecorder] ERROR: No audioUnit on inputNode!")
            return -1
        }
        var deviceIDValue = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceIDValue,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        Logger.debug("[AudioRecorder] AudioUnitSetProperty status: \(status)")
        return status
    }
}

// MARK: - Recording Errors

enum RecordingError: LocalizedError {
    case microphonePermissionDenied
    case recordingFailed
    case invalidFormat

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission denied. Please allow access in System Settings."
        case .recordingFailed:
            return "Recording failed. Please try again."
        case .invalidFormat:
            return "Invalid audio format."
        }
    }
}
