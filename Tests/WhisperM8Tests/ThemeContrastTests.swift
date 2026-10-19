import AppKit
import SwiftUI
import XCTest
@testable import WhisperM8

/// LR-ONB-016: Leserelevante Hilfetexte erreichen WCAG 4,5:1 in beiden Themes.
final class ThemeContrastTests: XCTestCase {
    private func resolved(_ color: Color, _ appearance: NSAppearance.Name) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        var out: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 1)
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            let ns = NSColor(color).usingColorSpace(.sRGB)!
            out = (ns.redComponent, ns.greenComponent, ns.blueComponent, ns.alphaComponent)
        }
        return out
    }

    private func luminance(_ c: (CGFloat, CGFloat, CGFloat)) -> Double {
        func lin(_ v: CGFloat) -> Double { let v = Double(v); return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.0) + 0.7152 * lin(c.1) + 0.0722 * lin(c.2)
    }

    private func contrast(_ fg: Color, on bg: Color, _ appearance: NSAppearance.Name) -> Double {
        let f = resolved(fg, appearance), b = resolved(bg, appearance)
        let mix = (f.r * f.a + b.r * (1 - f.a), f.g * f.a + b.g * (1 - f.a), f.b * f.a + b.b * (1 - f.a))
        let l1 = luminance(mix), l2 = luminance((b.r, b.g, b.b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    func testHelpTextTokenIsReadableInBothThemes() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            XCTAssertGreaterThanOrEqual(contrast(AppTheme.textSecondary, on: AppTheme.background, appearance), 4.5, "\(appearance.rawValue)")
        }
    }
}
