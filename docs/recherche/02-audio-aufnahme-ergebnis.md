# Recherche-Ergebnis: Audio-Aufnahme unter macOS

# Building WhisperM8: Complete macOS Audio Recording Guide

**AVAudioEngine is the recommended approach for WhisperM8**, providing real-time buffer access essential for speech-to-text applications. Record in **M4A format at 16kHz mono with 32kbps bitrate**—this matches Whisper's internal processing and achieves optimal file sizes while maintaining transcription accuracy. The combination allows over 100 minutes of recording within Whisper's 25MB limit.

---

## AVAudioEngine wins for speech-to-text applications

For a Whisper-powered app, the choice between `AVAudioRecorder` and `AVAudioEngine` comes down to one critical capability: **real-time buffer access**. AVAudioEngine provides direct access to audio samples as they're captured through its `installTap` mechanism, enabling streaming transcription and live audio analysis. AVAudioRecorder writes directly to file with no intermediate buffer access.

| Feature | AVAudioRecorder | AVAudioEngine |
|---------|-----------------|---------------|
| **Complexity** | Simple, few lines | Requires graph setup |
| **Real-time buffer access** | ❌ No | ✅ Yes (via `installTap`) |
| **Record to file** | ✅ Built-in | Requires manual file writing |
| **Metering** | ✅ Built-in | Calculate from buffers |
| **Best for** | Voice memos | Speech recognition |

AVAudioRecorder suits simple "record → save → transcribe later" workflows, but WhisperM8 benefits from AVAudioEngine's ability to process audio in real-time. You can feed buffers directly to local Whisper models like WhisperKit or whisper.cpp while simultaneously writing to disk.

**Important macOS distinction**: Unlike iOS, `AVAudioSession` is not available on native macOS apps. The system handles audio routing automatically—simply use AVAudioEngine directly without session configuration.

---

## Optimal audio settings for the Whisper API

Whisper internally resamples **all audio to 16kHz mono**. Recording at higher sample rates provides zero transcription benefit while inflating file sizes. OpenAI's API accepts `flac, mp3, mp4, mpeg, mpga, m4a, ogg, wav, webm` with a hard **25MB limit**.

### Recommended recording configuration

```swift
// Whisper-optimized AVAudioRecorder settings
let whisperSettings: [String: Any] = [
    AVFormatIDKey: kAudioFormatMPEG4AAC,        // M4A format - best compression
    AVSampleRateKey: 16000.0,                   // 16kHz - Whisper's native rate
    AVNumberOfChannelsKey: 1,                   // Mono - stereo doubles size with no benefit
    AVEncoderBitRateKey: 32000,                 // 32kbps - optimal for speech
    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
]
```

At these settings, you can record approximately **100+ minutes** before hitting the 25MB limit. Testing shows transcription accuracy remains consistent down to 32kbps—128kbps and higher is overkill for speech.

### Format comparison for Whisper

| Format | Size (1 min) | Best Use Case |
|--------|-------------|---------------|
| **M4A (AAC)** | ~240 KB | Primary recommendation—best compression |
| **MP3** | ~240 KB | Universal compatibility |
| **WAV** | ~1.9 MB | Only when compression artifacts matter |
| **FLAC** | ~600 KB | Archival with lossless quality |

For recordings exceeding 10 minutes, consider chunking with **5-second overlaps** at natural break points. Avoid segments under 1 second—they can cause Whisper to hallucinate phrases like "Don't forget to subscribe."

---

## Complete recording implementation with AVAudioEngine

