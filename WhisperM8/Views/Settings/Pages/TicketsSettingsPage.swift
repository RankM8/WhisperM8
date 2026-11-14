import AppKit
import SwiftUI

/// Einstellungen › Tickets (Labs): Schalter für die Ticket-Ansicht, Zugang zu
/// Linear je Workspace und die Zuordnung Projektordner → Team.
///
/// Solange der Schalter aus ist, fragt die Seite weder den Schlüsselbund noch
/// Linear. Gelesen und geschrieben wird im Modell, abseits des Main Threads.
struct TicketsSettingsPage: View {
    @AppStorage(PreferenceKeys.ticketBoardEnabled) private var enabled = false
    @State private var model: TicketsSettingsModel
    @State private var keyText = ""
    @State private var keyRevealed = false
    @State private var selectedProject = ""
    @State private var selectedTeam = ""
    @State private var workspacePendingRemoval: String?

    private let dependencies: TicketsSettingsDependencies

    init(dependencies: TicketsSettingsDependencies = .live, model: TicketsSettingsModel? = nil) {
        self.dependencies = dependencies
        _model = State(initialValue: model ?? TicketsSettingsModel(dependencies: dependencies))
    }

    var body: some View {
        SettingsPageContainer(
            title: "Tickets",
            subtitle: "Experimental: tickets from Linear and the chats working on them."
        ) {
            SettingsLabsNotice("Reads tickets from Linear to show which chat works on which ticket. WhisperM8 never changes tickets from here. Off by default; while it is off, the app reads nothing from Linear or the Keychain. The whisperm8 tickets command works either way.")

            SettingsSection("Ticket view") {
                SettingsToggleRow(
                    title: "Show tickets in Agent Chats",
                    subtitle: "Adds a Tickets view to the Agent Chats window: board and backlog of the project's team, with the chat working on each ticket.",
                    isOn: $enabled
                )
            }

            SettingsHelpText("While the switch is on, a ticket button sits in the title band of the Agent Chats window, next to the sidebar button. It switches between chats and tickets.")

            if enabled {
                accessSection
                mappingSection
            } else {
                SettingsHelpText("Turn the ticket view on above to set up access and projects.")
            }
        }
        .task(id: enabled) {
            if enabled {
                await model.load()
            } else {
                // Aus heißt: nichts mehr lesen, und kein getippter Key bleibt liegen.
                model.stop()
                keyText = ""
            }
        }
        .onChange(of: model.teamChoices) { _, choices in
            if !choices.contains(where: { $0.id == selectedTeam }) { selectedTeam = "" }
        }
        .confirmationDialog(
            Text("Remove the Linear key?"),
            isPresented: Binding(
                get: { workspacePendingRemoval != nil },
                set: { if !$0 { workspacePendingRemoval = nil } }
            ),
            presenting: workspacePendingRemoval
        ) { workspace in
            Button("Remove Key", role: .destructive) {
                Task { await model.removeKey(workspace: workspace) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { workspace in
            Text("WhisperM8 and `whisperm8 tickets` lose access to the workspace \(workspace). Projects stay linked to their teams.")
        }
    }

    // MARK: Zugang

    private var accessSection: some View {
        SettingsSection("Linear access") {
            ForEach(model.workspaces) { workspace in
                TicketsWorkspaceRow(workspace: workspace) {
                    workspacePendingRemoval = workspace.name
                }
            }

            SettingsRow(
                title: "API key",
                subtitle: "One key per workspace. The workspace is taken from the key itself."
            ) {
                HStack(spacing: 8) {
                    FocusableTextField(
                        text: $keyText,
                        placeholder: String(localized: "Linear API key..."),
                        isSecure: !keyRevealed,
                        onSubmit: saveKey
                    )
                    // `isSecure` tauscht die AppKit-Klasse; die Identität muss wechseln.
                    .id(keyRevealed)
                    .frame(width: 260, height: 24)

                    Button {
                        keyRevealed.toggle()
                    } label: {
                        TicketsKeyRevealIcon(isRevealed: keyRevealed)
                    }
                    .buttonStyle(.plain)
                    .help(Text("Show or hide the key"))
                    .accessibilityLabel(Text("Show or hide the key"))
                }
            }

            if !keyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                SettingsRow(title: "Check and save") {
                    Button("Check with Linear and Save", action: saveKey)
                        .buttonStyle(SettingsButtonStyle.primary)
                        .disabled(model.isSavingKey)
                }
            }

            switch model.keyNotice {
            case .saved(let text):
                SettingsHelpText(text)
            case .failed(let text):
                SettingsHelpText(text, tone: .error)
            case nil:
                SettingsHelpText("Create a personal API key in Linear under Settings › Security & access. WhisperM8 checks it with Linear and keeps it in the macOS Keychain.")
            }
        }
    }

    private func saveKey() {
        guard !model.isSavingKey else { return }
        let typed = keyText
        Task {
            // Das Feld erst nach Erfolg leeren: Ein Tippfehler lässt sich so korrigieren.
            if await model.saveKey(typed) { keyText = "" }
        }
    }

    // MARK: Zuordnung

    private var mappingSection: some View {
        SettingsSection("Projects and teams") {
            ForEach(model.mappings) { mapping in
                TicketsMappingRow(mapping: mapping) {
                    Task { await model.removeMapping(path: mapping.path) }
                }
            }

            if model.teamChoices.isEmpty {
                SettingsHelpText("No teams yet. They appear here once a key is saved and working.")
            } else {
                SettingsRow(title: "Link a project", subtitle: "Chats in this folder, and in worktrees below it, belong to the team.") {
                    HStack(spacing: 8) {
                        Picker(selection: $selectedProject) {
                            Text("Choose project").tag("")
                            ForEach(model.unmappedProjects) { project in
                                Text(verbatim: project.name).tag(project.path)
                            }
                            if !selectedProject.isEmpty, !model.unmappedProjects.contains(where: { $0.path == selectedProject }) {
                                Text(verbatim: TicketsSettingsText.shortPath(selectedProject)).tag(selectedProject)
                            }
                        } label: {
                            Text("Project")
                        }
                        .labelsHidden()
                        .frame(maxWidth: 170)

                        Picker(selection: $selectedTeam) {
                            Text("Choose team").tag("")
                            ForEach(model.teamChoices) { choice in
                                Text(verbatim: "\(choice.team) · \(choice.workspace)").tag(choice.id)
                            }
                        } label: {
                            Text("Team")
                        }
                        .labelsHidden()
                        .frame(maxWidth: 170)
                    }
                }
                SettingsRow(title: "Other folder", subtitle: "For a project that has no chats in WhisperM8 yet.") {
                    HStack(spacing: 8) {
                        Button("Choose Folder…") {
                            if let folder = dependencies.chooseFolder() { selectedProject = TicketConfig.normalized(folder) }
                        }
                        .buttonStyle(SettingsButtonStyle.standard)

                        Button("Link", action: assign)
                            .buttonStyle(SettingsButtonStyle.primary)
                            .disabled(selectedProject.isEmpty || selectedTeam.isEmpty)
                    }
                }
            }

            if let problem = model.mappingProblem {
                SettingsHelpText(problem, tone: .error)
            }
            if !model.teamChoices.isEmpty {
                SettingsHelpText("A chat only changes tickets in the workspace of its own project. Reading works everywhere.")
            }
        }
    }

    private func assign() {
        guard let choice = model.teamChoices.first(where: { $0.id == selectedTeam }), !selectedProject.isEmpty else { return }
        let path = selectedProject
        Task {
            if await model.assign(projectPath: path, to: choice) {
                selectedProject = ""
                selectedTeam = ""
            }
        }
    }
}

// MARK: - Zeilen

private struct TicketsWorkspaceRow: View {
    let workspace: TicketsSettingsModel.Workspace
    let remove: () -> Void

    var body: some View {
        // Titel und Untertitel laufen durch den Katalog. Die Adresse statt des
        // bloßen Kürzels kann dort kein Schlüssel sein.
        SettingsStatusRow(
            title: TicketsSettingsText.address(of: workspace.name),
            subtitle: subtitle,
            tone: tone,
            detail: detail
        ) {
            if workspace.hasKey {
                // Neutral: Auf einer Seite, auf der alles in Ordnung ist, soll das
                // Entfernen nicht das Auffälligste sein. Die Rückfrage kommt ohnehin.
                Button("Remove Key…", action: remove)
                    .buttonStyle(SettingsButtonStyle.standard)
            }
        }
    }

    private var tone: SettingsStatusTone {
        if !workspace.hasKey { return .warn }
        return workspace.problem == nil ? .ok : .error
    }

    private var detail: String {
        if !workspace.hasKey { return String(localized: "No key") }
        return workspace.problem == nil ? String(localized: "Connected") : String(localized: "Not working")
    }

    private var subtitle: String? {
        if !workspace.hasKey { return String(localized: "Paste a key of this workspace below to restore access.") }
        if let problem = workspace.problem { return problem }
        if workspace.teams.isEmpty { return String(localized: "No teams visible with this key.") }
        return String(localized: "Teams: \(workspace.teams.joined(separator: ", "))")
    }
}

private struct TicketsMappingRow: View {
    let mapping: TicketsSettingsModel.Mapping
    let remove: () -> Void

    var body: some View {
        // Der Pfad als Titel: Ein bloßer Ordnername liefe durch den Katalog und
        // könnte dort ein Schlüssel sein (ein Ordner „Link“ hieße „Zuordnen“).
        SettingsRow(title: TicketsSettingsText.shortPath(mapping.path)) {
            HStack(spacing: 10) {
                Text(verbatim: target)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(mapping.workspace == nil ? AppTheme.statusAwaiting : AppTheme.textSecondary)
                Button("Remove", action: remove)
                    .buttonStyle(SettingsButtonStyle.standard)
            }
        }
    }

    private var target: String {
        guard let workspace = mapping.workspace else {
            return String(localized: "\(mapping.team) · no workspace")
        }
        return "\(mapping.team) · \(workspace)"
    }
}

private struct TicketsKeyRevealIcon: View {
    let isRevealed: Bool

    var body: some View {
        Group {
            if isRevealed {
                Image(systemName: "eye.slash")
            } else {
                Image(systemName: "eye")
            }
        }
        .font(.system(size: 12.5, weight: .medium))
        .foregroundStyle(AppTheme.textSecondary)
        .frame(width: 24, height: 24)
        .background(AppTheme.control)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - Helfer

enum TicketsSettingsText {
    /// Adresse eines Workspaces, so wie Linear sie zeigt.
    static func address(of workspace: String) -> String {
        ["linear.app", workspace].joined(separator: "/")
    }

    /// Pfad mit `~` statt des Home-Ordners.
    static func shortPath(_ path: String, home: String = NSHomeDirectory()) -> String {
        path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

}

enum TicketsSettingsFolderPicker {
    @MainActor
    static func choose() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
