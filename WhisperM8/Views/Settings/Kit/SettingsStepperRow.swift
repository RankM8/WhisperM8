import SwiftUI

struct SettingsStepperRow<Value: Strideable & Comparable, Format: FormatStyle>: View
where Value.Stride: SignedNumeric, Format.FormatInput == Value, Format.FormatOutput == String {
    let title: String
    let subtitle: String?
    @Binding var value: Value
    let range: ClosedRange<Value>
    let format: Format

    init(
        title: String,
        subtitle: String? = nil,
        value: Binding<Value>,
        in range: ClosedRange<Value>,
        format: Format
    ) {
        self.title = title
        self.subtitle = subtitle
        self._value = value
        self.range = range
        self.format = format
    }

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle) {
            Stepper(value: $value, in: range) {
                Text(value, format: format)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
    }
}
