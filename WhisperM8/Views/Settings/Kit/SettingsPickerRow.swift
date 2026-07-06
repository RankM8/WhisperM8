import SwiftUI

struct SettingsPickerRow<Option: Hashable, Label: View>: View {
    let title: String
    let subtitle: String?
    @Binding var selection: Option
    let options: [Option]
    @ViewBuilder let label: (Option) -> Label

    init(
        title: String,
        subtitle: String? = nil,
        selection: Binding<Option>,
        options: [Option],
        @ViewBuilder label: @escaping (Option) -> Label
    ) {
        self.title = title
        self.subtitle = subtitle
        self._selection = selection
        self.options = options
        self.label = label
    }

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle) {
            Picker("", selection: $selection) {
                ForEach(options, id: \.self) { option in
                    label(option)
                        .tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }
}
