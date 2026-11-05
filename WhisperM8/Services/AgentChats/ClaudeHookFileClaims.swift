import Foundation

/// Chats, für die dieser App-Prozess die Hook-Dateien angelegt hat.
///
/// Grund (Review Hook-Stufe 0, 05.11.2026): Das Aufräumen beim App-Start läuft
/// im Hintergrund, während wiederhergestellte Chats schon starten. Ohne
/// Abstimmung konnte es eine gerade neu angelegte Event-Datei löschen; der
/// Chat hätte dann für seine ganze Laufzeit kein `SessionStart` und keine
/// Neubindung nach `/clear` oder `/resume` mehr bekommen.
///
/// `ClaudeHookBridge.prepareSettingsFile` beansprucht die ID, bevor es die
/// Dateien anlegt. Das Aufräumen löscht nur unter demselben Lock und nur
/// unbeanspruchte IDs. Läuft gerade eine Löschung für dieselbe ID, wartet der
/// Launch die eine Datei ab und legt danach frisch an. Freigegeben wird nie:
/// Das Aufräumen läuft nur beim Start, und die Menge bleibt so klein wie die
/// Zahl der gestarteten Chats.
final class ClaudeHookFileClaims: @unchecked Sendable {
    static let shared = ClaudeHookFileClaims()

    private let lock = NSLock()
    private var claimed: Set<UUID> = []

    func claim(_ localSessionID: UUID) {
        lock.lock()
        claimed.insert(localSessionID)
        lock.unlock()
    }

    func isClaimed(_ localSessionID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return claimed.contains(localSessionID)
    }

    /// Führt `remove` nur für eine unbeanspruchte ID aus und hält dabei den
    /// Lock, damit kein Launch derselben ID dazwischenkommt.
    func removeUnlessClaimed(_ localSessionID: UUID, _ remove: () -> Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !claimed.contains(localSessionID) else { return false }
        return remove()
    }
}
