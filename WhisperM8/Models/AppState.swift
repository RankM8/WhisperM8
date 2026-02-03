import SwiftUI
import AVFoundation

@Observable
class AppState {
    var isRecording = false
    var isTranscribing = false
    var audioLevel: Float = 0
    var recordingDuration: TimeInterval = 0
    var lastError: String?
    var lastTranscription: String?

    private var audioRecorder: AudioRecorder?
    private var overlayController: OverlayController?
    private var timer: Timer?

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

    init() {
        self.audioRecorder = AudioRecorder()
        self.overlayController = OverlayController()
    }

    @MainActor
    func startRecording() async {
        guard !isRecording && !isTranscribing else { return }

        do {
            try await audioRecorder?.startRecording()
            isRecording = true
            recordingDuration = 0
            lastError = nil

            overlayController?.show(appState: self)

            // Timer for duration
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.recordingDuration += 0.1
                    self.audioLevel = self.audioRecorder?.audioLevel ?? 0
                    self.overlayController?.update(appState: self)
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    @MainActor
    func stopRecording() async {
        guard isRecording else { return }

        timer?.invalidate()
        timer = nil

        guard let audioURL = audioRecorder?.stopRecording() else {
            isRecording = false
            overlayController?.hide()
            return
        }

        isRecording = false
        isTranscribing = true
        overlayController?.update(appState: self)

        do {
            // Get provider and API key from settings
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

            // Cleanup temp file
            try? FileManager.default.removeItem(at: audioURL)

        } catch {
            lastError = error.localizedDescription
        }

        isTranscribing = false
        overlayController?.hide()
    }
}
