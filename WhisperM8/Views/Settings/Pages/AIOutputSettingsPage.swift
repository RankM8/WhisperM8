import SwiftUI

enum AIOutputPageTab: String, CaseIterable, Hashable {
    case account
    case modes
    case templates
    case testLab

    var title: String {
        switch self {
        case .account:
            return "Account & Defaults"
        case .modes:
            return "Modes"
        case .templates:
            return "Templates"
        case .testLab:
            return "Test Lab"
        }
    }
}

struct AIOutputSettingsPage: View {
    // Binding statt @State, damit Deep-Links (alte Routen modes/templates/testLab)
    // aus SettingsView den Tab auch bei offenem Fenster wechseln können.
    @Binding var selectedTab: AIOutputPageTab
    @State private var templateModel = TemplateEditorModel()

    init(selectedTab: Binding<AIOutputPageTab>) {
        self._selectedTab = selectedTab
    }

    private let tabs = AIOutputPageTab.allCases.map {
        SettingsTab(id: $0, title: $0.title)
    }

    var body: some View {
        SettingsPageContainer(
            title: "AI Output",
            subtitle: "One home for the whole AI pipeline: account, defaults, modes, templates, testing."
        ) {
            SettingsTabs(selection: $selectedTab, tabs: tabs)
            tabContent
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .account:
            AIOutputAccountTab()
        case .modes:
            AIOutputModesTab { templateID in
                templateModel.select(templateID)
                selectedTab = .templates
            }
        case .templates:
            AIOutputTemplatesTab(model: templateModel)
        case .testLab:
            AIOutputTestLabTab()
        }
    }
}
