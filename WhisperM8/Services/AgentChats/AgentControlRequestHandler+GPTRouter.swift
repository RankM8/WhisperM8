import Foundation

// Bitte des Router-Dienstes an die App: fehlende Proxy-Instanz eines
// GPT-Konto-Profils starten (503-Pfad). Im Router der App ruft der Router das
// direkt auf; der Dienst hat keinen Zugriff auf den Proxy-Manager.
//
// Der Control-Socket nimmt Anfragen jedes lokalen Prozesses des Nutzers an
// (auch aus Chats per CLI). Deshalb wirkt die Methode nur, wenn es den Dienst
// in diesem Lauf überhaupt gibt, Backend und Konto-Profile an sind und das
// Profil angemeldet ist — und sie startet nie den main-Proxy oder den Router.
extension AgentControlRequestHandler {
    static let gptRouterStartProfileMethod = "gptRouter.startProfile"

    enum GPTRouterStartProfileDecision: Equatable {
        case start(String)
        case refuse(String)
    }

    static func gptRouterStartProfileDecision(
        profile: String?,
        mode: ClaudeGPTRouterMode,
        backendEnabled: Bool,
        profilesEnabled: Bool,
        isLoggedIn: (String) -> Bool
    ) -> GPTRouterStartProfileDecision {
        guard mode == .service else { return .refuse("Router-Dienst ist in diesem Lauf nicht aktiv.") }
        guard backendEnabled else { return .refuse("GPT-Backend ist aus.") }
        guard profilesEnabled else { return .refuse("GPT-Konto-Profile sind aus.") }
        guard let profile, GPTAccountProfiles.isValidProfileName(profile),
              profile != GPTAccountProfiles.mainProfileName else {
            return .refuse("Ungültiges GPT-Profil.")
        }
        guard isLoggedIn(profile) else { return .refuse("GPT-Profil ist nicht angemeldet.") }
        return .start(profile)
    }

    func gptRouterStartProfile(_ request: ChatsControlRequest) -> ChatsControlResponse {
        let preferences = AppPreferences.shared
        let decision = Self.gptRouterStartProfileDecision(
            profile: request.params["profile"]?.stringValue,
            mode: ClaudeGPTRouterMode.current,
            backendEnabled: preferences.claudeGPTBackendEnabled,
            profilesEnabled: preferences.isGPTAccountProfilesEnabled,
            isLoggedIn: { GPTAccountProfiles().profile(named: $0).isLoggedIn }
        )
        switch decision {
        case .refuse(let reason):
            return .failure(requestID: request.requestID, code: .invalid, message: reason)
        case .start(let profile):
            guard ClaudeCodeProxyManager.shared.startProfileInstanceForRouterService(profile: profile) else {
                return .failure(requestID: request.requestID, code: .invalid, message: "GPT-Profil wird nicht gestartet.")
            }
            return .success(requestID: request.requestID, result: .object(["status": .string("starting")]))
        }
    }
}
