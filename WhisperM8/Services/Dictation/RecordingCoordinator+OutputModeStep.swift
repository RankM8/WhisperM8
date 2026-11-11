import Foundation

extension RecordingCoordinator {
    /// Wechselt während der Aufnahme zum nächsten oder vorigen Ausgabemodus,
    /// mit Umlauf. Läuft über die Pill, damit sie den neuen Modus zeigt und
    /// derselbe Weg gilt wie beim Klick in ihr Menü. Der Wechsel gilt nur für
    /// diese Aufnahme: Beim nächsten Start steht wieder der Standardmodus.
    func stepOutputMode(_ step: Int) {
        guard let appState, appState.isRecording else { return }
        let modes = OutputMode.availableBuiltInModes()
        guard let targetID = OutputModeCycler.next(
            current: appState.selectedOutputMode.id, in: modes.map(\.id), step: step
        ), let mode = modes.first(where: { $0.id == targetID }),
            mode.id != appState.selectedOutputMode.id else { return }
        overlayController.setOutputMode(mode)
    }
}
