import Foundation

/// Liest das Worker-Verzeichnis des Claude-Supervisor-Daemons
/// (`<config-dir>/daemon/roster.json`). Der Supervisor fuehrt dort ALLE
/// aktuell gehosteten Background-Sessions: Short-ID → PID, volle
/// Session-ID, cwd — auch solche, die NICHT via `claude --bg` gespawnt
/// wurden, sondern aus einer interaktiven Session heraus gebackgroundet
/// (Left-Arrow / `/background`). Letztere haben KEIN
/// `~/.claude/jobs/<short-id>`-Verzeichnis, der `SupervisorJobReader`
/// sieht sie deshalb nicht; dieser Reader schon.
///
/// Nutzung: Resume→Attach-Fallback im `AgentCommandBuilder`. Eine Session,
/// die hier mit lebendigem Worker-Prozess steht, wuerde `claude --resume`
/// mit "currently running as a background agent" ablehnen — statt den User
/// in die CLI zu schicken, attached WhisperM8 direkt an den Worker.
///
/// Roster-Eintraege koennen stale sein (Daemon-/Worker-Crash raeumt die
/// Datei nicht immer auf) — deshalb zaehlt ein Eintrag nur, wenn sein
/// Worker-PID noch lebt.
enum SupervisorRosterReader {
    struct Worker: Equatable {
        var shortID: String
        var sessionID: String
        var pid: Int32
        var cwd: String?
        /// Hat der Daemon den Worker als Abzweig eines anderen Verlaufs neu
        /// gestartet (`dispatch.source = "respawn"`, `launch.fork = true`),
        /// steht hier die Session-ID des Ursprungs. Der Worker läuft dann
        /// unter einer NEUEN ID weiter (Befund 11.11.2026: Jarvis 64306879 →
        /// Kopie 84ca7666).
        var forkedFromSessionID: String? = nil
        var startedAt: Date? = nil
    }

    /// Ziel für `claude attach`: Short-ID und die Session-ID, unter der der
    /// Agent die Unterhaltung gerade führt (bei einem Abzweig ≠ der
    /// angefragten ID — der Chat wird dann umgebunden).
    struct WorkerMatch: Equatable {
        var shortID: String
        var sessionID: String
    }

    static func rosterURL(configDir: URL) -> URL {
        configDir
            .appendingPathComponent("daemon", isDirectory: true)
            .appendingPathComponent("roster.json", isDirectory: false)
    }

    /// Short-ID des lebendigen Workers, der `sessionID` gerade hostet —
    /// `nil` wenn die Session nicht (mehr) als Background-Agent laeuft.
    /// Lebt der Worker im Roster, wird angehaengt — auch wenn Claudes
    /// Registry-Eintrag (noch) fehlt (direkt nach `/background`, beim
    /// Respawn). Ein `--resume` wuerde Claude dann ablehnen (Review-Befund
    /// 11.11.2026).
    static func activeWorkerShortID(
        forSessionID sessionID: String,
        configDir: URL,
        isProcessAlive: (Int32) -> Bool = defaultIsProcessAlive
    ) -> String? {
        guard let data = try? Data(contentsOf: rosterURL(configDir: configDir)) else {
            return nil
        }
        return workers(fromRosterData: data).first(where: {
            $0.sessionID.caseInsensitiveCompare(sessionID) == .orderedSame
                && isProcessAlive($0.pid)
        })?.shortID
    }

    /// Ziel fuer `claude attach`: erst der Roster (die Session selbst, sonst
    /// der juengste Daemon-Abzweig von ihr); fehlt dort beides, der `jobId`
    /// eines lebenden Registry-Eintrags mit `kind: "bg"`. Nur wenn alles
    /// nichts kennt, gibt der Builder `--resume` frei.
    static func attachTarget(
        forSessionID sessionID: String,
        configDir: URL,
        isProcessAlive: (Int32) -> Bool = defaultIsProcessAlive,
        registryJobID: ((String) -> String?)? = nil
    ) -> WorkerMatch? {
        if let data = try? Data(contentsOf: rosterURL(configDir: configDir)),
           let found = match(forSessionID: sessionID, workers: workers(fromRosterData: data), isProcessAlive: isProcessAlive) {
            return found
        }
        let lookup = registryJobID ?? { id in liveBackgroundJobID(forSessionID: id, configDir: configDir) }
        return lookup(sessionID).map { WorkerMatch(shortID: $0, sessionID: sessionID) }
    }

