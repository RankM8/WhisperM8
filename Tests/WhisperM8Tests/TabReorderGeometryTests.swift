import CoreGraphics
import Foundation
import XCTest
@testable import WhisperM8

/// Etappe-0 Tab-Drag: deckt die reine Einfüge-Geometrie ab (Index aus Cursor-X,
/// X-Position der Linie) — ohne SwiftUI-Laufzeit.
final class TabReorderGeometryTests: XCTestCase {
    // 3 Tabs à 100pt Breite, 4pt Abstand: A[0…100] B[104…204] C[208…308].
    private let a = UUID()
    private let b = UUID()
    private let c = UUID()
    private var ids: [UUID] { [a, b, c] }
    private var frames: [UUID: CGRect] {
        [
            a: CGRect(x: 0, y: 0, width: 100, height: 24),   // midX 50
            b: CGRect(x: 104, y: 0, width: 100, height: 24), // midX 154
            c: CGRect(x: 208, y: 0, width: 100, height: 24), // midX 258
        ]
    }

    func testInsertionIndexCountsTabsLeftOfCursor() {
        XCTAssertEqual(TabReorderGeometry.insertionIndex(atX: 10, orderedIDs: ids, frames: frames), 0)
        XCTAssertEqual(TabReorderGeometry.insertionIndex(atX: 60, orderedIDs: ids, frames: frames), 1)
        XCTAssertEqual(TabReorderGeometry.insertionIndex(atX: 160, orderedIDs: ids, frames: frames), 2)
        XCTAssertEqual(TabReorderGeometry.insertionIndex(atX: 300, orderedIDs: ids, frames: frames), 3)
    }

    func testInsertionIndexBoundaryIsExclusiveOnMidpoint() {
        // midX == x zählt NICHT als „links" → Index bleibt davor.
        XCTAssertEqual(TabReorderGeometry.insertionIndex(atX: 50, orderedIDs: ids, frames: frames), 0)
    }

    func testInsertionIndexIgnoresMissingFrames() {
        let partial: [UUID: CGRect] = [a: frames[a]!, c: frames[c]!] // b fehlt
        // Bei x=300 zählen nur a(50) und c(258) → 2 statt 3.
        XCTAssertEqual(TabReorderGeometry.insertionIndex(atX: 300, orderedIDs: ids, frames: partial), 2)
    }

    func testInsertionXAtEdgesAndGaps() {
        XCTAssertEqual(TabReorderGeometry.insertionX(forIndex: 0, orderedIDs: ids, frames: frames, spacing: 4), -2)
        XCTAssertEqual(TabReorderGeometry.insertionX(forIndex: 1, orderedIDs: ids, frames: frames, spacing: 4), 102) // (100+104)/2
        XCTAssertEqual(TabReorderGeometry.insertionX(forIndex: 2, orderedIDs: ids, frames: frames, spacing: 4), 206) // (204+208)/2
        XCTAssertEqual(TabReorderGeometry.insertionX(forIndex: 3, orderedIDs: ids, frames: frames, spacing: 4), 310) // 308+2
    }

    func testInsertionXClampsOutOfRangeIndex() {
        XCTAssertEqual(TabReorderGeometry.insertionX(forIndex: 99, orderedIDs: ids, frames: frames, spacing: 4), 310)
        XCTAssertEqual(TabReorderGeometry.insertionX(forIndex: -5, orderedIDs: ids, frames: frames, spacing: 4), -2)
    }

    func testInsertionXNilWhenEmptyOrUnmeasured() {
        XCTAssertNil(TabReorderGeometry.insertionX(forIndex: 0, orderedIDs: [], frames: [:], spacing: 4))
        // Gap zwischen a und b, aber b noch nicht gemessen → nil.
        XCTAssertNil(TabReorderGeometry.insertionX(forIndex: 1, orderedIDs: ids, frames: [a: frames[a]!], spacing: 4))
    }
}
