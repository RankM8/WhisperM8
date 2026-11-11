import Darwin
import Foundation

/// Prüft die Chat-Identität eines Aufrufers gegen Claudes eigene Registry
/// (Befund D, 11.11.2026).
///
/// Claudes Daemon (`claude daemon run`) startet der erste Chat, der in den
/// Hintergrund geht — und der Daemon samt allen Workern, die er später startet,
/// erbt dessen Umgebung: `WHISPERM8_SESSION_ID` und `WHISPERM8_SESSION_TOKEN`
/// dieses einen Chats. Jeder Hintergrund-Agent, gleich aus welchem Chat, trat
/// danach unter dieser fremden Identität auf (belegt: Daemon 73520,
/// bg-pty-host 67732 und bg-spare 67815 trugen Fins ID).
///
/// Die Umgebung ist deshalb bei Hintergrund-Agents kein Beleg. Maßgeblich ist,
/// welcher Claude-Prozess den Aufruf trägt: der nächste Vorfahr mit einem
/// Registry-Eintrag (`<config>/sessions/<pid>.json`). Ist er ein
/// Hintergrund-Agent (`kind: "bg"`), gehört der Aufruf dem Chat, dessen
/// `externalSessionID` seine `sessionId` ist — oder keinem.
enum AgentCallerIdentityCheck {
    enum Verdict: Equatable {
        /// Die behauptete Identität passt (oder es gibt nichts zu prüfen).
        case keep
        /// Hintergrund-Agent mit fremder Identität: stattdessen dieser Chat
        /// (`nil` = keiner, Aufrufer gilt als extern).
        case replace(UUID?)
    }

    /// Pure Entscheidung.
    static func verdict(
        claimed: UUID?,
        record: ClaudeSessionRecord?,
        externalSessionIDOf: (UUID) -> String?,
        sessionForExternalID: (String) -> UUID?
    ) -> Verdict {
        guard let record, record.isBackground else { return .keep }
        if let claimed,
           externalSessionIDOf(claimed)?.caseInsensitiveCompare(record.sessionID) == .orderedSame {
            return .keep
        }
        let owner = sessionForExternalID(record.sessionID)
        return owner == claimed ? .keep : .replace(owner)
    }

    /// Der nächste Claude-Prozess in der Kette ab `pid` (inklusive), über alle
    /// Konten. `nil`, wenn kein Vorfahr in Claudes Registry steht.
    static func nearestClaudeRecord(
        startingAt pid: Int32,
        parentOf: (Int32) -> Int32? = { parentProcessID(of: $0) },
        recordFor: ((Int32) -> ClaudeSessionRecord?)? = nil,
        maxDepth: Int = 16
    ) -> ClaudeSessionRecord? {
        // Konten-Ordner einmal je Prüfung lesen, nicht je Vorfahr.
        let roots = recordFor == nil ? ClaudeSessionRegistry.roots() : []
        let recordFor = recordFor ?? { registryRecord(pid: $0, roots: roots) }
        var current = pid
        for _ in 0..<maxDepth {
            guard current > 1 else { return nil }
            if let record = recordFor(current) { return record }
            guard let parent = parentOf(current), parent != current else { return nil }
            current = parent
        }
        return nil
    }

    /// Registry-Eintrag genau dieses Prozesses (lebend), über alle Konten.
    static func registryRecord(pid: Int32, roots: [ClaudeSessionRegistry.Root]) -> ClaudeSessionRecord? {
        for root in roots {
            let url = root.url.appendingPathComponent("\(pid).json")
            if let record = ClaudeSessionRegistry.read(fileURL: url, profileName: root.profileName) {
                return record
            }
        }
        return nil
    }

    /// Elternprozess per `sysctl` (kein Subprozess).
    static func parentProcessID(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 0 ? parent : nil
    }

    /// Prozess-ID des Gegenübers eines Unix-Sockets (`LOCAL_PEERPID`).
    static func peerProcessID(socket fd: Int32) -> Int32? {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else { return nil }
        return pid
    }

    /// Workspace-Abfragen für `verdict` aus einer Sitzungsliste.
    static func lookups(sessions: [AgentChatSession]) -> (
        externalSessionIDOf: (UUID) -> String?, sessionForExternalID: (String) -> UUID?
    ) {
        var externalByID: [UUID: String] = [:]
        var holderByExternal: [String: AgentChatSession] = [:]
        for session in sessions where session.provider == .claude && session.status != .archived {
            guard let external = session.externalSessionID?.lowercased(), !external.isEmpty else { continue }
            externalByID[session.id] = external
            // Bei Doppeln führt der von Hand angelegte Chat (wie im Index-Merge).
            if let current = holderByExternal[external],
               !AgentSessionStore.prefersAsExternalHolder(session, over: current) {
                continue
            }
            holderByExternal[external] = session
        }
        let idByExternal = holderByExternal.mapValues(\.id)
        return ({ externalByID[$0] }, { idByExternal[$0.lowercased()] })
    }

    /// Prüfung für den Aufrufer DIESES Prozesses (CLI). Die Sitzungsliste wird
    /// nur geladen, wenn ein Hintergrund-Agent dahintersteht.
    static func checkCurrentProcess(
        claimed: UUID?,
        sessions: () -> [AgentChatSession]
    ) -> Verdict {
        guard let record = nearestClaudeRecord(startingAt: getpid()), record.isBackground else { return .keep }
        let lookup = lookups(sessions: sessions())
        return verdict(claimed: claimed, record: record,
                       externalSessionIDOf: lookup.externalSessionIDOf,
                       sessionForExternalID: lookup.sessionForExternalID)
    }
}
