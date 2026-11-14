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
        // WM8-75: zurückgehaltenes Enter nach einem Einfüge-Block sichtbar machen.
        // Nie während einer Aufnahme: Der Hinweis ersetzte sonst die Aufnahme-Pille.
        AgentTerminalController.onDelayedEnterWithheld = { [weak self] _ in
            guard let self, self.recordingPhase == .idle, !self.isStartingRecording else { return }
            self.recordingCoordinator.overlayController.showQuickActionHint(
                AgentTerminalController.delayedEnterWithheldHint, duration: 4)
        }
    }

    /// `target`: Ziel des Diktats; der Hotkey liefert wie bisher ins vordere Programm.
    func startRecording(target: DictationDeliveryTarget = .frontApp) async {
        await recordingCoordinator.startRecording(target: target)
    }

    /// `submit`: nach dem Schreiben in einen Chat auch senden.
    func stopRecording(submit: Bool = false) async {
        await recordingCoordinator.stopRecording(submit: submit)
    }

    /// `whisperm8 debug record`: echter Hotkey-Start ohne Kontext-Capture.
    func startRecordingForDebug() async -> RecordingCoordinator.StartReport? {
        await recordingCoordinator.startRecording(captureContext: false)
        return recordingCoordinator.lastStartReport
    }

    /// `whisperm8 debug pill`: die Pille ohne Aufnahme ein- und ausblenden.
    var overlayControllerForDebug: OverlayController { recordingCoordinator.overlayController }

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

    /// Bricht den laufenden Transkriptions-Upload ab; die Aufnahme wird gesichert.
    func cancelTranscription() {
        recordingCoordinator.cancelTranscription()
    }

    /// Markierten Text ohne Diktat mit einem Modus umarbeiten (Kurzbefehl,
    /// Menüleiste).
    func runQuickAction(modeID: String, input: QuickActionInput = .selection) async {
        // Kurzbefehl bei offenem Zwischenablage-Fenster: erst schließen, damit
        // die Markierung der App davor gemeint ist und der Cmd+C-Rückfall sie
        // erreicht (wie die Kopfzeile „Markierung korrigieren“).
        if input == .selection, ClipboardHistoryController.shared.isPanelVisible {
            ClipboardHistoryController.shared.hidePanel()
            try? await Task.sleep(for: .milliseconds(150))
        }
        await recordingCoordinator.quickActionRunner.run(modeID: modeID, input: input)
    }

    /// Ziel einer Aufnahme per Controller in der Pill anzeigen.
    func showControllerDictationTarget(_ label: String?) {
        recordingCoordinator.overlayController.controllerTargetLabel = label
    }

    /// Die Aufnahme startet noch (Mikrofon verbindet).
    var isStartingRecording: Bool { recordingCoordinator.isStartingRecording }

    /// Chat, in den die laufende Aufnahme geht; `nil` = vorderes Programm.
    var dictationTargetSessionID: UUID? {
        if case let .agentChat(sessionID) = recordingCoordinator.pendingDeliveryTarget { return sessionID }
        // Nach dem Stopp: das eingefrorene Ziel, solange transkribiert oder
        // nachbearbeitet wird (Review Runde 5, Befund 9).
        switch recordingPhase {
        case .transcribing, .postProcessing:
            if case let .agentChat(sessionID) = recordingCoordinator.inFlightDeliveryTarget { return sessionID }
            return nil
        default:
            return nil
        }
    }

    /// Läuft gerade eine Schnellaktion?
    var isQuickActionRunning: Bool { recordingCoordinator.quickActionRunner.isRunning }

    func cancelQuickAction() {
        recordingCoordinator.quickActionRunner.cancel()
    }

    /// Ausgabemodus der laufenden Aufnahme einen Schritt weiter oder zurück
    /// (Controller: Steuerkreuz links/rechts). Die Pill zeigt den neuen Modus.
    func stepOutputMode(_ step: Int) {
        recordingCoordinator.stepOutputMode(step)
    }

    /// Menüleiste: Schnellaktionen nur, wenn der Umfang Nacharbeit erlaubt.
    var usageProfileAllowsPostProcessing: Bool {
        AppPreferences.shared.usageProfile.wantsCodexEnrichment
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
