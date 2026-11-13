import Darwin
import Foundation

/// Ein laufender `codex`-Prozess mit seinen Startargumenten.
struct CodexProcess: Equatable {
    let pid: Int32
    /// Sitzungsführer (`getsid`): Der PTY-Prozess eines Chats ist per
    /// `forkpty` Sitzungsführer, egal wie viele Wrapper (Node, Volta)
    /// dazwischen liegen.
    let sessionLeader: Int32
    /// `argv` ohne den Programmpfad.
    let arguments: [String]
    /// Hängt an einem Terminal (sonst etwa ein verwaister Subagent-Job).
    var hasTerminal: Bool = true
}

/// Wo eine Codex-Sitzung schon läuft.
enum CodexRunningConflict: Equatable {
    case otherChat(title: String)
    /// Der Prozess eines gerade geschlossenen Chats läuft noch aus.
    case otherChatEnding(title: String)
    case outsideApp(pid: Int32, inTerminal: Bool)
}

/// Doppelstart-Sperre für Codex (nie zwei Prozesse auf einer Sitzung).
///
/// Codex führt keine Registry wie Claude: Keine Lock- oder PID-Datei je
/// Thread, in `state_5.sqlite` nur Zeitstempel (Recherche 13.11.2026). Belegt
/// ist ein laufender Prozess deshalb nur auf zwei Wegen:
/// 1. die eigenen laufenden Chats der App (Controller je Chat), und
/// 2. die Startargumente aller `codex`-Prozesse: `codex resume … <id>` (TUI)
///    und `codex … exec resume … <id>` (Subagent-Jobs). Der Node-Wrapper
///    `codex.js` startet das eigentliche Programm `codex` mit denselben
///    Argumenten; gelesen werden nur Prozesse dieses Namens.
///
/// Im Zweifel wird nicht gesperrt: Lässt sich die Prozessliste nicht lesen,
/// startet der Chat wie bisher. Grenzen der Argumente: Ein fremdes Codex, das
/// in der TUI per `/resume` auf diese Sitzung gewechselt hat, bleibt
/// unsichtbar; eines, das von ihr weggewechselt hat (`/new`, `/resume`),
/// sperrt weiter, bis es endet — die Meldung nennt seine PID. Threads, die im
/// gemeinsamen Hintergrunddienst laufen (Codex-App, IDE), sieht die Prüfung
/// nicht.
enum CodexSessionRunningGuard {
    /// Setzt der Prozess diese Sitzung fort?
    static func resumes(_ process: CodexProcess, sessionID: String) -> Bool {
        guard !sessionID.isEmpty, process.arguments.contains("resume") else { return false }
        return process.arguments.contains { $0.caseInsensitiveCompare(sessionID) == .orderedSame }
    }

    /// Die fortgesetzte ID aus einem Startkommando der App (`codex resume … <id>`).
    static func resumedID(inLaunchArguments arguments: [String]) -> String? {
        arguments.first == "resume" ? arguments.last : nil
    }

    /// Ein laufender Chat der App (jeder Anbieter, auch Terminal-Tabs):
    /// lokale ID, Titel, Codex-Sitzung (nur bei Codex-Chats), PTY-Prozess.
    struct AppChat: Equatable {
        let id: UUID
        let title: String
        let sessionID: String?
        let processID: Int32?
    }

    /// Pur: die laufenden Controller als `AppChat`. Bei Codex-Chats zählt die
    /// beim Start fortgesetzte ID vor der gebundenen.
    static func appChats(
        controllers: [(sessionID: UUID, arguments: [String], processID: Int32?)],
        sessions: [UUID: AgentChatSession]
    ) -> [AppChat] {
        controllers.compactMap { controller in
            guard let session = sessions[controller.sessionID] else { return nil }
            let codexID = session.provider == .codex && !session.isTerminal
                ? resumedID(inLaunchArguments: controller.arguments) ?? session.externalSessionID
                : nil
            let title = session.title.isEmpty ? String(session.id.uuidString.prefix(8)).lowercased() : session.title
            return AppChat(id: controller.sessionID, title: title, sessionID: codexID, processID: controller.processID)
        }
    }

