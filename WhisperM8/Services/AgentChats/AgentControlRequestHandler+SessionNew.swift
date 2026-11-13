import Foundation

// MARK: - session.new (`whisperm8 chats new`)

extension AgentControlRequestHandler {
    /// Konto eines neuen Claude-Chats. Läuft abseits des Main Threads, weil die
    /// Prüfung den Keychain liest (ein `security`-Aufruf). Ohne `--account`
    /// gilt das in den Einstellungen aktive Konto; ist es weg, abgemeldet oder
    /// abgelaufen, scheitert der Start (`resolveNewChatAccount`).
    static func resolveNewChatAccount(requested: String?) throws -> ClaudeAccountProfiles.NewChatAccount {
        let profiles = ClaudeAccountProfiles()
        return try profiles.resolveNewChatAccount(
            requested: requested,
            followsActiveProfile: AppPreferences.shared.isChatsNewProfileDefaultEnabled,
            loginReading: { profiles.readLoginExpiry(forProfile: $0) })
    }

    func sessionNew(_ request: ChatsControlRequest) async -> ChatsControlResponse {
        guard let projectRef = request.params["project"]?.stringValue, !projectRef.isEmpty else {
            return .failure(requestID: request.requestID, code: .invalid, message: "project fehlt")
        }
        let providerRaw = request.params["provider"]?.stringValue ?? "claude"
        guard let provider = AgentProvider(rawValue: providerRaw) else {
            return .failure(requestID: request.requestID, code: .invalid, message: "provider muss claude|codex sein")
        }
        let title = request.params["title"]?.stringValue
        let prompt = request.params["prompt"]?.stringValue
        let requestedAccount = request.params["account"]?.stringValue

        // Konto VOR dem Anlegen festlegen und prüfen: eine Session, die im
        // falschen Konto entstanden ist, lässt sich nur noch per
        // Transcript-Umzug korrigieren — der Fehler gehört vor die Erstellung.
        var account: ClaudeAccountProfiles.NewChatAccount?
        switch provider {
        case .codex:
            if let requestedAccount, !requestedAccount.trimmingCharacters(in: .whitespaces).isEmpty {
                return .failure(requestID: request.requestID, code: .invalid,
                                message: "--account gilt nur für Claude-Chats (Codex kennt keine Claude-Konten)")
            }
        case .claude:
            do {
                account = try Self.resolveNewChatAccount(requested: requestedAccount)
            } catch {
                await audit(request.actor, method: "new", target: projectRef,
                            outcome: "account", prompt: nil)
                return .failure(requestID: request.requestID, code: .notFound,
                                message: error.localizedDescription)
            }
        }

        let selection: ClaudeProfileSelection = .explicit(account?.profileName)
        let result = await MainActor.run {
            AgentChatLaunchService().openChatViaControl(
                provider: provider, projectRef: projectRef, title: title, prompt: prompt,
                claudeProfile: selection)
        }
        switch result {
        case .failure(let error):
            return .failure(requestID: request.requestID, code: .notFound, message: error.message)
        case .success(let launch):
            var session: [String: Any] = [
                "id": launch.id.uuidString, "title": launch.title,
                "project": launch.projectName, "provider": provider.rawValue,
            ]
            var auditTarget = "\(launch.projectName)/\(launch.title)"
            if let account {
                // Der gespeicherte Stempel ist die Wahrheit, nicht die Anfrage.
                let label = launch.profileName ?? ClaudeAccountProfiles.mainProfileName
                session["account"] = label
                session["accountSource"] = account.source.rawValue
                auditTarget += " [\(label)]"
            }
            await audit(request.actor, method: "new", target: auditTarget, outcome: "ok", prompt: prompt)
            return .success(requestID: request.requestID, result: .object([
                "ok": true,
                "session": session,
            ]))
        }
    }
}
