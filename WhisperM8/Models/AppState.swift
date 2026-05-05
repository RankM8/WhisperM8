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

    @ObservationIgnored
    private var recordingCoordinator: RecordingCoordinator!

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

    var hasAccessibilityPermission: Bool {
        recordingCoordinator.hasAccessibilityPermission
    }

    func requestAccessibilityPermission() {
        recordingCoordinator.requestAccessibilityPermission()
    }
}
