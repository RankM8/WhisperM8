import Observation
import SwiftUI

/// Gemessene Größe der Raster-Fläche. Ein eigenes beobachtbares Objekt statt
/// `@State` am Fenster: Das Schreiben beim Erscheinen und bei jedem
/// Größenwechsel werte sonst den ganzen Fensterbody samt Seitenleiste neu aus
/// — gemessen ein zweiter voller Durchlauf in jedem `grid.build`
/// (E2E-Befund 12.11.2026). Gelesen wird die Größe nur im Stufenwähler.
@MainActor
@Observable
final class GridAreaSizeBox {
    var size: CGSize = .zero

    /// Nur echte Änderungen schreiben — jeder Set löst sonst eine
    /// Neuauswertung des Wählers aus.
    func update(_ newSize: CGSize) {
        if size != newSize { size = newSize }
    }
}

/// Kompakter Stufen-Picker im Grid-Chrome (1 bis 9). Stufen, die nicht in
/// die gemessene Raster-Fläche passen (~240 pt je Spalte, ~200 pt je Zeile,
/// inkl. 1-px-Divider), werden ausgeblendet — die aktuelle Stufe bleibt immer
/// sichtbar. Eigene View, damit nur sie die Fläche beobachtet.
struct GridCapacityPicker: View {
    let entity: AgentGridWorkspace
    let area: GridAreaSizeBox
    let onSelect: (Int) -> Void

    var body: some View {
        let available = area.size
        HStack(spacing: 2) {
            ForEach(AgentGridWorkspace.allowedCapacities, id: \.self) { stage in
                if stage == entity.capacity || Self.stageFits(stage, in: available) {
                    Button {
                        onSelect(stage)
                    } label: {
                        Text(AgentChatsView.capacityLabel(stage))
                            .font(.system(size: 11, weight: stage == entity.capacity ? .bold : .medium).monospacedDigit())
                            .foregroundStyle(stage == entity.capacity ? AgentTheme.textPrimary : AgentTheme.textSecondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                stage == entity.capacity ? AgentTheme.accentTint : Color.clear,
                                in: RoundedRectangle(cornerRadius: 5)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Capacity \(AgentChatsView.capacityLabel(stage))")
                    .accessibilityLabel("Set capacity to \(AgentChatsView.capacityLabel(stage))")
                }
            }
        }
        .padding(3)
        .background(AgentTheme.header.opacity(0.92), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(AgentTheme.border, lineWidth: 1)
        }
    }

    static func stageFits(_ stage: Int, in size: CGSize) -> Bool {
        guard size.width > 0, size.height > 0 else { return true }
        let columns = CGFloat(AgentGridWorkspace.columns(forCapacity: stage))
        let rows = CGFloat(AgentGridWorkspace.rows(forCapacity: stage))
        return columns * GridSplitResolver.minPane + (columns - 1) <= size.width
            && rows * 200 + (rows - 1) <= size.height
    }
}
