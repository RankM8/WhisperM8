import Foundation
import XCTest
@testable import WhisperM8

/// Tests fuer die pure Sidebar-Breiten-Logik (Clamping gegen Fenstergeometrie,
/// Drag-Anwendung, Grenzen). Die Gesten-/Persistenz-Verdrahtung in
/// AgentChatsView ist SwiftUI und wird manuell ge-QA-t.
final class SidebarWidthResolverTests: XCTestCase {
    // MARK: - Grenzen

    func testMinEqualsLegacyFixedWidth() {
        XCTAssertEqual(SidebarWidthResolver.minWidth, 276,
                       "Untergrenze = bisherige Festbreite — die Sidebar wird nie schmaler als vor dem Feature")
        XCTAssertEqual(SidebarWidthResolver.defaultWidth, SidebarWidthResolver.minWidth,
                       "Doppelklick-Reset fuehrt zur alten Festbreite zurueck")
    }

    func testMaxWidthCappedByHalfWindow() {
        // 1400er Fenster ohne Inspector: Content-Grenze 920, Haelfte 700 → 700.
        XCTAssertEqual(SidebarWidthResolver.maxWidth(windowWidth: 1400, inspectorWidth: 0), 700)
    }

    func testMaxWidthCappedByContentMinWidth() {
        // 1100er Fenster + Inspector (292): 1100-480-292 = 328 < 550 → 328.
        XCTAssertEqual(SidebarWidthResolver.maxWidth(windowWidth: 1100, inspectorWidth: 292), 328)
    }

    func testMaxWidthNeverFallsBelowMinimum() {
        // 600er Fenster: Content-Grenze 120, Haelfte 300 → beide unter 276 →
        // die Sidebar behaelt ihr altes Festmass (Quetsch-Verhalten wie zuvor).
        XCTAssertEqual(SidebarWidthResolver.maxWidth(windowWidth: 600, inspectorWidth: 0),
                       SidebarWidthResolver.minWidth)
    }

    // MARK: - Effektive Breite (gespeicherter Wert → Layout-Wert)

    func testEffectiveWidthClampsBelowMinimum() {
        XCTAssertEqual(SidebarWidthResolver.effectiveWidth(stored: 100, windowWidth: 1100, inspectorWidth: 0),
                       SidebarWidthResolver.minWidth)
    }

    func testEffectiveWidthPassesValueInRange() {
        XCTAssertEqual(SidebarWidthResolver.effectiveWidth(stored: 340, windowWidth: 1100, inspectorWidth: 0), 340)
    }

    func testEffectiveWidthClampsAboveMaximum() {
        // 1100 ohne Inspector: max = min(620, 550) = 550.
        XCTAssertEqual(SidebarWidthResolver.effectiveWidth(stored: 900, windowWidth: 1100, inspectorWidth: 0), 550)
    }

    func testEffectiveWidthShrinksWhenInspectorOpens() {
        let without = SidebarWidthResolver.effectiveWidth(stored: 500, windowWidth: 1100, inspectorWidth: 0)
        let with = SidebarWidthResolver.effectiveWidth(stored: 500, windowWidth: 1100, inspectorWidth: 292)
        XCTAssertEqual(without, 500, "ohne Inspector passt der Wunschwert")
        XCTAssertEqual(with, 328, "mit Inspector wird live auf die neue Obergrenze geclampt")
    }

    func testSmallWindowAlwaysYieldsMinimum() {
        XCTAssertEqual(SidebarWidthResolver.effectiveWidth(stored: 400, windowWidth: 600, inspectorWidth: 0),
                       SidebarWidthResolver.minWidth,
                       "auf kleinen Fenstern gilt die alte Festbreite — der gespeicherte Wunschwert bleibt unangetastet")
    }

    func testZeroWindowWidthIsSafe() {
        // GeometryReader kann im ersten Layout-Pass 0 liefern.
        XCTAssertEqual(SidebarWidthResolver.effectiveWidth(stored: 999, windowWidth: 0, inspectorWidth: 0),
                       SidebarWidthResolver.minWidth)
    }

    // MARK: - Drag

    func testWidthDuringDragAddsTranslation() {
        XCTAssertEqual(SidebarWidthResolver.widthDuringDrag(startWidth: 300, translation: 40, windowWidth: 1100, inspectorWidth: 0), 340)
    }

    func testWidthDuringDragClampsAtBothEnds() {
        XCTAssertEqual(SidebarWidthResolver.widthDuringDrag(startWidth: 300, translation: -500, windowWidth: 1100, inspectorWidth: 0),
                       SidebarWidthResolver.minWidth,
                       "Drag weit nach links stoppt an der Untergrenze")
        XCTAssertEqual(SidebarWidthResolver.widthDuringDrag(startWidth: 300, translation: 5000, windowWidth: 1100, inspectorWidth: 0),
                       550,
                       "Drag weit nach rechts stoppt an der dynamischen Obergrenze")
    }
}
