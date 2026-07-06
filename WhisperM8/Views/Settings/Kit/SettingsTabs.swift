import SwiftUI

struct SettingsTab<ID: Hashable>: Identifiable, Hashable {
    let id: ID
    let title: String

    init(id: ID, title: String) {
        self.id = id
        self.title = title
    }
}

struct SettingsTabSelectionModel<ID: Hashable>: Equatable where ID: Equatable {
    var tabs: [SettingsTab<ID>]
    var selection: ID

    init(tabs: [SettingsTab<ID>], selection: ID) {
        self.tabs = tabs
        self.selection = selection
        normalize()
    }

    var resolvedSelection: ID {
        // Leere Tab-Liste darf nicht crashen: dann bleibt die Selektion wie sie ist.
        tabs.first(where: { $0.id == selection })?.id ?? tabs.first?.id ?? selection
    }

    mutating func select(_ id: ID) {
        // Unbekannte ID fällt auf den ersten Tab zurück; nur die leere Liste
        // behält die bestehende Selektion (Crash-Schutz, Review Phase 2).
        selection = tabs.contains(where: { $0.id == id }) ? id : (tabs.first?.id ?? selection)
    }

    mutating func normalize() {
        selection = resolvedSelection
    }
}

struct SettingsTabs<ID: Hashable>: View {
    @Binding var selection: ID
    let tabs: [SettingsTab<ID>]

    init(selection: Binding<ID>, tabs: [SettingsTab<ID>]) {
        self._selection = selection
        self.tabs = tabs
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                Button {
                    selection = tab.id
                } label: {
                    Text(tab.title)
                        .font(.system(size: 12, weight: isSelected(tab) ? .semibold : .medium))
                        .foregroundStyle(isSelected(tab) ? Color.white : AppTheme.textSecondary)
                        .frame(minWidth: 86)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(isSelected(tab) ? AppTheme.accentStrong : AppTheme.control)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(AppTheme.control)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        }
        .onAppear(perform: normalizeSelection)
        .onChange(of: tabs) { _, _ in normalizeSelection() }
    }

    private func isSelected(_ tab: SettingsTab<ID>) -> Bool {
        tab.id == selection
    }

    private func normalizeSelection() {
        guard !tabs.isEmpty else { return }
        if !tabs.contains(where: { $0.id == selection }) {
            selection = tabs[0].id
        }
    }
}
