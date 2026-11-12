import SwiftUI

/// Dunkles Glas der Diktat-Pille (Prototyp `rgba(19,22,27,.86)`): Material
/// liefert den Blur, die Tönung drückt es Richtung Fast-Schwarz, dazu ein
/// feiner heller Rand. Gemeinsam genutzt von der Diktat-Pille, der Pille der
/// Notch-Anzeige auf Bildschirmen ohne Notch und der Controller-Insel dort —
/// alle drei sehen gleich aus. Die Form gibt der Aufrufer vor (Kapsel in
/// Ruhe, abgerundetes Rechteck für aufgeklappte Inhalte).
struct PillGlassBackground<S: InsettableShape>: View {
    let shape: S

    var body: some View {
        shape
            .fill(.thinMaterial)
            .overlay(shape.fill(OverlayPalette.glassTint))
            .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
    }
}

/// Maße und Schatten, die alle Pillen teilen.
enum PillGlass {
    /// Höhe der Pille in Ruhe (wie `PillMetrics.height` der Diktat-Pille).
    static let height: CGFloat = PillMetrics.height
    /// Eckenradius aufgeklappter Inhalte: so rund wie die halbe Pillenhöhe.
    static let cornerRadius: CGFloat = PillMetrics.height / 2
}

extension View {
    /// Schatten der Diktat-Pille. Braucht im Fenster Platz rundum (die
    /// Diktat-Pille hat dafür `OverlayFrameResolver.contentMargin`).
    func pillGlassShadow() -> some View {
        shadow(color: .black.opacity(0.3), radius: 12, x: 0, y: 3)
    }
}
