import SwiftUI

/// Hinweis, solange Workspace-Änderungen nicht gespeichert werden konnten
/// (LR-AK-005). Der Store wiederholt selbst mit Backoff; der Knopf stößt
/// sofort einen Versuch an.
struct WorkspacePersistenceBanner: View {
    @State private var model = AgentWorkspaceUIModel.shared

    var body: some View {
        if model.persistenceFailing {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(AgentTheme.statusAwaiting)
                    .accessibilityHidden(true)
                Text("Your changes could not be saved yet. Trying again automatically.")
                    .font(.system(size: 12))
                    .foregroundStyle(AgentTheme.textPrimary)
                Spacer(minLength: 8)
                Button("Retry now") { model.retryPersist() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(AgentTheme.panel, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(AgentTheme.border, lineWidth: 1))
            .padding(.horizontal, 12)
            .padding(.top, 44)
        }
    }
}
