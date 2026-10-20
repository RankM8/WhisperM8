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
    var lastError: String? {
        didSet { if lastError != nil { errorRevision &+= 1 } }
    }
    /// Zähler für „neu entstandene“ Ergebnisse (Onboarding-Test, LR-ONB-013):
    /// steigen bei jedem gesetzten Fehler bzw. Diktatergebnis.
    private(set) var errorRevision = 0
    private(set) var transcriptionRevision = 0
    /// `true`, wenn eine gesicherte Aufnahme zum erneuten Transkribieren bereitliegt
    /// (Menüleisten-Eintrag). Gepflegt vom RecordingCoordinator.
    var hasPreservedRecording = false
    var lastTranscription: String? {
        didSet { if lastTranscription != nil { transcriptionRevision &+= 1 } }
    }
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

    /// `whisperm8 debug record`: echter Hotkey-Start ohne Kontext-Capture.
    func startRecordingForDebug() async -> RecordingCoordinator.StartReport? {
        await recordingCoordinator.startRecording(captureContext: false)
        return recordingCoordinator.lastStartReport
    }

    func cancelRecording() {
        recordingCoordinator.cancelRecording()
    }

    /// Menüleiste: neueste gesicherte Aufnahme erneut transkribieren.
    func retryLastPreservedRecording() async {
        await recordingCoordinator.retryLastPreservedRecording()
    }

    /// Synchrone Quit-Vorbereitung (laufende Aufnahme/Upload sichern).
    func prepareDictationForTermination() {
        recordingCoordinator.prepareForTermination()
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

    /// Stoppt alle laufenden Vordergrund-Agent-Chats auf einmal: terminiert
    /// jedes lebende PTY (graceful Ctrl+C → Kill) und markiert die zugehörigen
    /// Sessions als `.closed`, damit sie aus der "läuft"-Ansicht verschwinden,
    /// aber relaunchbar in der Sidebar bleiben. Background-Daemon-Jobs
    /// (`claude --bg`) haben kein PTY und werden bewusst nicht angefasst.
    /// Gibt die Anzahl gestoppter Sessions zurück.
    @discardableResult
    func stopAllForegroundSessions() -> Int {
        let stoppedIDs = AgentTerminalRegistry.shared.terminateAll()
        guard !stoppedIDs.isEmpty else { return 0 }
        let store = AgentSessionStore()
        for id in stoppedIDs {
            try? store.updateSession(id: id) { $0.status = .closed }
        }
        return stoppedIDs.count
    }

    var hasAccessibilityPermission: Bool {
        recordingCoordinator.hasAccessibilityPermission
    }

    func requestAccessibilityPermission() {
        recordingCoordinator.requestAccessibilityPermission()
    }
}
