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
    /// Startzeiten (µs seit 1970) des Prozesses und seines Sitzungsführers.
    var startTime: UInt64?
    var leaderStartTime: UInt64?
}

/// Ein Prozess, den der Nutzer per „Prozess beenden“ beenden darf: Vor jedem
/// Signal wird geprüft, dass unter der PID noch derselbe Prozess läuft
/// (Name `codex`, `resume <id>`, gleiche Startzeit).
struct CodexProcessTarget: Equatable {
    let pid: Int32
    let startTime: UInt64?
    let sessionID: String
}

/// Wo eine Codex-Sitzung schon läuft.
enum CodexRunningConflict: Equatable {
    case otherChat(title: String)
    /// Der Prozess eines gerade geschlossenen Chats läuft noch aus.
    case otherChatEnding(title: String, process: CodexProcessTarget)
    /// Der vorige Lauf dieses Chats endet länger als erwartet (> 30 s).
    case ownPreviousRun(process: CodexProcessTarget)
    case outsideApp(process: CodexProcessTarget, inTerminal: Bool)

    /// Der Prozess, den „Prozess beenden“ anbieten darf: nicht bei einem
    /// laufenden Chat der App (den schließt man dort) und nur mit bekannter
    /// Startzeit, damit die Prüfung vor dem Signal vollständig ist.
    var endableProcess: CodexProcessTarget? {
        let process: CodexProcessTarget
        switch self {
        case .otherChat: return nil
        case .otherChatEnding(_, let target), .ownPreviousRun(let target), .outsideApp(let target, _): process = target
        }
        return process.startTime == nil ? nil : process
    }

