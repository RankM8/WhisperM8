import Foundation

// MARK: - Session-Token-Registry

/// Pro PTY-Lauf ein frisches Zufalls-Token, das die App beim Spawn in die
/// Umgebung injiziert (`WHISPERM8_SESSION_TOKEN`). Beim Control-Request beweist
/// das Token, dass der Aufruf wirklich aus dieser Session-PTY stammt — die
/// nackte `WHISPERM8_SESSION_ID` wäre spoofbar (jeder Prozess des Users kann
/// sie raten).
///
/// Ehrliche Einordnung: Das ist Rechenschaft + Versehens-Schutz, keine
/// Security-Boundary gegen einen absichtlich bösartigen Prozess desselben
/// Users — der könnte auch direkt die App bedienen.
final class AgentSessionTokenRegistry: @unchecked Sendable {
    static let shared = AgentSessionTokenRegistry()

    private let lock = NSLock()
    private var tokensBySession: [UUID: String] = [:]

    private init() {}

    /// Erzeugt (oder ersetzt) das Token einer Session und gibt es zurück.
    func issueToken(for sessionID: UUID) -> String {
        let token = Self.randomToken()
        lock.lock()
        tokensBySession[sessionID] = token
        lock.unlock()
        return token
    }

    /// `true`, wenn `token` das aktuelle Token dieser Session ist.
    func verify(sessionID: UUID, token: String?) -> Bool {
        guard let token, !token.isEmpty else { return false }
        lock.lock()
        let expected = tokensBySession[sessionID]
        lock.unlock()
        return expected == token
    }

    func revoke(sessionID: UUID) {
        lock.lock()
        tokensBySession.removeValue(forKey: sessionID)
        lock.unlock()
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            // Fail-closed statt vorhersagbarem Null-Token (GPT-Review):
            // UUIDs nutzen einen eigenen CSPRNG-Pfad und sind als Fallback
            // ausreichend zufällig für dieses Rechenschafts-Token.
            return (UUID().uuidString + UUID().uuidString)
                .replacingOccurrences(of: "-", with: "")
        }
        return Data(bytes).base64EncodedString()
    }
}
