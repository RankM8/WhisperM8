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
            Text("Trockenlauf: \(gate.wouldPressCount)× würde drücken, \(gate.skippedCount)× übersprungen")
        } else {
            Text("Scharf: \(gate.pressCount)× umgeschaltet, \(gate.skippedCount)× übersprungen")
        }

        if let event = gate.lastEvent, let at = gate.lastEventAt {
            Text("Zuletzt \(Self.timeFormatter.string(from: at)): \(event)")
        }

        Menu("Codex-Mikrofon ist tatsächlich …") {
            Button("offen") { gate.correctAssumedState(to: .open) }
            Button("stumm") { gate.correctAssumedState(to: .muted) }
            Button("unbekannt") { gate.correctAssumedState(to: .unknown) }
        }

        Button("Zähler zurücksetzen") { gate.resetCounters() }
    }

    private var statusLine: String {
        let arm: String
        switch gate.armState {
        case .armed: arm = "scharf"
        case .codexNotRunning: arm = "Codex läuft nicht"
        case .noRecentSession: arm = "keine Sprachsitzung"
        case .pausedForDictation: arm = "pausiert (Diktat läuft)"
        }

        let assumed: String
        switch gate.assumedState {
        case .open: assumed = "Mikro offen"
        case .muted: assumed = "Mikro stumm"
        case .unknown: assumed = "Zustand unbekannt"
        }

        return "Voice Gate: \(arm) · \(assumed)"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
