import SwiftUI

/// Gemeinsame Kennung des Kerns: Ruhe-Kern und Diktat-Kern sind beim
/// Übergang ein und derselbe Kern, der mitgleitet und die Farbe wechselt.
enum PillMorphID {
    static let core = "pill-core"
}

extension AnyTransition {
    /// Zähler und Hinweis des Ruhebilds: beim Wachsen schnell weg, damit sie
    /// nicht unter ✓ und ✕ stehen bleiben; beim Zurückziehen erst gegen Ende
    /// da, wenn die Pille wieder schmal ist. Nur Deckkraft, keine Bewegung.
    static let pillRestContent = AnyTransition.asymmetric(
        insertion: .opacity.animation(.easeOut(duration: 0.15).delay(0.2)),
        removal: .opacity.animation(.easeOut(duration: 0.1)))
}

/// Ruhebild in der Diktat-Pille: genau das, was die ruhende Pille an dieser
/// Stelle zeigt. Aus ihm wächst das Diktat, in es zieht es sich zurück
/// (`UnifiedPillMorph`). Hülle, Höhe und Rand setzt `RecordingPillView`; hier
/// steht nur der Inhalt, aus denselben Bausteinen wie die Status-Anzeige
/// (`PillRestCoreView`, `UnifiedPillRestStatus`, `NotchHeaderRow`). Keine
/// Knöpfe: In diesen Momenten liegt die Status-Pille darüber bzw. nimmt das
/// Fenster keine Klicks an.
struct UnifiedPillRestLookView: View {
    let look: UnifiedPillRestLook
    let presentation: OverlayPresentation
    let morphSpace: Namespace.ID

    var body: some View {
        switch look {
        case .pill(let summary, let alert):
            PillRestCoreView()
                .matchedGeometryEffect(id: PillMorphID.core, in: morphSpace)
                .padding(.leading, 2)
                .transition(.opacity)
            UnifiedPillRestStatus(summary: summary, alert: alert)
                .transition(.pillRestContent)
        case .notch(let summary, let alert, let bodyWidth):
            NotchHeaderRow(display: NotchDisplay(
                style: notchStyle, summary: summary, alert: alert, isExpanded: false, sections: []))
                .padding(.horizontal, 12)
                .frame(width: bodyWidth)
                .transition(.pillRestContent)
        case .notchBand:
            // Nur das Band in der Aussparung, schwarz auf schwarz.
            Color.clear.frame(width: 0, height: 0)
        }
    }

    private var notchStyle: NotchDisplay.Style {
        if case .notch(let width, let height) = presentation { return .notch(width: width, height: height) }
        return .pill
    }
}
