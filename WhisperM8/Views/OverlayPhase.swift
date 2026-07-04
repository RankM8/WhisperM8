import SwiftUI

// MARK: - Phasen-Layer der Recording-Pill

/// Reiner Zustands-Layer der Recording-Pill: genau eine Phase zur Zeit.
/// Bewegungsart des Kerns UND Statusfarbe hängen an der Phase (Ton „Farbig"):
/// Mint = Aufnahme (Bars atmen mit dem Audio-Level), Amber = Transkription
/// (Scan-Lauflicht), Violett = Codex-Improve (gemeinsamer Puls).
enum OverlayPhase: Equatable {
    case recording
    case transcribing
    case improving

    static func resolve(isTranscribing: Bool, isPostProcessing: Bool) -> OverlayPhase {
        if isPostProcessing { return .improving }
        if isTranscribing { return .transcribing }
        return .recording
    }

    /// `true` sobald die Aufnahme beendet ist und verarbeitet wird —
    /// Mode-/Kontext-Bedienung ist dann gesperrt (wie heute).
    var isBusy: Bool { self != .recording }

    /// Status-Text der Phase — seit dem Label-Rückbau NUR noch als Tooltip
    /// am Kern sichtbar (User-Feedback: abgeschnittene Labels + Breiten-Tanz
    /// beim Phasenwechsel stören; die Bewegungsart trägt den Zustand).
    func statusLabel(postProcessingStatusText: String?) -> String? {
        switch self {
        case .recording:
            return nil
        case .transcribing:
            return "Transcribing…"
        case .improving:
            return postProcessingStatusText ?? "Improving…"
        }
    }

    /// Cancel-Semantik des ✕ wechselt mit der Phase — Texte unverändert zu heute.
    var cancelHelp: String {
        switch self {
        case .recording:
            return "Aufnahme abbrechen"
        case .transcribing:
            return "Transkription abbrechen — die Aufnahme bleibt gesichert"
        case .improving:
            return "Codex-Post-Processing abbrechen und Raw-Transkript verwenden"
        }
    }

    var cancelAccessibilityLabel: String {
        switch self {
        case .recording:
            return "Cancel recording"
        case .transcribing:
            return "Cancel transcription"
        case .improving:
            return "Cancel Codex post-processing"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .recording:
            return "Recording"
        case .transcribing:
            return "Transcribing"
        case .improving:
            return "Improving"
        }
    }
}

// MARK: - Farbpalette (adaptiv Light/Dark)

/// Zustandsfarben der Pill. Auf hellem Glas (`.thinMaterial` im Light-Modus)
/// brauchen die vibranten Dark-Töne dunklere Pendants, sonst fehlt Kontrast.
enum OverlayPalette {
    /// Mint — Aufnahme läuft.
    static let recording = dynamicColor(
        light: NSColor(red: 0.10, green: 0.62, blue: 0.42, alpha: 1),   // #1A9E6B
        dark: NSColor(red: 0.24, green: 0.86, blue: 0.59, alpha: 1)     // #3DDC97
    )

    /// Amber — Transkription läuft.
    static let transcribing = dynamicColor(
        light: NSColor(red: 0.72, green: 0.50, blue: 0.05, alpha: 1),   // #B8800D
        dark: NSColor(red: 0.95, green: 0.69, blue: 0.24, alpha: 1)     // #F2B13E
    )

    /// Violett — Codex-Improve läuft.
    static let improving = dynamicColor(
        light: NSColor(red: 0.45, green: 0.33, blue: 0.80, alpha: 1)    // #7354CC
        , dark: NSColor(red: 0.65, green: 0.55, blue: 0.98, alpha: 1)   // #A78BFA
    )

    /// Rot — Screen-Clip aktiv (Ring um den Kern + blinkendes Icon).
    static let clip = dynamicColor(
        light: NSColor(red: 0.85, green: 0.25, blue: 0.25, alpha: 1),   // #D94040
        dark: NSColor(red: 1.00, green: 0.42, blue: 0.42, alpha: 1)     // #FF6B6B
    )

    /// Dunkle Glas-Tönung der Pill (#13161B) — über dem Material, drückt es
    /// Richtung Fast-Schwarz (Prototyp: rgba(19,22,27,.86)). Die Pill rendert
    /// via erzwungenem darkAqua immer dunkel, unabhängig vom System-Theme.
    static let glassTint = Color(red: 19.0 / 255.0, green: 22.0 / 255.0, blue: 27.0 / 255.0)
        .opacity(0.55)

    static func tint(for phase: OverlayPhase) -> Color {
        switch phase {
        case .recording: return recording
        case .transcribing: return transcribing
        case .improving: return improving
        }
    }

    private static func dynamicColor(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

// MARK: - Timer-Formatierung

/// Formatiert die Aufnahmedauer als mm:ss — pur & getestet; der Clock-Layer
/// published den String nur bei echtem Sekundenwechsel (Tick-Diät).
enum OverlayClockFormatter {
    static func format(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
