import SwiftUI
import AVFoundation
import Carbon.HIToolbox
import ApplicationServices

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
    private var escKeyMonitor: Any?

    var menuBarIcon: String {
        if isRecording { return "mic.fill" }
        if isTranscribing { return "ellipsis.circle" }
        return "mic"
    }

    var statusText: String {
        if isRecording { return "Recording..." }
        if isTranscribing { return "Transcribing..." }
        return "Ready"
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

            // Set up ESC key listener to cancel recording
            setupEscKeyMonitor()

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

        // Stop timer and remove ESC key monitor
        timer?.invalidate()
        timer = nil
        removeEscKeyMonitor()

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

            // Cleanup audio file
            try? FileManager.default.removeItem(at: audioURL)

            // Auto-paste if enabled (this will also hide the panel)
            if UserDefaults.standard.object(forKey: "autoPasteEnabled") == nil || UserDefaults.standard.bool(forKey: "autoPasteEnabled") {
                pasteToActiveApp()
            } else {
                overlayController?.hide()
                Logger.paste.info("Auto-paste disabled, text copied to clipboard only")
            }

        } catch {
            lastError = error.localizedDescription
            overlayController?.hide()
        }

        isTranscribing = false
        isProcessing = false
    }

    @MainActor
    func cancelRecording() {
        guard isRecording else { return }

        // Stop timer and remove ESC key monitor
        timer?.invalidate()
        timer = nil
        removeEscKeyMonitor()

        // Stop recording and get URL (but don't transcribe)
        let audioURL = audioRecorder?.stopRecording()

        // Delete audio file if it exists
        if let audioURL {
            try? FileManager.default.removeItem(at: audioURL)
        }

        // Reset state
        isRecording = false
        audioLevel = 0
        recordingStartTime = nil

        // Hide overlay
        overlayController?.hide()

        Logger.paste.info("Recording cancelled by user")
    }

    // MARK: - ESC Key Monitor

    private func setupEscKeyMonitor() {
        // Remove any existing monitor first
        removeEscKeyMonitor()

        escKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }

            // Check for ESC key (keyCode 53)
            if event.keyCode == 53 && self.isRecording {
                Task { @MainActor in
                    self.cancelRecording()
                }
                return nil  // Consume the event
            }
            return event
        }
    }

    private func removeEscKeyMonitor() {
        if let monitor = escKeyMonitor {
            NSEvent.removeMonitor(monitor)
            escKeyMonitor = nil
        }
    }

    // MARK: - Auto-Paste

    var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    private func pasteToActiveApp() {
        // 1. Check permission
        guard AXIsProcessTrusted() else {
            Logger.permission.error("Accessibility permission missing - cannot auto-paste")
            lastError = "Accessibility permission required for auto-paste"
            requestAccessibilityPermission()
            overlayController?.hide()
            return
        }

        // 2. Get previous app
        guard let targetApp = overlayController?.getPreviousApp() else {
            Logger.paste.error("No previous app captured")
            overlayController?.hide()
            return
        }

        Logger.paste.info("Starting paste to: \(targetApp.localizedName ?? "unknown", privacy: .public)")

        // 3. Hide panel FIRST
        overlayController?.hide()

        // 4. Activate target app after 50ms
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            Logger.focus.info("Activating target app...")
            targetApp.activate()

            // 5. Wait for activation, then paste
            self.waitForActivation(of: targetApp) {
                // 6. Post CGEvent after 100ms
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    Logger.paste.info("Posting Cmd+V CGEvent")
                    self.postPasteEvent()
                }
            }
        }
    }

    private func waitForActivation(of app: NSRunningApplication, timeout: TimeInterval = 1.0, completion: @escaping () -> Void) {
        let start = Date()
        func check() {
            if NSWorkspace.shared.frontmostApplication == app {
                Logger.focus.info("Target app is now active")
                completion()
            } else if Date().timeIntervalSince(start) < timeout {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { check() }
            } else {
                Logger.focus.warning("Timeout waiting for app activation, pasting anyway")
                completion()
            }
        }
        check()
    }

    private func postPasteEvent() {
        let source = CGEventSource(stateID: .hidSystemState)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_ANSI_V), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_ANSI_V), keyDown: false) else {
            Logger.paste.error("Failed to create CGEvents")
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        usleep(20_000)  // 20ms between down and up
        keyUp.post(tap: .cghidEventTap)

        Logger.paste.info("Paste event posted successfully")
    }
}