    /// Pure Auswahl im Roster: erst der Worker der Session selbst, sonst der
    /// juengste lebende Abzweig GENAU dieser Session.
    static func match(
        forSessionID sessionID: String,
        workers: [Worker],
        isProcessAlive: (Int32) -> Bool
    ) -> WorkerMatch? {
        func same(_ lhs: String?) -> Bool { lhs?.caseInsensitiveCompare(sessionID) == .orderedSame }
        if let direct = workers.first(where: { same($0.sessionID) && isProcessAlive($0.pid) }) {
            return WorkerMatch(shortID: direct.shortID, sessionID: direct.sessionID)
        }
        return workers
            .filter { same($0.forkedFromSessionID) && isProcessAlive($0.pid) }
            .max { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
            .map { WorkerMatch(shortID: $0.shortID, sessionID: $0.sessionID) }
    }

    /// Ursprung eines Daemon-Abzweigs aus dem `dispatch`-Block. `launch.sessionId`
    /// ist ein Transcript-Pfad (`…/<id>.jsonl`) oder eine nackte ID.
    static func forkOrigin(fromDispatch dispatch: Any?) -> String? {
        guard let dispatch = dispatch as? [String: Any],
              let launch = dispatch["launch"] as? [String: Any],
              (launch["fork"] as? Bool) == true,
              let raw = launch["sessionId"] as? String, !raw.isEmpty else { return nil }
        var name = (raw as NSString).lastPathComponent
        if name.hasSuffix(".jsonl") { name = String(name.dropLast(6)) }
        return name.isEmpty ? nil : name
    }

    /// Alle lebenden Abzweige aller Konten: neue Session-ID → Ursprung (beides
    /// klein geschrieben). Fuer den Index-Merge, der Kopien nicht als neue
    /// Chats anlegen soll.
    static func liveForkOrigins(
        configDirs: [URL],
        isProcessAlive: (Int32) -> Bool = defaultIsProcessAlive
    ) -> [String: String] {
        var result: [String: String] = [:]
        for configDir in configDirs {
            guard let data = try? Data(contentsOf: rosterURL(configDir: configDir)) else { continue }
            for worker in workers(fromRosterData: data) where isProcessAlive(worker.pid) {
                if let origin = worker.forkedFromSessionID {
                    result[worker.sessionID.lowercased()] = origin.lowercased()
                }
            }
        }
        return result
    }

    /// `jobId` eines lebenden Hintergrund-Eintrags (`kind: "bg"`) in
    /// `<configDir>/sessions/` fuer diese Session.
    static func liveBackgroundJobID(
        forSessionID sessionID: String,
        configDir: URL,
        isAlive: ClaudeSessionRegistry.LivenessCheck = ClaudeSessionRegistry.isProcessAlive
    ) -> String? {
        let root = ClaudeSessionRegistry.Root(
            profileName: "",
            url: configDir.appendingPathComponent("sessions", isDirectory: true)
        )
        return ClaudeSessionRegistry.scan(roots: [root], isAlive: isAlive).first {
            $0.isBackground && $0.sessionID.caseInsensitiveCompare(sessionID) == .orderedSame
        }?.jobID.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Pure Decode — testbar ohne Filesystem. Unbekannte Felder werden
    /// ignoriert, defekte Eintraege uebersprungen.
    static func workers(fromRosterData data: Data) -> [Worker] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let workers = object["workers"] as? [String: [String: Any]] else {
            return []
        }
        return workers.compactMap { shortID, value in
            guard let sessionID = value["sessionId"] as? String,
                  let pid = value["pid"] as? NSNumber else {
                return nil
            }
            return Worker(
                shortID: shortID,
                sessionID: sessionID,
                pid: pid.int32Value,
                cwd: value["cwd"] as? String,
                forkedFromSessionID: forkOrigin(fromDispatch: value["dispatch"]),
                startedAt: (value["startedAt"] as? NSNumber).map {
                    Date(timeIntervalSince1970: $0.doubleValue / 1000)
                }
            )
        }
    }

    /// `kill(pid, 0)` prueft Existenz ohne Signalzustellung. EPERM hiesse
    /// "existiert, gehoert jemand anderem" — Supervisor-Worker laufen immer
    /// als derselbe User, deshalb reicht der 0-Vergleich.
    static func defaultIsProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0
    }
}
