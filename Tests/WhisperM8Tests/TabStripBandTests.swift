import XCTest
@testable import WhisperM8

/// Vorfall 2026-08-23: Das `onHover`-Flag des Tab-Strips blieb hängen
/// (SwiftUI verliert `onHover(false)` bei Kontextmenü/Drag über der Leiste),
/// und der allein daran gegatete `scrollWheel`-Monitor konsumierte JEDES
/// Mausrad-Event im Fenster — Scrollen war in Sidebar und Chats tot. Seitdem
/// gaten die Event-Monitore zustandslos über diesen Koordinaten-Hit-Test:
/// jedes Event entscheidet frisch, nichts kann hängen bleiben. Diese Tests
/// pinnen die Band-Geometrie (AppKit-Y unten-links, gemessene X-Spanne).
final class TabStripBandTests: XCTestCase {
    /// Fensterinhalt 800×600, Strip gemessen von x=80 (nach den Ampeln)
    /// bis x=500, im obersten 34pt-Band.
    private let contentHeight: CGFloat = 600
    private let strip = CGRect(x: 80, y: 566, width: 420, height: 34)

    func testPointerInsideBandAndSpanHits() {
        XCTAssertTrue(TabStripBand.contains(
            CGPoint(x: 200, y: 580),
            contentViewHeight: contentHeight, stripFrame: strip
        ))
    }

    func testBandEdgesCountAsInside() {
        // Unterkante des Bands (y = Höhe − 34) und beide X-Ränder der Spanne.
        XCTAssertTrue(TabStripBand.contains(
            CGPoint(x: 80, y: contentHeight - TabStripBand.height),
            contentViewHeight: contentHeight, stripFrame: strip
        ))
        XCTAssertTrue(TabStripBand.contains(
            CGPoint(x: 500, y: 599),
            contentViewHeight: contentHeight, stripFrame: strip
        ))
    }

    func testPointerBelowBandMisses() {
        // Sidebar-/Terminal-Bereich: gleiche X-Spanne, aber unterhalb des
        // Bands — genau die Events, die der hängende Hover-Zustand früher
        // fälschlich konsumiert hat.
        XCTAssertFalse(TabStripBand.contains(
            CGPoint(x: 200, y: 565),
            contentViewHeight: contentHeight, stripFrame: strip
        ))
        XCTAssertFalse(TabStripBand.contains(
            CGPoint(x: 200, y: 20),
            contentViewHeight: contentHeight, stripFrame: strip
        ))
    }

    func testPointerOutsideStripSpanMisses() {
        // Im Band, aber links der Spanne (Ampel-Zone) bzw. rechts davon
        // (freie Titelfläche) — dort gehört das Rad nicht dem Strip.
        XCTAssertFalse(TabStripBand.contains(
            CGPoint(x: 40, y: 580),
            contentViewHeight: contentHeight, stripFrame: strip
        ))
        XCTAssertFalse(TabStripBand.contains(
            CGPoint(x: 700, y: 580),
            contentViewHeight: contentHeight, stripFrame: strip
        ))
    }

    func testUnmeasuredStripNeverHits() {
        // Vor dem ersten Layout ist die Spanne leer — dann lieber keinen
        // Strip-Scroll als ein gekapertes Fenster-Event.
        XCTAssertFalse(TabStripBand.contains(
            CGPoint(x: 200, y: 580),
            contentViewHeight: contentHeight, stripFrame: .zero
        ))
    }
}