    /// Pur: Läuft die Sitzung schon, und wo?
    /// - Parameters:
    ///   - appChats: die laufenden Chats der App (ohne den startenden).
    ///   - processes: die `codex`-Prozesse; `nil`, wenn das Lesen scheiterte —
    ///     dann zählt nur die eigene Tabelle.
    ///   - terminatingOwner: Chat, dessen Prozess die App gerade beendet.
    static func conflict(
        sessionID: String,
        localID: UUID,
        appChats: [AppChat],
        processes: [CodexProcess]?,
        terminatingOwner: (Int32) -> UUID?,
        titleOf: (UUID) -> String
    ) -> CodexRunningConflict? {
        let others = appChats.filter { $0.id != localID }
        if let chat = others.first(where: {
            $0.sessionID.map { $0.caseInsensitiveCompare(sessionID) == .orderedSame } == true
        }) {
            return .otherChat(title: chat.title)
        }
        guard let processes else { return nil }
        let chatByPID = Dictionary(appChats.compactMap { chat in chat.processID.map { ($0, chat) } },
                                   uniquingKeysWith: { first, _ in first })
        for process in processes where resumes(process, sessionID: sessionID) {
            // Gerade beendet: der eigene Vorgänger (Tab-Neustart) läuft aus und
            // sperrt nicht; der eines anderen Chats schreibt noch und sperrt.
            if let owner = terminatingOwner(process.pid) ?? terminatingOwner(process.sessionLeader) {
                if owner == localID { continue }
                return .otherChatEnding(title: titleOf(owner))
            }
            // Prozess eines Chats der App (über den Sitzungsführer auch hinter Wrappern)?
            if let chat = chatByPID[process.pid] ?? chatByPID[process.sessionLeader] {
                if chat.id == localID { continue }
                return .otherChat(title: chat.title)
            }
            return .outsideApp(pid: process.pid, inTerminal: process.hasTerminal)
        }
        return nil
    }

    // MARK: Prozesse lesen

    /// Alle `codex`-Prozesse mit Argumenten. Nicht auf dem Main Thread
    /// aufrufen. Nur im App-Prozess (unter `swift test` und in der CLI leer,
    /// damit kein Test von zufällig laufenden Codex-Prozessen abhängt).
    /// `nil`, wenn die Prozessliste nicht lesbar ist (dann nicht sperren).
    static func liveCodexProcesses() -> [CodexProcess]? {
        guard AppInstance.isAppBundleProcess else { return [] }
        return readCodexProcesses()
    }

    /// Ohne Abschaltung (für Messungen); siehe `liveCodexProcesses`.
    static func readCodexProcesses() -> [CodexProcess]? {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return nil }
        var result: [CodexProcess] = []
        var name = [CChar](repeating: 0, count: 64)
        for pid in pids.prefix(Int(count)) where pid > 0 {
            guard proc_name(pid, &name, UInt32(name.count)) > 0,
                  isCodexName(String(cString: name)),
                  let arguments = arguments(of: pid) else { continue }
            var info = proc_bsdinfo()
            let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
            let hasTerminal = size == Int32(MemoryLayout<proc_bsdinfo>.size) ? info.e_tdev != UInt32(bitPattern: -1) : true
            result.append(CodexProcess(pid: pid, sessionLeader: getsid(pid), arguments: arguments,
                                       hasTerminal: hasTerminal))
        }
        return result
    }

    /// `codex` (npm-Symlink, Cask) oder umbenannte Builds wie
    /// `codex-aarch64-apple-darwin`. Hilfsprozesse mit eigenem Namen tragen
    /// kein `resume <id>` und fallen bei `resumes` heraus.
    static func isCodexName(_ name: String) -> Bool {
        name == "codex" || name.hasPrefix("codex-")
    }

    /// `argv` ohne Programmpfad aus `KERN_PROCARGS2`.
    private static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var argMax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, 2, &argMax, &size, nil, 0) == 0, argMax > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(argMax))
        size = buffer.count
        mib = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        return parseProcArgs(Array(buffer.prefix(size)))
    }

    /// Pur: `argc`, Programmpfad, Füll-Nullen, dann `argc` Argumente.
    static func parseProcArgs(_ bytes: [UInt8]) -> [String]? {
        guard bytes.count > 4 else { return nil }
        let argc = bytes.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        guard argc > 0 else { return nil }
        var index = 4
        while index < bytes.count, bytes[index] != 0 { index += 1 } // Programmpfad
        while index < bytes.count, bytes[index] == 0 { index += 1 } // Füllung
        var argv: [String] = []
        while index < bytes.count, argv.count < argc {
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            argv.append(String(decoding: bytes[start..<index], as: UTF8.self))
            index += 1
        }
        return argv.count == argc ? Array(argv.dropFirst()) : nil
    }
}
