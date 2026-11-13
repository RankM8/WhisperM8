import Darwin
import Foundation

/// Lebt der Codex-Prozess eines Chats, und seit wann? Eingabe für
/// `AgentTranscriptStatusDecider.decide`: Codex schreibt während einer Antwort
/// nichts ins Rollout, die Datei-Stille allein sagt deshalb nichts über Arbeit.
enum CodexProcessLiveness: Equatable {
    /// Kein Prozesswissen (Claude, Subagent-Jobs, Lesefehler): alte
    /// 120-s-Sicherung.
    case unknown
    case notRunning
    /// `since`: Startzeit des Prozesses; `nil`, wenn sie nicht lesbar war.
    case running(since: Date?)
}

extension CodexProcessLiveness {
    /// App: der Prozess im PTY des Chats (direktes Kind der App). `nil` →
    /// `.unknown`: ohne PTY weiß die App nichts über einen Prozess.
    static func of(pid: Int32?) -> CodexProcessLiveness {
        guard let pid, pid > 0 else { return .unknown }
        guard kill(pid, 0) == 0 || errno == EPERM else { return .notRunning }
        return .running(since: ProcessStartTime.of(pid: pid))
    }
}

/// CLI: welche Codex-Prozesse gehören zu welchem Chat? Die App gibt jedem
/// Chat-Prozess `WHISPERM8_SESSION_ID=<Chat-ID>` mit (`AgentTerminalView`);
/// die CLI kennt keine PTYs und liest deshalb die Umgebung der Codex-Prozesse.
/// Ein Lauf kostet so viel wie der Scan der Codex-Startsperre (gemessen
/// ~0,4 ms bei 580 Prozessen) und wird je CLI-Aufruf zwischengespeichert.
enum CodexChatProcessIndex {
    static let sessionEnvironmentKey = "WHISPERM8_SESSION_ID"

    /// Chat-ID → Startzeit des jüngsten Codex-Prozesses mit dieser ID.
    /// `nil`, wenn die Prozessliste oder ein lebender Codex-Prozess nicht
    /// lesbar war: Dann fehlt vielleicht genau der gesuchte, und „läuft
    /// nicht“ wäre geraten (Aufrufer fallen auf `.unknown` zurück).
    static func scan() -> [UUID: Date?]? {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return nil }
        var processes: [(sessionID: UUID, startedAt: Date?)] = []
        var name = [CChar](repeating: 0, count: 64)
        for pid in pids.prefix(Int(count)) where pid > 0 {
            guard proc_name(pid, &name, UInt32(name.count)) > 0,
                  CodexSessionRunningGuard.isCodexName(String(cString: name)) else { continue }
            guard let bytes = CodexSessionRunningGuard.procArgs(pid: pid) else {
                // Lebt, aber nicht lesbar → Index unbrauchbar. Zombies (schon
                // beendet, noch nicht abgeholt) sind lesbar tot: überspringen.
                if kill(pid, 0) == 0, !isZombie(pid) { return nil }
                continue
            }
            // Ein `codex exec`, den der Chat selbst startet (Subagent), erbt
            // dessen Chat-ID; er ist nicht der Chat-Prozess.
            guard isInteractiveRun(arguments: CodexSessionRunningGuard.parseProcArgs(bytes) ?? []),
                  let id = sessionID(inEnvironment: parseProcEnvironment(bytes)) else { continue }
            processes.append((id, ProcessStartTime.of(pid: pid)))
        }
        return index(processes)
    }

    /// Codex-Unterbefehle, die keine Chat-Oberfläche sind.
    static let nonInteractiveSubcommands: Set<String> = [
        "exec", "e", "app-server", "mcp-server", "mcp", "apply", "a", "login", "logout",
        "sandbox", "debug", "completion", "cloud", "features",
    ]
    /// Optionen mit eigenem Wert (`-a never exec` → Unterbefehl `exec`).
    static let optionsWithValue: Set<String> = [
        "-c", "--config", "-m", "--model", "-p", "--profile", "-s", "--sandbox",
        "-a", "--ask-for-approval", "-C", "--cd", "-i", "--image", "--add-dir",
        "--enable", "--disable", "--local-provider",
    ]

    /// Pur: Ist das die Chat-Oberfläche (`codex`, `codex resume <id>`,
    /// `codex <prompt>`) und kein Unterbefehl wie `exec`? Entscheidet das erste
    /// Argument, das keine Option und kein Optionswert ist.
    static func isInteractiveRun(arguments: [String]) -> Bool {
        var skipValue = false
        for argument in arguments {
            if skipValue { skipValue = false; continue }
            if argument == "--" { return true }
            if argument.hasPrefix("-") {
                skipValue = optionsWithValue.contains(argument)
                continue
            }
            return !nonInteractiveSubcommands.contains(argument)
        }
        return true
    }

    /// `KERN_PROCARGS2` schlägt für Zombies fehl, `kill(pid, 0)` aber nicht.
    /// `proc_pidinfo` liefert für Zombies nichts, `sysctl` mit `p_stat` schon.
    static func isZombie(_ pid: pid_t) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return false }
        return info.kp_proc.p_stat == SZOMB
    }

    /// Pur: je Chat der jüngste Prozess (ein auslaufender Vorgänger beim
    /// Neustart darf den neuen Lauf nicht verdecken).
    static func index(_ processes: [(sessionID: UUID, startedAt: Date?)]) -> [UUID: Date?] {
        var result: [UUID: Date?] = [:]
        for process in processes {
            if let existing = result[process.sessionID],
               (existing ?? .distantPast) >= (process.startedAt ?? .distantPast) { continue }
            result[process.sessionID] = process.startedAt
        }
        return result
    }

    /// Pur: Chat-ID aus der Umgebung eines Prozesses.
    static func sessionID(inEnvironment environment: [String]) -> UUID? {
        let prefix = sessionEnvironmentKey + "="
        guard let entry = environment.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        return UUID(uuidString: String(entry.dropFirst(prefix.count)))
    }

    /// Pur: die Umgebung aus einem `KERN_PROCARGS2`-Puffer — sie folgt auf
    /// argc, Programmpfad, Füll-Nullen und die argc Argumente.
    static func parseProcEnvironment(_ bytes: [UInt8]) -> [String] {
        guard bytes.count > 4 else { return [] }
        let argc = bytes.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        guard argc > 0 else { return [] }
        var index = 4
        while index < bytes.count, bytes[index] != 0 { index += 1 } // Programmpfad
        while index < bytes.count, bytes[index] == 0 { index += 1 } // Füllung
        var strings = 0
        while index < bytes.count, strings < argc { // argv
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            index += 1
            strings += 1
        }
        var environment: [String] = []
        while index < bytes.count, bytes[index] != 0 {
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            environment.append(String(decoding: bytes[start..<index], as: UTF8.self))
            index += 1
        }
        return environment
    }
}

extension CodexProcessLiveness {
    /// CLI: aus dem Prozess-Index für einen Chat. Ohne Index (Liste nicht
    /// lesbar) `.unknown`.
    static func of(sessionID: UUID, index: [UUID: Date?]?) -> CodexProcessLiveness {
        guard let index else { return .unknown }
        guard let entry = index[sessionID] else { return .notRunning }
        return .running(since: entry)
    }
}
