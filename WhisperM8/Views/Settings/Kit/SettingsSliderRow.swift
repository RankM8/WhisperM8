import SwiftUI

struct SettingsSliderRow: View {
    let title: String
    let subtitle: String?
    @Binding var value: Double
    let range: ClosedRange<Double>

    init(
        title: String,
        subtitle: String? = nil,
        value: Binding<Double>,
        in range: ClosedRange<Double>
    ) {
        self.title = title
        self.subtitle = subtitle
        self._value = value
        self.range = range
    }

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle) {
            Slider(value: $value, in: range)
                .tint(AppTheme.accent)
                .frame(width: 180)
        }
    }
}
