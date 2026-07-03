import SwiftUI

struct AgentChatsAccessView: View {
    @AppStorage("defaultAgentProvider") private var defaultAgentProviderRaw = "claude"
    @AppStorage("isAutoChatRenameEnabled") private var isAutoChatRenameEnabled = true
    @AppStorage("isTerminalBellEnabled") private var isTerminalBellEnabled = true
    @AppStorage("codexExtraArguments") private var codexExtraArguments = ""
    @AppStorage("claudeExtraArguments") private var claudeExtraArguments = ""

    var body: some View {
        Form {
            Section("Agent Workspace") {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Agent Chats")
                            .font(.headline)
                        Text("Open the Codex and Claude session hub for project chats, resumes, and task follow-up.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        WindowRequestCenter.shared.request(.agentChats)
                    } label: {
                        Label("Open Agent Chats", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            Section("Standard-Provider") {
                Picker("Neuer Chat startet mit", selection: $defaultAgentProviderRaw) {
                    Text("Claude Code").tag("claude")
                    Text("Claude Agents").tag("claude-agents")
                    Text("Codex").tag("codex")
                }
                .pickerStyle(.segmented)

                Text("Bestimmt, welcher Provider beim 'Neuer Chat'-Button und beim Plus-Knopf eines Projekts genutzt wird. **Claude Agents** öffnet die Multi-Session-Dashboard-View statt eines einzelnen Chats.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Chat-Verhalten") {
                Toggle("Chats automatisch umbenennen", isOn: $isAutoChatRenameEnabled)
                Text("Nach dem ersten Turn-Ende wird der Titel via `claude -p` aus dem Transcript abgeleitet. Wenn aus: Default-Titel \"Claude Chat\"/\"Codex Chat\" bleibt bis du selbst umbenennst.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Terminal-Sounds erlauben", isOn: $isTerminalBellEnabled)
                Text("Manche TUI-Prompts senden ein Bell-Zeichen (`\\a`), das macOS als System-Ton spielt. Wenn aus: Terminal bleibt komplett still.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Fertig-Ton und Benachrichtigungen beim Turn-Ende sind zu **Claude Code** umgezogen (linke Seitenleiste).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Claude CLI · Extra-Argumente") {
                TextField("z. B. --dangerously-skip-permissions", text: $claudeExtraArguments)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())

                Text("Wird vorne an jeden `claude`-Aufruf angehängt — auch beim Resume bestehender Sessions. Whitespace-getrennt; Quotes erlaubt für Argumente mit Leerzeichen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Codex CLI · Extra-Argumente") {
                TextField("z. B. --ask-for-approval untrusted", text: $codexExtraArguments)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())

                Text("Wird vorne an jeden `codex`-Aufruf angehängt (vor `-C`/`-m`/`resume`). Whitespace-getrennt; Quotes erlaubt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
