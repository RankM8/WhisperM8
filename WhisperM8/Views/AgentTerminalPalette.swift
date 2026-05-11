import AppKit
import SwiftTerm
import SwiftUI

/// Light- und Dark-Paletten fürs eingebettete SwiftTerm-Terminal.
///
/// SwiftTerm rendert ANSI-Color-Codes (`ESC[31m` = Red Index 1) gegen eine
/// 16-Color-Palette, die `installColors(_:)` setzt. Claude Code und Codex CLI
/// emittieren nur Indizes — wir liefern die RGB-Werte. Dadurch funktioniert
/// ein Light/Dark-Wechsel **ohne Subprocess-Restart**: wir tauschen die
/// Palette zur Laufzeit, der Render-Layer schreibt sofort neu.
///
/// Farb-Wahl folgt grob Tango/Solarized-Linien: gut lesbar auf beiden
/// Backgrounds, gleicher Hue-Charakter, im Light etwas tiefere Sättigung
/// damit Text nicht ausbrennt.
enum AgentTerminalPalette {
    struct Resolved {
        let background: NSColor
        let foreground: NSColor
        let ansi16: [SwiftTerm.Color]
    }

    static func palette(for scheme: ColorScheme) -> Resolved {
        switch scheme {
        case .light: return light
        default:     return dark
        }
    }

    // MARK: - Dark (Default, wie bisher in WhisperM8)

    private static let dark = Resolved(
        background: NSColor(calibratedRed: 0.058, green: 0.060, blue: 0.064, alpha: 1),
        foreground: NSColor(calibratedRed: 0.92,  green: 0.92,  blue: 0.93,  alpha: 1),
        ansi16: [
            // Standard
            term(0x1d, 0x1f, 0x21), // 0: black
            term(0xcc, 0x66, 0x66), // 1: red
            term(0xb5, 0xbd, 0x68), // 2: green
            term(0xf0, 0xc6, 0x74), // 3: yellow
            term(0x81, 0xa2, 0xbe), // 4: blue
            term(0xb2, 0x94, 0xbb), // 5: magenta
            term(0x8a, 0xbe, 0xb7), // 6: cyan
            term(0xc5, 0xc8, 0xc6), // 7: white
            // Bright
            term(0x66, 0x6a, 0x6e), // 8: bright black (= grau)
            term(0xff, 0x90, 0x90), // 9: bright red
            term(0xc8, 0xd3, 0x7c), // 10: bright green
            term(0xff, 0xd9, 0x7a), // 11: bright yellow
            term(0x9e, 0xc3, 0xea), // 12: bright blue
            term(0xd0, 0xa9, 0xd8), // 13: bright magenta
            term(0xa1, 0xe2, 0xd9), // 14: bright cyan
            term(0xff, 0xff, 0xff)  // 15: bright white
        ]
    )

    // MARK: - Light (neu — kalibriert für weißen Background)

    private static let light = Resolved(
        background: NSColor(calibratedRed: 1.00,  green: 1.00,  blue: 1.00,  alpha: 1),
        foreground: NSColor(calibratedRed: 0.12,  green: 0.12,  blue: 0.13,  alpha: 1),
        ansi16: [
            // Standard — gleiche Hue-Familie wie Dark, aber kontrastreicher gegen weiß.
            term(0x20, 0x21, 0x24), // 0: black (sehr dunkel)
            term(0xa6, 0x1b, 0x29), // 1: red
            term(0x2f, 0x7d, 0x1f), // 2: green
            term(0xb4, 0x6a, 0x00), // 3: yellow (eher amber für Lesbarkeit)
            term(0x1f, 0x4f, 0xa5), // 4: blue
            term(0x82, 0x35, 0xa0), // 5: magenta
            term(0x0e, 0x6f, 0x79), // 6: cyan (teal)
            term(0x4a, 0x4e, 0x55), // 7: white (= dunkleres Grau für Standard-Foreground)
            // Bright
            term(0x66, 0x6a, 0x6e), // 8: bright black (mittleres Grau)
            term(0xc9, 0x2e, 0x3a), // 9: bright red
            term(0x40, 0x99, 0x2d), // 10: bright green
            term(0xd9, 0x82, 0x0d), // 11: bright yellow
            term(0x29, 0x69, 0xc8), // 12: bright blue
            term(0xa0, 0x47, 0xc0), // 13: bright magenta
            term(0x10, 0x8c, 0x96), // 14: bright cyan
            term(0x20, 0x21, 0x24)  // 15: bright white (= dark text auf weiß)
        ]
    )

    /// Helper: NSColor-style 8-bit RGB → SwiftTerm.Color (16-bit).
    private static func term(_ r: UInt16, _ g: UInt16, _ b: UInt16) -> SwiftTerm.Color {
        SwiftTerm.Color(red: r * 257, green: g * 257, blue: b * 257)
    }
}
