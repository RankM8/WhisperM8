import AppKit

/// Einmaliger Hinweis beim Schließen eines Tabs mit laufendem Chat (LR-AU-024):
/// Tab zu heißt NICHT Chat beendet — der Prozess läuft weiter (Tokens, CPU,
/// Dateiänderungen). Beenden bleibt in der Sidebar (Beenden/Archivieren, dort
/// mit Bestätigung). Der Entscheider ist pur und über Closures testbar.
struct TabCloseNotice {
    var wasShown: () -> Bool
    var markShown: () -> Void

    /// `true`, wenn der Hinweis JETZT erscheinen soll (nur mit laufendem
    /// Prozess, nur beim ersten Mal); merkt sich das Erscheinen.
    func consume(processRunning: Bool) -> Bool {
        guard processRunning, !wasShown() else { return false }
        markShown()
        return true
    }

    static let standard = TabCloseNotice(
        wasShown: { AppPreferences.shared.tabCloseRunningNoticeShown },
        markShown: { AppPreferences.shared.tabCloseRunningNoticeShown = true }
    )

    @MainActor
    static func present() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(localized: "The chat is still running")
        alert.informativeText = String(localized: "Closing a tab does not stop the chat. It keeps working in the background. To stop it, use End or Archive in the sidebar.")
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }
}
