import Foundation

// Zweite Raute der R1-Insel (Insel-Paket): links das Steuerkreuz mit
// Schaltern und Befehlen für die App, rechts wie bisher die Tasten für den
// Chat. Pur; die Werte kommen im Ereignis-Pfad vom Ausführer.

/// Ein Feld der App-Raute, in der Lage des Steuerkreuzes.
enum ControllerAppSlot: String, CaseIterable, Sendable {
    /// ▲ Limits aller Konten (Karte, solange R1 gehalten ist).
    case limits
    /// ◀ Mitteilungen eine Stufe weiter, wie die Glocke in der Seitenleiste.
    case alerts
    /// ▶ Wach bleiben eine Stufe weiter, wie der Wach-Knopf.
    case stayAwake
    /// ▼ Zwischenablage-Verlauf auf und zu.
    case clipboard

    init?(direction: ControllerDirection) {
        switch direction {
        case .up: self = .limits
        case .left: self = .alerts
        case .right: self = .stayAwake
        case .down: self = .clipboard
        }
    }

    var direction: ControllerDirection {
        switch self {
        case .limits: return .up
        case .alerts: return .left
        case .stayAwake: return .right
        case .clipboard: return .down
        }
    }

    /// Schalter lassen die Insel offen (mehrmals drücken bis zur gewünschten
    /// Stufe); Befehle schließen sie.
    var isToggle: Bool { self == .alerts || self == .stayAwake }
}

/// Stufe der Glocke (Spiegel von `AgentAlertLevel`, damit der Kern pur bleibt).
enum ControllerAlertStage: String, CaseIterable, Sendable {
    case all, soundOff, off
}

/// Stufe des Wach-Knopfs (Spiegel von `StayAwakeMode`).
enum ControllerAwakeStage: String, CaseIterable, Sendable {
    case off, whileWorking, always

    var next: ControllerAwakeStage {
        switch self {
        case .off: return .whileWorking
        case .whileWorking: return .always
        case .always: return .off
        }
    }
}

/// Stand der beiden Schalter, wie die Raute ihn unter dem Namen zeigt.
struct ControllerAppToggles: Equatable, Sendable {
    var alert: ControllerAlertStage = .all
    /// Was der nächste Druck bringt — „Ton aus“ fällt weg, wenn es nichts
    /// stumm zu schalten gibt (dieselbe Regel wie die Glocke).
    var nextAlert: ControllerAlertStage = .soundOff
    var awake: ControllerAwakeStage = .off
    /// Die nächste Stufe bräuchte die einmalige Admin-Freigabe, und die fehlt.
    var awakeNeedsPermission = false

    var nextAwake: ControllerAwakeStage { awake.next }
}

/// Ergebnis eines Drucks auf den Wach-Schalter.
enum ControllerStayAwakeResult: Equatable, Sendable {
    case changed(ControllerAwakeStage)
    /// Die nächste Stufe braucht die Admin-Freigabe: kein Dialog, die Insel
    /// sagt „Erst in der Seitenleiste freigeben“, der Controller vibriert.
    case needsPermission
    /// Der Freigabe-Dialog der Seitenleiste ist gerade offen.
    case busy
}

/// Bestätigungszeile unter den Rauten nach einem Schalter: was jetzt gilt und
/// was der nächste Druck bringt.
enum ControllerToggleConfirmation: Equatable, Sendable {
    case alert(ControllerAlertStage, next: ControllerAlertStage)
    case awake(ControllerAwakeStage, next: ControllerAwakeStage)
    case awakeNeedsPermission

    var slot: ControllerAppSlot {
        switch self {
        case .alert: return .alerts
        case .awake, .awakeNeedsPermission: return .stayAwake
        }
    }
}

/// Konto des Ziel-Chats im Kopf der R1-Insel: „main · 5 h 42 %“.
struct ControllerIslandAccountBadge: Equatable, Sendable {
    var name: String
    /// Verbraucht im 5-Stunden-Fenster (Prozent); `nil`: kein Stand.
    var fiveHourUsed: Double?
}

/// Konto, dessen Limits ein Chat belastet: GPT-Chats ihr GPT-Konto, sonst das
/// Claude-Konto. Codex und Shells haben keins.
struct ControllerUsageAccount: Equatable, Sendable {
    var kind: ControllerAccountChoice.Kind
    var name: String
}
