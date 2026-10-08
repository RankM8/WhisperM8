import AppKit
import SwiftUI

/// Rendert Ansichten offscreen als PNG — für die UI-Snapshot-Galerie der Tests
/// (`scripts/ui-snapshots.sh`) und das Fenster-Foto des Debug-Steuerkanals.
///
/// Weg über `NSHostingView` in einem unsichtbaren Fenster + `cacheDisplay`,
/// NICHT `ImageRenderer`: der zeichnet AppKit-gestützte Bedienelemente
/// (Toggle, Picker, TextField) auf macOS nur als Platzhalter. `cacheDisplay`
/// zeichnet die echten Controls, braucht keine Bildschirmaufnahme-Berechtigung
/// und berührt kein sichtbares Fenster.
@MainActor
enum ViewSnapshotRenderer {
    enum Appearance: String, CaseIterable, Sendable {
        case light
        case dark

        var appearanceName: NSAppearance.Name {
            switch self {
            case .light: return .aqua
            case .dark: return .darkAqua
            }
        }
    }

    enum RenderError: LocalizedError {
        case emptyBounds
        case bitmapUnavailable
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .emptyBounds: return "Die Ansicht hat keine Fläche."
            case .bitmapUnavailable: return "Bitmap für den Snapshot konnte nicht angelegt werden."
            case .encodingFailed: return "PNG-Kodierung fehlgeschlagen."
            }
        }
    }

    /// Rendert eine SwiftUI-Ansicht in fester Größe. `settle` lässt den Run
    /// Loop kurz laufen, damit `onAppear`/`.task` und nachgelagerte
    /// Layout-Durchläufe fertig sind — deshalb nur in Tests/Werkzeugen, nie
    /// aus einem Event-Handler der laufenden App aufrufen.
    static func pngData<Content: View>(
        _ view: Content,
        size: CGSize,
        appearance: Appearance,
        background: Color = AppTheme.background,
        scale: CGFloat = 2,
        settle: TimeInterval = 0.15
    ) throws -> Data {
        // Hintergrund explizit: `cacheDisplay` zeichnet nur die View, nicht
        // den Fensterhintergrund — dunkle Snapshots wären sonst transparent.
        let root = view
            .frame(width: size.width, height: size.height)
            .background(background)
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance.appearanceName)
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }

        host.layoutSubtreeIfNeeded()
        if settle > 0 {
            RunLoop.main.run(until: Date().addingTimeInterval(settle))
        }
        host.layoutSubtreeIfNeeded()
        return try pngData(of: host, scale: scale)
    }

    /// Zeichnet eine vorhandene NSView (z. B. den Inhalt eines offenen
    /// Fensters) in eine Bitmap mit `scale`-facher Pixeldichte.
    static func pngData(of view: NSView, scale: CGFloat = 2) throws -> Data {
        let bounds = view.bounds
        guard bounds.width >= 1, bounds.height >= 1 else { throw RenderError.emptyBounds }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((bounds.width * scale).rounded()),
            pixelsHigh: Int((bounds.height * scale).rounded()),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { throw RenderError.bitmapUnavailable }
        // Punktgröße = View-Größe, Pixel = scale-fach → scharfe Schrift.
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw RenderError.encodingFailed
        }
        return png
    }
}
