import AppKit
import SwiftUI

/// 22 Theme-Tokens, je in Light- und Dark-Variante. Alle Werte werden über
/// `Color.dynamic(light:dark:)` aufgelöst — der zugrundeliegende
/// `NSColor(name:dynamicProvider:)` liest die aktuelle `NSAppearance` aus
/// der View-Hierarchie, sodass `.preferredColorScheme(.light/.dark)` auf
/// dem Root die Tokens automatisch umschaltet.
enum AgentTheme {
    static let background = Color.dynamic(
        light: Color(red: 1.0, green: 1.0, blue: 1.0),
        dark: Color(red: 0.058, green: 0.060, blue: 0.064)
    )
    static let sidebar = Color.dynamic(
        light: Color(red: 0.935, green: 0.935, blue: 0.940),
        dark: Color(red: 0.075, green: 0.078, blue: 0.082)
    )
    static let header = Color.dynamic(
        light: Color(red: 0.950, green: 0.950, blue: 0.955),
        dark: Color(red: 0.070, green: 0.072, blue: 0.076)
    )
    static let surface = Color.dynamic(
        light: Color(red: 1.0, green: 1.0, blue: 1.0),
        dark: Color(red: 0.090, green: 0.092, blue: 0.097)
    )
    static let panel = Color.dynamic(
        light: Color(red: 1.0, green: 1.0, blue: 1.0),
        dark: Color(red: 0.105, green: 0.108, blue: 0.114)
    )
    static let control = Color.dynamic(
        light: Color(red: 0.920, green: 0.920, blue: 0.928),
        dark: Color(red: 0.140, green: 0.143, blue: 0.150)
    )
    static let hover = Color.dynamic(
        light: Color.black.opacity(0.045),
        dark: Color.white.opacity(0.04)
    )
    static let selection = Color.dynamic(
        light: Color.black.opacity(0.075),
        dark: Color.white.opacity(0.07)
    )
    static let selectionStrong = Color.dynamic(
        light: Color.black.opacity(0.11),
        dark: Color.white.opacity(0.10)
    )
    static let headerTab = Color.dynamic(
        light: Color(red: 0.928, green: 0.928, blue: 0.936),
        dark: Color(red: 0.080, green: 0.082, blue: 0.086)
    )
    static let tabSelected = Color.dynamic(
        light: Color(red: 1.0, green: 1.0, blue: 1.0),
        dark: Color(red: 0.115, green: 0.118, blue: 0.124)
    )
    static let statusPill = Color.dynamic(
        light: Color(red: 0.985, green: 0.985, blue: 0.990),
        dark: Color(red: 0.050, green: 0.052, blue: 0.055)
    )
    static let border = Color.dynamic(
        light: Color.black.opacity(0.08),
        dark: Color.white.opacity(0.06)
    )
    static let borderStrong = Color.dynamic(
        light: Color.black.opacity(0.13),
        dark: Color.white.opacity(0.10)
    )
    static let connector = Color.dynamic(
        light: Color.black.opacity(0.11),
        dark: Color.white.opacity(0.10)
    )
    static let connectorActive = Color.dynamic(
        light: Color.black.opacity(0.25),
        dark: Color.white.opacity(0.22)
    )
    static let textPrimary = Color.dynamic(
        light: Color.black.opacity(0.90),
        dark: Color.white.opacity(0.92)
    )
    static let textSecondary = Color.dynamic(
        light: Color.black.opacity(0.58),
        dark: Color.white.opacity(0.55)
    )
    static let textTertiary = Color.dynamic(
        light: Color.black.opacity(0.42),
        dark: Color.white.opacity(0.38)
    )
    static let accentDiffPos = Color.dynamic(
        light: Color(red: 0.18, green: 0.62, blue: 0.30),
        dark: Color(red: 0.40, green: 0.85, blue: 0.45)
    )
    static let accentDiffNeg = Color.dynamic(
        light: Color(red: 0.78, green: 0.22, blue: 0.22),
        dark: Color(red: 0.95, green: 0.40, blue: 0.40)
    )

    // MARK: - Linear-Akzent (Indigo) + Status
    // Markenakzent für Auswahl, primären „Neuer Chat"-Button und Fokus.
    // Dark etwas aufgehellt für Kontrast auf dunklen Flächen.
    static let accent = Color.dynamic(
        light: Color(hex: "#5e6ad2"),
        dark: Color(hex: "#7c84e8")
    )
    static let accentStrong = Color.dynamic(
        light: Color(hex: "#4b56c0"),
        dark: Color(hex: "#5e6ad2")
    )
    /// Hintergrund der ausgewählten Zeile (Indigo-Tint).
    static let accentTint = Color.dynamic(
        light: Color(hex: "#5e6ad2").opacity(0.13),
        dark: Color(hex: "#7c84e8").opacity(0.16)
    )
    /// Sehr dezenter Indigo-/Amber-Tint (z.B. wartende Zeile, Hover auf Auswahl).
    static let accentTintSoft = Color.dynamic(
        light: Color(hex: "#5e6ad2").opacity(0.07),
        dark: Color(hex: "#7c84e8").opacity(0.09)
    )
    /// Status-Indikatorfarben (zentral statt hartkodiert in den Rows).
    static let statusWorking = Color.dynamic(
        light: Color(hex: "#3fa873"),
        dark: Color(hex: "#4cc38a")
    )
    static let statusAwaiting = Color.dynamic(
        light: Color(hex: "#c9962a"),
        dark: Color(hex: "#e9b949")
    )
    static let statusError = Color.dynamic(
        light: Color(hex: "#d6473d"),
        dark: Color(hex: "#e5594f")
    )
}

extension Color {
    static func dynamic(light: Color, dark: Color) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(isDark ? dark : light)
        })
    }

    init(hex: String) {
        let scanner = Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")))
        var rgb: UInt64 = 0
        scanner.scanHexInt64(&rgb)
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0
        )
    }
}

extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
