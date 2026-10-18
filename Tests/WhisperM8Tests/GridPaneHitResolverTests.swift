import CoreGraphics
import XCTest
@testable import WhisperM8

/// LR-AU-016: Pane-Fokus-Routing per Klickposition statt Hover-Flag.
final class GridPaneHitResolverTests: XCTestCase {
    private let a = UUID(), b = UUID()
    private var frames: [UUID: CGRect] {
        [a: CGRect(x: 300, y: 100, width: 400, height: 600),
         b: CGRect(x: 701, y: 100, width: 400, height: 600)]
    }

    func testPaneAtPointFindsContainingPane() {
        XCTAssertEqual(GridPaneHitResolver.pane(at: CGPoint(x: 400, y: 300), frames: frames), a)
        XCTAssertEqual(GridPaneHitResolver.pane(at: CGPoint(x: 900, y: 300), frames: frames), b)
    }

    /// Sidebar-Suchfeld (links vom Grid) und Kopfzeile (über dem Grid): keine Pane.
    func testClicksOutsideGridHitNoPane() {
        XCTAssertNil(GridPaneHitResolver.pane(at: CGPoint(x: 100, y: 300), frames: frames))
        XCTAssertNil(GridPaneHitResolver.pane(at: CGPoint(x: 400, y: 40), frames: frames))
    }

    /// Hängendes Hover-Flag auf `a`, Klick außerhalb → kein Fokuswechsel.
    func testStaleHoverFlagDoesNotMoveFocusForClickOutsideGrid() {
        XCTAssertNil(GridPaneHitResolver.focusTarget(hovered: a, point: CGPoint(x: 100, y: 300), frames: frames))
    }

    /// Die Pane unter dem Klick gewinnt, auch wenn das Flag auf eine andere zeigt.
    func testPaneUnderClickWinsOverHoverFlag() {
        XCTAssertEqual(GridPaneHitResolver.focusTarget(hovered: a, point: CGPoint(x: 900, y: 300), frames: frames), b)
    }

    /// Noch nichts gemessen: altes Verhalten (Flag), kein Fokus, der nie wandert.
    func testFallsBackToHoverFlagWithoutMeasuredFrames() {
        XCTAssertEqual(GridPaneHitResolver.focusTarget(hovered: a, point: .zero, frames: [:]), a)
        XCTAssertNil(GridPaneHitResolver.focusTarget(hovered: nil, point: .zero, frames: [:]))
    }

    func testSwiftUIPointConversion() {
        let p = GridPaneHitResolver.swiftUIPoint(locationInWindow: CGPoint(x: 10, y: 700), contentViewHeight: 800, safeAreaTopInset: 28)
        XCTAssertEqual(p, CGPoint(x: 10, y: 72))
    }
}
