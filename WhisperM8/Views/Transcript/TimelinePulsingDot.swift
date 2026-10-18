import SwiftUI

/// Sanft pulsierender Status-Punkt (schlichter als der Sonar-Dot der
/// Sidebar — hier reicht ein Opacity-Puls, kein auslaufender Ring).
///
/// Stammt aus der abgelösten Timeline-Ansicht; genutzt vom Live-Hinweis der
/// Verlaufsansicht und von der Subagent-Detailansicht.
struct TimelinePulsingDot: View {
    let color: Color
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .opacity(pulsing ? 0.35 : 1.0)
            // Ruhig-Modus (Default, LR-AU-002): kein Dauer-Puls — der Punkt steht
            // in voller Deckkraft. Dauer-Puls nur mit `agentStatusPulseEnabled`.
            .animation(
                AgentStatusPulse.continuousEnabled
                    ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                    : nil,
                value: pulsing
            )
            .onAppear { if AgentStatusPulse.continuousEnabled { pulsing = true } }
    }
}
