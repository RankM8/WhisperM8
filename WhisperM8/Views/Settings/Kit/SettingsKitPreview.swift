import SwiftUI

#Preview("SettingsKit Dark") {
    SettingsKitPreviewCatalog()
        .preferredColorScheme(.dark)
        .frame(width: 760)
        .padding(32)
        .background(AppTheme.background)
}

#Preview("SettingsKit Light") {
    SettingsKitPreviewCatalog()
        .preferredColorScheme(.light)
        .frame(width: 760)
        .padding(32)
        .background(AppTheme.background)
}

private struct SettingsKitPreviewCatalog: View {
    @State private var isEnabled = true
    @State private var pickerSelection = "clean"
    @State private var tabSelection = "modes"
    @State private var listSelection = "template"
    @State private var sliderValue = 0.42
    @State private var stepperValue = 8
    @State private var text = "Rewrite this transcript as concise release notes."

    private let pickerOptions = ["raw", "clean", "email"]
    private let tabs = [
        SettingsTab(id: "modes", title: "Modes"),
        SettingsTab(id: "templates", title: "Templates"),
        SettingsTab(id: "lab", title: "Test Lab")
    ]
    private let listItems = [
        SettingsListPanelItem(id: "mode", title: "Clean", subtitle: "Default"),
        SettingsListPanelItem(id: "template", title: "Release Notes", subtitle: "Custom"),
        SettingsListPanelItem(id: "report", title: "Daily Report", subtitle: "Built-in")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsTabs(selection: $tabSelection, tabs: tabs)

            SettingsSection("General") {
                SettingsToggleRow(
                    title: "Enable transcription cleanup",
                    subtitle: "Runs the selected mode after every recording.",
                    isOn: $isEnabled
                )

                SettingsPickerRow(
                    title: "Default output mode",
                    subtitle: "Used when the overlay has no explicit mode selected.",
                    selection: $pickerSelection,
                    options: pickerOptions
                ) { option in
                    Text(option.capitalized)
                }

                SettingsSliderRow(
                    title: "Target volume",
                    subtitle: "System audio level while recording.",
                    value: $sliderValue,
                    in: 0...1
                )

                SettingsStepperRow(
                    title: "Maximum screenshots",
                    subtitle: "Caps visual context per recording.",
                    value: $stepperValue,
                    in: 0...20,
                    format: .number
                )
            }

            SettingsSection("Status") {
                SettingsStatusRow(
                    title: "Codex CLI",
                    subtitle: "Used for local post-processing.",
                    tone: .ok,
                    detail: "Ready"
                ) {
                    Button("Check") {}
                        .buttonStyle(SettingsButtonStyle.standard)
                }

                SettingsButtonRow(title: "Template", subtitle: "Save or remove the selected template.") {
                    Button("Save") {}
                        .buttonStyle(SettingsButtonStyle.primary)
                    Button("Delete") {}
                        .buttonStyle(SettingsButtonStyle.destructive)
                }

                SettingsCopyCommandRow(command: "codex --version", caption: "Terminal command")
            }

            HStack(alignment: .top, spacing: 18) {
                SettingsListPanel(items: listItems, selection: $listSelection)
                VStack(alignment: .leading, spacing: 10) {
                    SettingsCodeBlock(text: "codex exec \"Summarize the current transcript\"", minHeight: 74)
                    SettingsTextArea(text: $text, minHeight: 86)
                    SettingsHelpText("Warnings use statusAwaiting and errors use statusError.", tone: .warning)
                }
            }
        }
    }
}
