import SwiftUI

/// Abhängigkeiten der MCP-Sektion — `.live` liest die echten Konten, Snapshots
/// geben feste Daten (Muster `TranscriptionSettingsDependencies`).
struct ClaudeMCPSyncDependencies {
    var snapshot: () -> ClaudeMCPSync.Snapshot
    var apply: (ClaudeMCPSync.Plan) async -> ClaudeMCPSync.Outcome

    static var live: Self {
        Self(
            snapshot: { ClaudeMCPSync().snapshot() },
            apply: { await ClaudeMCPSync().apply($0) }
        )
    }
}

/// „MCP Servers" auf der Konten-Seite: welcher Server fehlt in welchem Konto,
/// ein Knopf zum Verteilen und der Schalter für den Auto-Angleich beim Start.
/// Verteilt wird nur über `claude mcp add-json -s user` — nur ergänzen, nie löschen.
struct ClaudeMCPSyncSection: View {
    var dependencies: ClaudeMCPSyncDependencies = .live

    @AppStorage(PreferenceKeys.mcpAutoSyncEnabled) private var autoSync = false
    @State private var excluded: Set<String> = []
    @State private var snapshot = ClaudeMCPSync.Snapshot(profileNames: [], servers: [:])
    @State private var isSyncing = false
    @State private var feedback: String?

    private var plan: ClaudeMCPSync.Plan { ClaudeMCPSync.plan(snapshot, excluded: excluded) }

    var body: some View {
        SettingsSection("MCP Servers") {
            if snapshot.serverNames.isEmpty {
                SettingsHelpText("No user-level MCP servers in any account.")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(snapshot.serverNames, id: \.self) { server in
                        serverRow(server)
                    }
                }
                .padding(.vertical, 4)
            }

            SettingsButtonRow(
                title: plan.additions.isEmpty ? "All accounts have the same servers" : "Copy missing servers to all accounts",
                subtitle: plan.additions.isEmpty
                    ? "Nothing to do. Servers with different definitions per account are never copied."
                    : (plan.additions.count == 1
                        ? String(localized: "1 missing entry — added with Claude's own “claude mcp add-json -s user”. Never removes anything; servers that sign in with OAuth need a one-time /mcp login per account.")
                        : String(localized: "\(plan.additions.count) missing entries — added with Claude's own “claude mcp add-json -s user”. Never removes anything; servers that sign in with OAuth need a one-time /mcp login per account."))
            ) {
                Button {
                    syncNow()
                } label: {
                    isSyncing ? Text("Copying…") : Text("Copy")
                }
                .buttonStyle(SettingsButtonStyle.primary)
                .disabled(plan.additions.isEmpty || isSyncing)
            }

            SettingsToggleRow(
                title: "Sync automatically at launch",
                subtitle: "Adds servers that are missing in an account each time WhisperM8 starts. Only adds, never removes — to drop a server, remove it in every account.",
                isOn: $autoSync
            )

            if let feedback {
                SettingsHelpText(feedback)
            }
        }
        .onAppear {
            excluded = Set(AppPreferences.shared.mcpSyncExcludedServers)
            snapshot = dependencies.snapshot()
        }
    }

    @ViewBuilder
    private func serverRow(_ server: String) -> some View {
        let missing = snapshot.missingProfiles(for: server)
        let isExcluded = excluded.contains(server)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: statusSymbol(missing: missing, server: server, isExcluded: isExcluded))
                .foregroundStyle(statusColor(missing: missing, server: server, isExcluded: isExcluded))
                .frame(width: 14)
            Text(settingsLocalized: server)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
            Text(settingsLocalized: statusText(missing: missing, server: server, isExcluded: isExcluded))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button {
                toggleExclusion(server)
            } label: {
                isExcluded ? Text("Include") : Text("Exclude")
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }

    private func statusText(missing: [String], server: String, isExcluded: Bool) -> String {
        if isExcluded { return "excluded — stays per account" }
        if snapshot.hasConflict(server) { return "different definitions per account — not copied" }
        if plan.manual.contains(server) {
            return String(localized: "contains secrets — set it up manually in \(missing.joined(separator: ", ")) (never passed on the command line)")
        }
        if missing.isEmpty { return "in all accounts" }
        return String(localized: "missing in \(missing.joined(separator: ", "))")
    }

    private func statusSymbol(missing: [String], server: String, isExcluded: Bool) -> String {
        if isExcluded { return "minus.circle" }
        if snapshot.hasConflict(server) || plan.manual.contains(server) { return "exclamationmark.triangle" }
        return missing.isEmpty ? "checkmark.circle" : "circle.dashed"
    }

    private func statusColor(missing: [String], server: String, isExcluded: Bool) -> Color {
        if isExcluded { return .secondary }
        if snapshot.hasConflict(server) || plan.manual.contains(server) { return .orange }
        return missing.isEmpty ? .green : .secondary
    }

    private func toggleExclusion(_ server: String) {
        var list = AppPreferences.shared.mcpSyncExcludedServers
        if let index = list.firstIndex(of: server) {
            list.remove(at: index)
        } else {
            list.append(server)
        }
        AppPreferences.shared.mcpSyncExcludedServers = list
        excluded = Set(list)
    }

    private func syncNow() {
        let plan = self.plan
        isSyncing = true
        feedback = nil
        Task { @MainActor in
            let outcome = await dependencies.apply(plan)
            isSyncing = false
            snapshot = dependencies.snapshot()
            if outcome.failed.isEmpty {
                feedback = outcome.added.count == 1
                    ? String(localized: "Added 1 server entry.")
                    : String(localized: "Added \(outcome.added.count) server entries.")
            } else {
                let sample = outcome.failed.prefix(3).map { "\($0.addition.server) → \($0.addition.profile): \($0.message)" }
                feedback = String(localized: "Added \(outcome.added.count), failed \(outcome.failed.count): \(sample.joined(separator: "; "))")
            }
        }
    }
}
