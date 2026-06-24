import SwiftUI

/// Ausdrucksstarke Status-Indikatoren für die Sidebar-Chat-Zeilen.
/// Ersetzt die früher hartkodierten 5px-Punkte in `SessionListButton` und
/// `PinnedSessionRow` (eine Quelle statt zwei Duplikate):
/// - `working`       grüner Sonar-Puls (gefüllter Ring läuft nach außen + blendet aus)
/// - `awaitingInput` atmender Amber-Halo (Outline-Ring, auffälliger) — „wartet auf dich"
/// - `idle`          ruhiger gedämpfter Punkt
/// - `errored`       hohler roter Ring
/// - `stopped`/`nil` leer → die Row zeigt stattdessen die „zuletzt aktiv"-Zeit
///
/// Die Animation läuft rein render-seitig über eigenen `@State` und kollidiert
/// nicht mit dem Equatable-Skip der Row (Status kommt via onReceive+@State rein).
/// Nur `working`/`awaitingInput` animieren — `idle`/`stopped` sind statisch,
/// damit viele ruhende Zeilen keine Dauerlast erzeugen.
struct AgentStatusIndicator: View {
    let status: AgentSessionRuntimeStatus?

    private let core: CGFloat = 7

    var body: some View {
        switch status {
        case .working:
            PulsingDot(color: AgentTheme.statusWorking, maxScale: 2.7, duration: 2.1, filledRing: true)
                .help("Arbeitet …")
        case .awaitingInput:
            PulsingDot(color: AgentTheme.statusAwaiting, maxScale: 2.2, duration: 1.5, filledRing: false)
                .help("Wartet möglicherweise auf User-Input")
        case .idle:
            Circle()
                .fill(AgentTheme.statusWorking.opacity(0.42))
                .frame(width: core, height: core)
                .help("Bereit")
        case .errored:
            Circle()
                .strokeBorder(AgentTheme.statusError, lineWidth: 1.4)
                .frame(width: core, height: core)
                .help("Mit Fehler beendet")
        case .stopped, .none:
            Color.clear.frame(width: 1, height: 1)
        }
    }
}

/// Gefüllter Kern + ein nach außen laufender Ring, der ausblendet.
/// `filledRing` = Sonar (gefüllt, working), sonst Halo (Outline, awaiting).
private struct PulsingDot: View {
    let color: Color
    let maxScale: CGFloat
    let duration: Double
    let filledRing: Bool

    @State private var animate = false
    private let core: CGFloat = 7

    var body: some View {
        ZStack {
            ring
                .frame(width: core, height: core)
                .scaleEffect(animate ? maxScale : 1)
                .opacity(animate ? 0 : (filledRing ? 0.45 : 0.65))
            Circle()
                .fill(color)
                .frame(width: core, height: core)
        }
        .frame(width: core, height: core)
        .onAppear {
            // Aus dem Ruhezustand starten, dann unendlich nach außen pulsen.
            animate = false
            withAnimation(.easeOut(duration: duration).repeatForever(autoreverses: false)) {
                animate = true
            }
        }
    }

    @ViewBuilder
    private var ring: some View {
        if filledRing {
            Circle().fill(color)
        } else {
            Circle().strokeBorder(color, lineWidth: 1.6)
        }
    }
}

/// Kompakte „vor X"-Formatierung für die Sidebar-Zeilen (zuletzt aktiv).
/// Bewusst knapp wie im Prototyp: „jetzt", „5m", „3h", „2d", „1w", „3mo".
/// `now` injizierbar für deterministische Tests.
enum SidebarRelativeTime {
    static func short(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "jetzt" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        let days = hours / 24
        if days < 7 { return "\(days)d" }
        let weeks = days / 7
        if weeks < 5 { return "\(weeks)w" }
        let months = days / 30
        return "\(months)mo"
    }
}
