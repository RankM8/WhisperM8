import SwiftUI
import AVFoundation
import Carbon.HIToolbox
import ApplicationServices
import UserNotifications

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

            // Duck system audio immediately
            AudioDuckingManager.shared.duck()

            // Re-enforce duck multiple times to catch AirPods HFP switch
            Task { @MainActor in
                for delay in [0.3, 0.6, 1.0, 1.5] {
                    try? await Task.sleep(for: .seconds(delay))
                    guard self.isRecording else { break }
                    AudioDuckingManager.shared.duck()
                }
            }

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
        guard isRecording, !isTranscribing, !isProcessing else {
            Logger.debug("stopRecording guard failed: isRecording=\(isRecording), isTranscribing=\(isTranscribing), isProcessing=\(isProcessing)")
            return
        }

        // Minimum recording duration (300ms)
        if let startTime = recordingStartTime {
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed < 0.3 {
                Logger.debug(" Recording too short: \(elapsed)s")
                return
            }
        }

        isProcessing = true

        // Store duration BEFORE stopping timer (important!)
        let audioDuration = recordingDuration
        Logger.debug(" Stopping recording. Duration: \(String(format: "%.1f", audioDuration))s")

        // Stop timer and remove ESC key monitor
        timer?.invalidate()
        timer = nil
        removeEscKeyMonitor()

        // Stop recording
        let audioURL = audioRecorder?.stopRecording()
        isRecording = false
        audioLevel = 0
        recordingStartTime = nil

        // Restore system audio
        Logger.debug("[AppState] Calling AudioDuckingManager.restore()")
        AudioDuckingManager.shared.restore()

        guard let audioURL else {
            Logger.debug(" ERROR: No audio URL returned from recorder")
            overlayController?.hide()
            isProcessing = false
            showErrorAlert(title: "Recording Error", message: "No audio file was created.")
            return
        }

        Logger.debug(" Audio file: \(audioURL.path)")

        // Check file exists and get size
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: audioURL.path)
            let fileSize = attributes[.size] as? Int64 ?? 0
            let fileSizeMB = Double(fileSize) / (1024 * 1024)
            Logger.debug(" Audio file size: \(String(format: "%.2f", fileSizeMB)) MB")
        } catch {
            Logger.debug(" WARNING: Could not get file attributes: \(error)")
        }

        // Transcribe
        isTranscribing = true
        overlayController?.update(appState: self)

        do {
            // Migrate settings if needed (for old installations)
            TranscriptionSettings.migrateIfNeeded()

            let provider = TranscriptionSettings.loadProvider()
            let model = TranscriptionSettings.loadModel()
            Logger.debug("Using provider: \(provider.rawValue), model: \(model.rawValue)")

            guard let apiKey = KeychainManager.load(key: provider.keychainKey), !apiKey.isEmpty else {
                Logger.debug("ERROR: No API key found for \(provider.keychainKey)")
                throw TranscriptionError.missingAPIKey
            }
            Logger.debug(" API key loaded (length: \(apiKey.count))")

            let language = UserDefaults.standard.string(forKey: "language") ?? "de"
            Logger.debug(" Language: \(language)")

            let service = provider.createService(apiKey: apiKey, model: model)
            Logger.debug(" Starting transcription...")

            let text = try await service.transcribe(audioURL: audioURL, language: language.isEmpty ? nil : language, audioDuration: audioDuration)

            Logger.debug(" Transcription SUCCESS! Text length: \(text.count) characters")
            Logger.debug(" Text preview: \(String(text.prefix(100)))...")

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
                Logger.debug(" Auto-paste disabled, text copied to clipboard only")
            }

        } catch let urlError as URLError {
            // Handle URL/network errors specifically
            let errorMessage: String
            switch urlError.code {
            case .timedOut:
                errorMessage = "Request timed out. The server took too long to respond."
            case .notConnectedToInternet:
                errorMessage = "No internet connection."
            case .networkConnectionLost:
                errorMessage = "Network connection was lost."
            case .cannotConnectToHost:
                errorMessage = "Cannot connect to server."
            default:
                errorMessage = "Network error: \(urlError.localizedDescription)"
            }
            Logger.debug(" URL ERROR: \(urlError.code.rawValue) - \(errorMessage)")
            lastError = errorMessage
            overlayController?.hide()
            try? FileManager.default.removeItem(at: audioURL)
            showErrorAlert(title: "Transcription Failed", message: errorMessage)

        } catch let transcriptionError as TranscriptionError {
            // Handle our custom errors
            let errorMessage = transcriptionError.errorDescription ?? "Unknown error"
            Logger.debug(" TRANSCRIPTION ERROR: \(errorMessage)")
            lastError = errorMessage
            overlayController?.hide()
            try? FileManager.default.removeItem(at: audioURL)
            showErrorAlert(title: "Transcription Failed", message: errorMessage)

        } catch {
            // Handle any other errors
            let errorMessage = error.localizedDescription
            Logger.debug(" UNKNOWN ERROR: \(type(of: error)) - \(errorMessage)")
            lastError = errorMessage
            overlayController?.hide()
            try? FileManager.default.removeItem(at: audioURL)
            showErrorAlert(title: "Transcription Failed", message: errorMessage)
        }

        isTranscribing = false
        isProcessing = false
        Logger.debug(" stopRecording completed")
    }

    // MARK: - Error Alert

    private func showErrorAlert(title: String, message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
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

        // Restore system audio
        AudioDuckingManager.shared.restore()

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
