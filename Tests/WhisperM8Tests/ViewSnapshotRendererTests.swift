import AppKit
import SwiftUI
import XCTest
@testable import WhisperM8

/// Der Renderer hinter `scripts/ui-snapshots.sh` und dem Fenster-Foto des
/// Debug-Steuerkanals: echte Controls, doppelte Pixeldichte, deckender
/// Hintergrund je Erscheinungsbild.
final class ViewSnapshotRendererTests: XCTestCase {
    @MainActor
    private func bitmap(_ appearance: ViewSnapshotRenderer.Appearance) throws -> NSBitmapImageRep {
        let view = VStack {
            Toggle("Schalter", isOn: .constant(true))
            Text("Hallo")
        }
        let png = try ViewSnapshotRenderer.pngData(
            view,
            size: CGSize(width: 120, height: 60),
            appearance: appearance,
            settle: 0
        )
        return try XCTUnwrap(NSBitmapImageRep(data: png))
    }

    private func brightness(_ rep: NSBitmapImageRep, x: Int, y: Int) throws -> CGFloat {
        let color = try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.01, "Hintergrund muss deckend sein")
        return (color.redComponent + color.greenComponent + color.blueComponent) / 3
    }

    @MainActor
    func testRendersAtDoubleScaleWithOpaqueThemeBackground() throws {
        let light = try bitmap(.light)
        XCTAssertEqual(light.pixelsWide, 240)
        XCTAssertEqual(light.pixelsHigh, 120)
        XCTAssertGreaterThan(try brightness(light, x: 2, y: 2), 0.9)

        // Vorfall beim Bau: ohne expliziten Hintergrund war Dunkel transparent.
        let dark = try bitmap(.dark)
        XCTAssertLessThan(try brightness(dark, x: 2, y: 2), 0.15)
    }

    @MainActor
    func testRendersContentNotJustBackground() throws {
        let rep = try bitmap(.light)
        let background = try brightness(rep, x: 2, y: 2)
        var differing = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
                let value = try brightness(rep, x: x, y: y)
                if abs(value - background) > 0.2 { differing += 1 }
            }
        }
        XCTAssertGreaterThan(differing, 20, "Toggle/Text fehlen im Bild")
    }

    @MainActor
    func testEmptyViewIsRejected() {
        XCTAssertThrowsError(try ViewSnapshotRenderer.pngData(of: NSView(frame: .zero)))
    }
}
