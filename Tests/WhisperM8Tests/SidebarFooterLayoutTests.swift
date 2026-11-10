import AppKit
import SwiftUI
import XCTest
@testable import WhisperM8

/// Befund 10.11.2026: Die Fußzeile der Sidebar brauchte auf Deutsch mehr Platz,
/// als die Sidebar breit ist. Der `VStack` der Sidebar wuchs mit, ragte über
/// seine Spalte hinaus und verdeckte Tab-Leiste und Terminal. Die Fußzeile darf
/// der Sidebar deshalb nie mehr als deren Mindestbreite abverlangen — auch im
/// schlimmsten Fall mit Update-Hinweis.
@MainActor
final class SidebarFooterLayoutTests: XCTestCase {
    private func fittedWidth(proposed: CGFloat) -> CGFloat {
        let footer = SidebarFooterBar(onOpenSettings: {}) {
            UISnapshotGallery.sidebarFooterTrailingPlaceholders()
        }
        let host = NSHostingController(rootView: footer)
        return host.sizeThatFits(in: CGSize(width: proposed, height: 60)).width
    }

    func testFooterFitsIntoMinimumSidebarWidth() {
        XCTAssertLessThanOrEqual(
            fittedWidth(proposed: SidebarWidthResolver.minWidth),
            SidebarWidthResolver.minWidth
        )
    }

    /// Die kleinste Breite ist sprachunabhängig: ohne Platz bleibt nur das
    /// Zahnrad, die Beschriftung zählt dann nicht mehr mit.
    func testMinimumWidthLeavesRoomBelowSidebarMinimum() {
        XCTAssertLessThanOrEqual(fittedWidth(proposed: 0), SidebarWidthResolver.minWidth - 24)
    }

    func testFooterFillsWideSidebar() {
        XCTAssertEqual(fittedWidth(proposed: 400), 400, accuracy: 0.5)
    }
}
