import Foundation

// Bitte des Router-Dienstes an die App: fehlende Proxy-Instanz eines
// GPT-Konto-Profils starten (503-Pfad). Im Router der App ruft der Router das
// direkt auf; der Dienst hat keinen Zugriff auf den Proxy-Manager.
extension AgentControlRequestHandler {
    static let gptRouterStartProfileMethod = "gptRouter.startProfile"

    func gptRouterStartProfile(_ request: ChatsControlRequest) -> ChatsControlResponse {
        guard let profile = request.params["profile"]?.stringValue,
              GPTAccountProfiles.isValidProfileName(profile),
              profile != GPTAccountProfiles.mainProfileName else {
            return .failure(requestID: request.requestID, code: .invalid, message: "Ungültiges GPT-Profil.")
        }
        // Wie im Router der App: nur angemeldete Profile, Start im Hintergrund.
        guard GPTAccountProfiles().profile(named: profile).isLoggedIn else {
            return .failure(requestID: request.requestID, code: .invalid, message: "GPT-Profil ist nicht angemeldet.")
        }
        ClaudeCodeProxyManager.shared.startInstanceInBackground(profile: profile)
        return .success(requestID: request.requestID, result: .object(["status": .string("starting")]))
    }
}
