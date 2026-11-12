import AppKit
import SwiftUI
import XCTest
@testable import WhisperM8

/// Kein Sprung beim Übergang: Das Ruhebild in der Diktat-Pille muss Pixel für
/// Pixel so aussehen wie die ruhende Pille, aus der es wächst (ohne Notch die
/// Status-Pille, an der Notch die Zeile unter der Aussparung). Beide werden so
/// verankert gerendert wie in ihren Fenstern.
@MainActor
final class UnifiedPillRestLookPixelTests: XCTestCase {
    private let summary = NotchSummary(working: 2, waiting: 1)

    private func pixels(_ view: some View, size: CGSize, name: String) throws -> NSBitmapImageRep {
        let png = try ViewSnapshotRenderer.pngData(
            view, size: size, appearance: .dark, background: Color(red: 0.5, green: 0.6, blue: 0.7))
        // Zum Nachsehen bei Abweichungen: Bilder ablegen.
        if let dir = ProcessInfo.processInfo.environment["WHISPERM8_PIXELTEST_DIR"] {
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        return try XCTUnwrap(NSBitmapImageRep(data: png))
    }

    /// Anteil abweichender Pixel. Toleranz zwölf Farbstufen: Die Status-Pille
    /// schneidet ihren Inhalt vor dem Schatten auf die Kapsel zu, die
    /// Diktat-Pille nicht; ihr Schatten weicht deshalb um bis zu zehn Stufen ab
    /// (schon vor dem Übergang so, im Fenster nicht zu sehen). Das Innere der
    /// Pille ist gleich.
    private func mismatch(_ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep) -> Double {
        guard lhs.pixelsWide == rhs.pixelsWide, lhs.pixelsHigh == rhs.pixelsHigh,
              lhs.bitsPerPixel == rhs.bitsPerPixel, lhs.bytesPerRow == rhs.bytesPerRow,
              let a = lhs.bitmapData, let b = rhs.bitmapData else { return 1 }
        let bytesPerPixel = lhs.bitsPerPixel / 8
        var differing = 0
        for y in 0..<lhs.pixelsHigh {
            for x in 0..<lhs.pixelsWide {
                let offset = y * lhs.bytesPerRow + x * bytesPerPixel
                for channel in 0..<bytesPerPixel where abs(Int(a[offset + channel]) - Int(b[offset + channel])) > 12 {
                    differing += 1
                    break
                }
            }
        }
        return Double(differing) / Double(lhs.pixelsWide * lhs.pixelsHigh)
    }

    private func restController(_ presentation: OverlayPresentation, _ look: UnifiedPillRestLook) -> OverlayController {
        let controller = OverlayController(presentsWindow: false)
        controller.presentation = presentation
        controller.pillAlignment = .center
        controller.restLook = look
        controller.showsRestLook = true
        return controller
    }

    func testPillRestLookMatchesTheStatusPill() throws {
        for alert in [nil, NotchAlert(sessionID: UUID(), title: "Jarvis: Supervisor", kind: .awaitingInput)] {
            let size = CGSize(width: OverlayFrameResolver.panelSize.width, height: 88)
            let display = NotchDisplay(style: .pill, summary: summary, alert: alert, isExpanded: false, sections: [])
            let status = try pixels(UnifiedStatusPillView(display: display), size: size, name: "pille-status-\(alert != nil)")
            let controller = restController(.pill, .pill(summary: summary, alert: alert))
            let rest = try pixels(
                RecordingOverlayView(controller: controller).environment(\.colorScheme, .dark), size: size,
                name: "pille-ruhebild-\(alert != nil)")
            XCTAssertLessThan(mismatch(status, rest), 0.001, "Ruhebild weicht von der Status-Pille ab (Hinweis: \(alert != nil))")
        }
    }

    func testNotchRestLookMatchesTheNotchStatus() throws {
        let notchWidth: CGFloat = 185
        let band: CGFloat = 32
        for alert in [nil, NotchAlert(sessionID: UUID(), title: "Jarvis: Supervisor", kind: .awaitingInput)] {
            let bodyWidth = alert == nil ? notchWidth : max(notchWidth, NotchGeometry.alertWidth)
            let size = CGSize(width: OverlayFrameResolver.panelSize.width, height: band + 40 + 24)
            let display = NotchDisplay(
                style: .notch(width: notchWidth, height: band), summary: summary, alert: alert,
                isExpanded: false, sections: [])
            let status = try pixels(
                ZStack(alignment: .top) {
                    Color.clear
                    NotchStatusView(display: display).frame(width: bodyWidth, height: band + NotchGeometry.chinHeight)
                },
                size: size, name: "notch-status-\(alert != nil)")
            let controller = restController(
                .notch(width: notchWidth, height: band), .notch(summary: summary, alert: alert, bodyWidth: bodyWidth))
            let rest = try pixels(
                RecordingOverlayView(controller: controller).environment(\.colorScheme, .dark), size: size,
                name: "notch-ruhebild-\(alert != nil)")
            XCTAssertLessThan(mismatch(status, rest), 0.001, "Ruhebild weicht von der Notch-Anzeige ab (Hinweis: \(alert != nil))")
        }
    }
}
