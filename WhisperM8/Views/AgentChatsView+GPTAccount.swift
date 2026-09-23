import SwiftUI

/// Kontextmenue „GPT-Konto": stempelt einen Chat (oder die Auswahl) auf ein
/// anderes ChatGPT-Konto des GPT-Backends um. Anders als beim Claude-Konto
/// zieht dabei kein Transcript um — der Stempel wirkt beim naechsten Start
/// des Chats, weil der Konto-Header beim Spawn eingefroren wird.
/// Plan: docs/plans/gpt-account-switcher.md, Slice 4.
extension AgentChatsView {
    func canSwitchGPTAccount(_ session: AgentChatSession) -> Bool {
        session.provider == .claude
            && session.effectiveKind == .chat
            && AppPreferences.shared.claudeGPTBackendEnabled
            && AppPreferences.shared.isGPTAccountProfilesEnabled
    }

    @ViewBuilder
    func gptAccountMenu(_ session: AgentChatSession) -> some View {
        if canSwitchGPTAccount(session) {
            let group = actionGroup(for: session)
            let sessions = workspace.sessions.filter { group.contains($0.id) && canSwitchGPTAccount($0) }
            let currentProfiles = Set(sessions.map { $0.gptProfileName ?? GPTAccountProfiles.mainProfileName })
            let label = sessions.count == 1
                ? "GPT-Konto"
                : "\(sessions.count) Chats: GPT-Konto"
            Menu(label, systemImage: "person.crop.circle") {
                ForEach(GPTAccountProfiles().profiles()) { profile in
                    let isCurrent = currentProfiles == [profile.name]
                    Button {
                        setGPTAccount(sessions, toProfile: profile)
                    } label: {
                        if isCurrent {
                            Label(gptAccountLabel(profile), systemImage: "checkmark")
                        } else {
                            Text(gptAccountLabel(profile))
                        }
                    }
                    .disabled(!profile.isLoggedIn || isCurrent)
                }
                Divider()
                Text("Wirkt beim nächsten Start des Chats")
            }
        }
    }

    private func gptAccountLabel(_ profile: GPTAccountProfile) -> String {
        var parts = [profile.name]
        if let email = profile.emailAddress { parts.append(email) }
        if !profile.isLoggedIn { parts.append("nicht angemeldet") }
        return parts.joined(separator: " · ")
    }

    private func setGPTAccount(_ sessions: [AgentChatSession], toProfile profile: GPTAccountProfile) {
        do {
            try store.setGPTSessionProfile(
                ids: sessions.map(\.id),
                profileName: profile.isMain ? nil : profile.name
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
