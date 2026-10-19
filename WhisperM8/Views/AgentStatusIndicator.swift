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
    /// Sanfter Puls über Core Animation (`SoftPulseRing`), Default an.
    static let softEnabled: Bool = AppPreferences().isAgentStatusSoftPulseEnabled

    /// Pur: bewegt sich der Halo dauerhaft?
    static func isContinuous(switchEnabled: Bool) -> Bool { switchEnabled }
}

/// Bedeutung der Status-Punkte für VoiceOver und für Nutzer ohne Farbwahrnehmung
/// (LR-AU-009): Label je Status plus eine Form, die ohne Farbe unterscheidbar
/// ist. Pur und unit-getestet; die Ansicht hängt nur noch dran.
enum AgentStatusAccessibility {
    /// Form des Kerns — working = Scheibe, awaiting = Raute, idle = kleine
    /// graue Scheibe, errored = Ring. Statisch, keine Dauerbewegung.
    enum Shape: Equatable { case disc, diamond, hollowRing, idleDisc, none }

    static func shape(for status: AgentSessionRuntimeStatus?) -> Shape {
        switch status {
        case .working: return .disc
        case .awaitingInput: return .diamond
        case .idle: return .idleDisc
        case .errored: return .hollowRing
        case .stopped, .none: return .none
        }
    }

    /// Kurzes VoiceOver-Label; `nil` = kein Status, nichts vorlesen.
    static func label(for status: AgentSessionRuntimeStatus?) -> String? {
        switch status {
        case .working: return String(localized: "Working")
        case .awaitingInput: return String(localized: "Waiting for you")
        case .idle: return String(localized: "Ready")
        case .errored: return String(localized: "Error")
        case .stopped, .none: return nil
        }
    }

    /// Tooltip (ausführlicher als das Label).
    static func help(for status: AgentSessionRuntimeStatus?) -> String? {
        switch status {
        case .working: return String(localized: "Working …")
        case .awaitingInput: return String(localized: "May be waiting for your input")
        case .idle: return String(localized: "Ready — waiting for a prompt")
        case .errored: return String(localized: "Ended with an error")
        case .stopped, .none: return nil
        }
    }
}

/// Zusammengefasstes VoiceOver-Element einer Sidebar-Zeile bzw. eines Tabs:
/// Titel, Status, Projekt (LR-AU-009).
enum AgentRowAccessibility {
    static func summary(title: String, status: AgentSessionRuntimeStatus?, project: String?) -> String {
        var parts = [title]
        if let label = AgentStatusAccessibility.label(for: status) { parts.append(label) }
        if let project, !project.isEmpty { parts.append(project) }
        return parts.joined(separator: ", ")
    }
}

struct AgentStatusIndicator: View {
    let status: AgentSessionRuntimeStatus?
    /// Tab-Leiste: dieselben Farben und Bedeutungen, aber 5 pt und ohne Puls —
    /// eine Reihe pulsierender Tabs wäre unruhig.
    var compact = false

    private var core: CGFloat { compact ? 5 : 7 }

    var body: some View {
        Group {
            if compact {
                compactBody
            } else {
                fullBody
            }
        }
        .modifier(StatusAccessibilityModifier(status: status))
    }

    @ViewBuilder
    private var compactBody: some View {
        switch status {
        case .working:
            Circle().fill(AgentTheme.statusWorking).frame(width: core, height: core)
        case .awaitingInput:
            StatusDiamond(color: AgentTheme.statusAwaiting, size: core)
        case .idle:
            Circle().fill(AgentTheme.textTertiary.opacity(0.55)).frame(width: core, height: core)
        case .errored:
            Circle().strokeBorder(AgentTheme.statusError, lineWidth: 1.2).frame(width: core, height: core)
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
        case .awaitingInput:
            PulsingDot(color: AgentTheme.statusAwaiting, maxScale: 2.2, duration: 1.5, filledRing: false,
                       diamondCore: true,
                       continuous: AgentStatusPulse.isContinuous(switchEnabled: AgentStatusPulse.continuousEnabled))
        case .idle:
            Circle()
                .fill(AgentTheme.textTertiary.opacity(0.55))
                .frame(width: core, height: core)
        case .errored:
            Circle()
                .strokeBorder(AgentTheme.statusError, lineWidth: 1.4)
                .frame(width: core, height: core)
        case .stopped, .none:
            Color.clear.frame(width: 1, height: 1)
        }
    }
}

/// Tooltip + VoiceOver-Label für den Status-Punkt. Ohne Status bleibt der
/// Punkt unsichtbar und stumm.
private struct StatusAccessibilityModifier: ViewModifier {
    let status: AgentSessionRuntimeStatus?

    func body(content: Content) -> some View {
        if let label = AgentStatusAccessibility.label(for: status) {
            content
                .help(AgentStatusAccessibility.help(for: status) ?? label)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
        } else {
            content.accessibilityHidden(true)
        }
    }
}

/// Raute als Form-Signal für „wartet auf dich" — statisch, gleiche optische
/// Größe wie die Scheibe.
private struct StatusDiamond: View {
    let color: Color
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.12)
            .fill(color)
            .frame(width: size * 0.8, height: size * 0.8)
            .rotationEffect(.degrees(45))
            .frame(width: size, height: size)
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
    /// Raute statt Scheibe als Kern (Form-Signal ohne Farbe, LR-AU-009).
    var diamondCore = false
    var continuous = false

    /// Ruhe-Größe/-Deckkraft des Halos im Ruhig-Modus: sichtbar größer als der
    /// Idle-Punkt, ohne Bewegung.
    private let restScale: CGFloat = 1.7
    private let restOpacity: Double = 0.35

    @State private var animate = false
    private let core: CGFloat = 7

    var body: some View {
        ZStack {
            if !continuous, AgentStatusPulse.softEnabled {
                // Sanfter Puls im Render-Server statt SwiftUI-Animation
                // (siehe `SoftPulseRing`) — gleiche Form wie der alte Puls.
                SoftPulseRing(
                    color: NSColor(color), maxScale: maxScale, duration: duration * 1.3,
                    filled: filledRing, startOpacity: filledRing ? 0.45 : 0.65)
                    .frame(width: core, height: core)
                    .allowsHitTesting(false)
            } else {
                ring
                    .frame(width: core, height: core)
                    .scaleEffect(ringScale)
                    .opacity(ringOpacity)
            }
            if diamondCore {
                StatusDiamond(color: color, size: core)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: core, height: core)
            }
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

/// Kompakte „vor X"-Formatierung für die Sidebar-Zeilen (zuletzt aktiv),
/// über `RelativeDateTimeFormatter` lokalisiert (de: „vor 5 Min.", en: „5 min. ago").
/// `now` und `locale` injizierbar für deterministische Tests.
enum SidebarRelativeTime {
    static func short(_ date: Date, now: Date = Date(), locale: Locale = .current) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .abbreviated
        // Unter einer Minute nur „jetzt" (named) — numerisch käme „vor 12 Sek.";
        // ab einer Minute numerisch, damit „vor 2 Mon." statt „letzter Monat" steht.
        if now.timeIntervalSince(date) < 60 {
            formatter.dateTimeStyle = .named
            return formatter.localizedString(for: now, relativeTo: now)
        }
        formatter.dateTimeStyle = .numeric
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
