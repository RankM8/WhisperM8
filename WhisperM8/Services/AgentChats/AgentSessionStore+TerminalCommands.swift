import Foundation

// Terminal-Tabs mit festem Befehl (`chats new --provider terminal --command`).
extension AgentSessionStore {
    /// Vic: Ein per CLI angelegter Befehls-Tab, der nie gezeigt wurde, startete
    /// seinen Befehl sonst beim ersten Anzeigen, auch Tage später. Tabs aus
    /// einem früheren App-Lauf starten deshalb nicht mehr von selbst; sie
    /// zeigen den Befehl und einen Knopf zum Starten.
    func expirePendingTerminalCommands(createdBefore appLaunch: Date) throws {
        try mutateWorkspaceIfChanged { workspace in
            var changed = false
            for index in workspace.sessions.indices
            where Self.terminalCommandExpires(workspace.sessions[index], appLaunch: appLaunch) {
                workspace.sessions[index].shouldLaunchOnOpen = false
                changed = true
            }
            return changed
        }
    }

    /// Startzeit dieses App-Prozesses, einmal gelesen.
    static let appLaunchedAt: Date? = ProcessStartTime.of(pid: getpid())

    static func terminalCommandExpires(_ session: AgentChatSession, appLaunch: Date) -> Bool {
        session.isTerminal && session.terminalCommand?.isEmpty == false && !session.hasLaunchedInitialPrompt
            && session.shouldLaunchOnOpen == true && session.createdAt < appLaunch
    }
}

/// Führt eine Arbeit genau einmal aus, solange sie gelingt (scheitert sie,
/// darf der nächste Aufruf es erneut versuchen).
final class OncePerLaunch: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    var hasRun: Bool {
        lock.lock(); defer { lock.unlock() }
        return done
    }

    func run(_ work: () throws -> Void) rethrows {
        lock.lock()
        if done { lock.unlock(); return }
        lock.unlock()
        try work()
        lock.lock(); done = true; lock.unlock()
    }
}

extension AgentSessionStore {
    /// Vic: Der Verfall lief bei jedem schnellen Laden unter dem Store-Lock über
    /// alle Sitzungen. Nach dem ersten Durchgang je App-Lauf kann nichts mehr
    /// verfallen (neue Tabs sind jünger als der App-Start), also einmal.
    static let pendingTerminalCommandExpiry = OncePerLaunch()
}
