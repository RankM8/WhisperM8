import AVFoundation
import Combine

@Observable
class AudioRecorder {
    private var engine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var recordingURL: URL?
    private var converter: AVAudioConverter?

    var audioLevel: Float = 0
    var isRecording = false

    func startRecording() async throws {
        // Always cleanup first
        if engine != nil {
            _ = stopRecording()
        }

        // Reset state
        audioLevel = 0
        recordingURL = nil
        audioFile = nil
        converter = nil

        // Check permission
        let permission = await AVCaptureDevice.requestAccess(for: .audio)
        guard permission else {
            throw RecordingError.microphonePermissionDenied
        }

        // Create fresh engine
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // Input format from device
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Target format: 16kHz Mono for optimal API compatibility
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw RecordingError.invalidFormat
        }

        // Create converter if needed
        if inputFormat.sampleRate != 16000 || inputFormat.channelCount != 1 {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        }

        // Temp file for M4A output
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")

        // Audio file settings for M4A (AAC)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32000
        ]

        audioFile = try AVAudioFile(forWriting: url, settings: settings)
        recordingURL = url

        // Install tap for recording + level metering
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }

            // Calculate audio level
            let level = self.calculateLevel(buffer: buffer)
            Task { @MainActor in
                self.audioLevel = level
            }

            // Write to file (with conversion if needed)
            self.writeBuffer(buffer, inputFormat: inputFormat, targetFormat: targetFormat)
        }

        try engine.start()
        self.engine = engine
        isRecording = true
    }

    func stopRecording() -> URL? {
        guard isRecording else { return nil }

        // Remove tap first
        if let engine = engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        converter = nil
        isRecording = false
        audioLevel = 0

        // Close the audio file
        audioFile = nil

        // Save URL and reset
        let url = recordingURL
        recordingURL = nil

        return url
    }

    private func calculateLevel(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else { return 0 }
        let frames = buffer.frameLength

        var sum: Float = 0
        for i in 0..<Int(frames) {
            let sample = channelData[i]
            sum += sample * sample
        }

        // RMS calculation
        let rms = sqrt(sum / Float(frames))

        // Normalize to 0-1 range (adjust multiplier for sensitivity)
        return min(rms * 3.0, 1.0)
    }

    private func writeBuffer(_ buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat, targetFormat: AVAudioFormat) {
        guard let audioFile else { return }

        do {
            if let converter = converter {
                // Need to convert
                let frameCapacity = AVAudioFrameCount(
                    Double(buffer.frameLength) * targetFormat.sampleRate / inputFormat.sampleRate
                )

                guard let convertedBuffer = AVAudioPCMBuffer(
                    pcmFormat: targetFormat,
                    frameCapacity: frameCapacity
                ) else { return }

                var error: NSError?
                let status = converter.convert(to: convertedBuffer, error: &error) { inNumPackets, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }

                if status == .haveData {
                    try audioFile.write(from: convertedBuffer)
                }
            } else {
                // No conversion needed
                try audioFile.write(from: buffer)
            }
        } catch {
            // Silently ignore write errors
        }
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
