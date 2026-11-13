import AppKit
import SwiftUI
import XCTest
@testable import WhisperM8

/// Kein Sprung beim Übergang: Das Ruhebild in der Diktat-Pille muss Pixel für
/// Pixel so aussehen wie die ruhende Pille, aus der es wächst (ohne Notch die
/// Status-Pille, an der Notch die Zeile unter der Aussparung). Beide Seiten
/// stehen nebeneinander in EINEM Bild (links Status, rechts Ruhebild, oben
/// ohne, unten mit Hinweis), jede Zelle so verankert wie im Fenster; danach
/// werden die Hälften verglichen. Ein Bild je Darstellung hält den Test billig.
@MainActor
final class UnifiedPillRestLookPixelTests: XCTestCase {
    private let summary = NotchSummary(working: 2, waiting: 1)
    private let alerts: [NotchAlert?] = [nil, NotchAlert(sessionID: UUID(), title: "Jarvis: Supervisor", kind: .awaitingInput)]

    /// Zelle wie ein Fenster: Inhalt oben links mit der ganzen Fläche (eine
    /// Ausrichtungslinie der Pille wirkt so nicht über die Zelle hinaus).
    private static func cell(_ content: some View, _ size: CGSize) -> some View {
        GeometryReader { _ in content }.frame(width: size.width, height: size.height)
    }

