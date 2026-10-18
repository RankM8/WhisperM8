import SwiftUI

/// Ausdrucksstarke Status-Indikatoren für die Sidebar-Chat-Zeilen.
/// Ersetzt die früher hartkodierten 5px-Punkte in `SessionListButton` und
/// `PinnedSessionRow` (eine Quelle statt zwei Duplikate):
/// - `working`       grüner Sonar-Puls (gefüllter Ring läuft nach außen + blendet aus)
/// - `awaitingInput` atmender Amber-Halo (Outline-Ring, auffälliger) — „wartet auf dich"
/// - `idle`          ruhiger GRAUER Punkt (Prozess lebt, wartet auf Prompt).
///   Bewusst nicht grün: Grün ist exklusiv für „arbeitet gerade" reserviert —
///   der frühere gedimmt-grüne Idle-Punkt war bei 7 px vom Working-Grün kaum
///   unterscheidbar und ließ ruhende Chats dauerhaft „laufend" wirken.
/// - `errored`       hohler roter Ring
/// - `stopped`/`nil` leer → die Row zeigt stattdessen die „zuletzt aktiv"-Zeit
///
/// Die Animation läuft rein render-seitig über eigenen `@State` und kollidiert
/// nicht mit dem Equatable-Skip der Row (Status kommt via onReceive+@State rein).
/// Ruhig-Modus (Default seit LR-AU-002): KEIN Endlos-Animation. Der Status bleibt
/// ohne Bewegung erkennbar — working = grüner Kern + gefüllter Halo, awaitingInput
/// = Amber-Kern + Ring (Form + Farbe, nicht nur Animation). Jeder Dauer-Puls hielt die Layout-Schleife
/// des ganzen Fensters am Laufen (WindowServer ~50 %). Die alte Dauerbewegung
/// gibt es nur mit `defaults write … agentStatusPulseEnabled -bool YES`.
/// Nur `working`/`awaitingInput` haben einen Halo — `idle`/`stopped` sind statisch.
enum AgentStatusPulse {
    /// Einmal pro Prozess gelesen (Schalter wirkt nach Neustart).
    static let continuousEnabled: Bool = AppPreferences().isAgentStatusPulseEnabled

    /// Pur: bewegt sich der Halo dauerhaft?
    static func isContinuous(switchEnabled: Bool) -> Bool { switchEnabled }
}

struct AgentStatusIndicator: View {
    let status: AgentSessionRuntimeStatus?
    /// Tab-Leiste: dieselben Farben und Bedeutungen, aber 5 pt und ohne Puls —
    /// eine Reihe pulsierender Tabs wäre unruhig.
    var compact = false

    private var core: CGFloat { compact ? 5 : 7 }

    var body: some View {
        if compact {
            compactBody
        } else {
            fullBody
        }
    }

    @ViewBuilder
    private var compactBody: some View {
        switch status {
        case .working:
            Circle().fill(AgentTheme.statusWorking).frame(width: core, height: core)
                .help("Arbeitet …")
        case .awaitingInput:
            Circle().fill(AgentTheme.statusAwaiting).frame(width: core, height: core)
                .help("Wartet möglicherweise auf User-Input")
        case .idle:
            Circle().fill(AgentTheme.textTertiary.opacity(0.55)).frame(width: core, height: core)
                .help("Bereit — wartet auf einen Prompt")
        case .errored:
            Circle().strokeBorder(AgentTheme.statusError, lineWidth: 1.2).frame(width: core, height: core)
                .help("Mit Fehler beendet")
        case .stopped, .none:
            Color.clear.frame(width: 1, height: 1)
        }
    }

    @ViewBuilder
    private var fullBody: some View {
        switch status {
        case .working:
            PulsingDot(color: AgentTheme.statusWorking, maxScale: 2.7, duration: 2.1, filledRing: true,
                       continuous: AgentStatusPulse.isContinuous(switchEnabled: AgentStatusPulse.continuousEnabled))
                .help("Arbeitet …")
        case .awaitingInput:
            PulsingDot(color: AgentTheme.statusAwaiting, maxScale: 2.2, duration: 1.5, filledRing: false,
                       continuous: AgentStatusPulse.isContinuous(switchEnabled: AgentStatusPulse.continuousEnabled))
                .help("Wartet möglicherweise auf User-Input")
        case .idle:
            Circle()
                .fill(AgentTheme.textTertiary.opacity(0.55))
                .frame(width: core, height: core)
                .help("Bereit — wartet auf einen Prompt")
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

/// Gefüllter Kern + Ring. `filledRing` = Sonar (gefüllt, working), sonst Halo
/// (Outline, awaiting). `continuous` = Dauer-Puls (nur per A/B-Schalter);
/// sonst steht der Ring ruhig (statischer Halo, keine Animation).
private struct PulsingDot: View {
    let color: Color
    let maxScale: CGFloat
    let duration: Double
    let filledRing: Bool
    var continuous = false

    /// Ruhe-Größe/-Deckkraft des Halos im Ruhig-Modus: sichtbar größer als der
    /// Idle-Punkt, ohne Bewegung.
    private let restScale: CGFloat = 1.7
    private let restOpacity: Double = 0.35

    @State private var animate = false
    private let core: CGFloat = 7

    var body: some View {
        ZStack {
            ring
                .frame(width: core, height: core)
                .scaleEffect(ringScale)
                .opacity(ringOpacity)
            Circle()
                .fill(color)
                .frame(width: core, height: core)
        }
        .frame(width: core, height: core)
        .onAppear {
            guard continuous else { return }
            // Aus dem Ruhezustand starten, dann unendlich nach außen pulsen.
            animate = false
            withAnimation(.easeOut(duration: duration).repeatForever(autoreverses: false)) {
                animate = true
            }
        }
    }

    private var ringScale: CGFloat {
        if continuous { return animate ? maxScale : 1 }
        return restScale
    }

    private var ringOpacity: Double {
        if continuous { return animate ? 0 : (filledRing ? 0.45 : 0.65) }
        return restOpacity
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
