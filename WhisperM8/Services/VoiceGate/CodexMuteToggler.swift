import AppKit
import Carbon.HIToolbox
import Foundation

// ==============================================================================
// Phase 2: der eigentliche Tastendruck.
//
// Codex' Kommando `realtimeVoice.toggleMicrophoneMute` hat `shortcutScope: app`
// — der Accelerator feuert NUR, wenn Codex das Key-Window hat. Im Spike am
// 26.07.2026 nachgewiesen: `CGEventPostToPid` ohne Aktivierung bleibt wirkungslos
// (null Log-Signaturen), mit Aktivierung greift es zuverlaessig. Der kurze
// Fokus-Roundtrip ist deshalb unvermeidbar und vom Nutzer abgenommen.
//
// Das Muster stammt aus dem `PasteService`, der seit langem genau so arbeitet.
// ==============================================================================

enum CodexMuteTogglerError: LocalizedError {
    case accessibilityPermissionMissing
    case codexNotRunning
    case activationFailed
    case eventCreationFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionMissing:
            return "Bedienungshilfen-Berechtigung fehlt — ohne sie kann WhisperM8 keine Tasten senden."
        case .codexNotRunning:
            return "Codex läuft nicht."
        case .activationFailed:
            return "Codex ließ sich nicht in den Vordergrund holen — Tastendruck unterblieben."
        case .eventCreationFailed:
            return "Tastendruck-Event konnte nicht erzeugt werden."
        }
    }
}

struct CodexMuteToggleResult {
    /// Vorherige App, zu der zurueckgekehrt wurde (nil = Codex war schon vorn).
    let restoredTo: String?
    /// Gesamtdauer des Roundtrips.
    let duration: TimeInterval
}

@MainActor
struct CodexMuteToggler {
    /// Tastenkombination, die in Codex auf „Toggle Voice Chat microphone" liegt.
    /// Muss mit der Belegung in Codex' Einstellungen uebereinstimmen.
    var keyCode: UInt16 = UInt16(kVK_ANSI_U)
    var modifiers: CGEventFlags = [.maskControl, .maskShift]

    /// Wie lange auf den Fokuswechsel gewartet wird.
    var activationTimeout: TimeInterval = 1.0
    /// Nachlauf, bis Chromium das Key-Window gesetzt hat.
    var settleDelay: TimeInterval = 0.35

    func toggle() async throws -> CodexMuteToggleResult {
        guard PermissionService.hasAccessibilityPermission else {
            PermissionService.requestAccessibilityPermission()
            throw CodexMuteTogglerError.accessibilityPermissionMissing
        }

        let codexApps = NSRunningApplication.runningApplications(
            withBundleIdentifier: CodexVoiceSessionProbe.codexBundleIdentifier
        )
        guard let codex = codexApps.first else {
            throw CodexMuteTogglerError.codexNotRunning
        }

        let started = Date()
        let previous = NSWorkspace.shared.frontmostApplication
        let needsRestore = previous?.bundleIdentifier != CodexVoiceSessionProbe.codexBundleIdentifier

        codex.activate()
        guard await waitForActivation(of: codex) else {
            throw CodexMuteTogglerError.activationFailed
        }
        // Chromium meldet die App als frontmost, bevor das KEY-WINDOW steht.
        // Gemessen am 27.07.2026: mit 0,08 s ging ein Druck durch und der
        // naechste unter identischen Bedingungen verpuffte; ein Handtest mit
        // 0,8 s war zuverlaessig. 0,35 s ist der Kompromiss — der Roundtrip
        // bleibt damit klar unter einer halben Sekunde.
        await sleep(seconds: settleDelay)

        guard postShortcut() else {
            if needsRestore { previous?.activate() }
            throw CodexMuteTogglerError.eventCreationFailed
        }

        await sleep(seconds: 0.08)

        var restoredTo: String?
        if needsRestore, let previous {
            previous.activate()
            restoredTo = previous.localizedName
        }

        return CodexMuteToggleResult(
            restoredTo: restoredTo,
            duration: Date().timeIntervalSince(started)
        )
    }

    // MARK: - Details

    private func waitForActivation(of app: NSRunningApplication) async -> Bool {
        let deadline = Date().addingTimeInterval(activationTimeout)
        while Date() < deadline {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
                return true
            }
            await sleep(seconds: 0.02)
        }
        return false
    }

    private func postShortcut() -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return false
        }
        keyDown.flags = modifiers
        keyUp.flags = modifiers

        keyDown.post(tap: .cghidEventTap)
        usleep(20_000)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private func sleep(seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}
