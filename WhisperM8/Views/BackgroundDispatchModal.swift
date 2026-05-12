import SwiftUI

/// Liste der Permission-Modes, die wir im Modal anbieten. Reihenfolge ist
/// "least surprising first" — Default = vom cwd geerbter Mode.
private let backgroundPermissionModes: [(value: String?, label: String, hint: String)] = [
    (nil, "Default", "Nutzt defaultMode aus den Settings des Projekts."),
    ("acceptEdits", "acceptEdits", "Auto-Approve fuer Edits + Standard-FS-Commands."),
    ("plan", "plan", "Verlangt Approval vor Execution."),
    ("auto", "auto", "Auto-Mode-Classifier entscheidet pro Tool."),
    ("dontAsk", "dontAsk", "Nichts ueberhalb der Allow-Liste — gut fuer streng abgeschottete Runs."),
    ("bypassPermissions", "bypassPermissions", "Skipped alle Permission-Prompts (vorher 1x interaktiv aktivieren).")
]

/// Wird vom Caller zurueckgegeben, wenn der User auf "Starten" klickt.
struct BackgroundDispatchRequest: Equatable {
    let prompt: String
    let subAgent: String?
    let permissionMode: String?
}

/// Modaler SwiftUI-Sheet zum Spawnen eines neuen Hintergrund-Agents.
///
/// Drei Kontrollen: Prompt (Multiline), Sub-Agent-Picker (auf Basis von
/// `SubAgentDiscovery`), Permission-Mode-Picker. Submit ist Cmd+Enter,
/// Esc schliesst.
struct BackgroundDispatchModal: View {
    let project: AgentProject
    let availableSubAgents: [SubAgent]
    var onCancel: () -> Void
    var onDispatch: (BackgroundDispatchRequest) -> Void

    @State private var prompt: String = ""
    @State private var selectedSubAgentID: String? = nil
    @State private var permissionMode: String? = nil
    @FocusState private var promptFocused: Bool

    private var trimmedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool { !trimmedPrompt.isEmpty }

    private var selectedSubAgent: SubAgent? {
        guard let id = selectedSubAgentID else { return nil }
        return availableSubAgents.first(where: { $0.id == id })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            promptField

            permissionModeField

            if !availableSubAgents.isEmpty {
                subAgentGrid
            }

            footer
        }
        .padding(24)
        .frame(width: 580)
        .background(AgentTheme.panel)
        .onAppear { promptFocused = true }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.horizontal.circle")
                    .foregroundStyle(.orange)
                    .font(.system(size: 16, weight: .semibold))
                Text("Neuer Hintergrund-Agent")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AgentTheme.textPrimary)
            }
            Text("\(project.name) · \(project.path)")
                .font(.system(size: 11))
                .foregroundStyle(AgentTheme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: - Prompt

    private var promptField: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel("Initialer Prompt")
            TextEditor(text: $prompt)
                .focused($promptFocused)
                .font(.system(size: 13))
                .frame(minHeight: 90, maxHeight: 140)
                .padding(8)
                .background(AgentTheme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(AgentTheme.border, lineWidth: 1)
                )
                .cornerRadius(6)
                .overlay(alignment: .topLeading) {
                    if prompt.isEmpty {
                        Text("z. B. „Untersuch warum der CI-Test flaky ist und öffne einen PR\"")
                            .font(.system(size: 13))
                            .foregroundStyle(AgentTheme.textTertiary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 14)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    // MARK: - Permission

    private var permissionModeField: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel("Permission Mode")
            Picker("", selection: permissionModeBinding) {
                ForEach(backgroundPermissionModes, id: \.label) { mode in
                    Text(mode.label).tag(mode.value)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 240, alignment: .leading)

            if let hint = backgroundPermissionModes.first(where: { $0.value == permissionMode })?.hint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(AgentTheme.textTertiary)
            }
        }
    }

    /// SwiftUI's Picker mag `Optional<String>` als Tag, aber wir muessen das
    /// Binding ueber den Optional-Wrap fuehren. Ein expliziter Binding hilft.
    private var permissionModeBinding: Binding<String?> {
        Binding(
            get: { permissionMode },
            set: { permissionMode = $0 }
        )
    }

    // MARK: - Sub-Agent Library

    private var subAgentGrid: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                fieldLabel("Sub-Agent (optional)")
                Spacer()
                Text("\(availableSubAgents.count) verfügbar")
                    .font(.system(size: 11))
                    .foregroundStyle(AgentTheme.textTertiary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 8)], spacing: 8) {
                noneTile
                ForEach(availableSubAgents) { agent in
                    agentTile(agent)
                }
            }
        }
    }

    private var noneTile: some View {
        let isSelected = selectedSubAgentID == nil
        return Button {
            selectedSubAgentID = nil
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle().fill(AgentTheme.textTertiary).frame(width: 7, height: 7)
                    Text("Kein Sub-Agent")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AgentTheme.textPrimary)
                }
                Text("Default Claude — keine Spezialisierung.")
                    .font(.system(size: 10))
                    .foregroundStyle(AgentTheme.textTertiary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? AgentTheme.selection : AgentTheme.control.opacity(0.5))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.orange : AgentTheme.border, lineWidth: 1)
            )
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    private func agentTile(_ agent: SubAgent) -> some View {
        let isSelected = selectedSubAgentID == agent.id
        let swatch = swatchColor(for: agent.color)
        return Button {
            selectedSubAgentID = agent.id
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle().fill(swatch).frame(width: 7, height: 7)
                    Text("@\(agent.name)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AgentTheme.textPrimary)
                        .lineLimit(1)
                    if agent.scope == .project {
                        Text("PROJ")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.orange)
                    }
                }
                Text(agent.description ?? "(keine Beschreibung)")
                    .font(.system(size: 10))
                    .foregroundStyle(AgentTheme.textTertiary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? AgentTheme.selection : AgentTheme.control.opacity(0.5))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.orange : AgentTheme.border, lineWidth: 1)
            )
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .help(agent.fileURL.path)
    }

    private func swatchColor(for raw: String?) -> Color {
        guard let raw, !raw.isEmpty else { return AgentTheme.textTertiary }
        // Hex-Form akzeptieren, sonst per Name auf Palette mappen.
        if raw.hasPrefix("#") {
            return Color(hex: raw)
        }
        switch raw.lowercased() {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "cyan", "blue": return .blue
        case "purple", "magenta": return .purple
        case "pink": return .pink
        default: return AgentTheme.textSecondary
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if let agent = selectedSubAgent, agent.isolationWorktree {
                Label("läuft in eigenem Worktree", systemImage: "square.stack.3d.up")
                    .font(.system(size: 11))
                    .foregroundStyle(AgentTheme.textTertiary)
            }
            Spacer()
            Button("Abbrechen", role: .cancel) { onCancel() }
                .keyboardShortcut(.cancelAction)
            Button {
                submit()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill")
                    Text("Hintergrund-Agent starten")
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canSubmit)
        }
    }

    private func submit() {
        guard canSubmit else { return }
        onDispatch(
            BackgroundDispatchRequest(
                prompt: trimmedPrompt,
                subAgent: selectedSubAgent?.name,
                permissionMode: permissionMode
            )
        )
    }

    // MARK: - Helpers

    private func fieldLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.04)
            .foregroundStyle(AgentTheme.textTertiary)
    }
}
