import SwiftUI

struct SettingsSliderRow: View {
    let title: String
    let subtitle: String?
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double?

    init(
        title: String,
        subtitle: String? = nil,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self._value = value
        self.range = range
        self.step = step
    }

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle) {
            slider
                .tint(AppTheme.accent)
                .frame(width: 180)
                .accessibilityLabel(Text(title))
        }
    }

    @ViewBuilder
    private var slider: some View {
        if let step {
            Slider(value: $value, in: range, step: step)
        } else {
            Slider(value: $value, in: range)
        }
    }
}
