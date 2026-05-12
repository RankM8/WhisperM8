import SwiftUI

enum RecordingPhase: Equatable {
    case idle
    case recording
    case transcribing
    case postProcessing

    static func resolve(
        isRecording: Bool,
        isTranscribing: Bool,
        isPostProcessing: Bool
    ) -> RecordingPhase {
        if isRecording { return .recording }
        if isPostProcessing { return .postProcessing }
        if isTranscribing { return .transcribing }
        return .idle
    }
}

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

    /// Aktuell ausgewählter Agent-Chat im Agent-Chats-Window. Wird von dort via
    /// `onChange/onAppear/onDisappear` gepflegt. `RecordingCoordinator` liest diesen
    /// Slot beim Start einer Aufnahme und propagiert ihn ins `contextBundle`,
    /// sodass der Recording-Overlay „Chat" als aktiven Kontext anzeigt.
    var activeAgentChat: AgentChatContextRef?

    @ObservationIgnored
    private var recordingCoordinator: RecordingCoordinator!

    var recordingPhase: RecordingPhase {
        RecordingPhase.resolve(
            isRecording: isRecording,
            isTranscribing: isTranscribing,
            isPostProcessing: isPostProcessing
        )
    }

    var menuBarIcon: String {
        switch recordingPhase {
        case .recording:
            return "mic.fill"
        case .postProcessing:
            return "sparkles"
        case .transcribing:
            return "ellipsis.circle"
        case .idle:
            return "mic"
        }
    }

    var statusText: String {
        switch recordingPhase {
        case .recording:
            return "Recording..."
        case .postProcessing:
            return postProcessingStatusText ?? "Improving..."
        case .transcribing:
            return "Transcribing..."
        case .idle:
            return "Ready"
        }
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

    func cancelPostProcessing() {
        recordingCoordinator.cancelPostProcessing()
    }

    func removeAgentChatFromContext() {
        recordingCoordinator.removeAgentChatFromContext()
    }

    func removeSelectedTextFromContext() {
        recordingCoordinator.removeSelectedTextFromContext()
    }

    func removeAttachmentFromContext(id: UUID) {
        recordingCoordinator.removeAttachmentFromContext(id: id)
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
