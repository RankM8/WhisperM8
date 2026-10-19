import SwiftUI

/// Menüleisten-Abschnitt des Voice Gates. Im Trockenlauf die einzige
/// dauerhaft sichtbare Rückmeldung: Ist das Gate scharf, was wurde erkannt,
/// und wie oft hätte es gedrückt.
struct VoiceGateMenuSection: View {
    let gate: VoiceGateCoordinator

    var body: some View {
        Text(statusLine)

        if let error = gate.startupError {
            Text("⚠️ \(error)")
        }

        if AppPreferences.shared.isCodexVoiceGateDryRun {
            Text("Dry run: would press \(gate.wouldPressCount)×, skipped \(gate.skippedCount)×")
        } else {
            Text("Armed: toggled \(gate.pressCount)×, skipped \(gate.skippedCount)×")
        }

        if let event = gate.lastEvent, let at = gate.lastEventAt {
            Text("Last at \(Self.timeFormatter.string(from: at)): \(event)")
        }

        Menu("Codex microphone is actually …") {
            Button("open") { gate.correctAssumedState(to: .open) }
            Button("muted") { gate.correctAssumedState(to: .muted) }
            Button("unknown") { gate.correctAssumedState(to: .unknown) }
        }

        Button("Reset counters") { gate.resetCounters() }
    }

    private var statusLine: String {
        let arm: String
        switch gate.armState {
        case .armed: arm = String(localized: "armed")
        case .codexNotRunning: arm = String(localized: "Codex not running")
        case .noRecentSession: arm = String(localized: "no voice session")
        case .pausedForDictation: arm = String(localized: "paused (dictation running)")
        }

        let assumed: String
        switch gate.assumedState {
        case .open: assumed = String(localized: "mic open")
        case .muted: assumed = String(localized: "mic muted")
        case .unknown: assumed = String(localized: "state unknown")
        }

        return "Voice Gate: \(arm) · \(assumed)"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("jmmss")
        return formatter
    }()
}
