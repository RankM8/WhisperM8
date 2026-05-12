import AppKit
import SwiftUI

/// Drei-Stufen-Schalter für das App-Theme: `system` (folgt macOS), `light`,
/// `dark`. Wird in `AppPreferences` persistiert und vom `ThemeManager`
/// publishiert, sodass die SwiftUI-Scene-Roots `.preferredColorScheme(...)`
/// daraus ableiten können.
enum AppearanceOverride: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Hell"
        case .dark: return "Dunkel"
        }
    }

    var systemImage: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon.fill"
        }
    }

    /// `nil` für `system` ist der entscheidende Trick: nur `nil` an
    /// `.preferredColorScheme(_:)` weitergeben bedeutet „kein Override,
    /// folge dem OS". `.light`/`.dark` erzwingen das jeweilige Schema.
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// Für AppKit-Pfade: `NSApp.appearance` muss zusätzlich gesetzt werden,
    /// weil `.preferredColorScheme` nur die Window-Appearance steuert (z. B.
    /// das Menubar-Icon und nicht-aktivierende NSPanels erben sonst nicht).
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}