```swift
import AVFoundation

class WhisperAudioRecorder {
    private let audioEngine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    
    /// Whisper-optimal format: 16kHz, mono, 16-bit PCM
    static let whisperFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16000.0,
        channels: 1,
        interleaved: true
    )!
    
    func startRecording(to url: URL, onBuffer: ((AVAudioPCMBuffer) -> Void)? = nil) throws {
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
        // Create file for recording
        audioFile = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16000.0,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false
            ]
        )
        
        // Install tap for real-time buffer access
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            // Write to file
            try? self?.audioFile?.write(from: buffer)
            
            // Optional: Feed to Whisper model for live transcription
            onBuffer?(buffer)
        }
        
        audioEngine.prepare()
        try audioEngine.start()
    }
    
    func stopRecording() -> URL? {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        let url = audioFile?.url
        audioFile = nil
        return url
    }
}
```

### Selecting specific microphones on macOS

AVAudioEngine defaults to the system's default input device. Selecting a specific microphone requires Core Audio APIs:

```swift
import CoreAudio

func listInputDevices() -> [(id: AudioDeviceID, name: String)] {
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    
    var dataSize: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), 
                                    &propertyAddress, 0, nil, &dataSize)
    
    let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                               &propertyAddress, 0, nil, &dataSize, &deviceIDs)
    
    return deviceIDs.compactMap { id -> (AudioDeviceID, String)? in
        // Filter for devices with input channels
        guard hasInputChannels(deviceID: id) else { return nil }
        return (id, getDeviceName(deviceID: id))
    }
}

func setInputDevice(_ deviceID: AudioDeviceID, for engine: AVAudioEngine) {
    guard let audioUnit = engine.inputNode.audioUnit else { return }
    var deviceIDValue = deviceID
    AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                         kAudioUnitScope_Global, 0, &deviceIDValue,
                         UInt32(MemoryLayout<AudioDeviceID>.size))
}
```

---

## Microphone permissions require both Info.plist and entitlements

macOS enforces strict privacy controls. Without proper configuration, your app will crash immediately when accessing the microphone.

### Required Info.plist entry

```xml
<key>NSMicrophoneUsageDescription</key>
<string>WhisperM8 needs microphone access to transcribe your speech to text.</string>
```

### Entitlements for sandboxed apps (Mac App Store)

```xml
<key>com.apple.security.app-sandbox</key>
<true/>
<key>com.apple.security.device.audio-input</key>
<true/>
```

For apps with both App Sandbox and Hardened Runtime enabled, you may need the additional `com.apple.security.device.microphone` entitlement.

### Complete permission handling implementation

```swift
import AVFoundation
import AppKit

class MicrophonePermissionManager {
    
    static func requestAccess() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
    
    static func showPermissionDeniedAlert() {
        let alert = NSAlert()
        alert.messageText = "Microphone Access Required"
        alert.informativeText = "WhisperM8 needs microphone access to transcribe speech. Please enable it in System Settings."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        
        if alert.runModal() == .alertFirstButtonReturn {
            openMicrophoneSettings()
        }
    }
    
    static func openMicrophoneSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
    }
}

// Usage in your app
Task {
    if await MicrophonePermissionManager.requestAccess() {
        try recorder.startRecording(to: outputURL)
    } else {
        MicrophonePermissionManager.showPermissionDeniedAlert()
    }
}
```

---

## Real-time audio level feedback for UI

Visual feedback during recording enhances user experience. Both AVAudioRecorder and AVAudioEngine support level metering, but through different mechanisms.

### AVAudioRecorder metering (simpler approach)

```swift
class RecorderLevelMonitor: ObservableObject {
    @Published var normalizedLevel: Float = 0.0
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    
    func startMonitoring(recorder: AVAudioRecorder) {
        self.recorder = recorder
        recorder.isMeteringEnabled = true
        
        // Poll at 20Hz for smooth visualization
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            recorder.updateMeters()
            let power = recorder.averagePower(forChannel: 0)  // -160 to 0 dB
            self?.normalizedLevel = self?.normalizeDecibels(power) ?? 0
        }
    }
    
    /// Convert dB (-60 to 0) to 0.0-1.0 scale for UI
    private func normalizeDecibels(_ dB: Float) -> Float {
        let minDb: Float = -60
        guard dB.isFinite else { return 0 }
        if dB < minDb { return 0 }
        if dB >= 0 { return 1 }
        return (dB - minDb) / (0 - minDb)
    }
}
```

