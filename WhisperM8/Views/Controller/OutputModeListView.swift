import SwiftUI

/// Liste aller wählbaren Ausgabemodi über der Aufnahme-Pill, solange der
/// Modus per Controller gewechselt wird. Der aktuelle Modus trägt denselben
/// Akzentrahmen wie die Markierung im Controller-Menü. Kein Bestätigen: Der
/// Wechsel gilt sofort, die Liste zeigt nur, wo man steht.
///
/// Gleiche Optik wie die Pill (dunkles Glas, immer dunkel).
struct OutputModeListView: View {
    let modes: [OutputMode]
    let selectedID: String

    static let width: CGFloat = 240
    static let rowHeight: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Output mode")
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(Color.white.opacity(0.55))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 2)
            ForEach(modes) { mode in
                row(mode, marked: mode.id == selectedID)
            }
        }
        .padding(6)
        .frame(width: Self.width, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.thinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(OverlayPalette.glassTint))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
                )
        }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Output mode"))
    }

    private func row(_ mode: OutputMode, marked: Bool) -> some View {
        Text(verbatim: mode.name)
            .font(.system(size: 13, weight: marked ? .semibold : .regular))
            .foregroundStyle(marked ? Color.white : Color.white.opacity(0.75))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .frame(height: Self.rowHeight)
            .background {
                if marked {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(AppTheme.accentTint)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(AppTheme.accent, lineWidth: 2)
                        )
                }
            }
            .accessibilityAddTraits(marked ? .isSelected : [])
    }
}
