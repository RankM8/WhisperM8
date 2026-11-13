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

    /// `result.session` von `session.new`. `account` steht immer drin: der
    /// Name des Claude-Kontos (auch `main`) bzw. `null` bei Codex-Chats, die
    /// kein Claude-Konto haben (bis 13.11.2026 stand dort fälschlich `main`).
    /// Maßgeblich ist der gespeicherte Stempel, nicht die Anfrage.
    static func sessionNewPayload(
        id: UUID, title: String, projectName: String, provider: AgentProvider,
        storedProfile: String?, account: ClaudeAccountProfiles.NewChatAccount?
    ) -> [String: Any] {
        var session: [String: Any] = [
            "id": id.uuidString, "title": title,
            "project": projectName, "provider": provider.rawValue,
            "account": NSNull(),
        ]
        if provider == .claude, let account {
            session["account"] = storedProfile ?? ClaudeAccountProfiles.mainProfileName
            session["accountSource"] = account.source.rawValue
        }
        return session
    }

    /// Ergebnis von `startSessionNew`.
    enum SessionNewStart {
        /// Abgelehnt, bevor irgendetwas angelegt wurde. `auditOutcome` = nil:
        /// reiner Bedienfehler, kein Audit-Eintrag.
        case rejected(ChatsControlErrorCode, String, auditOutcome: String?)
        /// `launch` wurde (genau einmal) aufgerufen.
        case launched(
            Result<AgentChatLaunchService.ControlLaunchResult, ControlLaunchError>,
            account: ClaudeAccountProfiles.NewChatAccount?)
    }

    /// Kontoentscheidung von `session.new`, getrennt vom Anlegen.
    ///
    /// Das Konto wird VOR dem Anlegen festgelegt und geprüft: eine Session,
    /// die im falschen Konto entstanden ist, lässt sich nur noch per
    /// Transcript-Umzug korrigieren — der Fehler gehört vor die Erstellung.
    /// Scheitert die Kontowahl, wird `launch` nie aufgerufen. Gelingt sie,
    /// bekommt `launch` immer eine ausdrückliche Wahl (`.explicit`), nie
    /// `.activeDefault` — sonst könnte der Store still ein anderes Konto
    /// nehmen als das geprüfte.
    static func startSessionNew(
        provider: AgentProvider,
        requestedAccount: String?,
        resolveAccount: (String?) throws -> ClaudeAccountProfiles.NewChatAccount,
        launch: (ClaudeProfileSelection) async -> Result<AgentChatLaunchService.ControlLaunchResult, ControlLaunchError>
    ) async -> SessionNewStart {
        var account: ClaudeAccountProfiles.NewChatAccount?
        switch provider {
        case .codex:
            if let requestedAccount, !requestedAccount.trimmingCharacters(in: .whitespaces).isEmpty {
                return .rejected(.invalid,
                                 "--account gilt nur für Claude-Chats (Codex kennt keine Claude-Konten)",
                                 auditOutcome: nil)
            }
        case .claude:
            do {
                account = try resolveAccount(requestedAccount)
            } catch {
                return .rejected(.notFound, error.localizedDescription, auditOutcome: "account")
            }
        }
        return .launched(await launch(.explicit(account?.profileName)), account: account)
    }

    func sessionNew(_ request: ChatsControlRequest) async -> ChatsControlResponse {
        guard let projectRef = request.params["project"]?.stringValue, !projectRef.isEmpty else {
            return .failure(requestID: request.requestID, code: .invalid, message: "project fehlt")
        }
        let providerRaw = request.params["provider"]?.stringValue ?? "claude"
        let title = request.params["title"]?.stringValue
        let prompt = request.params["prompt"]?.stringValue
        let requestedAccount = request.params["account"]?.stringValue
        if providerRaw == "terminal" {
            return await terminalNew(request, projectRef: projectRef, title: title)
        }
        guard let provider = AgentProvider(rawValue: providerRaw) else {
            return .failure(requestID: request.requestID, code: .invalid, message: "provider muss claude|codex|terminal sein")
        }

        let start = await Self.startSessionNew(
            provider: provider, requestedAccount: requestedAccount,
            resolveAccount: Self.resolveNewChatAccount(requested:),
            launch: { selection in
                await MainActor.run {
                    AgentChatLaunchService().openChatViaControl(
                        provider: provider, projectRef: projectRef, title: title, prompt: prompt,
                        claudeProfile: selection)
                }
            })
        let account: ClaudeAccountProfiles.NewChatAccount?
        let result: Result<AgentChatLaunchService.ControlLaunchResult, ControlLaunchError>
        switch start {
        case .rejected(let code, let message, let auditOutcome):
            if let auditOutcome {
                await audit(request.actor, method: "new", target: projectRef,
                            outcome: auditOutcome, prompt: nil)
            }
            return .failure(requestID: request.requestID, code: code, message: message)
        case .launched(let launchResult, let resolved):
            account = resolved
            result = launchResult
        }
        switch result {
        case .failure(let error):
            return .failure(requestID: request.requestID, code: .notFound, message: error.message)
        case .success(let launch):
            let session = Self.sessionNewPayload(
                id: launch.id, title: launch.title, projectName: launch.projectName,
                provider: provider, storedProfile: launch.profileName, account: account)
            var auditTarget = "\(launch.projectName)/\(launch.title)"
            if let label = session["account"] as? String { auditTarget += " [\(label)]" }
            await audit(request.actor, method: "new", target: auditTarget, outcome: "ok", prompt: prompt)
            return .success(requestID: request.requestID, result: .object([
                "ok": true,
                "session": session,
            ]))
        }
    }

    /// `chats new --provider terminal [--command "…"]`: Terminal-Tab wie aus dem
    /// Menü, mit Befehl als `/bin/sh -c` statt Login-Shell. Gestartet wird
    /// beim Anzeigen des Tabs (wie jeder Chat); die CLI meldet, ob er schon läuft.
    private func terminalNew(_ request: ChatsControlRequest, projectRef: String, title: String?) async -> ChatsControlResponse {
        let command = request.params["command"]?.stringValue
        if request.params["account"]?.stringValue?.isEmpty == false {
            return .failure(requestID: request.requestID, code: .invalid,
                            message: "--account gilt nur für Claude-Chats")
        }
        let result = await MainActor.run {
            AgentChatLaunchService().openChatViaControl(
                provider: .claude, projectRef: projectRef, title: title, prompt: nil,
                claudeProfile: .explicit(nil), terminalCommand: command, asTerminal: true)
        }
        switch result {
        case .failure(let error):
            return .failure(requestID: request.requestID, code: .notFound, message: error.message)
        case .success(let launch):
            // Der Befehl selbst gehört nicht ins Audit (kann Pfade, Tokens enthalten).
            await audit(request.actor, method: "new", target: "\(launch.projectName)/\(launch.title) [terminal]",
                        outcome: "ok", prompt: nil)
            return .success(requestID: request.requestID, result: .object([
                "ok": true,
                "session": [
                    "id": launch.id.uuidString, "title": launch.title, "project": launch.projectName,
                    "provider": "terminal", "kind": "terminal", "account": NSNull(),
                    "hasCommand": command?.isEmpty == false,
                ] as [String: Any],
            ]))
        }
    }
}
