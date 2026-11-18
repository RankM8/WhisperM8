import SwiftUI

/// Zähler links und rechts der Kamera-Insel (Dynamic Island), in der Höhe der
/// Kapsel. In der Mitte bleibt die Aussparung frei: Dort zeichnet das System
/// die Insel über jedes Fenster. Die Zähler stehen zur Kamera hin
/// ausgerichtet; rechts bleibt Luft für die Mikrofon-Anzeige des Systems
/// (`NotchIslandGeometry.slotInnerGap`).
struct NotchIslandChipsRow: View {
    let band: NotchIslandBand
    let summary: NotchSummary

    private var chips: [(kind: NotchChip.Kind, count: Int)] {
        [(.working, summary.working), (.waiting, summary.waiting),
         (.errored, summary.errored), (.done, summary.freshDone)].filter { $0.count > 0 }
    }

    var body: some View {
        let chips = chips
        let split = NotchIslandGeometry.chipSplit(chipCount: chips.count)
        HStack(spacing: 0) {
            side(Array(chips.prefix(split.leading)), towardCamera: .trailing)
                .frame(width: band.leadingSlot, alignment: .trailing)
            Color.clear.frame(width: band.cutoutWidth)
            side(Array(chips.dropFirst(split.leading)), towardCamera: .leading)
                .frame(width: band.trailingSlot, alignment: .leading)
        }
        .frame(height: band.capsuleHeight)
        // Das Band wächst nur zu der Seite, auf der Zähler stehen.
        .offset(x: band.centerOffset)
    }

    private func side(_ chips: [(kind: NotchChip.Kind, count: Int)], towardCamera edge: HorizontalEdge) -> some View {
        HStack(spacing: NotchIslandGeometry.chipSpacing) {
            ForEach(chips, id: \.kind) { chip in
                NotchChip(kind: chip.kind, count: chip.count, palette: .notch)
                    .fixedSize()
                    .frame(width: NotchIslandGeometry.chipWidth, alignment: edge == .trailing ? .trailing : .leading)
            }
        }
        .padding(edge == .trailing ? .trailing : .leading, chips.isEmpty ? 0 : NotchIslandGeometry.slotInnerGap)
    }
}
