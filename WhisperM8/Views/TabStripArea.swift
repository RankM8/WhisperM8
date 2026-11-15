import SwiftUI

/// Bereich der Tab-Leiste aus Streifen, Knöpfen dahinter und Griff-Fläche
/// (WM8-80, Paket 5). Er misst zwei Breiten für die Breitenregel: den ganzen
/// Bereich und die Knöpfe.
///
/// Warum es keinen Messkreislauf gibt:
/// - `.frame(minWidth: 0, maxWidth: .infinity)` macht den Bereich genau so
///   breit, wie das Fenster ihn anbietet. Ohne `minWidth: 0` nähme ein
///   flexibler Rahmen die Breite seines Inhalts als Untergrenze und wüchse mit
///   breiteren Tabs mit (so geschehen bei `gridAreaSize`).
/// - Die Knöpfe sind `fixedSize`, ihre Breite hängt nicht an den Tabs.
/// - Der Streifen bekommt höchstens `AgentTabWidthResolver
///   .stripViewportWidth`, also Bereich minus Knöpfe, beide Abstände und die
///   Mindestbreite der Griff-Fläche. Der Inhalt passt damit immer hinein.
/// Beide Messwerte hängen also nur am Fenster; die Tab-Breiten folgen aus
/// ihnen und wirken nicht zurück.
struct TabStripArea<Strip: View, Trailing: View>: View {
    /// Breite des Streifens; `nil` vor der ersten Messung.
    let stripWidth: CGFloat?
    var onMeasure: (_ areaWidth: CGFloat?, _ trailingWidth: CGFloat?) -> Void
    @ViewBuilder var strip: Strip
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: AgentTabWidthResolver.areaSpacing) {
            strip
                .frame(width: stripWidth)
            trailing
                .fixedSize()
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { onMeasure(nil, $0) }
            Spacer(minLength: AgentTabWidthResolver.dragAreaMinWidth)
                .windowDragArea(depth: TabStripBand.height)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        // `onGeometryChange` statt GeometryReader + Preference: Die Preference
        // kommt erst mit dem nächsten Update-Zyklus an; stößt danach nichts
        // einen an, bleibt der Startwert 0 stehen (im Test reproduziert,
        // 15.11.2026). Die Geometrie-Meldung folgt direkt dem Layout.
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { onMeasure($0, nil) }
    }
}