    /// Vic: Ein Codex im Terminal kann seit dem Start per `/new` oder
    /// `/resume` an etwas anderem arbeiten, die Startargumente bleiben. Vor
    /// dem Beenden deshalb fragen; die anderen Fälle gehören sicher zu
    /// dieser Sitzung oder zu einem beendeten Chat.
    var endNeedsConfirmation: Bool {
        if case .outsideApp(_, true) = self { return true }
        return false
    }
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
    ///   - terminatingOwner: Chat, dessen Prozess die App gerade beendet (30 s).
    ///   - formerOwner: Chat, dessen Prozess die App früher beendet hat (bis 24 h).
    static func conflict(
        sessionID: String,
        localID: UUID,
        appChats: [AppChat],
        processes: [CodexProcess]?,
        terminatingOwner: (_ pid: Int32, _ startTime: UInt64?) -> UUID?,
        formerOwner: (_ pid: Int32, _ startTime: UInt64?) -> UUID? = { _, _ in nil },
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
            let target = CodexProcessTarget(pid: process.pid, startTime: process.startTime, sessionID: sessionID)
            // Gerade beendet: der eigene Vorgänger (Tab-Neustart) läuft aus und
            // sperrt nicht; der eines anderen Chats schreibt noch und sperrt.
            if let owner = terminatingOwner(process.pid, process.startTime)
                ?? terminatingOwner(process.sessionLeader, process.leaderStartTime) {
                if owner == localID { continue }
                return .otherChatEnding(title: titleOf(owner), process: target)
            }
            // Prozess eines laufenden Chats der App (über den Sitzungsführer auch
            // hinter Wrappern)? Geht vor dem 24-h-Verlauf: Ein lebender Chat
            // darf nie als „beendeter Lauf“ mit Beenden-Knopf erscheinen.
            if let chat = chatByPID[process.pid] ?? chatByPID[process.sessionLeader] {
                if chat.id == localID { continue }
                return .otherChat(title: chat.title)
            }
            // Länger als das Fenster: sperrt, aber mit der richtigen Zuordnung
            // statt „außerhalb von WhisperM8“ (Startzeit gegen neu vergebene PIDs).
            if let owner = formerOwner(process.pid, process.startTime)
                ?? formerOwner(process.sessionLeader, process.leaderStartTime) {
                return owner == localID
                    ? .ownPreviousRun(process: target)
                    : .otherChatEnding(title: titleOf(owner), process: target)
            }
            return .outsideApp(process: target, inTerminal: process.hasTerminal)
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
                  let process = readProcess(pid: pid) else { continue }
            result.append(process)
        }
        return result
    }

    /// Ein einzelner Prozess mit Argumenten, Terminal und Startzeiten; `nil`,
    /// wenn er nicht (mehr) lesbar ist. Prüft den Namen nicht.
    static func readProcess(pid: Int32) -> CodexProcess? {
        guard let arguments = arguments(of: pid) else { return nil }
        var info = proc_bsdinfo()
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        let readable = size == Int32(MemoryLayout<proc_bsdinfo>.size)
        let leader = getsid(pid)
        return CodexProcess(
            pid: pid, sessionLeader: leader, arguments: arguments,
            hasTerminal: readable ? info.e_tdev != UInt32(bitPattern: -1) : true,
            startTime: ProcessStartTime.microseconds(pid: pid),
            leaderStartTime: ProcessStartTime.microseconds(pid: leader))
    }

    /// Läuft unter der PID noch genau der Prozess, den die Meldung nannte?
    static func isStillTarget(_ target: CodexProcessTarget, current: CodexProcess?, currentName: String?) -> Bool {
        guard let current, current.pid == target.pid,
              let currentName, isCodexName(currentName),
              resumes(current, sessionID: target.sessionID) else { return false }
        guard let expected = target.startTime else { return true }
        return current.startTime == expected
    }

    /// Der Prozessname zu einer PID (`proc_name`), `nil` wenn nicht lesbar.
    static func processName(pid: Int32) -> String? {
        var name = [CChar](repeating: 0, count: 64)
        guard proc_name(pid, &name, UInt32(name.count)) > 0 else { return nil }
        return String(cString: name)
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

/// „Prozess beenden“ aus der Sperr-Meldung. Zuerst nur SIGTERM: Codex kann
/// den Verlauf sauber zu Ende schreiben. SIGKILL gibt es nur als zweiten,
/// ausdrücklich bestätigten Schritt, wenn der Prozess nach SIGTERM nicht
/// endet — ohne ihn säße ein Nutzer bei einem hängenden Prozess fest, ein
/// SIGKILL ohne Rückfrage könnte eine halb geschriebene Verlaufszeile
/// hinterlassen. Vor jedem Signal wird geprüft, dass unter der PID noch
/// derselbe Prozess läuft (Name, `resume <id>`, Startzeit).
struct CodexProcessTerminator {
    enum Outcome: Equatable {
        case ended
        case stillRunning
        /// Unter der PID läuft inzwischen etwas anderes: kein Signal gesendet.
        case notTheSameProcess
        /// Das Signal ging nicht raus (etwa keine Berechtigung).
        case signalFailed(errno: Int32)
    }

    var read: (Int32) -> (process: CodexProcess?, name: String?) = { pid in
        (CodexSessionRunningGuard.readProcess(pid: pid), CodexSessionRunningGuard.processName(pid: pid))
    }
    var signal: (Int32, Int32) -> Int32 = { kill($0, $1) }
    var hasExited: (Int32) -> Bool = { ProcessExitWaiter.hasExited(pid: $0) }
    var waitForExit: (Int32, TimeInterval) async -> Bool = { pid, timeout in
        await ProcessExitWaiter.waitForExit(pid: pid, timeout: timeout)
    }

    func end(_ target: CodexProcessTarget, force: Bool) async -> Outcome {
        if hasExited(target.pid) { return .ended }
        let current = read(target.pid)
        guard CodexSessionRunningGuard.isStillTarget(target, current: current.process, currentName: current.name) else {
            return hasExited(target.pid) ? .ended : .notTheSameProcess
        }
        guard signal(target.pid, force ? SIGKILL : SIGTERM) == 0 else {
            let error = errno
            return hasExited(target.pid) ? .ended : .signalFailed(errno: error)
        }
        return await waitForExit(target.pid, 3) ? .ended : .stillRunning
    }
}