### AVAudioEngine tap-based metering (for real-time processing)

```swift
class EngineLevelMonitor: ObservableObject {
    @Published var level: Float = 0.0
    private let audioEngine = AVAudioEngine()
    
    func startMonitoring() throws {
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            let rms = self?.calculateRMS(buffer: buffer) ?? 0
            let dB = 20 * log10(max(rms, Float.ulpOfOne))
            
            DispatchQueue.main.async {
                self?.level = self?.normalizeDecibels(dB) ?? 0
            }
        }
        
        try audioEngine.start()
    }
    
    private func calculateRMS(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let samples = Array(UnsafeBufferPointer(start: channelData[0], 
                                                 count: Int(buffer.frameLength)))
        return sqrt(samples.map { $0 * $0 }.reduce(0, +) / Float(buffer.frameLength))
    }
}
```

### SwiftUI level meter view

```swift
struct LevelMeterView: View {
    let level: Float  // 0.0 to 1.0
    
    var body: some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.green.opacity(0.3))
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.green)
                        .frame(width: geo.size.width * CGFloat(level))
                        .animation(.linear(duration: 0.05), value: level)
                }
        }
        .frame(height: 8)
    }
}
```

**Threading warning**: Audio tap callbacks execute on background threads. Always dispatch UI updates to the main thread with `DispatchQueue.main.async`.

---

## Putting it all together: WhisperM8 architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Permission Check                                            │
│  AVCaptureDevice.authorizationStatus(for: .audio)           │
└─────────────────────┬───────────────────────────────────────┘
                      │ Authorized
                      ▼
┌─────────────────────────────────────────────────────────────┐
│  AVAudioEngine                                               │
│  ┌─────────────┐                                            │
│  │ InputNode   │──── installTap(bufferSize: 4096) ─────────┤
│  │ (Mic)       │                                            │
│  └─────────────┘                                            │
└─────────────────────┬───────────────────────────────────────┘
                      │ AVAudioPCMBuffer
          ┌───────────┴───────────┐
          ▼                       ▼
┌─────────────────┐    ┌─────────────────┐
│ Write to File   │    │ Level Metering  │
│ (16kHz mono M4A)│    │ (RMS → dB → UI) │
└────────┬────────┘    └─────────────────┘
         │
         ▼
┌─────────────────┐    ┌─────────────────┐
│ OpenAI Whisper  │    │ Local Whisper   │
│ API (25MB max)  │ OR │ (WhisperKit)    │
└─────────────────┘    └─────────────────┘
```

---

## Conclusion

WhisperM8 should use **AVAudioEngine** with taps on the input node, recording to **M4A at 16kHz mono with 32kbps bitrate**. This configuration provides real-time buffer access for live transcription while producing files well under Whisper's 25MB limit. Request microphone permissions using `AVCaptureDevice.requestAccess(for: .audio)` with proper Info.plist and entitlement configuration. For audio visualization, calculate RMS levels from buffers (AVAudioEngine) or use built-in metering (AVAudioRecorder), converting decibels to a 0-1 scale with a -60dB floor for responsive UI feedback.

The key insight is that Whisper's internal processing normalizes all audio to 16kHz mono anyway—recording at higher specifications wastes bandwidth and storage without improving transcription quality.

---

## Zusammenfassung

<!-- Nach der Recherche ausfüllen -->

## Empfohlener Ansatz

<!-- Nach der Recherche ausfüllen -->

## Audio-Format Empfehlung

<!-- Nach der Recherche ausfüllen -->

## Code-Beispiele

<!-- Nach der Recherche ausfüllen -->

## Permission Handling

<!-- Nach der Recherche ausfüllen -->
