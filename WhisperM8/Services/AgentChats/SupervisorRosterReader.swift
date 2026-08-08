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
    }

    static func rosterURL(configDir: URL) -> URL {
        configDir
            .appendingPathComponent("daemon", isDirectory: true)
            .appendingPathComponent("roster.json", isDirectory: false)
    }

    /// Short-ID des lebendigen Workers, der `sessionID` gerade hostet —
    /// `nil` wenn die Session nicht (mehr) als Background-Agent laeuft.
    static func activeWorkerShortID(
        forSessionID sessionID: String,
        configDir: URL,
        isProcessAlive: (Int32) -> Bool = defaultIsProcessAlive
    ) -> String? {
        guard let data = try? Data(contentsOf: rosterURL(configDir: configDir)) else {
            return nil
        }
        return workers(fromRosterData: data)
            .first {
                $0.sessionID.caseInsensitiveCompare(sessionID) == .orderedSame
                    && isProcessAlive($0.pid)
            }?
            .shortID
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
                cwd: value["cwd"] as? String
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
