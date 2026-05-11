import SwiftUI

struct OutputDashboardView: View {
    @Environment(AppState.self) private var appState
    @State private var selection: OutputDashboardSection? = .overview

    var body: some View {
        NavigationSplitView {
            List(OutputDashboardSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            switch selection ?? .overview {
            case .overview:
                OutputOverviewView()
                    .environment(appState)
            case .reports:
                TranscriptReportsView()
            case .tasks:
                TaskReportsView()
            case .modes:
                OutputModesView()
            case .templates:
                OutputTemplatesView()
            case .codex:
                CodexSettingsView()
            case .testLab:
                OutputTestLabView()
            }
        }
        .frame(minWidth: 860, minHeight: 620)
    }
}
