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
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
    }
}
