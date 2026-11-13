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
    /// PID des PTY-Prozesses je Session. Ein Token gilt nur für Aufrufer, in
    /// deren Prozesskette diese PID steht (Review-Befund 11.11.2026): Claudes
    /// Daemon erbt Umgebung samt Token, ist aber kein Nachfahre der PTY.
    private var processIDsBySession: [UUID: Int32] = [:]
    /// Sessions, in deren PTY nur ein `claude attach`-Client läuft.
    private var attachSessions = Set<UUID>()

    private init() {}

    /// Erzeugt (oder ersetzt) das Token einer Session und gibt es zurück.
    func issueToken(for sessionID: UUID) -> String {
        let token = Self.randomToken()
        lock.lock()
        tokensBySession[sessionID] = token
        lock.unlock()
        return token
    }

    /// Übernommener Chat (Neustart ohne Chatverlust): Der Prozess läuft weiter
    /// und hat sein Token in der Umgebung; die neue App trägt es samt PID aus
    /// dem Manifest wieder ein. Sonst scheiterten alle `whisperm8 chats`-,
    /// `board`- und `speak`-Aufrufe aus dem überlebenden Chat.
    func register(token: String, for sessionID: UUID, pid: Int32, isAttach: Bool) {
        guard !token.isEmpty else { return }
        lock.lock()
        tokensBySession[sessionID] = token
        processIDsBySession[sessionID] = pid
        if isAttach { attachSessions.insert(sessionID) } else { attachSessions.remove(sessionID) }
        lock.unlock()
    }

    /// `true`, wenn `token` das aktuelle Token dieser Session ist.
    func verify(sessionID: UUID, token: String?) -> Bool {
        guard let token, !token.isEmpty else { return false }
        lock.lock()
        let expected = tokensBySession[sessionID]
        lock.unlock()
        return expected == token
    }

    /// Nach dem Spawn: PID der PTY und ob dort nur ein Attach-Client läuft.
    func bindProcess(sessionID: UUID, pid: Int32, isAttach: Bool) {
        lock.lock()
        processIDsBySession[sessionID] = pid
        if isAttach { attachSessions.insert(sessionID) } else { attachSessions.remove(sessionID) }
        lock.unlock()
    }

    /// PID der laufenden PTY einer Session, sonst `nil`.
    func processID(for sessionID: UUID) -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        return processIDsBySession[sessionID]
    }

    /// Sessions, deren Tab gerade nur an einen Hintergrund-Agent angedockt ist.
    func attachSessionIDs() -> Set<UUID> {
        lock.lock()
        defer { lock.unlock() }
        return attachSessions
    }

    func revoke(sessionID: UUID) {
        lock.lock()
        tokensBySession.removeValue(forKey: sessionID)
        processIDsBySession.removeValue(forKey: sessionID)
        attachSessions.remove(sessionID)
        lock.unlock()
    }

    /// Widerruft das Token nur, wenn es noch DAS ist, das der endende PTY-Lauf
    /// bekam — ein schon neu gestarteter Lauf derselben Session (Resume) hat ein
    /// frisches Token, das ein spätes `processTerminated` nicht treffen darf.
    func revoke(sessionID: UUID, ifToken token: String) {
        lock.lock()
        if tokensBySession[sessionID] == token {
            tokensBySession.removeValue(forKey: sessionID)
            processIDsBySession.removeValue(forKey: sessionID)
            attachSessions.remove(sessionID)
        }
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
