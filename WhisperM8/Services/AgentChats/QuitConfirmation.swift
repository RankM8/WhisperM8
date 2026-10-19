import AppKit

/// Cmd+Q bei laufender Arbeit (Beschluss D4, LR-AU-006): Arbeiten oder warten
/// Chats, fragt die App nach — mit der Wahl, sie beim nächsten Start
/// fortzusetzen (derselbe Weg wie die Absturz-Wiederaufnahme). Ruhende Chats
/// beendet Cmd+Q still wie bisher.
enum QuitConfirmation {
    enum Choice: Equatable {
        case quitAndResume
        case quit
        case cancel
    }

    /// Laufende Chats, die gerade arbeiten oder auf eine Antwort warten.
    static func busySessionIDs(
        running: Set<UUID>,
        status: (UUID) -> AgentSessionRuntimeStatus?
    ) -> Set<UUID> {
        running.filter {
            let current = status($0)
            return current == .working || current == .awaitingInput
        }
    }

    /// Abmelden, Neustart, Ausschalten: kein Dialog (er hielte das System auf).
    static func isSystemQuit(_ reason: OSType?) -> Bool {
        guard let reason else { return false }
        return [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAERestart,
                kAEShowShutdownDialog, kAEShutDown].contains(reason)
    }

    @MainActor
    static func ask(busyCount: Int) -> Choice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = busyCount == 1
            ? String(localized: "A chat is still working")
            : String(localized: "\(busyCount) chats are still working")
        alert.informativeText = String(localized: "Quitting stops them mid-task. WhisperM8 can reopen them the next time it starts, so you can pick up where they stopped.")
        alert.addButton(withTitle: String(localized: "Quit and Reopen Later"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Quit Anyway"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .quitAndResume
        case .alertThirdButtonReturn: return .quit
        default: return .cancel
        }
    }
}
