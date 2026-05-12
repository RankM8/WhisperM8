import Foundation

/// Snapshot eines vom Claude-Supervisor verwalteten Background-Jobs aus
/// `~/.claude/jobs/<short-id>/state.json`. Das Format ist
/// Anthropic-Implementation-Detail (nicht stabil dokumentiert) — wir parsen
/// defensiv und nehmen nur die Felder, die wir wirklich brauchen.
struct SupervisorJobState: Equatable {
    /// Short-ID (8-stelliger Hex), gleichzeitig der Directory-Name unter
    /// `~/.claude/jobs/`.
    let shortID: String
    /// Vom Supervisor gepflegter Anzeigename (entweder vom Auto-Namer oder
    /// dem User manuell vergeben). Fallback: der `intent`.
    let name: String?
    /// Initialer Prompt — wird angezeigt wenn `name` leer ist.
    let intent: String?
    /// Working-Directory des Sub-Chats (kann ein Worktree-Pfad sein).
    let cwd: String
    /// Lebenszyklus-State der TUI: "working" / "done" / "blocked" / etc.
    /// Wir benutzen den Wert primaer fuer Status-Indikatoren.
    let state: String?
    /// Pfad zur JSONL-Datei dieser Session — die mtime des Files ist die
    /// "wann hat sich hier zuletzt was getan"-Wahrheit.
    let linkScanPath: String?
    /// Vom Supervisor gepflegter `updatedAt`-Zeitstempel im state.json.
    /// Manche Build-Varianten setzen den nicht zuverlaessig — nicht
    /// allein darauf verlassen, sondern lieber `linkScanPath.mtime`
    /// nehmen.
    let updatedAt: Date?
}

/// Reader fuer einzelne `state.json`-Files. Trennt File-IO vom Pure-Parser,
/// damit Tests komplett ohne Disk laufen koennen.
enum SupervisorJobReader {
    /// Default-Verzeichnis fuer Jobs. Sucht `~/.claude/jobs/`.
    static var defaultJobsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/jobs", isDirectory: true)
    }

    /// Liest alle Job-State-Files aus dem Jobs-Directory. Subdirectories
    /// mit ungueltigem state.json werden uebersprungen, niemals geworfen.
    static func readAll(from directory: URL = defaultJobsDirectory) -> [SupervisorJobState] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var result: [SupervisorJobState] = []
        for entry in entries {
            // Wir skippen Files (wie pins.json) — Jobs sind Directories.
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                continue
            }
            let stateURL = entry.appendingPathComponent("state.json")
            guard let state = readSingle(stateFileURL: stateURL, shortID: entry.lastPathComponent) else {
                continue
            }
            result.append(state)
        }
        return result
    }

    /// Liest ein einzelnes state.json — `shortID` kommt aus dem
    /// Directory-Namen (kanonisch). Liefert `nil` bei IO- oder Parse-Fehler.
    static func readSingle(stateFileURL: URL, shortID: String) -> SupervisorJobState? {
        guard let data = try? Data(contentsOf: stateFileURL) else { return nil }
        return parse(data: data, shortIDFallback: shortID)
    }

    /// Pure Parser — nimmt JSON-Bytes + den Short-ID-Fallback (aus dem
    /// Directory-Namen) und liefert ein `SupervisorJobState`. Bei
    /// fehlendem `cwd` (Pflichtfeld) gibt es `nil`.
    static func parse(data: Data, shortIDFallback: String) -> SupervisorJobState? {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let short = (raw["daemonShort"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? shortIDFallback
        guard !short.isEmpty else { return nil }
        guard let cwd = raw["cwd"] as? String, !cwd.isEmpty else { return nil }
        let name = (raw["name"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let intent = (raw["intent"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let state = (raw["state"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let linkScanPath = (raw["linkScanPath"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let updatedAt = parseISODate(raw["updatedAt"] as? String)
        return SupervisorJobState(
            shortID: short,
            name: name,
            intent: intent,
            cwd: cwd,
            state: state,
            linkScanPath: linkScanPath,
            updatedAt: updatedAt
        )
    }

    /// Findet den Job mit der juengsten Aktivitaet auf seiner JSONL-Datei.
    /// "juengste Aktivitaet" = `linkScanPath.mtime` maximal. Faellt zurueck
    /// auf den state.json-`updatedAt`-Wert, wenn die JSONL nicht zugreifbar
    /// ist (z. B. weil sie geloescht wurde).
    ///
    /// `recencyWindow` (Default 60 s) blendet alles aus, was laenger nicht
    /// mehr geschrieben wurde — sonst wuerde der Header eine "aktive
    /// Session" zeigen, in der sich seit 2 Stunden nichts mehr tut.
    static func mostRecentlyActive(
        among jobs: [SupervisorJobState],
        within recencyWindow: TimeInterval = 60,
        now: Date = Date(),
        modificationDate: (URL) -> Date? = { Self.modificationDate(at: $0) }
    ) -> SupervisorJobState? {
        var best: (job: SupervisorJobState, mtime: Date)?
        for job in jobs {
            let mtime: Date
            if let path = job.linkScanPath,
               let date = modificationDate(URL(fileURLWithPath: path)) {
                mtime = date
            } else if let date = job.updatedAt {
                mtime = date
            } else {
                continue
            }
            // Recency-Filter: zu alte Sessions ignorieren.
            guard now.timeIntervalSince(mtime) <= recencyWindow else { continue }
            if best == nil || mtime > best!.mtime {
                best = (job, mtime)
            }
        }
        return best?.job
    }

    /// Liest die mtime einer JSONL-Datei — gibt `nil` bei IO-Fehler oder
    /// wenn das File nicht existiert.
    static func modificationDate(at url: URL) -> Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return attrs[.modificationDate] as? Date
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoFormatterWithoutFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Parsed ISO-8601-Strings tolerant gegenueber Fractional-Seconds
    /// (`2026-05-12T18:11:14.327Z`) und ohne.
    static func parseISODate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        if let date = isoFormatter.date(from: raw) { return date }
        if let date = isoFormatterWithoutFractional.date(from: raw) { return date }
        return nil
    }
}