    private func render(_ view: some View, cell size: CGSize, name: String) throws -> NSBitmapImageRep {
        let png = try ViewSnapshotRenderer.pngData(
            view, size: CGSize(width: size.width * 2, height: size.height * CGFloat(alerts.count)),
            appearance: .dark, background: Color(red: 0.5, green: 0.6, blue: 0.7), scale: 2, settle: 0)
        // Zum Nachsehen bei Abweichungen: Bild ablegen.
        if let dir = ProcessInfo.processInfo.environment["WHISPERM8_PIXELTEST_DIR"] {
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        return try XCTUnwrap(NSBitmapImageRep(data: png))
    }

    /// Anteil abweichender Pixel zwischen linker und rechter Zelle einer
    /// Zeile, Toleranz drei Farbstufen (Kantenglättung). Früher zwölf: Die
    /// Diktat-Pille schnitt ihren Inhalt nicht vor dem Schatten zu und warf
    /// je Ebene einen Schatten; im Fenster, über dem echten Hintergrund, war
    /// sie dadurch sichtbar dunkler (Aufnahme 13.11.2026). Seitdem sind beide
    /// gleich gebaut.
    private func mismatch(_ image: NSBitmapImageRep, row: Int, tolerance: Int = 3) -> Double {
        guard let data = image.bitmapData else { return 1 }
        let bytesPerPixel = image.bitsPerPixel / 8
        let cellWidth = image.pixelsWide / 2
        let cellHeight = image.pixelsHigh / alerts.count
        var differing = 0
        for y in (row * cellHeight)..<((row + 1) * cellHeight) {
            for x in 0..<cellWidth {
                let left = y * image.bytesPerRow + x * bytesPerPixel
                let right = left + cellWidth * bytesPerPixel
                for channel in 0..<bytesPerPixel where abs(Int(data[left + channel]) - Int(data[right + channel])) > tolerance {
                    differing += 1
                    break
                }
            }
        }
        return Double(differing) / Double(cellWidth * cellHeight)
    }

    /// Schutz gegen ein leeres Bild: In jeder linken Zelle steht eine dunkle Pille.
    private func darkPixels(_ image: NSBitmapImageRep, row: Int) -> Int {
        guard let data = image.bitmapData else { return 0 }
        let bytesPerPixel = image.bitsPerPixel / 8
        let cellHeight = image.pixelsHigh / alerts.count
        var dark = 0
        for y in (row * cellHeight)..<((row + 1) * cellHeight) {
            for x in 0..<(image.pixelsWide / 2) {
                let offset = y * image.bytesPerRow + x * bytesPerPixel
                if Int(data[offset]) + Int(data[offset + 1]) + Int(data[offset + 2]) < 120 { dark += 1 }
            }
        }
        return dark
    }

    private static func restController(_ presentation: OverlayPresentation, _ look: UnifiedPillRestLook) -> OverlayController {
        let controller = OverlayController(presentsWindow: false)
        controller.presentation = presentation
        controller.pillAlignment = .center
        controller.restLook = look
        controller.showsRestLook = true
        return controller
    }

    func testPillRestLookMatchesTheStatusPill() throws {
        try assertPillRestLookMatchesTheStatusPill(solidBlack: false, name: "pille")
    }

    /// Einstellung „Tiefschwarzer Hintergrund“: Beide Seiten zeichnen dasselbe
    /// Schwarz, der Übergang bleibt deckungsgleich.
    func testPillRestLookMatchesTheStatusPillInSolidBlack() throws {
        try assertPillRestLookMatchesTheStatusPill(solidBlack: true, name: "pille-schwarz")
    }

    private func assertPillRestLookMatchesTheStatusPill(solidBlack: Bool, name: String) throws {
        let size = CGSize(width: OverlayFrameResolver.panelSize.width, height: 88)
        let summary = summary
        let alerts = alerts
        let view = VStack(spacing: 0) {
            ForEach(Array(alerts.enumerated()), id: \.offset) { _, alert in
                HStack(spacing: 0) {
                    Self.cell(UnifiedStatusPillView(display: NotchDisplay(
                        style: .pill, summary: summary, alert: alert, isExpanded: false, sections: [])), size)
                    Self.cell(RecordingOverlayView(controller: Self.restController(.pill, .pill(summary: summary, alert: alert)))
                        .environment(\.colorScheme, .dark), size)
                }
            }
        }
        .environment(\.pillSolidBlackOverride, solidBlack)
        let image = try render(view, cell: size, name: name)
        for row in alerts.indices {
            XCTAssertGreaterThan(darkPixels(image, row: row), 2000, "keine Pille gezeichnet (Zeile \(row))")
            XCTAssertLessThan(mismatch(image, row: row), 0.001, "Ruhebild weicht von der Status-Pille ab (Zeile \(row))")
        }
    }

    func testNotchRestLookMatchesTheNotchStatus() throws {
        let notchWidth: CGFloat = 185
        let band: CGFloat = 32
        let size = CGSize(width: OverlayFrameResolver.panelSize.width, height: band + 40 + 24)
        let summary = summary
        let alerts = alerts
        let view = VStack(spacing: 0) {
            ForEach(Array(alerts.enumerated()), id: \.offset) { _, alert in
                let bodyWidth = alert == nil ? notchWidth : max(notchWidth, NotchGeometry.alertWidth)
                let display = NotchDisplay(
                    style: .notch(width: notchWidth, height: band), summary: summary, alert: alert,
                    isExpanded: false, sections: [])
                HStack(spacing: 0) {
                    // Notch-Fenster: so breit wie der Körper, oben bündig, mittig über der Notch.
                    Self.cell(HStack {
                        Spacer(minLength: 0)
                        NotchStatusView(display: display).frame(width: bodyWidth, height: band + NotchGeometry.chinHeight)
                        Spacer(minLength: 0)
                    }, size)
                    Self.cell(RecordingOverlayView(controller: Self.restController(
                        .notch(width: notchWidth, height: band),
                        .notch(summary: summary, alert: alert, bodyWidth: bodyWidth)))
                        .environment(\.colorScheme, .dark), size)
                }
            }
        }
        let image = try render(view, cell: size, name: "notch")
        for row in alerts.indices {
            XCTAssertGreaterThan(darkPixels(image, row: row), 2000, "keine Notch-Zeile gezeichnet (Zeile \(row))")
            XCTAssertLessThan(mismatch(image, row: row), 0.001, "Ruhebild weicht von der Notch-Anzeige ab (Zeile \(row))")
        }
    }
}
