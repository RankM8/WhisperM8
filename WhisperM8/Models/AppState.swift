import SwiftUI
import AVFoundation
import Carbon.HIToolbox

@Observable
class AppState {
    // Singleton instance
    static let shared = AppState()

    var isRecording = false
    var isTranscribing = false
    var audioLevel: Float = 0
    var recordingDuration: TimeInterval = 0
    var lastError: String?
    var lastTranscription: String?

    private var audioRecorder: AudioRecorder?
    private var overlayController: OverlayController?
    private var timer: Timer?
    private var recordingStartTime: Date?
    private var isProcessing = false

    var menuBarIcon: String {
        if isRecording { return "mic.fill" }
        if isTranscribing { return "ellipsis.circle" }
        return "mic"
    }

    var statusText: String {
        if isRecording { return "Aufnahme läuft..." }
        if isTranscribing { return "Transkribiere..." }
        return "Bereit"
    }

    private init() {
        self.audioRecorder = AudioRecorder()
        self.overlayController = OverlayController()
    }

    @MainActor
    func startRecording() async {
        guard !isRecording && !isTranscribing && !isProcessing else { return }

        isProcessing = true

        // Cleanup before starting
        timer?.invalidate()
        timer = nil
        overlayController?.hide()

        do {
            try await audioRecorder?.startRecording()

            recordingStartTime = Date()
            isRecording = true
            recordingDuration = 0
            audioLevel = 0
            lastError = nil
            isProcessing = false

            overlayController?.show(appState: self)

            // Timer for duration
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    if let startTime = self.recordingStartTime {
                        self.recordingDuration = Date().timeIntervalSince(startTime)
                    } else {
                        self.recordingDuration = 0
                    }
                    self.audioLevel = self.audioRecorder?.audioLevel ?? 0
                    self.overlayController?.update(appState: self)
                }
            }
        } catch {
            lastError = error.localizedDescription
            isProcessing = false
        }
    }

    @MainActor
    func stopRecording() async {
        guard isRecording, !isTranscribing, !isProcessing else { return }

        // Minimum recording duration (300ms)
        if let startTime = recordingStartTime {
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed < 0.3 { return }
        }

        isProcessing = true

        // Stop timer
        timer?.invalidate()
        timer = nil

        // Stop recording
        let audioURL = audioRecorder?.stopRecording()
        isRecording = false
        audioLevel = 0
        recordingStartTime = nil

        guard let audioURL else {
            overlayController?.hide()
            isProcessing = false
            return
        }

        // Transcribe
        isTranscribing = true
        overlayController?.update(appState: self)

        do {
            let providerRawValue = UserDefaults.standard.string(forKey: "selectedProvider") ?? APIProvider.openai.rawValue
            let provider = APIProvider(rawValue: providerRawValue) ?? .openai

            guard let apiKey = KeychainManager.load(key: "\(provider.rawValue)_apikey"), !apiKey.isEmpty else {
                throw TranscriptionError.missingAPIKey
            }

            let language = UserDefaults.standard.string(forKey: "language") ?? "de"

            let service = provider.createService(apiKey: apiKey)
            let text = try await service.transcribe(audioURL: audioURL, language: language.isEmpty ? nil : language)

            // Copy to clipboard
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)

            lastTranscription = text

            // Auto-paste
            pasteToActiveApp()

            // Cleanup
            try? FileManager.default.removeItem(at: audioURL)

        } catch {
            lastError = error.localizedDescription
        }

        isTranscribing = false
        isProcessing = false
        overlayController?.hide()
    }

    // MARK: - Auto-Paste

    private func pasteToActiveApp() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let source = CGEventSource(stateID: .combinedSessionState)

            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_ANSI_V), keyDown: true)
            keyDown?.flags = .maskCommand
            keyDown?.post(tap: .cghidEventTap)

            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_ANSI_V), keyDown: false)
            keyUp?.flags = .maskCommand
            keyUp?.post(tap: .cghidEventTap)
        }
    }
}
