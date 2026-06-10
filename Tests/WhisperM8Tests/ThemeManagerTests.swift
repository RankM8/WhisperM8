import AppKit
import Foundation
import XCTest
@testable import WhisperM8

final class ThemeManagerTests: XCTestCase {
    // MARK: - ThemeManager.resolve

    func testThemeResolveOverrideLightAlwaysReturnsLight() {
        XCTAssertEqual(
            ThemeManager.resolve(override: .light, systemAppearance: NSAppearance(named: .darkAqua)),
            .light
        )
        XCTAssertEqual(
            ThemeManager.resolve(override: .light, systemAppearance: NSAppearance(named: .aqua)),
            .light
        )
        XCTAssertEqual(
            ThemeManager.resolve(override: .light, systemAppearance: nil),
            .light
        )
    }

    func testThemeResolveOverrideDarkAlwaysReturnsDark() {
        XCTAssertEqual(
            ThemeManager.resolve(override: .dark, systemAppearance: NSAppearance(named: .aqua)),
            .dark
        )
        XCTAssertEqual(
            ThemeManager.resolve(override: .dark, systemAppearance: NSAppearance(named: .darkAqua)),
            .dark
        )
    }

    func testThemeResolveSystemFollowsAppearance() {
        XCTAssertEqual(
            ThemeManager.resolve(override: .system, systemAppearance: NSAppearance(named: .aqua)),
            .light
        )
        XCTAssertEqual(
            ThemeManager.resolve(override: .system, systemAppearance: NSAppearance(named: .darkAqua)),
            .dark
        )
    }

    func testThemeResolveSystemFallsBackToDarkWhenAppearanceUnknown() {
        XCTAssertEqual(
            ThemeManager.resolve(override: .system, systemAppearance: nil),
            .dark
        )
    }

    func testAppearanceOverridePreferredColorSchemeMapping() {
        XCTAssertNil(AppearanceOverride.system.preferredColorScheme)
        XCTAssertEqual(AppearanceOverride.light.preferredColorScheme, .light)
        XCTAssertEqual(AppearanceOverride.dark.preferredColorScheme, .dark)
    }

    func testClaudeThemeNameMapping() {
        // Beide Schemata → Claude's eigene Theme-Farben (`light` / `dark`),
        // NICHT die `*-ansi`-Varianten. `light-ansi` rendert UI-Chrome
        // (Input-Box, Status-Pills) mit ANSI-Indizes, die gegen den weißen
        // Background als schwarze Bänder erscheinen. `dark-ansi` führte
        // umgekehrt dazu, dass Highlights mit weißem ANSI-BG gegen den
        // weißen Default-Foreground unlesbar wurden.
        XCTAssertEqual(ClaudeThemeWriter.claudeThemeName(for: .light), "light")
        XCTAssertEqual(ClaudeThemeWriter.claudeThemeName(for: .dark), "dark")
    }
}
