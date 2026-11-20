import AppKit
import SwiftUI
import XCTest
@testable import WhisperM8

/// Die große Form an der Kamera-Insel am gezeichneten Bild: eine Fläche ohne
/// Hals, zu nur die Kapsel, und eine Kopfzeile, deren Seiten ihren Platz
/// behalten. Maße des Bildschirms wie in `NotchIslandGeometryTests`.
@MainActor
final class NotchIslandLargePixelTests: XCTestCase {
    private let screen = NotchScreenInfo(
        displayID: 1, frame: CGRect(x: 0, y: 0, width: 1736, height: 1133),
        visibleFrame: CGRect(x: 0, y: 0, width: 1736, height: 1088),
        safeAreaTop: 40, auxiliaryLeftWidth: 838.5, auxiliaryRightWidth: 838.5, isBuiltIn: true)

    /// Hintergrund des Bilds: weder schwarz noch weiß.
    private let backdrop = Color(red: 0.5, green: 0.6, blue: 0.7)

    private func render(_ view: some View, size: CGSize, name: String) throws -> NSBitmapImageRep {
        let png = try ViewSnapshotRenderer.pngData(
            view, size: size, appearance: .dark, background: backdrop, scale: 1, settle: 0)
        if let dir = ProcessInfo.processInfo.environment["WHISPERM8_PIXELTEST_DIR"] {
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("insel-gross-\(name).png"))
        }
        return try XCTUnwrap(NSBitmapImageRep(data: png))
    }

    /// Helligkeit eines Punkts (Summe aus Rot, Grün, Blau; Koordinaten von oben links).
    private func brightness(_ image: NSBitmapImageRep, _ x: CGFloat, _ y: CGFloat) -> Int {
        guard let data = image.bitmapData else { return -1 }
        let offset = Int(y) * image.bytesPerRow + Int(x) * (image.bitsPerPixel / 8)
        return Int(data[offset]) + Int(data[offset + 1]) + Int(data[offset + 2])
    }

    private func isBlack(_ image: NSBitmapImageRep, _ x: CGFloat, _ y: CGFloat) -> Bool { brightness(image, x, y) < 30 }
    private func isBackdrop(_ image: NSBitmapImageRep, _ x: CGFloat, _ y: CGFloat) -> Bool {
        (380...500).contains(brightness(image, x, y))
    }

    private func display(
        alert: NotchAlert?, band: NotchIslandBand, large: NotchIslandLargeDisplay
    ) -> NotchDisplay {
        NotchDisplay(
            style: .island(band), summary: NotchSummary(working: 2, waiting: 1), alert: alert, isExpanded: false,
            sections: [], islandLarge: large)
    }

    /// Offen ist der Hinweis EINE Fläche: schon in der Menüleiste (auf Höhe
    /// der Kamera) so breit wie unten, mit runden Ecken; kein Hals mit
    /// Kasten darunter. Der Rand des Fensters um die Form bleibt leer.
    func testOpenFormIsOneShapeWithoutANeck() throws {
        let occupancy = NotchMenuBarOccupancy(frames: [])
        let band = NotchIslandGeometry.band(screen: screen, occupancy: occupancy, presentation: .compact(.leading))
        let form = NotchIslandLargeGeometry.form(screen: screen, kind: .alert, occupancy: occupancy)
        let canvas = NotchIslandLargeGeometry.canvas(form.frame, margin: NotchIslandLargeGeometry.overshootMargin).size
        let alert = NotchAlert(sessionID: UUID(), title: "Chat A", kind: .awaitingInput)
        let view = NotchStatusView(display: display(alert: alert, band: band, large: .open(form)))
            .frame(width: canvas.width, height: canvas.height)
        let image = try render(view, size: canvas, name: "offen")
        let mid = canvas.width / 2
        // Auf Höhe der Insel (Menüleiste) weit links und rechts der Kamera: schwarz.
        // 150 pt neben der Kamera: jenseits der runden Ecken, weit außerhalb jedes Halses.
        for y in [3, 30, 60, 104] as [CGFloat] {
            XCTAssertTrue(isBlack(image, mid - 150, y), "links bei y \(y)")
            XCTAssertTrue(isBlack(image, mid + 150, y), "rechts bei y \(y)")
        }
        XCTAssertTrue(isBlack(image, mid - 186, 54), "volle Breite in der Mitte der Höhe")
        XCTAssertTrue(isBlack(image, mid + 186, 54))
        // Runde Ecken und leerer Rand.
        XCTAssertTrue(isBackdrop(image, mid - 188, 2), "Ecke oben links")
        XCTAssertTrue(isBackdrop(image, mid + 188, 106), "Ecke unten rechts")
        XCTAssertTrue(isBackdrop(image, 6, 50), "Rand links")
        XCTAssertTrue(isBackdrop(image, mid, canvas.height - 6), "Rand unten")
        // Der Chat-Name steht da (heller Text in der Fläche).
        var bright = 0
        for x in stride(from: mid - 150, to: mid, by: 1) where brightness(image, x, 66) > 500 { bright += 1 }
        XCTAssertGreaterThan(bright, 8, "kein Text im Hinweis")
    }

    /// Zu (erstes Bild beim Aufgehen, letztes beim Zugehen) steht im großen
    /// Fenster nur die Kapsel an ihrer Stelle; alles andere ist leer, auch
    /// der Inhalt der offenen Form ist nicht zu sehen.
    func testClosedFormIsOnlyTheCapsule() throws {
        let occupancy = NotchMenuBarOccupancy(frames: [])
        let band = NotchIslandGeometry.band(screen: screen, occupancy: occupancy, presentation: .compact(.leading))
        let form = NotchIslandLargeGeometry.form(screen: screen, kind: .alert, occupancy: occupancy)
        let canvas = NotchIslandLargeGeometry.canvas(form.frame, margin: NotchIslandLargeGeometry.overshootMargin).size
        let seed = NotchIslandLargeGeometry.seedFrame(
            screen: screen, band: band, presentation: .compact(.leading), occupancy: occupancy)
        let outline = NotchIslandLargeGeometry.outline(of: seed, screen: screen)
        let alert = NotchAlert(sessionID: UUID(), title: "Chat A", kind: .awaitingInput)
        let view = NotchStatusView(display: display(alert: alert, band: band, large: .closed(form, outline: outline)))
            .frame(width: canvas.width, height: canvas.height)
        let image = try render(view, size: canvas, name: "zu")
        let capsule = outline.rect(in: CGRect(origin: .zero, size: canvas))
        XCTAssertTrue(isBlack(image, capsule.midX + 20, capsule.midY), "die Kapsel um die Kamera")
        XCTAssertTrue(isBackdrop(image, capsule.midX, capsule.minY - 1.5), "über der Kapsel")
        XCTAssertTrue(isBackdrop(image, capsule.minX - 12, capsule.midY), "Menü links der Kapsel")
        XCTAssertTrue(isBackdrop(image, capsule.maxX + 12, capsule.midY), "Menü rechts der Kapsel")
        for x in stride(from: CGFloat(20), to: canvas.width - 20, by: 12) {
            XCTAssertTrue(isBackdrop(image, x, 70), "unter der Menüleiste nichts bei x \(x)")
        }
    }

    /// Die Kopfzeile lässt Apples Insel die Mitte, und jede Seite behält
    /// ihren Platz, auch wenn die andere leer ist (ohne wartende Chats
    /// rutschte der rechte Inhalt sonst unter Apples Insel).
    func testHeaderSidesKeepTheirPlace() throws {
        var occupancy = NotchMenuBarOccupancy(frames: [])
        occupancy.systemIsland = 802...945
        let form = NotchIslandLargeGeometry.form(screen: screen, kind: .dictation, occupancy: occupancy)
        let size = CGSize(width: form.size.width, height: form.headerHeight)
        let marker = Rectangle().fill(Color.white).frame(width: 20, height: 10)
        func whiteRange(_ image: NSBitmapImageRep) -> ClosedRange<CGFloat>? {
            let xs = stride(from: CGFloat(0), to: size.width, by: 1).filter { self.brightness(image, $0, 17) > 700 }
            guard let first = xs.first, let last = xs.last else { return nil }
            return first...last
        }
        let padding = NotchIslandLargeGeometry.headerInset
        let onlyTrailing = try render(
            NotchIslandLargeHeader(form: form) { EmptyView() } trailing: { marker }.background(Color.black),
            size: size, name: "kopf-rechts")
        let right = try XCTUnwrap(whiteRange(onlyTrailing))
        XCTAssertEqual(right.upperBound, size.width - padding - 1, accuracy: 1.5)
        XCTAssertGreaterThan(right.lowerBound, size.width / 2 + form.slotTrailing - 1, "nicht unter Apples Insel")

        let onlyLeading = try render(
            NotchIslandLargeHeader(form: form) { marker } trailing: { EmptyView() }.background(Color.black),
            size: size, name: "kopf-links")
        let left = try XCTUnwrap(whiteRange(onlyLeading))
        XCTAssertEqual(left.lowerBound, padding, accuracy: 1.5)
        XCTAssertLessThan(left.upperBound, size.width / 2 - form.slotLeading + 1, "nicht unter Apples Insel")
    }

    /// Diktat aufgeklappt: Die Kapsel ist zur Form geworden. Neben der Form
    /// steht keine zweite Kapsel mit Wellenform mehr.
    func testOpenDictationHasNoSecondCapsule() throws {
        let occupancy = NotchMenuBarOccupancy(frames: [])
        let band = NotchIslandGeometry.band(screen: screen)
        let capsule = try XCTUnwrap(NotchIslandGeometry.dictationCapsule(screen: screen, occupancy: occupancy))
        let form = NotchIslandLargeGeometry.form(
            screen: screen, kind: .dictation, occupancy: occupancy,
            reserve: NotchIslandGeometry.dictationReserve(screen: screen, occupancy: occupancy))
        let size = CGSize(width: 608, height: 200)

        func image(open: Bool, name: String) throws -> NSBitmapImageRep {
            let controller = OverlayController(presentsWindow: false)
            controller.presentation = .island(band)
            controller.islandCapsule = capsule
            controller.islandDictationForm = form
            controller.isIslandExpanded = open
            let view = IslandDictationView(controller: controller, capsule: capsule, band: band)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            return try render(view, size: size, name: name)
        }
        let mid = size.width / 2
        let capsuleMidX = mid + capsule.offset
        let closed = try image(open: false, name: "diktat-zu")
        XCTAssertTrue(isBlack(closed, capsuleMidX + 30, band.topGap + 4), "die Kapsel neben der Insel")
        XCTAssertTrue(isBackdrop(closed, mid, 18), "über der Kamera zeichnen wir zugeklappt nichts")
        XCTAssertTrue(isBackdrop(closed, mid, 100), "unter der Menüleiste nichts")

        let open = try image(open: true, name: "diktat-offen")
        // Eine Fläche um die Kamera, 420 × 178 pt, ab der Oberkante.
        for y in [4, 40, 100, 170] as [CGFloat] {
            XCTAssertTrue(isBlack(open, mid - 170, y), "links bei y \(y)")
            XCTAssertTrue(isBlack(open, mid + 170, y), "rechts bei y \(y)")
        }
        XCTAssertTrue(isBackdrop(open, mid, 190), "unter der Form")
        XCTAssertTrue(isBackdrop(open, mid - 230, 18), "links neben der Form")
        // In der Zeile der Insel steht links nur die Kopfzeile, keine Wellenform der Kapsel.
        var colored = 0
        for x in stride(from: mid - 200, to: mid - 80, by: 1) where brightness(open, x, band.topGap + 16) > 120 {
            colored += 1
        }
        XCTAssertEqual(colored, 0, "die Wellenform der Kapsel steht nicht mehr da")
    }
}
