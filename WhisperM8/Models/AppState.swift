import SwiftUI

@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    var isRecording = false
    var isTranscribing = false
    var audioLevel: Float = 0
    var recordingDuration: TimeInterval = 0
    var lastError: String?
    var lastTranscription: String?
    var selectedOutputMode = OutputMode.defaultMode()
    var isPostProcessing = false
    var lastRawTranscription: String?
    var lastFinalTranscription: String?
    var lastOutputMode: OutputMode?
    var selectedContext = SelectedContext.empty
    var lastSelectedContext: SelectedContext?
    var contextBundle = TranscriptContextBundle.empty
    var lastContextBundle: TranscriptContextBundle?
    var isScreenClipRecording = false
    var lastTranscriptRunReport: TranscriptRunReport?
    var postProcessingStatusText: String?

    @ObservationIgnored
    private var recordingCoordinator: RecordingCoordinator!

    var menuBarIcon: String {
        if isRecording { return "mic.fill" }
        if isPostProcessing { return "sparkles" }
        if isTranscribing { return "ellipsis.circle" }
        return "mic"
    }

    var statusText: String {
        if isRecording { return "Recording..." }
        if isPostProcessing { return postProcessingStatusText ?? "Improving..." }
        if isTranscribing { return "Transcribing..." }
        return "Ready"
    }

    func setOutputMode(_ mode: OutputMode) {
        selectedOutputMode = mode
        AppPreferences.shared.lastSelectedOutputModeID = mode.id
    }

    private init() {
        self.recordingCoordinator = RecordingCoordinator(appState: self)
    }

    func startRecording() async {
        await recordingCoordinator.startRecording()
    }

    func stopRecording() async {
        await recordingCoordinator.stopRecording()
    }

    func cancelRecording() {
        recordingCoordinator.cancelRecording()
    }

    func addContextScreenshot() {
        recordingCoordinator.addContextScreenshot()
    }

    func toggleScreenClip() {
        recordingCoordinator.toggleScreenClip()
    }

    func clearContextBundle() {
        recordingCoordinator.clearContextBundle()
    }

    var hasAccessibilityPermission: Bool {
        recordingCoordinator.hasAccessibilityPermission
    }

    func requestAccessibilityPermission() {
        recordingCoordinator.requestAccessibilityPermission()
    }
}
